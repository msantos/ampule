# Ampule

An elixir library for Linux containers.

## Description

Why not model a container as part of a pipeline? [1]

What is a pipeline? A pipeline calls a function which acts as a filter. A
filter transforms the data. It can map over the elements or reduce them,
maintaining internal state. A filter could be modeled as a closure.

A Linux container is a closure.

`ampule` returns a closure which is running a virtual machine. Data may
be passed into the closure and transformed.

The key here is Erlang distribution. We start containers running erlang
nodes and run the code within the container.

It'd be possible to do this "safely" in the future by passing terms in the
Erlang external term format between nodes rather than using distribution,
maybe over SSL or SSH.

Just as Elixir processes are cheap compared to system processes, wouldn't
it be nice if creating virtual machines was as cheap as creating a
system process?

`ampule` works by creating a chroot with a script running busybox to
get a dhcp address before exec'ing an unprivileged erlang instance in
distributed mode.

ampule is basically a primitive imitation of the Erlang `slave` module,
except that instead of running over, e.g., ssh, it creates the container
and starts the erlang node.

## Dependencies

`ampule` requires `erlxc`, which in turn requires a recent version of
`liblxc`. `erlxc` needs root privileges, see the README for setup:

https://github.com/msantos/erlxc

## Examples

`iex` must be running in distributed mode:

```
iex --name ampule@192.168.123.54 -S mix
```

* Run a pipeline via anonymous containers:

```elixir
{:erlang,:node,[]}
  |> Ampule.call
  |> Ampule.mfa(:erlang, :atom_to_list)
  |> Ampule.call
```

  This example runs `:erlang.node` in a container, converts the output
  to a tuple (`{:erlang, :atom_to_list, nodename}`) which can be passed
  back into `Ampule.call/1` to be run in a new container.

* Run a pipeline via named containers:

```elixir
container = Ampule.spawn
{:erlang,:node,[]}
  |> Ampule.call(container)
  |> Ampule.mfa(:erlang, :atom_to_list)
  |> Ampule.call(container)
  |> list_to_atom
```

  Gets the nodename of the container as a list, does the conversion of
  the atom to a list inside the same container, then completes the cycle
  of life by making the list into an atom again.

* Spawn a process in a container

```elixir
container = Ampule.spawn
pid = self
Node.spawn(container.nodename, fn -> ls = :os.cmd('ls -al'); send(pid, ls) end)
```

* Boot a container running Ubuntu

  Anything written to the system console is sent as messages to the process.

```elixir
container = Ampule.create

# default username
"ubuntu\n" |> Ampule.console container

# default passowrd
"ubuntu\n" |> Ampule.console container

# run a command
"ls -al\n" |> Ampule.console container
```

## TODO

* To be safer, ampule could, by default, use a bridge disconnected from
  the network. The bridge could be a system bridge or an Erlang bridge.

* Timeout and destroy if container creation/erlang boot fails

* Support other functions in the `rpc` module

* ampule vs ampoule vs ampul

[1]: http://cr.yp.to/qmail/qmailsec-20071101.pdf
