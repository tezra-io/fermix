defmodule FermixCore.Sandbox.ExternalEnv do
  @moduledoc """
  A skill's own credential, stored by Fermix and read into every sandboxed
  command as an allowed environment variable (M45 §4.1, §4.2).

  Two facts live here and nowhere else:

    * **Validation.** Which names and values may be stored at all. A name is a
      shell-exportable identifier that Fermix does not set itself; a value is
      one line, because the command-source reader refuses multi-line output and
      a value that stored fine but never read back would be the worst failure.
    * **The managed predicate.** A name is managed exactly when its
      `[sandbox.env.<NAME>]` source is the writer's own lookup for
      `{:external_env, NAME}` under the active profile. The settings rows,
      `secret.set` and `secret.clear` all ask this one question, so "stored by
      Fermix" can never mean two things.

  Managed compares where the value comes from (the source kind, the command
  and its arguments), not the lookup timeout: an operator who raised the
  timeout for a slow keychain has not moved the value anywhere.

  Everything here is pure except `managed_source/2`, which asks the configured
  writer for its lookup and performs no I/O.
  """

  alias FermixCore.Sandbox.Config
  alias FermixCore.Setup.SecretWriter

  @name_pattern ~r/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/
  # The default keys every command already gets, plus the daemon's own home.
  @reserved_names ~w(PATH HOME USER LANG SHELL TMPDIR FERMIX_HOME)
  @reserved_prefix "LC_"
  @max_value_bytes 8_192
  @max_managed 64
  @line_breaks ["\n", "\r", <<0>>]

  @type name_error :: :invalid_name | :reserved_name
  @type value_error :: :empty_value | :value_too_large | :value_not_single_line
  @type source_kind :: :managed | :engine_env | :alias | :helper

  @doc "The writer key a stored name lives under."
  @spec key(String.t()) :: SecretWriter.external_key()
  def key(name) when is_binary(name), do: {:external_env, name}

  @doc "The most names one settings file may store."
  @spec max_managed() :: pos_integer()
  def max_managed, do: @max_managed

  @doc "The largest value, in bytes, that may be stored."
  @spec max_value_bytes() :: pos_integer()
  def max_value_bytes, do: @max_value_bytes

  @doc """
  Whether `name` may be stored: the exact, case-sensitive pattern, and not a
  name Fermix sets for every command itself.
  """
  @spec validate_name(String.t()) :: :ok | {:error, name_error()}
  def validate_name(name) when is_binary(name) do
    cond do
      not Regex.match?(@name_pattern, name) -> {:error, :invalid_name}
      reserved?(name) -> {:error, :reserved_name}
      true -> :ok
    end
  end

  @doc "Whether `value` may be stored: 1 to 8,192 bytes, no NUL, CR or LF."
  @spec validate_value(String.t()) :: :ok | {:error, value_error()}
  def validate_value(value) when is_binary(value) do
    cond do
      value == "" -> {:error, :empty_value}
      byte_size(value) > @max_value_bytes -> {:error, :value_too_large}
      String.contains?(value, @line_breaks) -> {:error, :value_not_single_line}
      true -> :ok
    end
  end

  @doc """
  The `[sandbox.env.<NAME>]` source a stored name carries: the writer's own
  lookup, normalized the way the settings file reads it back.
  """
  @spec managed_source(String.t(), keyword()) :: Config.env_source()
  def managed_source(name, opts \\ []) when is_binary(name) and is_list(opts) do
    lookup = SecretWriter.command_source(key(name), opts)
    Config.normalize(env: [sources: %{name => lookup}]).env.sources[name]
  end

  @doc """
  The one managed predicate (M45 §4.2). A name Fermix would never store is
  never managed, whatever its source says: it has no lookup to compare with.
  """
  @spec managed?(Config.env_source(), String.t(), keyword()) :: boolean()
  def managed?(source, name, opts \\ []) when is_map(source) and is_binary(name) do
    validate_name(name) == :ok and reads_lookup?(source, managed_source(name, opts))
  end

  @doc """
  Where an allowed name's value comes from: stored by Fermix, the engine's own
  environment under the same name, the engine's environment under an alias, or
  any other command (an operator helper, or a provider key setup linked).
  """
  @spec source_kind(Config.env_config(), String.t(), keyword()) :: source_kind()
  def source_kind(%{sources: sources}, name, opts \\ []) when is_binary(name) do
    case Map.get(sources, name) do
      nil -> :engine_env
      %{source: :env, name: aliased} when aliased in [nil, name] -> :engine_env
      %{source: :env} -> :alias
      source -> if managed?(source, name, opts), do: :managed, else: :helper
    end
  end

  @doc "Every managed name in the policy, allowed or not, sorted."
  @spec managed_names(Config.env_config(), keyword()) :: [String.t()]
  def managed_names(%{sources: sources}, opts \\ []) do
    sources
    |> Enum.filter(fn {name, source} -> managed?(source, name, opts) end)
    |> Enum.map(fn {name, _source} -> name end)
    |> Enum.sort()
  end

  @doc """
  The policy with `name` stored: allowed (appended when absent), removed from
  the deny list, and its source set to the writer's lookup.
  """
  @spec put_managed(Config.env_config(), String.t(), keyword()) :: Config.env_config()
  def put_managed(%{allow: allow, deny: deny, sources: sources} = env, name, opts \\ [])
      when is_binary(name) do
    allow = if name in allow, do: allow, else: allow ++ [name]
    source = managed_source(name, opts)

    %{env | allow: allow, deny: List.delete(deny, name), sources: Map.put(sources, name, source)}
  end

  @doc """
  The policy with a managed `name`'s source dropped, so the still-allowed name
  reads the engine's environment. Any other source is returned untouched.
  """
  @spec drop_managed(Config.env_config(), String.t(), keyword()) :: Config.env_config()
  def drop_managed(%{sources: sources} = env, name, opts \\ []) when is_binary(name) do
    if source_kind(env, name, opts) == :managed do
      %{env | sources: Map.delete(sources, name)}
    else
      env
    end
  end

  defp reserved?(name), do: name in @reserved_names or String.starts_with?(name, @reserved_prefix)

  # A writer with no lookup (no OS store on this host) manages nothing.
  defp reads_lookup?(source, expected) do
    is_binary(expected.command) and address(source) == address(expected)
  end

  defp address(source), do: Map.take(source, [:source, :command, :args])
end
