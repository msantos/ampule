## Copyright (c) 2014, Michael Santos <michael.santos@gmail.com>
## Permission to use, copy, modify, and/or distribute this software for any
## purpose with or without fee is hereby granted, provided that the above
## copyright notice and this permission notice appear in all copies.
##
## THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
## WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
## MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
## ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
## WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
## ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
## OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

defrecord :container, Record.extract(:container, from: "deps/erlxc/include/erlxc.hrl")
defrecord Container, container: nil, nodename: nil, destroy: false

defmodule Ampule do
  @utsname "@ampule########"

  def create(name \\ @utsname, options \\ []) do
    options = Ampule.Chroot.new(options)
    container = :erlxc.spawn name, options
    true = :liblxc.wait(:erlxc.container(container), "RUNNING", 0)
    Container.new [container: container]
  end

  def spawn(name \\ @utsname, options \\ []) do
    case Node.alive? do
      true -> true
      false ->
        distname = :erlxc.name("ampule##") |> binary_to_atom
        distribute!(distname)
    end

    options = options
              |> Ampule.Chroot.new
              |> Ampule.Chroot.sandbox

    container = create(name, options)
    nodename = nodename(container.container)
    ping nodename
    container.update(nodename: nodename)
  end

  def distribute!(nodename) do
    true = case :net_kernel.start([nodename]) do
      {:ok, _} ->
        cookie = :erlxc.name("########") |> binary_to_atom
        Node.set_cookie(cookie)
      {:error, {:already_started, _}} ->
        true
      {:error, {{:already_started, _}, _}} ->
        true
      error ->
        error
    end
  end

  defp nodename(container) do
    port = :erlxc.container container
    case :liblxc.get_ips(port, "", "", 0) do
      [] -> nodename container
      [ip|_] -> :"ampule@#{ip}"
    end
  end

  defp ping(nodename) do
    case Node.connect(nodename) do
      true ->
        true
      false ->
        ping nodename
    end
  end

  def call(mfa) do
    container = Ampule.spawn
    call mfa, container.update(destroy: true)
  end

  def call({m,f,a}, container = Container[nodename: nodename]) do
    reply = :rpc.call nodename, m, f, a
    destroy container
    reply
  end

  def callopt(mfa, options) do
    container = Ampule.spawn(@utsname, options)
    call mfa, container.update(destroy: true)
  end

  defp destroy(Container[container: container, destroy: true]) do
    :erlxc_drv.stop :erlxc.container(container)
  end

  defp destroy(_container) do
    true
  end

  def mfa(a,m,f,v \\ []) do
    {m,f,[a|v]}
  end

  def console(data, Container[container: container]) do
    :erlxc.send container, data
  end

  defmodule Chroot do
    def new(options \\ []) do
      options = ListDict.put_new(options, :uid, Ampule.Chroot.id)

      uid = ListDict.fetch!(options, :uid)

      options = ListDict.put_new(options, :gid, uid)
      options = ListDict.put_new(options, :cgroup, cgroup())
      ListDict.put_new(options, :path, "/tmp/ampule")
    end
  
    def sandbox(options) do
      uid = ListDict.fetch!(options, :uid)
      gid = ListDict.fetch!(options, :gid)

      cookie = ListDict.get(options, :cookie, Node.get_cookie)
      bridge = ListDict.get(options, :bridge, "br0")
      ipaddr = ListDict.get(options, :ipaddr, "dhcp")

      cmd = "erl -pa /priv -noinput -setcookie #{cookie} -name ampule@$ip"
      argv = ["/ampule", ipaddr, "#{uid}", "#{gid}", cmd]
      options = ListDict.put(options, :start, [argv: argv])

      config = ListDict.get(options, :config, Ampule.Chroot.config)

      priv = Path.join(:code.priv_dir(:ampule), "share")
      File.mkdir_p!(priv)

      config = config ++ [
        {"lxc.network.type", "veth"},
        {"lxc.network.flags", "up"},
        {"lxc.network.link", bridge},
        {"lxc.mount.entry", "#{priv} priv none ro,bind,nosuid 0 0"},
        {"lxc.mount.entry", "tmpfs home/ampule tmpfs uid=#{uid},gid=#{gid},noatime,mode=1777,nosuid,size=128M 0 0"}
        ]

      config = config ++  case ipaddr(ipaddr) do
        "dhcp" -> []
        {:ok, {_,_,_,_}} -> [{"lxc.network.ipv4", ipaddr}]
        {:ok, {_,_,_,_,_,_,_,_}} -> [{"lxc.network.ipv6", ipaddr}]
      end

      options = ListDict.put(options, :config, config)

      chroot = ListDict.get(options, :chroot, Ampule.Chroot.chroot)
      chroot = chroot ++ [file: [
         {"udhcpc.script", dhcp_script(), 0755},
         {"ampule", boot("/udhcpc.script", cmd), 0755}
         ]]
      ListDict.put(options, :chroot, chroot)
    end

    defp ipaddr("dhcp"), do: "dhcp"
    defp ipaddr(ip), do: :inet_parse.address(bitstring_to_list(ip))

    def config do
      directories = ["/lib64", "/etc/alternatives"]
      extra = lc directory inlist directories, File.dir?(directory) do
        mount = Path.relative(directory)
        {"lxc.mount.entry", "#{directory} #{mount} none ro,bind,nosuid 0 0"}
      end

      init = init_path()

      [
        {"lxc.cgroup.devices.deny", "a"},
        {"lxc.cgroup.devices.allow", "c 1:3 rwm"},
        {"lxc.cgroup.devices.allow", "c 1:5 rwm"},
        {"lxc.cgroup.devices.allow", "c 1:8 rwm"},
        {"lxc.cgroup.devices.allow", "c 1:9 rwm"},
        {"lxc.cgroup.devices.allow", "c 5:2 rwm"},
        {"lxc.cgroup.devices.allow", "c 136:* rwm"},
        {"lxc.cgroup.devices.allow", "c 1:7 rwm"},
        {"lxc.cgroup.cpuset.cpus", "0"},
        {"lxc.cgroup.cpu.shares", "256"},
        {"lxc.mount.entry", "/lib lib none ro,bind,nosuid 0 0"},
        {"lxc.mount.entry", "/bin bin none ro,bind,nosuid 0 0"},
        {"lxc.mount.entry", "/usr usr none ro,bind,nosuid 0 0"},
        {"lxc.mount.entry", "/sbin sbin none ro,bind,nosuid 0 0"},
        {"lxc.mount.entry", "#{init} sbin/init none ro,bind 0 0"},
        {"lxc.mount.entry", "tmpfs tmp tmpfs noatime,mode=1777,nosuid,size=128M 0 0"},
        {"lxc.mount.entry", "/dev dev none ro,bind,nosuid 0 0"},
        {"lxc.pts", "1024"},
        {"lxc.mount.entry", "devpts dev/pts devpts rw,noexec,nosuid,gid=5,mode=0620 0 0"},
        {"lxc.mount.entry", "proc proc proc nodev,noexec,nosuid 0 0"} |
        extra
      ]
    end

    def init_path do
      path = case :code.priv_dir(:erlxc) do
        {:error, :bad_name} ->
          Path.join [:code.which(:erlxc), "..", "priv"]
        dir ->
          dir
      end

      Path.join [path, "erlxc_exec"]
    end

    def cgroup do
      [{"blkio.weight", "500"},
        {"memory.soft_limit_in_bytes", "268435456"},
        {"memory.limit_in_bytes", "53687091"}]
    end

    def chroot do
      [dir: ["run", "run/shm", "home", "home/ampule", "sbin",
            "selinux", "sys", "tmp", "lib", "dev", "dev/pts",
            "etc", "etc/alternatives", "root", "boot", "var",
            "var/run", "var/log", "usr", "bin", "lib64", "proc",
            "priv"]]
    end

    def dhcp_script do
      """
      #!/bin/sh
      
      env
      case "$1" in
        deconfig)
          ip addr flush dev $interface
        ;;
      
        renew|bound)
          # flush all the routes
          if [ -n "$router" ]; then
            ip route del default 2> /dev/null
          fi
      
          # check broadcast
          if [ -n "$broadcast" ]; then
            broadcast="broadcast $broadcast"
          fi
      
          # add a new ip address
          ip addr add $ip/$mask $broadcast dev $interface
      
          if [ -n "$router" ]; then
            ip route add default via $router dev $interface
          fi
      
          env > /tmp/env
        ;;
      esac
      """
    end

    def boot script, cmd do
      """
      #!/bin/sh
      
      export ip=$1
      uid=$2
      gid=$3
      
      if [ "$ip" = "dhcp" ]; then
        busybox udhcpc -s #{script}
        . /tmp/env
      fi
      cat /tmp/env
      
      export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
      export HOME=/home/ampule
      cd $HOME
      exec /sbin/init $uid $gid /bin/sh -c "#{cmd}"
      """
    end

    def id do
      0xf0000000 + :crypto.rand_uniform 0, 0xffff
    end
  end
end
