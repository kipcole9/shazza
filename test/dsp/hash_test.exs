defmodule Shazza.DSP.HashTest do
  use ExUnit.Case, async: true

  alias Shazza.DSP.Hash

  test "pack/unpack roundtrip across the valid ranges" do
    for f1 <- [0, 1, 137, 511], f2 <- [0, 1, 200, 511], dt <- [0, 1, 99, 16_383] do
      packed = Hash.pack(f1, f2, dt)
      assert {f1, f2, dt} == Hash.unpack(packed)
    end
  end

  test "different inputs produce different hashes" do
    a = Hash.pack(10, 20, 30)
    b = Hash.pack(10, 20, 31)
    c = Hash.pack(10, 21, 30)
    d = Hash.pack(11, 20, 30)
    assert MapSet.new([a, b, c, d]) |> MapSet.size() == 4
  end
end
