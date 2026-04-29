defmodule FermixCore.Agents.SkillRegistry do
  @moduledoc """
  Filesystem-backed registry for discovered skills.

  The registry holds an in-memory snapshot of installed skills. Three roots
  feed into one snapshot, each tagged with a trust source on load:

    * `core_dir` (default: `priv/skills` inside the Fermix release) → `:core`
    * `local_dir` (default: `~/.fermix/skills`) → `:local`
    * `plugin_dir` (default: `~/.fermix/skills/_plugins`) → `:third_party`

  Anything outside the three known roots fails closed to `:third_party`. The
  `source` is recorded on the loaded `AgentDefinition.trust` field so the
  sub-agent policy gate has a stable enforcement input.

  When a `capability_registry` is configured, each loaded skill is also
  registered as a `%Capability{kind: :skill}` so the LLM can invoke skills
  by name through the unified capability surface. Stale skill capabilities
  are dropped on every reload so renamed or removed skills disappear in
  lock-step with the snapshot.
  """

  use GenServer
  require Logger

  alias FermixCore.Agents.AgentDefinition
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Capabilities.Skill

  @type skill_snapshot :: %{String.t() => AgentDefinition.t()}
  @type reload_error ::
          {:invalid_skill, String.t(), term()}
          | {:read_failed, String.t(), term()}

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

  @spec load(GenServer.server(), String.t()) ::
          {:ok, AgentDefinition.t()} | {:error, {:unknown_skill, String.t()}}
  def load(server \\ __MODULE__, skill_name) when is_binary(skill_name) do
    GenServer.call(server, {:load, skill_name})
  end

  @spec reload(GenServer.server()) :: {:ok, [String.t()]} | {:error, reload_error()}
  def reload(server \\ __MODULE__) do
    GenServer.call(server, :reload)
  end

  @impl true
  def init(opts) do
    local_dir = Keyword.get(opts, :skills_dir, default_local_dir())
    File.mkdir_p!(local_dir)

    dirs = %{
      core_dir: Keyword.get(opts, :core_dir, default_core_dir()),
      local_dir: local_dir,
      plugin_dir: Keyword.get(opts, :plugin_dir, default_plugin_dir(local_dir))
    }

    capability_registry = Keyword.get(opts, :capability_registry)
    bundled_dir = Keyword.get(opts, :bundled_dir, default_core_dir())
    maybe_seed_default_skills(local_dir, bundled_dir, opts)
    {definitions, errors} = discover(dirs)
    log_discovery_errors(errors)

    if capability_registry do
      sync_capabilities(capability_registry, %{}, definitions)
    end

    {:ok,
     %{
       skills_dir: local_dir,
       dirs: dirs,
       definitions: definitions,
       capability_registry: capability_registry
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

  def handle_call({:load, skill_name}, _from, state) do
    reply =
      case Map.fetch(state.definitions, skill_name) do
        {:ok, definition} -> {:ok, definition}
        :error -> {:error, {:unknown_skill, skill_name}}
      end

    {:reply, reply, state}
  end

  def handle_call(:reload, _from, state) do
    {definitions, errors} = discover(state.dirs)
    log_discovery_errors(errors)

    if state.capability_registry do
      sync_capabilities(state.capability_registry, state.definitions, definitions)
    end

    {:reply, {:ok, snapshot_names(definitions)}, %{state | definitions: definitions}}
  end

  defp discover(dirs) do
    [:core_dir, :local_dir, :plugin_dir]
    |> Enum.flat_map(fn key ->
      dir = Map.fetch!(dirs, key)
      list_skill_paths(dir)
    end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce({%{}, []}, fn path, {definitions, errors} ->
      case load_definition(path, dirs) do
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

  defp load_definition(path, dirs) do
    with {:ok, contents} <- read_skill_file(path),
         {:ok, attrs, system_prompt} <- split_frontmatter(contents),
         {:ok, definition} <-
           AgentDefinition.new(
             attrs
             |> Map.put("system_prompt", system_prompt)
             |> Map.put("source_path", path)
           ) do
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
      under?(skill_dir, dirs.core_dir) -> :core
      under?(skill_dir, dirs.plugin_dir) -> :third_party
      under?(skill_dir, dirs.local_dir) -> :local
      true -> :third_party
    end
  end

  defp under?(_path, nil), do: false

  defp under?(path, root) do
    expanded_root = Path.expand(root)
    expanded_path = Path.expand(path)

    expanded_path == expanded_root or
      String.starts_with?(expanded_path, expanded_root <> "/")
  end

  defp sync_capabilities(server, previous, current) do
    previous_names = MapSet.new(Map.keys(previous))
    current_names = MapSet.new(Map.keys(current))

    Enum.each(MapSet.difference(previous_names, current_names), fn name ->
      CapabilityRegistry.unregister(server, name)
    end)

    Enum.each(current, fn {name, definition} ->
      capability = Skill.from_definition(definition)
      CapabilityRegistry.unregister(server, name)

      case CapabilityRegistry.register(server, capability) do
        :ok -> :ok
        {:error, {:duplicate_name, _}} -> :ok
      end
    end)
  end

  defp read_skill_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:read_failed, path, reason}}
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

  defp skill_name_from_path(path) do
    path
    |> Path.dirname()
    |> Path.basename()
  end

  defp default_local_dir do
    Path.join(System.user_home!(), ".fermix/skills")
  end

  defp default_plugin_dir(local_dir) do
    Path.join(local_dir, "_plugins")
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
