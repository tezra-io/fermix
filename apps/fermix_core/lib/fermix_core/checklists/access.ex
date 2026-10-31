defmodule FermixCore.Checklists.Access do
  @moduledoc """
  Who may see and change the owner's lists (MILESTONE_85 §11).

  The owner's alone. The list tools, the index note and the list lines of the
  prompt exist only on the owner's attended, top-level turn in a private chat
  or the owner's own voice call (`private_owner_turn?/1`, the one notion open
  loops use, `OpenLoops.Access.private_owner_turn?/1`), so a guest, a group
  chat, a Slack channel mention, a shared Buzz session, a delegated worker and
  a coding continuation see none of them. The one other caller is a scheduled
  job whose allowed tools name the tool (`job_run?/2`): its run is at operator
  trust, and `schedule_job` gives a job these tools only from the owner's
  private turn (`check_job_tools/2`).

  What the turn had read is the other fact (`read_outside?/1`, the access
  gate's rule): after outside content, `checklist_edit` still adds and ticks,
  its rows stamped, and every other change waits for a clean turn
  (`Checklists.Ops`).
  """

  alias FermixCore.Harness.Authorization
  alias FermixCore.OpenLoops.Access, as: OpenLoopsAccess

  @tool_prefix "checklist_"

  @doc "Whether `name` is one of the list tools, by the feature's name token."
  @spec tool_name?(String.t()) :: boolean()
  def tool_name?(name) when is_binary(name), do: String.starts_with?(name, @tool_prefix)

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
  these: a job reaches a list only by naming the tool.
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
  Whether a device connection may read and change the lists (M85 §07, §11):
  only one the daemon placed as the owner's (`:independent`), the rule the
  Mac's proposals answer by; one the daemon started, a detached one or an
  unplaced one may not.
  """
  @spec device_owner?(atom() | nil) :: boolean()
  def device_owner?(caller), do: caller == :independent

  @doc "Where a change came from, as a row records it: a job's run, or the chat."
  @spec made_via(map()) :: String.t()
  def made_via(context) when is_map(context) do
    if Authorization.scheduled?(context), do: "job", else: "chat"
  end

  @doc """
  For `schedule_job`: a job may name a list tool only when it is set up on the
  owner's own private turn, the one place the tools are offered to a person.
  """
  @spec check_job_tools([String.t()], map()) :: :ok | {:error, String.t()}
  def check_job_tools(names, context) when is_list(names) and is_map(context) do
    case Enum.find(names, &tool_name?/1) do
      nil ->
        :ok

      name ->
        if private_owner_turn?(context), do: :ok, else: {:error, job_refusal(name)}
    end
  end

  defp job_refusal(name) do
    "#{name} can be given to a job only from the owner's own private chat or their voice " <>
      "call, so this job was not set up; ask the owner to set it up there."
  end

  @doc "The sentence a list tool returns on a turn that may not use it, naming the tool."
  @spec refusal(String.t()) :: String.t()
  def refusal(tool) when is_binary(tool) and tool != "" do
    "#{tool} is available only on the owner's own turn in a private chat or a voice call, or " <>
      "in a scheduled job set up there that names it; group chats and guest, delegated and " <>
      "other runs cannot read or change the owner's lists."
  end

  @doc "The sentence for any op but an add or a check after outside content."
  @spec outside_refusal() :: String.t()
  def outside_refusal,
    do: "That change waits for a turn that read nothing from outside; ask me again."
end
