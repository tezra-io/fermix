defmodule FermixCore.Auth.Redaction do
  @moduledoc """
  Redacts credential-shaped data before it reaches logs, CLI output, or tool errors.
  """

  @sensitive_key_fragments ~w(access_token refresh_token id_token authorization client_secret secret token)
  @tokenish ~r/[A-Za-z0-9._-]*(?:access|refresh|id)?-?token[A-Za-z0-9._-]*/i
  @bearer ~r/Bearer\s+[A-Za-z0-9._~+\/=-]+/i

  @spec redact(term()) :: term()
  def redact(value) when is_map(value) do
    value
    |> Enum.map(fn {key, inner} -> redact_pair(key, inner) end)
    |> Enum.into(%{})
  end

  def redact(value) when is_list(value), do: Enum.map(value, &redact/1)

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
