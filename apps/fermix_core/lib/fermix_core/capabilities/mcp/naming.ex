defmodule FermixCore.Capabilities.MCP.Naming do
  @moduledoc """
  Sanitizes MCP tool names so they pass OpenAI Responses API validation
  (`^[a-zA-Z0-9_-]+$`, max 64 bytes), and keeps a reverse map from
  sanitized name back to `{server, original_tool_name}` for telemetry,
  error messages, and `fermix mcp list`.

  Sanitization is deterministic: same input always returns the same
  candidate name. Truncation past 64 bytes appends a SHA256 prefix to
  preserve uniqueness. Collisions are detected by `register/3` against
  the live ETS table; the second registration gets a hash suffix.

  Empty-after-sanitize raises `ArgumentError` — refusing to register
  a meaningless name is louder than silently dropping the tool.
  """

  @table __MODULE__

  @max_length 64

  @spec init() :: :ok
  def init do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _tid ->
        :ok
    end
  end

  @doc """
  Build a sanitized capability name for the given server + tool. Does not
  touch the reverse map; call `register/3` to publish the mapping.

  Operator-configured servers get the default `mcp_<server>_` prefix;
  plugin-owned servers pass `prefix: "<plugin>_"` so their discovered tools
  stay continuous with the `http` rail's namespace (M8 §8.2). `prefix: nil`
  means the default.
  """
  @spec candidate(String.t(), String.t(), keyword()) :: String.t()
  def candidate(server, original, opts \\ [])
      when is_binary(server) and is_binary(original) and is_list(opts) do
    prefix = prefix_for(server, Keyword.get(opts, :prefix))
    tool_part = sanitize_segment(original)

    if tool_part == "" do
      raise ArgumentError, "invalid MCP tool name #{inspect({server, original})}"
    end

    cap_length(prefix, tool_part, original)
  end

  defp prefix_for(server, nil), do: "mcp_" <> sanitize_segment(server) <> "_"

  defp prefix_for(_server, prefix) when is_binary(prefix) and prefix != "", do: prefix

  @doc """
  Register a sanitized name. Detects collisions against the existing
  reverse map; on conflict, appends an 8-char SHA256 suffix and emits a
  collision telemetry event. Returns the final published name.
  """
  @spec register(String.t(), String.t(), String.t()) :: String.t()
  def register(server, original, sanitized)
      when is_binary(server) and is_binary(original) and is_binary(sanitized) do
    init()
    final = resolve_collision(sanitized, server, original)
    :ets.insert(@table, {final, {server, original}})
    final
  end

  @spec lookup(String.t()) :: {:ok, {String.t(), String.t()}} | :error
  def lookup(sanitized) when is_binary(sanitized) do
    case :ets.whereis(@table) do
      :undefined ->
        :error

      _tid ->
        case :ets.lookup(@table, sanitized) do
          [{^sanitized, mapping}] -> {:ok, mapping}
          [] -> :error
        end
    end
  end

  @spec unregister(String.t()) :: :ok
  def unregister(sanitized) when is_binary(sanitized) do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _tid -> :ets.delete(@table, sanitized) && :ok
    end
  end

  @doc """
  Sanitize one segment (server name or tool name).

  The OpenAI Responses API accepts `[a-zA-Z0-9_-]`, but we additionally
  normalize `-` → `_` so that two server names that differ only in
  punctuation (`fs.local` vs `fs-local`) collapse into the same
  sanitized form. That makes collisions detectable and lets us emit a
  telemetry event instead of silently shipping two indistinguishable
  capabilities to the LLM.
  """
  @spec sanitize_segment(String.t()) :: String.t()
  def sanitize_segment(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/u, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
  end

  defp cap_length(prefix, tool_part, original) do
    candidate = prefix <> tool_part

    if byte_size(candidate) <= @max_length do
      candidate
    else
      truncate_with_hash(prefix, tool_part, original)
    end
  end

  defp truncate_with_hash(prefix, tool_part, original) do
    hash = short_hash(prefix <> original)
    suffix = "_" <> hash
    keep = @max_length - byte_size(prefix) - byte_size(suffix)
    keep = max(keep, 0)
    truncated = binary_part(tool_part, 0, min(byte_size(tool_part), keep))
    prefix <> truncated <> suffix
  end

  defp resolve_collision(candidate, server, original) do
    case lookup(candidate) do
      :error ->
        candidate

      {:ok, {existing_server, existing_original}}
      when existing_server == server and existing_original == original ->
        candidate

      {:ok, {existing_server, existing_original}} ->
        emit_collision(server, original, candidate, {existing_server, existing_original})
        suffix = "_" <> short_hash(server <> "::" <> original)
        keep = @max_length - byte_size(suffix)
        truncated = binary_part(candidate, 0, min(byte_size(candidate), keep))
        truncated <> suffix
    end
  end

  defp short_hash(payload) do
    :crypto.hash(:sha256, payload)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end

  defp emit_collision(server, original, sanitized, {existing_server, existing_original}) do
    :telemetry.execute(
      [:fermix, :capability, :mcp_name_collision],
      %{count: 1},
      %{
        server: server,
        original: original,
        sanitized: sanitized,
        collided_with: %{server: existing_server, original: existing_original}
      }
    )
  end
end
