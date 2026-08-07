defmodule FermixCore.Capabilities.MCP.Remote.Json do
  @moduledoc """
  Bounded JSON encode/decode for the remote MCP rail (M27 §7.4).

  Two bounds, applied in a deliberate order:

    1. **Bytes**, enforced upstream while the response streams
       (`Remote.Connection`), so an unbounded body is never allocated.
    2. **Structure** — depth and node count — enforced here, after decode.

  Checking structure after decode is not a hole: the byte cap already bounded
  what could be allocated. What the structural bound protects is everything
  *downstream* — the descriptor hasher, the schema walker, the capability
  builder — none of which should have to defend itself against a 10,000-deep
  document that arrived inside a legal 2 MiB.

  Nothing here truncates. A document that exceeds a bound is refused whole.
  """

  alias FermixCore.Capabilities.MCP.Remote.Limits

  @doc """
  Encode an outgoing JSON-RPC payload, refusing one that exceeds the request
  byte or depth bound.
  """
  @spec encode(map()) :: {:ok, binary()} | {:error, term()}
  def encode(payload) when is_map(payload) do
    with :ok <- check_depth(payload, Limits.max_request_depth(), :request_depth),
         {:ok, encoded} <- encode_term(payload) do
      check_size(encoded, Limits.max_request_bytes(), :request_bytes)
    end
  end

  @doc """
  Decode an incoming payload under an explicit byte/depth/node budget. Callers
  pass the budget for their own boundary — a discovery page, a tool result, and
  a single descriptor schema do not share one.
  """
  @spec decode(binary(), keyword()) :: {:ok, term()} | {:error, term()}
  def decode(raw, opts) when is_binary(raw) and is_list(opts) do
    max_bytes = Keyword.fetch!(opts, :max_bytes)
    max_depth = Keyword.fetch!(opts, :max_depth)
    max_nodes = Keyword.get(opts, :max_nodes)

    with {:ok, raw} <- check_size(raw, max_bytes, :payload_bytes),
         {:ok, decoded} <- decode_term(raw),
         :ok <- check_depth(decoded, max_depth, :payload_depth),
         :ok <- check_nodes(decoded, max_nodes) do
      {:ok, decoded}
    end
  end

  @doc "Depth of a decoded term. A scalar is depth 1."
  @spec depth(term()) :: pos_integer()
  def depth(term) when is_map(term) and map_size(term) == 0, do: 1
  def depth(term) when is_list(term) and term == [], do: 1

  def depth(term) when is_map(term) do
    1 + (term |> Map.values() |> Enum.reduce(0, &max(depth(&1), &2)))
  end

  def depth(term) when is_list(term) do
    1 + Enum.reduce(term, 0, &max(depth(&1), &2))
  end

  def depth(_term), do: 1

  @doc "Total node count of a decoded term (containers and scalars alike)."
  @spec nodes(term()) :: pos_integer()
  def nodes(term) when is_map(term) do
    1 + (term |> Map.values() |> Enum.reduce(0, &(nodes(&1) + &2)))
  end

  def nodes(term) when is_list(term), do: 1 + Enum.reduce(term, 0, &(nodes(&1) + &2))
  def nodes(_term), do: 1

  defp encode_term(payload) do
    {:ok, Jason.encode!(payload)}
  rescue
    error in [Jason.EncodeError, Protocol.UndefinedError] ->
      {:error, {:json_encode_failed, error.__struct__}}
  end

  # The raw body never enters the error: a malformed payload is exactly the
  # case where the bytes are most likely to be attacker- or user-content, and
  # §11.1 forbids raw bodies reaching a log, trace, or status string.
  defp decode_term(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
    end
  end

  defp check_size(value, max, tag) do
    size = byte_size(value)
    if size > max, do: {:error, {tag, size, max}}, else: {:ok, value}
  end

  defp check_depth(term, max, tag) do
    found = depth(term)
    if found > max, do: {:error, {tag, found, max}}, else: :ok
  end

  defp check_nodes(_term, nil), do: :ok

  defp check_nodes(term, max) do
    found = nodes(term)
    if found > max, do: {:error, {:payload_nodes, found, max}}, else: :ok
  end
end
