defmodule FermixCore.Kept.Access do
  @moduledoc """
  Who may see and change what Fermix keeps for the owner (M89 §07, §14; the
  lists' MILESTONE_85 §11): one rule for every kept kind, named by its tools'
  prefixes (`tool_prefixes/0`).

  The owner's alone. A kept kind's tools, its per-turn lines and its index
  exist only on the owner's attended, top-level turn in a private chat or the
  owner's own voice call (`private_owner_turn?/1`, the one notion open loops
  use, `OpenLoops.Access.private_owner_turn?/1`), so a guest, a group chat, a
  Slack channel mention, a shared Buzz session, a delegated worker and a
  coding continuation see none of them. The one other caller is a scheduled
  job whose allowed tools name the tool (`job_run?/2`): its run is at operator
  trust, and `schedule_job` gives a job a kept kind's tools only from the
  owner's private turn, and only one that has read nothing from outside
  (`check_job_tools/2`). A device reads and changes them
  only over a connection the daemon placed as the owner's (`device_gate/1`).

  What the turn had read is the other fact (`read_outside?/1`, the access
  gate's rule): after outside content each kind runs only the ops it allows
  there, and what such an op adds is stamped and framed when read back
  (`outside_frame/0`). Which ops a kind allows, and its sentences, are the
  kind's own.
  """

  alias FermixCore.Harness.Authorization
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.OpenLoops.Access, as: OpenLoopsAccess

  # The lists' tools, and the trips' to come (M89 §14).
  @tool_prefixes ["checklist_", "trip_"]
  @outside_frame "(added after outside content)"

  @doc "The prefixes that name a kept kind's tools."
  @spec tool_prefixes() :: [String.t()]
  def tool_prefixes, do: @tool_prefixes

  @doc "Whether `name` is one of a kept kind's tools, by its prefix."
  @spec tool_name?(String.t()) :: boolean()
  def tool_name?(name) when is_binary(name), do: String.starts_with?(name, @tool_prefixes)

  @doc """
  Whether `context` is the owner's attended, top-level turn in a private chat
  or the owner's own voice call.
  """
  @spec private_owner_turn?(map()) :: boolean()
  def private_owner_turn?(context) when is_map(context),
    do: OpenLoopsAccess.private_owner_turn?(context)

  @doc """
  Whether `context` is a scheduled job's run at operator trust whose allowed
  tools name `tool`. A job whose list is empty runs with every tool, but not
  these: a job reaches a kept thing only by naming the tool.
  """
  @spec job_run?(map(), String.t()) :: boolean()
  def job_run?(context, tool) when is_map(context) and is_binary(tool) do
    Authorization.scheduled?(context) and
      Map.get(context, :source_trust) == :operator and
      Map.get(context, :effective_trust) == :operator and
      tool in List.wrap(Map.get(context, :effective_allowed_tools))
  end

  @doc "Whether `context` may use `tool`: the owner's private turn, or a job that names it."
  @spec permitted?(map(), String.t()) :: boolean()
  def permitted?(context, tool) when is_map(context) and is_binary(tool),
    do: private_owner_turn?(context) or job_run?(context, tool)

  @doc """
  Whether the turn in `context` may have read content someone else could have
  written; an absent or malformed record counts, as the access gate reads it.
  """
  @spec read_outside?(map()) :: boolean()
  def read_outside?(context) when is_map(context), do: OpenLoopsAccess.read_outside?(context)

  @doc """
  Whether a device connection may read and change what Fermix keeps (M85 §07,
  §11): only one the daemon placed as the owner's (`:independent`), the rule
  the Mac's proposals answer by; one the daemon started, a detached one or an
  unplaced one may not.
  """
  @spec device_owner?(atom() | nil) :: boolean()
  def device_owner?(caller), do: caller == :independent

  @doc "`device_owner?/1` as a gate: `{:error, :not_owner}` for any other connection."
  @spec device_gate(atom() | nil) :: :ok | {:error, :not_owner}
  def device_gate(caller), do: if(device_owner?(caller), do: :ok, else: {:error, :not_owner})

  @doc "The owner a device's read or edit is for, as a turn's context names it."
  @spec device_context() :: %{memory_owner_id: String.t(), memory_agent_id: String.t()}
  def device_context,
    do: %{memory_owner_id: MemoryConfig.owner_id(), memory_agent_id: MemoryConfig.agent_id()}

  @doc "The wire a device's change came over, as a row records it: the Mac's or a phone's."
  @spec device_made_via!(String.t()) :: String.t()
  def device_made_via!(made_via) when made_via in ["mac", "phone"], do: made_via

  @doc "Where a change came from, as a row records it: a job's run, or the chat."
  @spec made_via(map()) :: String.t()
  def made_via(context) when is_map(context) do
    if Authorization.scheduled?(context), do: "job", else: "chat"
  end

  @doc """
  For `schedule_job`: a job may name a kept kind's tool only when it is set up
  on the owner's own private turn, the one place the tools are offered to a
  person, and only from one that has read nothing from outside: a job's run is
  at operator trust and reads nothing, so every op runs there, and what a
  page asked for would land through it whole.
  """
  @spec check_job_tools([String.t()], map()) :: :ok | {:error, String.t()}
  def check_job_tools(names, context) when is_list(names) and is_map(context) do
    case Enum.find(names, &tool_name?/1) do
      nil -> :ok
      name -> job_turn(name, context)
    end
  end

  defp job_turn(name, context) do
    cond do
      not private_owner_turn?(context) -> {:error, job_refusal(name)}
      read_outside?(context) -> {:error, outside_job_refusal(name)}
      true -> :ok
    end
  end

  defp job_refusal(name) do
    "#{name} can be given to a job only from the owner's own private chat or their voice " <>
      "call, so this job was not set up; ask the owner to set it up there."
  end

  defp outside_job_refusal(name) do
    "#{name} can't be given to a job from a turn that has read something from outside, " <>
      "since the job would change the owner's things without them; this job was not set " <>
      "up, so say what it would do and ask the owner to set it up in their next message."
  end

  @doc "The mark that frames what was written after outside content, when it is read back."
  @spec outside_frame() :: String.t()
  def outside_frame, do: @outside_frame
end
