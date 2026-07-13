defmodule FermixCore.Sandbox.ConfigMutation do
  @moduledoc """
  Narrow mutation surface for sandbox config changes.
  """

  alias FermixCore.Sandbox.CommandCapabilities
  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.Mode
  alias FermixCore.Sandbox.PathPolicy
  alias FermixCore.Setup.ConfigStore

  @type mutation ::
          {:set_mode, atom() | String.t()}
          | {:add_allowed_root, String.t()}
          | {:remove_allowed_root, String.t()}
          | {:add_env_passthrough, String.t(), map() | keyword()}
          | {:remove_env_passthrough, String.t()}
          | {:set_command_profile, atom() | String.t()}
          | {:enable_preset, String.t()}
          | {:disable_preset, String.t()}
          | {:enable_command, String.t(), map() | keyword()}
          | {:disable_command, String.t()}

  @spec set_mode(Config.t() | map() | keyword(), atom() | String.t()) ::
          {:ok, Config.t()} | {:error, term()}
  def set_mode(config, mode) do
    {:ok, Config.normalize(config) |> Map.put(:mode, Config.normalize(mode: mode).mode)}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  @spec add_allowed_root(Config.t() | map() | keyword(), String.t()) ::
          {:ok, Config.t()} | {:error, term()}
  def add_allowed_root(config, path) when is_binary(path) do
    config = Config.normalize(config)

    with {:ok, root} <- normalize_grant_root(path),
         :ok <- reject_unsafe_root(root, config) do
      {:ok, %{config | allowed_roots: Enum.uniq(config.allowed_roots ++ [root])}}
    end
  end

  @spec remove_allowed_root(Config.t() | map() | keyword(), String.t()) :: {:ok, Config.t()}
  def remove_allowed_root(config, path) when is_binary(path) do
    root = PathPolicy.canonical_path(path)
    config = Config.normalize(config)
    {:ok, %{config | allowed_roots: List.delete(config.allowed_roots, root)}}
  end

  @spec add_env_passthrough(Config.t() | map() | keyword(), String.t(), map() | keyword()) ::
          {:ok, Config.t()}
  def add_env_passthrough(config, name, source_spec) when is_binary(name) do
    config = Config.normalize(config)
    env = config.env
    source = Config.normalize(env: [sources: %{name => source_spec}]).env.sources[name]

    updated = %{
      env
      | allow: Enum.uniq(env.allow ++ [name]),
        sources: Map.put(env.sources, name, source)
    }

    {:ok, %{config | env: updated}}
  end

  @spec remove_env_passthrough(Config.t() | map() | keyword(), String.t()) :: {:ok, Config.t()}
  def remove_env_passthrough(config, name) when is_binary(name) do
    config = Config.normalize(config)
    env = config.env
    updated = %{env | allow: List.delete(env.allow, name), sources: Map.delete(env.sources, name)}
    {:ok, %{config | env: updated}}
  end

  @spec set_command_profile(Config.t() | map() | keyword(), atom() | String.t()) ::
          {:ok, Config.t()} | {:error, term()}
  def set_command_profile(config, profile) do
    normalized = Config.normalize(commands: [profile: profile])
    config = Config.normalize(config)
    {:ok, %{config | commands: %{config.commands | profile: normalized.commands.profile}}}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  @spec enable_preset(Config.t() | map() | keyword(), String.t()) :: {:ok, Config.t()}
  def enable_preset(config, preset) when is_binary(preset) do
    config = Config.normalize(config)
    commands = config.commands
    {:ok, %{config | commands: %{commands | presets: Enum.uniq(commands.presets ++ [preset])}}}
  end

  @spec disable_preset(Config.t() | map() | keyword(), String.t()) :: {:ok, Config.t()}
  def disable_preset(config, preset) when is_binary(preset) do
    config = Config.normalize(config)
    commands = config.commands
    {:ok, %{config | commands: %{commands | presets: List.delete(commands.presets, preset)}}}
  end

  @spec enable_command(Config.t() | map() | keyword(), String.t(), map() | keyword()) ::
          {:ok, Config.t()} | {:error, term()}
  def enable_command(config, name, command_spec) when is_binary(name) do
    config = Config.normalize(config)
    spec = Config.normalize(commands: [explicit: %{name => command_spec}]).commands.explicit[name]
    spec = %{spec | enabled: true}
    {:ok, put_command(config, name, spec)}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  @spec disable_command(Config.t() | map() | keyword(), String.t()) :: {:ok, Config.t()}
  def disable_command(config, name) when is_binary(name) do
    config = Config.normalize(config)

    case Map.fetch(config.commands.explicit, name) do
      {:ok, spec} -> {:ok, put_command(config, name, %{spec | enabled: false})}
      :error -> {:ok, config}
    end
  end

  @spec diff(Config.t() | map() | keyword(), Config.t() | map() | keyword()) :: String.t()
  def diff(current_config, proposed_config) do
    current = summary_sets(current_config)
    proposed = summary_sets(proposed_config)

    [
      diff_line("effective_roots", current.roots, proposed.roots),
      diff_line("allowed_roots", current.allowed_roots, proposed.allowed_roots),
      diff_line("env", current.env, proposed.env),
      diff_line("presets", current.presets, proposed.presets),
      diff_line("commands", current.commands, proposed.commands)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  @spec requires_confirmation?(Config.t() | map() | keyword(), Config.t() | map() | keyword()) ::
          boolean()
  def requires_confirmation?(current_config, proposed_config) do
    current = summary_sets(current_config)
    proposed = summary_sets(proposed_config)

    gained?(current.roots, proposed.roots) or gained?(current.env, proposed.env) or
      gained?(current.presets, proposed.presets) or gained?(current.commands, proposed.commands)
  end

  @spec apply(Config.t() | map() | keyword(), mutation(), keyword()) ::
          {:ok, Config.t()} | {:error, term()}
  def apply(config, mutation, opts \\ []) do
    with {:ok, updated} <- mutate(config, mutation) do
      maybe_persist(updated, opts)
    end
  end

  defp maybe_persist(config, opts) do
    if Keyword.get(opts, :dry_run, false) do
      {:ok, config}
    else
      with :ok <- persist(config, opts), do: {:ok, config}
    end
  end

  @spec persist(Config.t() | map() | keyword(), keyword()) :: :ok | {:error, term()}
  def persist(config, opts \\ []) do
    config = Config.normalize(config)
    supervised = Keyword.take(opts, [:supervised])

    with {:ok, snapshot} <- ConfigStore.load_runtime_config(supervised),
         updated = Map.put(snapshot, :sandbox, Config.to_keyword(config)),
         :ok <- ConfigStore.save_snapshot(updated, supervised) do
      ConfigStore.apply_snapshot(updated, supervised)

      with :ok <- maybe_write_grant_record(opts) do
        refresh_command_capabilities(config)
      end
    end
  end

  defp mutate(config, {:set_mode, mode}), do: set_mode(config, mode)
  defp mutate(config, {:add_allowed_root, path}), do: add_allowed_root(config, path)
  defp mutate(config, {:remove_allowed_root, path}), do: remove_allowed_root(config, path)

  defp mutate(config, {:add_env_passthrough, name, source}),
    do: add_env_passthrough(config, name, source)

  defp mutate(config, {:remove_env_passthrough, name}), do: remove_env_passthrough(config, name)
  defp mutate(config, {:set_command_profile, profile}), do: set_command_profile(config, profile)
  defp mutate(config, {:enable_preset, preset}), do: enable_preset(config, preset)
  defp mutate(config, {:disable_preset, preset}), do: disable_preset(config, preset)
  defp mutate(config, {:enable_command, name, spec}), do: enable_command(config, name, spec)
  defp mutate(config, {:disable_command, name}), do: disable_command(config, name)

  defp put_command(config, name, spec) do
    commands = config.commands
    explicit = Map.put(commands.explicit, name, spec)
    %{config | commands: %{commands | explicit: explicit}}
  end

  defp normalize_grant_root(path) do
    path
    |> Path.expand()
    |> PathPolicy.canonical_path()
    |> then(&{:ok, &1})
  end

  defp reject_unsafe_root(root, config) do
    protected_roots = ["/", System.user_home!(), ConfigStore.fermix_home(), config.home]

    if root in Enum.map(protected_roots, &PathPolicy.canonical_path/1) or
         Enum.any?(PathPolicy.protected_paths(config), &inside_or_equal?(root, &1)) do
      {:error, {:unsafe_root, root}}
    else
      :ok
    end
  end

  defp summary_sets(config) do
    config = Config.normalize(config)

    %{
      roots: MapSet.new(Mode.effective_roots(config)),
      allowed_roots: MapSet.new(config.allowed_roots),
      env: MapSet.new(config.env.allow),
      presets: MapSet.new(config.commands.presets),
      commands: config.commands.explicit |> enabled_command_names() |> MapSet.new()
    }
  end

  defp enabled_command_names(commands) do
    commands
    |> Enum.filter(fn {_name, spec} -> spec.enabled end)
    |> Enum.map(fn {name, _spec} -> name end)
  end

  defp diff_line(label, current, proposed) do
    gained = MapSet.difference(proposed, current) |> MapSet.to_list()
    lost = MapSet.difference(current, proposed) |> MapSet.to_list()

    [format_delta(label, "+", gained), format_delta(label, "-", lost)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp format_delta(_label, _marker, []), do: ""
  defp format_delta(label, marker, values), do: "#{label} #{marker} #{Enum.join(values, ", ")}"

  defp gained?(current, proposed), do: not MapSet.subset?(proposed, current)

  defp maybe_write_grant_record(grant_record: record) when is_map(record),
    do: write_grant_record(record)

  defp maybe_write_grant_record(_opts), do: :ok

  defp write_grant_record(record) do
    dir = ConfigStore.workspace_paths().grants

    path =
      Path.join(
        dir,
        "grant-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}.json"
      )

    with :ok <- File.mkdir_p(dir) do
      File.write(path, Jason.encode!(record))
    end
  end

  defp refresh_command_capabilities(config) do
    if Process.whereis(FermixCore.Capabilities.Registry) do
      CommandCapabilities.refresh(FermixCore.Capabilities.Registry, config)
    else
      :ok
    end
  end

  defp inside_or_equal?(path, root), do: path == root or String.starts_with?(path, root <> "/")
end
