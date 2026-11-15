defmodule FermixCore.Checklists.Access do
  @moduledoc """
  The sentences the owner's lists refuse a caller with (MILESTONE_85 §11).

  Who may call is the rule every kept kind shares (`Kept.Access`): the owner's
  attended, top-level turn in a private chat or the owner's own voice call, or
  a scheduled job whose allowed tools name the tool. After outside content
  `checklist_edit` still adds and ticks, its rows stamped, and every other
  change waits for a clean turn (`Checklists.Ops`).
  """

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
