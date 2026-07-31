defmodule FermixCore.Agents.SkillRegistry do
  @moduledoc """
  Filesystem-backed registry for discovered skills.

  The registry holds an in-memory snapshot of installed skills. Three roots
  feed into one snapshot, each tagged with a trust source on load:

    * `core_dir` (default: `priv/skills` inside the Fermix release) → `:operator`
    * `local_dir` (default: `$FERMIX_HOME/skills`, i.e. `~/.fermix/skills`) → `:operator`
    * `plugin_skill_dirs` (enabled plugin skill roots under `$FERMIX_HOME/plugins`) → `:guest`

  Local and plugin roots resolve through `ConfigStore` so they follow
  `FERMIX_HOME` (dev daemons, tests) instead of hardcoding the real home.

  Bundled and user-installed skills are operator-trusted (the operator
  vetted them by installing). Plugin-loaded skills and anything outside
  the three known roots fail closed to `:guest` (read-only). The
  `source` is recorded on the loaded `AgentDefinition.trust` field so
  the sub-agent policy gate has a stable enforcement input.

  Skills are not registered as provider-visible capabilities. The main
  runtime renders a compact catalog and uses `skill_view` / `skill_run`
  built-ins for progressive disclosure and delegation.
  """

  use GenServer
  require Logger

  alias FermixCore.Agents.AgentDefinition
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Plugins.Registry, as: PluginRegistry
  alias FermixCore.Setup.ConfigStore

  @type skill_snapshot :: %{String.t() => AgentDefinition.t()}
  @type reload_error ::
          {:invalid_skill, String.t(), term()}
          | {:read_failed, String.t(), term()}

  # Reference file names are confined to a strict lowercase alphabet: no dots,
  # slashes, or `..`, so a name can never traverse out of `references/`.
  @reference_name_pattern ~r/^[a-z0-9_]{1,64}$/

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec list(GenServer.server()) :: [String.t()]
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  @spec list_detailed(GenServer.server()) :: [AgentDefinition.t()]
  def list_detailed(server \\ __MODULE__) do
    GenServer.call(server, :list_detailed)
  end

  @spec snapshot(GenServer.server()) :: {:ok, map()}
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @spec load(GenServer.server(), String.t()) ::
          {:ok, AgentDefinition.t()} | {:error, {:unknown_skill, String.t()}}
  def load(server \\ __MODULE__, skill_name) when is_binary(skill_name) do
    GenServer.call(server, {:load, skill_name})
  end

  @spec reload(GenServer.server()) :: {:ok, map()} | {:error, reload_error()}
  def reload(server \\ __MODULE__) do
    GenServer.call(server, :reload)
  end

  @typedoc "Errors returned by `read_reference/3`."
  @type reference_error ::
          {:unknown_skill, String.t()}
          | {:invalid_reference_name, String.t()}
          | {:reference_not_found, term()}
          | {:read_failed, term()}

  @doc """
  Read a bundled reference file for a loaded skill.

  Reference files live in `<skill_dir>/references/<ref_name>.md`, seeded
  alongside the skill by `File.cp_r`. `ref_name` is confined to
  `^[a-z0-9_]{1,64}$` (no dots, slashes, or `..`) and the resolved path is
  asserted to stay strictly under the skill's own `references/` directory; a
  symlink at either the `references/` directory or the reference file is refused
  so a read can never escape the skill tree. This is a server-side read so it is
  independent of the sandbox (skills under `$FERMIX_HOME` are not a sandbox
  root in strict/standard mode).
  """
  @spec read_reference(GenServer.server(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, reference_error()}
  def read_reference(server \\ __MODULE__, skill_name, ref_name)
      when is_binary(skill_name) and is_binary(ref_name) do
    GenServer.call(server, {:read_reference, skill_name, ref_name})
  end

  @impl true
  def init(opts) do
    local_dir = Keyword.get(opts, :skills_dir, default_local_dir())
    File.mkdir_p!(local_dir)

    dirs = %{
      core_dir: Keyword.get(opts, :core_dir, default_core_dir()),
      local_dir: local_dir,
      plugin_skill_dirs:
        Keyword.get(opts, :plugin_skill_dirs, PluginRegistry.enabled_skill_dirs())
    }

    capability_registry = Keyword.get(opts, :capability_registry)
    bundled_dir = Keyword.get(opts, :bundled_dir, default_core_dir())
    maybe_seed_default_skills(local_dir, bundled_dir, opts)

    cleanup_stale_skill_capabilities(capability_registry)
    {definitions, errors} = discover(dirs, capability_registry)
    log_discovery_errors(errors)

    {:ok,
     %{
       skills_dir: local_dir,
       dirs: dirs,
       definitions: definitions,
       capability_registry: capability_registry,
       version: 1,
       errors: errors
     }}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, snapshot_names(state.definitions), state}
  end

  def handle_call(:list_detailed, _from, state) do
    detailed =
      state.definitions
      |> Map.values()
      |> Enum.sort_by(& &1.name)

    {:reply, detailed, state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, {:ok, snapshot_from_state(state)}, state}
  end

  def handle_call({:load, skill_name}, _from, state) do
    reply =
      case Map.fetch(state.definitions, skill_name) do
        {:ok, definition} -> {:ok, definition}
        :error -> {:error, {:unknown_skill, skill_name}}
      end

    {:reply, reply, state}
  end

  def handle_call({:read_reference, skill_name, ref_name}, _from, state) do
    {:reply, read_reference_from_state(state, skill_name, ref_name), state}
  end

  def handle_call(:reload, _from, state) do
    cleanup_stale_skill_capabilities(state.capability_registry)
    dirs = refresh_plugin_skill_dirs(state.dirs)
    {definitions, errors} = discover(dirs, state.capability_registry)
    log_discovery_errors(errors)

    version = state.version + 1
    summary = reload_summary(state.definitions, definitions, errors, version)

    {:reply, {:ok, summary},
     %{state | dirs: dirs, definitions: definitions, errors: errors, version: version}}
  end

  defp discover(dirs, capability_registry) do
    dirs
    |> discovery_dirs()
    |> Enum.flat_map(fn {_source, dir} -> list_skill_paths(dir) end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce({%{}, []}, fn path, {definitions, errors} ->
      case load_definition(path, dirs, capability_registry) do
        {:ok, definition} ->
          {Map.put(definitions, definition.name, definition), errors}

        {:error, reason} ->
          {definitions, [reason | errors]}
      end
    end)
    |> then(fn {definitions, errors} -> {definitions, Enum.reverse(errors)} end)
  end

  defp list_skill_paths(dir) when is_binary(dir) do
    dir
    |> Path.join("*/SKILL.md")
    |> Path.wildcard()
  end

  defp list_skill_paths(nil), do: []

  defp load_definition(path, dirs, capability_registry) do
    with {:ok, contents} <- read_skill_file(path),
         {:ok, attrs, system_prompt} <- split_frontmatter(contents),
         {:ok, definition} <-
           AgentDefinition.new(
             attrs
             |> Map.put("system_prompt", system_prompt)
             |> Map.put("source_path", path)
           ),
         :ok <- validate_no_capability_collision(definition, capability_registry) do
      trust = classify_source(path, dirs)
      {:ok, AgentDefinition.with_trust(definition, trust)}
    else
      {:error, reason} ->
        {:error, {:invalid_skill, skill_name_from_path(path), reason}}
    end
  end

  defp classify_source(skill_path, dirs) do
    skill_dir = Path.dirname(skill_path)

    cond do
      under?(skill_dir, dirs.core_dir) -> :operator
      under_any?(skill_dir, Map.get(dirs, :plugin_skill_dirs, [])) -> :guest
      under?(skill_dir, dirs.local_dir) -> :operator
      true -> :guest
    end
  end

  defp discovery_dirs(dirs) do
    base = [
      {:core_dir, Map.get(dirs, :core_dir)},
      {:local_dir, Map.get(dirs, :local_dir)}
    ]

    plugin_dirs =
      dirs
      |> Map.get(:plugin_skill_dirs, [])
      |> Enum.map(&{:plugin_skill_dir, &1})

    base ++ plugin_dirs
  end

  defp refresh_plugin_skill_dirs(dirs) do
    Map.put(dirs, :plugin_skill_dirs, PluginRegistry.enabled_skill_dirs())
  end

  defp under?(_path, nil), do: false

  defp under?(path, root) do
    expanded_root = Path.expand(root)
    expanded_path = Path.expand(path)

    expanded_path == expanded_root or
      String.starts_with?(expanded_path, expanded_root <> "/")
  end

  defp under_any?(path, roots) when is_list(roots) do
    Enum.any?(roots, &under?(path, &1))
  end

  defp validate_no_capability_collision(_definition, nil), do: :ok

  defp validate_no_capability_collision(%AgentDefinition{name: name}, server) do
    case CapabilityRegistry.find(server, name) do
      {:ok, %{kind: kind}} -> {:error, {:name_collision, name, kind}}
      :error -> :ok
    end
  end

  defp cleanup_stale_skill_capabilities(nil), do: :ok

  defp cleanup_stale_skill_capabilities(server) do
    CapabilityRegistry.unregister_kind(server, :skill)
  end

  defp read_skill_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:read_failed, path, reason}}
    end
  end

  defp read_reference_from_state(state, skill_name, ref_name) do
    with {:ok, definition} <- fetch_definition(state, skill_name),
         {:ok, safe_name} <- validate_reference_name(ref_name),
         {:ok, path} <- resolve_reference_path(definition.source_path, safe_name) do
      read_reference_file(path)
    end
  end

  defp fetch_definition(state, skill_name) do
    case Map.fetch(state.definitions, skill_name) do
      {:ok, definition} -> {:ok, definition}
      :error -> {:error, {:unknown_skill, skill_name}}
    end
  end

  defp validate_reference_name(ref_name) do
    if String.match?(ref_name, @reference_name_pattern) do
      {:ok, ref_name}
    else
      {:error, {:invalid_reference_name, ref_name}}
    end
  end

  defp resolve_reference_path(source_path, safe_name) when is_binary(source_path) do
    references_dir =
      source_path
      |> Path.dirname()
      |> Path.join("references")
      |> Path.expand()

    candidate = references_dir |> Path.join(safe_name <> ".md") |> Path.expand()

    with :ok <- assert_confined(candidate, references_dir, safe_name),
         :ok <- assert_real_directory(references_dir) do
      {:ok, candidate}
    end
  end

  defp resolve_reference_path(_source_path, safe_name) do
    {:error, {:reference_not_found, safe_name}}
  end

  defp assert_confined(candidate, references_dir, safe_name) do
    if String.starts_with?(candidate, references_dir <> "/") do
      :ok
    else
      {:error, {:invalid_reference_name, safe_name}}
    end
  end

  # `references_dir` must be a real directory, not a symlink. `Path.expand`
  # resolves `.`/`..` lexically but never symlinks, so a `references` symlink
  # pointing outside the skill dir would pass the lexical prefix check above and
  # let a read escape the skill tree — the final-component `File.lstat` in
  # `read_reference_file` follows that intermediate symlink. `File.lstat` here
  # does not follow the last component, so a symlinked references dir is refused
  # before any file is read.
  defp assert_real_directory(references_dir) do
    case File.lstat(references_dir) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _stat} -> {:error, {:reference_not_found, references_dir}}
      {:error, :enoent} -> {:error, {:reference_not_found, references_dir}}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  # File.lstat does not follow symlinks, so a symlinked reference is rejected
  # instead of read — it can never escape the references dir.
  defp read_reference_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> read_regular_file(path)
      {:ok, _stat} -> {:error, {:reference_not_found, path}}
      {:error, :enoent} -> {:error, {:reference_not_found, path}}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  defp read_regular_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  defp split_frontmatter(contents) do
    case Regex.run(~r/\A---\r?\n(.*?)\r?\n---\r?\n?(.*)\z/s, contents) do
      [_, frontmatter, body] ->
        with {:ok, attrs} <- parse_frontmatter(frontmatter) do
          {:ok, attrs, String.trim(body)}
        end

      _ ->
        {:error, :missing_frontmatter}
    end
  end

  defp parse_frontmatter(frontmatter) do
    frontmatter
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, attrs} ->
      attrs
      |> parse_frontmatter_line(String.trim(line))
    end)
  end

  defp parse_frontmatter_line(attrs, ""), do: {:cont, {:ok, attrs}}
  defp parse_frontmatter_line(attrs, "#" <> _line), do: {:cont, {:ok, attrs}}

  defp parse_frontmatter_line(attrs, line) do
    case String.split(line, ":", parts: 2) do
      [key, value] ->
        case parse_scalar(String.trim(value)) do
          {:ok, parsed} -> {:cont, {:ok, Map.put(attrs, String.trim(key), parsed)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _ ->
        {:halt, {:error, {:invalid_frontmatter_line, line}}}
    end
  end

  defp parse_scalar(""), do: {:ok, ""}
  defp parse_scalar("true"), do: {:ok, true}
  defp parse_scalar("false"), do: {:ok, false}

  defp parse_scalar(value) do
    cond do
      String.starts_with?(value, "[") ->
        Jason.decode(value)

      match?({_, ""}, Integer.parse(value)) ->
        {parsed, ""} = Integer.parse(value)
        {:ok, parsed}

      match?({_, ""}, Float.parse(value)) ->
        {parsed, ""} = Float.parse(value)
        {:ok, parsed}

      quoted_string?(value) ->
        {:ok, String.slice(value, 1, byte_size(value) - 2)}

      true ->
        {:ok, value}
    end
  end

  defp quoted_string?(value) do
    String.length(value) >= 2 and String.starts_with?(value, "\"") and
      String.ends_with?(value, "\"")
  end

  defp snapshot_names(definitions) do
    definitions
    |> Map.keys()
    |> Enum.sort()
  end

  defp snapshot_skills(definitions) do
    definitions
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  defp snapshot_from_state(state) do
    %{
      version: state.version,
      skills: snapshot_skills(state.definitions),
      errors: state.errors
    }
  end

  defp reload_summary(previous, current, errors, version) do
    previous_names = MapSet.new(Map.keys(previous))
    current_names = MapSet.new(Map.keys(current))

    added = MapSet.difference(current_names, previous_names)
    removed = MapSet.difference(previous_names, current_names)
    shared = MapSet.intersection(previous_names, current_names)

    changed =
      shared
      |> Enum.filter(fn name -> Map.fetch!(previous, name) != Map.fetch!(current, name) end)
      |> Enum.sort()

    %{
      version: version,
      skills: snapshot_skills(current),
      names: snapshot_names(current),
      added: added |> MapSet.to_list() |> Enum.sort(),
      removed: removed |> MapSet.to_list() |> Enum.sort(),
      changed: changed,
      errors: errors
    }
  end

  defp skill_name_from_path(path) do
    path
    |> Path.dirname()
    |> Path.basename()
  end

  defp default_local_dir do
    ConfigStore.workspace_paths().skills
  end

  defp default_core_dir do
    case :code.priv_dir(:fermix_core) do
      {:error, _reason} -> nil
      priv -> priv |> to_string() |> Path.join("skills")
    end
  end

  defp maybe_seed_default_skills(skills_dir, bundled_dir, opts) do
    if should_seed_default_skills?(skills_dir, opts) and directory_empty?(skills_dir) do
      seed_default_skills(skills_dir, bundled_dir)
    end
  end

  defp should_seed_default_skills?(skills_dir, opts) do
    Keyword.get(
      opts,
      :seed_defaults,
      Path.expand(skills_dir) == Path.expand(default_local_dir())
    )
  end

  defp seed_default_skills(_skills_dir, nil), do: :ok

  defp seed_default_skills(skills_dir, bundled) do
    bundled
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.reject(&File.exists?(Path.join(skills_dir, Path.basename(&1))))
    |> Enum.each(fn source_dir ->
      File.cp_r!(source_dir, Path.join(skills_dir, Path.basename(source_dir)))
    end)
  end

  defp directory_empty?(path) do
    case File.ls(path) do
      {:ok, []} -> true
      {:ok, _entries} -> false
      {:error, _reason} -> true
    end
  end

  defp log_discovery_errors([]), do: :ok

  defp log_discovery_errors(errors) do
    Enum.each(errors, fn error ->
      Logger.warning("Skipping invalid skill during discovery: #{inspect(error)}")
    end)
  end
end
