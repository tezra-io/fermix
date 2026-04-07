defmodule FermixCore.Agents.SkillRegistry do
  @moduledoc """
  Filesystem-backed registry for discovered skills.

  The registry holds an in-memory snapshot of `~/.fermix/skills/`. New, removed,
  or changed skills do not affect callers until `reload/1` is called. Discovery
  fails fast on the first invalid skill file during init or reload, and a failed
  reload preserves the previous snapshot.
  """

  use GenServer

  alias FermixCore.Agents.AgentDefinition

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
    skills_dir = Keyword.get(opts, :skills_dir, default_skills_dir())
    File.mkdir_p!(skills_dir)

    case discover(skills_dir) do
      {:ok, definitions} ->
        {:ok, %{skills_dir: skills_dir, definitions: definitions}}

      {:error, reason} ->
        {:stop, reason}
    end
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
    case discover(state.skills_dir) do
      {:ok, definitions} ->
        {:reply, {:ok, snapshot_names(definitions)}, %{state | definitions: definitions}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp discover(skills_dir) do
    skills_dir
    |> Path.join("*/SKILL.md")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, definitions} ->
      case load_definition(path) do
        {:ok, definition} ->
          {:cont, {:ok, Map.put(definitions, definition.name, definition)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp load_definition(path) do
    with {:ok, contents} <- read_skill_file(path),
         {:ok, attrs, system_prompt} <- split_frontmatter(contents),
         {:ok, definition} <-
           AgentDefinition.new(
             attrs
             |> Map.put("system_prompt", system_prompt)
             |> Map.put("source_path", path)
           ) do
      {:ok, definition}
    else
      {:error, reason} ->
        {:error, {:invalid_skill, skill_name_from_path(path), reason}}
    end
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

  defp default_skills_dir do
    Path.join(System.user_home!(), ".fermix/skills")
  end
end
