defmodule FermixCore.Auth.Redaction do
  @moduledoc """
  Redacts credential-shaped data before it reaches logs, CLI output, or tool errors.
  """

  @sensitive_key_fragments ~w(access_token refresh_token id_token authorization client_secret secret token)
  @tokenish ~r/[A-Za-z0-9._-]*(?:access|refresh|id)?-?token[A-Za-z0-9._-]*/i
  @bearer ~r/Bearer\s+[A-Za-z0-9._~+\/=-]+/i

  @spec redact(term()) :: term()
  # A JSON parse error keeps the input it failed on: all of it in `:data`, a slice
  # in `:token`. For a credential file that is every token in it, and the values
  # are not token-shaped words the rules below can find, so the input goes whole;
  # the position still says where the parse broke.
  def redact(%Jason.DecodeError{} = error),
    do: %{error | data: "[REDACTED]", token: "[REDACTED]"}

  # A struct is a map that does not enumerate, so its fields are redacted and its
  # type kept: an error such as `%Req.TransportError{}` still reads as itself.
  def redact(%_{} = struct), do: Map.merge(struct, struct |> Map.from_struct() |> redact())

  def redact(value) when is_map(value) do
    value
    |> Enum.map(fn {key, inner} -> redact_pair(key, inner) end)
    |> Enum.into(%{})
  end

  def redact(value) when is_list(value), do: Enum.map(value, &redact/1)

  # A pair led by a string is a key/value entry (a header list, a decoded form),
  # so a sensitive key hides its value as it does in a map. A tuple led by an
  # atom is an error reason whose tag names the failure, not the value after it
  # (`{:secret_store_failed, reason}`), so it is only traversed, below.
  def redact({key, value}) when is_binary(key) do
    if sensitive_key?(key), do: {key, "[REDACTED]"}, else: {redact(key), redact(value)}
  end

  # Error reasons are tuples (`{:error, {:http, body}}`), so a credential inside
  # one is found the same way as inside a list.
  def redact(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> redact() |> List.to_tuple()

  def redact(value) when is_binary(value) do
    value
    |> String.replace(@bearer, "Bearer [REDACTED]")
    |> String.replace(@tokenish, "[REDACTED]")
  end

  def redact(value), do: value

  @spec format(term()) :: String.t()
  def format(value), do: value |> redact() |> inspect()

  defp redact_pair(key, value) when is_atom(key) do
    if sensitive_key?(Atom.to_string(key)), do: {key, "[REDACTED]"}, else: {key, redact(value)}
  end

  defp redact_pair(key, value) when is_binary(key) do
    if sensitive_key?(key), do: {key, "[REDACTED]"}, else: {key, redact(value)}
  end

  defp redact_pair(key, value), do: {key, redact(value)}

  defp sensitive_key?(key) do
    normalized = String.downcase(key)
    Enum.any?(@sensitive_key_fragments, &String.contains?(normalized, &1))
  end
end
