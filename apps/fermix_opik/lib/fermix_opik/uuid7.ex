defmodule FermixOpik.UUID7 do
  @moduledoc """
  Minimal UUIDv7 generator (RFC 9562).

  Opik's SDKs generate v7 ids so a row's id encodes its `start_time` and rows
  stay time-ordered. The public REST API accepts any UUID, but v7 keeps the
  Opik UI ordering sane — so we generate v7 rather than pull in a dependency.

  Layout (128 bits): unix_ts_ms(48) | ver(4)=7 | rand_a(12) | var(2)=0b10 | rand_b(62).
  """

  @doc "A new UUIDv7 string stamped with the current wall-clock millisecond."
  @spec generate() :: String.t()
  def generate, do: generate(System.system_time(:millisecond))

  @doc "A UUIDv7 string stamped with `unix_ms` (for deterministic tests/replay)."
  @spec generate(integer()) :: String.t()
  def generate(unix_ms) when is_integer(unix_ms) do
    <<rand_a::12, rand_b::62, _rest::bitstring>> = :crypto.strong_rand_bytes(10)

    <<unix_ms::48, 7::4, rand_a::12, 2::2, rand_b::62>>
    |> format()
  end

  defp format(<<a::32, b::16, c::16, d::16, e::48>>) do
    [a, b, c, d, e]
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map_join("-", fn {value, width} ->
      value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
    end)
  end
end
