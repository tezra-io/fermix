defmodule FermixOpik.UUID7Test do
  use ExUnit.Case, async: true

  alias FermixOpik.UUID7

  @uuid_re ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  test "generates a well-formed version-7 uuid" do
    assert UUID7.generate() =~ @uuid_re
  end

  test "embeds the supplied millisecond timestamp" do
    ms = 1_780_000_000_000
    <<hex_ts::binary-size(8), _::binary>> = UUID7.generate(ms) |> String.replace("-", "")
    {ts_high, ""} = Integer.parse(hex_ts, 16)
    # first 48 bits are the timestamp; the first 32 bits (8 hex) are ms >> 16
    assert ts_high == div(ms, 65_536)
  end

  test "is unique across rapid calls" do
    ids = for _ <- 1..1_000, do: UUID7.generate()
    assert length(Enum.uniq(ids)) == 1_000
  end
end
