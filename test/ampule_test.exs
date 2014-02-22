defmodule AmpuleTest do
  use ExUnit.Case

  test "anonymous container" do
    result = {:lists, :reverse, ['1234567890']} |> Ampule.call
    assert('0987654321' == result)
  end

  test "named container" do
    container = Ampule.spawn
    result = {:lists, :reverse, ['1234567890']} |> Ampule.call(container)
    assert('0987654321' == result)
  end

end
