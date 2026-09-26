defmodule FermixCore.SoulCuration.UnreviewedEditNotice do
  @moduledoc """
  The one owner line sent when `SOUL.md` changed on disk outside `/soul`.

  Every reviewed writer of `SOUL.md` (setup seeding, template adoption, `/soul
  apply|revert|reset`) records the new bytes in `Resource.Registry` before the
  prompt is rebuilt, so a file whose hash the registry does not hold was
  written by something no review saw: a hand edit, a shell command, a steered
  agent. `Prompt.BootstrapLoader` records that change as an `unreviewed_edit`
  revision and calls `notify/1` once for it, and this line tells the owner how
  to undo it with the `/soul revert` they already have.

  The line is Fermix-authored and goes to the owner's private inbox
  (`Delivery.OwnerInbox`), never into the conversation whose turn happened to
  rebuild the prompt, which may be a group.
  """

  require Logger

  alias FermixCore.Delivery.ChannelSend
  alias FermixCore.Delivery.OwnerInbox

  @type event :: %{path: String.t(), revision: pos_integer()}

  @doc """
  Sends the notice from a supervised task, so a prompt build never waits on a
  channel. A send that cannot happen is logged with its reason; the revision
  stays in `/soul history` either way. Starting the task is asserted, not
  logged: `FermixCore.TaskSupervisor` has no child cap, so it fails only when
  the daemon's supervision tree is down, which no prompt build should outlive.
  """
  @spec notify(event()) :: :ok
  def notify(%{path: path, revision: revision} = event)
      when is_binary(path) and is_integer(revision) and revision > 1 do
    {:ok, _pid} =
      Task.Supervisor.start_child(FermixCore.TaskSupervisor, fn -> deliver_or_log(event) end)

    :ok
  end

  @doc """
  Resolves the owner's inbox and sends the notice through `ChannelSend`.

  Seams: `OwnerInbox`'s `:jobs_config` and `:configured_owners`, and
  `ChannelSend`'s `:adapter` and `:channels`.
  """
  @spec deliver(event(), keyword()) :: :ok | :no_delivery_target | {:error, term()}
  def deliver(%{revision: revision} = event, opts \\ [])
      when is_integer(revision) and revision > 1 and is_list(opts) do
    case OwnerInbox.resolve(opts) do
      {:ok, inbox} ->
        send_opts = Keyword.take(opts, [:adapter, :channels])
        ChannelSend.send(inbox.platform, inbox.destination, text(event), [], send_opts)

      :no_delivery_target ->
        :no_delivery_target
    end
  end

  @doc "The notice text: the new revision and the `/soul revert` that undoes it."
  @spec text(event()) :: String.t()
  def text(%{revision: revision}) when is_integer(revision) and revision > 1 do
    "SOUL.md changed on disk outside /soul and is now revision #{revision}. " <>
      "If you didn't make this change, `/soul revert #{revision - 1}` undoes it; " <>
      "`/soul history` lists every revision."
  end

  defp deliver_or_log(event) do
    case deliver(event) do
      :ok ->
        :ok

      :no_delivery_target ->
        Logger.warning(
          "SOUL.md changed outside /soul (revision #{event.revision}); " <>
            "no owner inbox is configured, so the owner was not told"
        )

      {:error, reason} ->
        Logger.warning(
          "SOUL.md changed outside /soul (revision #{event.revision}); " <>
            "the owner notice failed: #{inspect(reason)}"
        )
    end
  end
end
