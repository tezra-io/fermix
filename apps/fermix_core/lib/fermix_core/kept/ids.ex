defmodule FermixCore.Kept.Ids do
  @moduledoc """
  The ids of the things Fermix keeps for the owner (M89 §07): a kind's prefix
  and ten lowercase base32 characters, `ck_` for a list and `ci_` for one of
  its rows, `tr_` for a trip and `ti_` for one of its days or stops. Shared
  by every kept kind, so a second kind adds its prefixes here and mints and
  checks its ids the lists' way. Pure.
  """

  @prefixes ["ck_", "ci_", "tr_", "ti_"]
  @alphabet ~c"0123456789abcdefghjkmnpqrstvwxyz"
  @suffix ~r/\A[0-9a-z]{10}\z/

  @doc "A new id: `prefix` and ten lowercase base32 characters."
  @spec new(String.t()) :: String.t()
  def new(prefix) when prefix in @prefixes do
    suffix =
      10
      |> :crypto.strong_rand_bytes()
      |> :binary.bin_to_list()
      |> Enum.map(&Enum.at(@alphabet, rem(&1, 32)))

    prefix <> List.to_string(suffix)
  end

  @doc "Whether `id` is `prefix` and ten characters of `[0-9a-z]`, as an id is checked on the wire."
  @spec valid?(term(), String.t()) :: boolean()
  def valid?(id, prefix) when prefix in @prefixes do
    is_binary(id) and String.starts_with?(id, prefix) and
      Regex.match?(@suffix, binary_part(id, byte_size(prefix), byte_size(id) - byte_size(prefix)))
  end
end
