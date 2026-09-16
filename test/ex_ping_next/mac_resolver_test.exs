defmodule ExPingNext.MacResolverTest do
  use ExUnit.Case, async: true

  alias ExPingNext.MacResolver

  @interfaces [
    {{192, 168, 0, 130}, {192, 168, 0, 255}, {255, 255, 255, 0}}
  ]

  test "recognizes an address on a local subnet" do
    assert MacResolver.same_subnet?({192, 168, 0, 1}, @interfaces)
  end

  test "rejects an address outside local subnets" do
    refute MacResolver.same_subnet?({192, 168, 1, 1}, @interfaces)
  end
end
