defmodule FermixCore.Sandbox.Config do
  @moduledoc """
  Runtime config for the local workspace sandbox.
  """

  @modes ~w(strict standard open)a
  @env_modes ~w(selected all)a
  @command_profiles ~w(bare assistant extended)a

  @type env_source :: %{
          source: :env | :command,
          name: String.t() | nil,
          command: String.t() | nil,
          args: [String.t()],
          timeout_ms: pos_integer()
        }

  @type env_config :: %{
          mode: :selected | :all,
          allow: [String.t()],
          deny: [String.t()],
          sources: %{String.t() => env_source()}
        }

  @type commands_config :: %{
          profile: :bare | :assistant | :extended,
          presets: [String.t()],
          explicit: %{String.t() => command_spec()}
        }

  @type command_spec :: %{
          enabled: boolean(),
          command: String.t(),
          args: [String.t()],
          pass_env: [String.t()],
          timeout_ms: pos_integer(),
          description: String.t() | nil
        }

  @type t :: %__MODULE__{
          mode: :strict | :standard | :open,
          home: String.t(),
          workspace_root: String.t(),
          allowed_roots: [String.t()],
          blocked_roots: [String.t()],
          env: env_config(),
          commands: commands_config()
        }

  defstruct mode: :standard,
            home: nil,
            workspace_root: nil,
            allowed_roots: [],
            blocked_roots: [],
            env: %{mode: :selected, allow: [], deny: [], sources: %{}},
            commands: %{profile: :bare, presets: [], explicit: %{}}

  @spec default() :: t()
  def default do
    home = fermix_home()

    %__MODULE__{
      home: home,
      workspace_root: Path.join(home, "workspace")
    }
  end

  @spec current() :: t()
  def current do
    :fermix_core
    |> Application.get_env(:sandbox, default())
    |> normalize()
  end

  @spec normalize(t() | map() | keyword() | nil) :: t()
  def normalize(nil), do: default()
  def normalize(%__MODULE__{} = config), do: normalize(Map.from_struct(config))

  def normalize(config) when is_map(config) or is_list(config) do
    defaults = default()

    %__MODULE__{
      mode: enum_value(value(config, "mode", :mode, defaults.mode), @modes, :mode),
      home: expand_path(value(config, "home", :home, defaults.home)),
      workspace_root:
        expand_path(value(config, "workspace_root", :workspace_root, defaults.workspace_root)),
      allowed_roots:
        path_list(value(config, "allowed_roots", :allowed_roots, []), :allowed_roots),
      blocked_roots:
        path_list(value(config, "blocked_roots", :blocked_roots, []), :blocked_roots),
      env: normalize_env(value(config, "env", :env, %{})),
      commands: normalize_commands(value(config, "commands", :commands, %{}))
    }
  end

  @spec to_keyword(t() | map() | keyword()) :: keyword()
  def to_keyword(config) do
    config = normalize(config)

    [
      mode: config.mode,
      workspace_root: config.workspace_root,
      allowed_roots: config.allowed_roots,
      blocked_roots: config.blocked_roots,
      env: env_to_keyword(config.env),
      commands: commands_to_keyword(config.commands)
    ]
  end

  defp normalize_env(config) when is_map(config) or is_list(config) do
    %{
      mode: enum_value(value(config, "mode", :mode, :selected), @env_modes, :env_mode),
      allow: string_list(value(config, "allow", :allow, []), :env_allow),
      deny: string_list(value(config, "deny", :deny, []), :env_deny),
      sources: env_sources(config)
    }
  end

  defp normalize_commands(config) when is_map(config) or is_list(config) do
    %{
      profile: enum_value(value(config, "profile", :profile, :bare), @command_profiles, :profile),
      presets: command_presets(config),
      explicit: command_specs(config)
    }
  end

  defp command_presets(config) do
    config
    |> value("presets", :presets, value(config, "enabled_presets", :enabled_presets, []))
    |> string_list(:presets)
  end

  defp command_specs(config) do
    explicit =
      config
      |> value("explicit", :explicit, %{})
      |> normalize_command_map()

    section_commands =
      config
      |> entries()
      |> Enum.reject(fn {key, _value} ->
        key in [
          "profile",
          :profile,
          "presets",
          :presets,
          "enabled_presets",
          :enabled_presets,
          "explicit",
          :explicit
        ]
      end)
      |> Enum.into(%{}, fn {name, spec} -> {to_string(name), normalize_command_spec(spec)} end)

    Map.merge(explicit, section_commands)
  end

  defp normalize_command_map(commands) when is_map(commands) or is_list(commands) do
    Map.new(commands, fn {name, spec} -> {to_string(name), normalize_command_spec(spec)} end)
  end

  defp normalize_command_spec(spec) when is_map(spec) or is_list(spec) do
    command = normalize_string(value(spec, "command", :command, nil))

    if is_nil(command) do
      raise ArgumentError, "sandbox command spec requires command"
    end

    %{
      enabled: boolean_value(value(spec, "enabled", :enabled, true), :enabled),
      command: command,
      args: string_list(value(spec, "args", :args, []), :args),
      pass_env: string_list(value(spec, "pass_env", :pass_env, []), :pass_env),
      timeout_ms: positive_int(value(spec, "timeout_ms", :timeout_ms, 30_000), :timeout_ms),
      description: normalize_string(value(spec, "description", :description, nil))
    }
  end

  defp env_sources(config) do
    explicit =
      config
      |> value("sources", :sources, %{})
      |> normalize_sources_map()

    section_sources =
      config
      |> entries()
      |> Enum.reject(fn {key, _value} ->
        key in ["mode", :mode, "allow", :allow, "deny", :deny, "sources", :sources]
      end)
      |> Enum.into(%{}, fn {name, source} -> {to_string(name), normalize_source(source)} end)

    Map.merge(explicit, section_sources)
  end

  defp normalize_sources_map(sources) when is_map(sources) or is_list(sources) do
    Map.new(sources, fn {name, source} -> {to_string(name), normalize_source(source)} end)
  end

  defp normalize_source(source) when is_map(source) or is_list(source) do
    source_type = enum_value(value(source, "source", :source, :env), [:env, :command], :source)

    %{
      source: source_type,
      name: normalize_string(value(source, "name", :name, nil)),
      command: normalize_string(value(source, "command", :command, nil)),
      args: string_list(value(source, "args", :args, []), :args),
      timeout_ms: positive_int(value(source, "timeout_ms", :timeout_ms, 3_000), :timeout_ms)
    }
  end

  defp env_to_keyword(env) do
    [
      mode: env.mode,
      allow: env.allow,
      deny: env.deny,
      sources: Map.new(env.sources, fn {name, source} -> {name, source_to_keyword(source)} end)
    ]
  end

  defp source_to_keyword(source) do
    []
    |> put_if_present(:source, source.source)
    |> put_if_present(:name, source.name)
    |> put_if_present(:command, source.command)
    |> put_if_present(:args, source.args)
    |> put_if_present(:timeout_ms, source.timeout_ms)
  end

  defp commands_to_keyword(commands) do
    [
      profile: commands.profile,
      presets: commands.presets,
      explicit: Map.new(commands.explicit, fn {name, spec} -> {name, command_to_keyword(spec)} end)
    ]
  end

  defp command_to_keyword(spec) do
    []
    |> put_if_present(:enabled, spec.enabled)
    |> put_if_present(:command, spec.command)
    |> put_if_present(:args, spec.args)
    |> put_if_present(:pass_env, spec.pass_env)
    |> put_if_present(:timeout_ms, spec.timeout_ms)
    |> put_if_present(:description, spec.description)
  end

  defp enum_value(value, valid, key) when is_atom(value) do
    if value in valid, do: value, else: raise_invalid_enum!(key, value, valid)
  end

  defp enum_value(value, valid, key) when is_binary(value) do
    atom = Enum.find(valid, &(Atom.to_string(&1) == value))
    if is_nil(atom), do: raise_invalid_enum!(key, value, valid), else: atom
  end

  defp enum_value(value, valid, key), do: raise_invalid_enum!(key, value, valid)

  defp raise_invalid_enum!(key, value, valid) do
    allowed = Enum.map_join(valid, ", ", &Atom.to_string/1)
    raise ArgumentError, "invalid sandbox #{key} #{inspect(value)}; expected one of: #{allowed}"
  end

  defp path_list(values, key), do: values |> string_list(key) |> Enum.map(&expand_path/1)

  defp string_list(values, key) when is_list(values) do
    Enum.map(values, fn value ->
      value = normalize_string(value)

      if is_nil(value),
        do: raise(ArgumentError, "sandbox #{key} entries must be strings"),
        else: value
    end)
  end

  defp string_list(value, key) do
    raise ArgumentError, "sandbox #{key} must be a list, got: #{inspect(value)}"
  end

  defp positive_int(value, _key) when is_integer(value) and value > 0, do: value

  defp positive_int(value, key) do
    raise ArgumentError, "sandbox #{key} must be a positive integer, got: #{inspect(value)}"
  end

  defp boolean_value(value, _key) when is_boolean(value), do: value

  defp boolean_value(value, key) do
    raise ArgumentError, "sandbox #{key} must be a boolean, got: #{inspect(value)}"
  end

  defp expand_path(path) do
    path
    |> normalize_string()
    |> case do
      nil -> nil
      "~" -> System.user_home!()
      "~/" <> rest -> Path.join(System.user_home!(), rest)
      value -> value
    end
    |> case do
      nil -> nil
      value -> Path.expand(value)
    end
  end

  defp value(config, string_key, atom_key, default) when is_map(config) do
    Map.get(config, string_key, Map.get(config, atom_key, default))
  end

  defp value(config, _string_key, atom_key, default) when is_list(config) do
    Keyword.get(config, atom_key, default)
  end

  defp entries(config) when is_map(config), do: Map.to_list(config)
  defp entries(config) when is_list(config), do: config

  defp normalize_string(nil), do: nil

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(_value), do: nil

  defp put_if_present(keyword, _key, nil), do: keyword
  defp put_if_present(keyword, _key, []), do: keyword
  defp put_if_present(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp fermix_home do
    System.get_env("FERMIX_HOME") || Path.join(System.user_home!(), ".fermix")
  end
end
