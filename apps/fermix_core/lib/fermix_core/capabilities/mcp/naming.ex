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

  ## `mode: :preserve` (M27 §7.7)

  A signed remote plugin whose upstream names already carry its namespace
  (`eden_get_note`) uses `mode: :preserve`: the final capability name is the
  **exact** upstream name, never `eden_eden_get_note`. Preserved names still
  pass the same character and 64-byte validation — `validate_name/1` is the one
  gate both modes go through — and they never hash-rename on collision. That is
  what `reserve/3` is for: a preserved name that is already taken fails the whole
  registration rather than quietly becoming a different tool the manifest never
  signed. Existing stdio plugins keep `register/3`'s prefixing and renaming.
  """

  alias FermixCore.Capabilities.MCP.Telemetry

  @table __MODULE__

  @max_length 64
  @name_regex ~r/^[A-Za-z0-9_-]+$/

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

  `mode: :preserve` returns the exact upstream name (M27 §7.7); an upstream name
  that would not pass validation raises rather than being silently repaired into
  a name the manifest never signed.
  """
  @spec candidate(String.t(), String.t(), keyword()) :: String.t()
  def candidate(server, original, opts \\ [])
      when is_binary(server) and is_binary(original) and is_list(opts) do
    case Keyword.get(opts, :mode, :prefix) do
      :preserve -> preserved!(server, original)
      :prefix -> prefixed(server, original, Keyword.get(opts, :prefix))
    end
  end

  defp preserved!(server, original) do
    case validate_name(original) do
      :ok ->
        original

      {:error, reason} ->
        raise ArgumentError, "#{inspect(reason)} for #{inspect({server, original})}"
    end
  end

  defp prefixed(server, original, prefix_opt) do
    prefix = prefix_for(server, prefix_opt)
    tool_part = sanitize_segment(original)

    if tool_part == "" do
      raise ArgumentError, "invalid MCP tool name #{inspect({server, original})}"
    end

    cap_length(prefix, tool_part, original)
  end

  @doc """
  The one name gate both modes go through: `[A-Za-z0-9_-]`, 1–64 bytes.

  Returns a tuple rather than raising so the transactional registration path can
  preflight every final name before it registers any of them.
  """
  @spec validate_name(String.t()) :: :ok | {:error, {atom(), String.t()}}
  def validate_name(name) when is_binary(name) do
    cond do
      name == "" -> {:error, {:empty_capability_name, name}}
      byte_size(name) > @max_length -> {:error, {:capability_name_too_long, name}}
      not Regex.match?(@name_regex, name) -> {:error, {:invalid_capability_name, name}}
      true -> :ok
    end
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

  @doc """
  Reserve an exact name, refusing rather than renaming on collision.

  The signed-contract path cannot hash-rename: a renamed tool is a tool the
  manifest never signed, and a partially renamed profile is exactly the
  half-honoured contract §7.7 forbids. A conflict fails the whole registration.
  """
  @spec reserve(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, {:capability_conflict, String.t()}}
  def reserve(server, original, name)
      when is_binary(server) and is_binary(original) and is_binary(name) do
    init()

    case lookup(name) do
      :error -> insert(server, original, name)
      {:ok, {^server, ^original}} -> {:ok, name}
      {:ok, _other} -> {:error, {:capability_conflict, name}}
    end
  end

  defp insert(server, original, name) do
    :ets.insert(@table, {name, {server, original}})
    {:ok, name}
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
        Telemetry.emit_collision(
          server,
          original,
          candidate,
          {existing_server, existing_original}
        )

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
end
