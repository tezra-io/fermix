defmodule FermixCore.Native do
  @moduledoc """
  The computer's own services (M76 §4.3): what this computer offers beyond
  pixels, behind one seam. `Native.Provider` answers, from the build, who
  serves them (the Fermix app on a Mac, the session bus on Linux, or nobody),
  and each service (`Native.Notifications`) resolves its backend from that.

  `local_surface?/1` is the one answer to "is the person at this computer" on
  a turn (§4.6). It reads the tool context `TurnRunner` builds for every turn:
  `channel` (the message's channel string) and `computer_use_origin`, which
  `TurnRunner.computer_use_origin/1` derives. Every reader of the question
  asks here (whether a turn may raise a permission prompt, which caller "snooze
  that" may match a reminder rung on this computer for), so no two of them can
  disagree about what counts as this computer.
  """

  # The surfaces only this computer can reach, each a socket in the daemon's
  # home: the Mac app's chat (`companion`), `fermix ask` (`cli`), and an editor
  # or the Linux app's chat over `acp.sock` (`acp`).
  @local_channels ["companion", "cli", "acp"]

  @doc """
  Whether the person is at this computer on the turn `context` describes.

  True for an attended turn on one of this computer's own sockets (the Mac
  chat, `fermix ask`, an editor) and for a Live voice call, which only the
  local voice socket carries. False for every chat channel and the phone,
  though `computer_use_origin/1` marks their foreground turns attended too
  (`:interactive`): attended is not proof the person is here. False, too, for
  a prompt a local socket carried for nobody (`:unattended`: a process the
  daemon started, a detached one, a re-ingested coding notice), and for a
  context that names no origin, such as a scheduled run's: absence is never
  read as presence.
  """
  @spec local_surface?(map()) :: boolean()
  def local_surface?(context) when is_map(context) do
    case Map.get(context, :computer_use_origin) do
      :voice -> true
      :interactive -> Map.get(context, :channel) in @local_channels
      _unattended_or_absent -> false
    end
  end
end
