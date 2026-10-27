defmodule FermixCore.Jobs.CueSurface do
  @moduledoc """
  The one tool surface of a cue run (M60 §9.3, §11 S5; PLAN §1 "One cue-run
  surface"). Three callers share it, so they cannot drift: the runner, which
  hands `tools/4` to the agent loop as the run's exact allowlist; the
  whole-surface test; and `manage_watcher`'s echo of what a cue run will lack
  (`lacking/4`).

  A cue run reads and reports:

    * the base readers `file_read`, `view_image`, `glob_search`,
      `content_search` and `git_read`, narrowed by the job's allowlist and the
      skill's (a missing allowlist narrows nothing from its side);
    * `cue_history` always (its own watcher's deliveries, framed);
    * `memory_store`, `memory_recall` and `memory_forget` only when the
      watcher's task notes are on (they reach only the task's own notes);
    * the mandate's `tools` and `read_tools`, in full, never deferred; the
      runner's mandate (`Cues.Mandates.for_job/2`) carries no `read_tools`
      while the mandate is not in force, since a reader has no other check.

  Nothing else, whatever the job names: no `web_search` or `web_fetch`, no
  `shell` or `browser`, no write, exec, desktop, channel, scheduling, harness or
  delegation tool, none of the deferral bridges, no `recall_activity` or
  `voice_call_context`, and no plugin, MCP or skill capability except a
  mandate's. The list is an exact allowlist, so the agent loop answers a call
  to any other name "not available" and the registry never advertises one.
  """

  alias FermixCore.Capabilities.Capability

  @base_tools ~w(file_read view_image glob_search content_search git_read)
  @history_tool "cue_history"
  @note_tools ~w(memory_store memory_recall memory_forget)

  @typedoc "A job row, or any map carrying its `allowed_tools`."
  @type job :: %{optional(:allowed_tools) => [String.t()] | nil, optional(atom()) => term()}

  @typedoc "A loaded skill definition, or nil when the job names none."
  @type skill ::
          %{optional(:allowed_tools) => [String.t()] | nil, optional(atom()) => term()} | nil

  @typedoc "The watcher whose cue woke the run: only `task_notes?` is read."
  @type watcher :: %{required(:task_notes?) => boolean(), optional(atom()) => term()}

  @typedoc "The job's mandate (lane F), or nil: only `tools` and `read_tools` are read."
  @type mandate ::
          %{required(:tools) => [String.t()], required(:read_tools) => [String.t()]} | nil

  @doc """
  Whether a built-in capability (or a tool name) can be in a cue run's surface
  before any job, skill or notes narrowing, a mandate aside: the base readers,
  `cue_history` and the three note tools. A plugin, MCP or skill capability is
  never allowed here; only a mandate grants one (`tools/4`).
  """
  @spec allowed?(Capability.t() | String.t()) :: boolean()
  def allowed?(%Capability{kind: :builtin, name: name}), do: allowed?(name)
  def allowed?(%Capability{}), do: false

  def allowed?(name) when is_binary(name),
    do: name in @base_tools or name == @history_tool or name in @note_tools

  @doc """
  The exact tool names a cue run of `job` (with `skill`, woken through
  `watcher`, under `mandate`) is offered, in a stable order.
  """
  @spec tools(job(), skill(), watcher(), mandate()) :: [String.t()]
  def tools(job, skill, %{task_notes?: notes?} = _watcher, mandate)
      when is_map(job) and (is_map(skill) or is_nil(skill)) and is_boolean(notes?) do
    base =
      @base_tools
      |> narrow(allowlist(job))
      |> narrow(allowlist(skill))

    Enum.uniq(base ++ [@history_tool] ++ note_tools(notes?) ++ mandate_tools(mandate))
  end

  @doc """
  The tools the job's (and skill's) allowlist names that a cue run will not
  have, sorted, for Fermix's echo when a watcher links the job. A job and skill
  with no allowlist name nothing, so nothing is listed.
  """
  @spec lacking(job(), skill(), watcher(), mandate()) :: [String.t()]
  def lacking(job, skill, watcher, mandate) do
    offered = tools(job, skill, watcher, mandate)

    case named_tools(allowlist(job), allowlist(skill)) do
      nil -> []
      named -> named |> Enum.reject(&(&1 in offered)) |> Enum.uniq() |> Enum.sort()
    end
  end

  # The runner's rule (`Jobs.Runner.narrow_allowed_tools/1`): an absent or empty
  # allowlist narrows nothing from its side.
  defp allowlist(nil), do: nil

  defp allowlist(map) when is_map(map) do
    case Map.get(map, :allowed_tools) do
      nil -> nil
      [] -> nil
      list when is_list(list) -> list
    end
  end

  defp narrow(tools, nil), do: tools
  defp narrow(tools, allowed), do: Enum.filter(tools, &(&1 in allowed))

  defp named_tools(nil, nil), do: nil
  defp named_tools(job_list, nil), do: job_list
  defp named_tools(nil, skill_list), do: skill_list
  defp named_tools(job_list, skill_list), do: Enum.filter(job_list, &(&1 in skill_list))

  defp note_tools(true), do: @note_tools
  defp note_tools(false), do: []

  defp mandate_tools(nil), do: []

  defp mandate_tools(%{tools: tools, read_tools: read_tools})
       when is_list(tools) and is_list(read_tools),
       do: tools ++ read_tools
end
