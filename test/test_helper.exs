ExUnit.start
case node() do
  :nonode@nohost ->
    {:ok, _} = :net_kernel.start([:ampuletest])
    cookie = :crypto.rand_bytes(8) |> :base64.encode_to_string |> list_to_atom
    :erlang.set_cookie(node(), cookie)
  _ ->
    true
end
