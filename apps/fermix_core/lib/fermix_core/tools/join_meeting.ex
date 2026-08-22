defmodule FermixCore.Tools.JoinMeeting do
  @moduledoc """
  Send the notetaker into a live meeting (MILESTONE_21 C2 §14.1).

  This module is the operator-facing surface of `FermixCore.Meetings.join/2`
  and nothing more: the URL and the operator's title go straight through, and a
  refusal is rendered as the sentence that says which thing to turn on. Every
  decision — which capture lane the URL needs, whether that lane is usable,
  whether another meeting is already running — belongs to `Meetings`, so the
  tool cannot drift from the subsystem's own admission rules.

  Attended-owner-only at advertisement and at execution, through the same
  `Temporal.Access` predicate the temporal event tools use. `Meetings.join/2`
  repeats that check as its second gate; this one keeps the tool out of a
  guest's, a subagent's, and a scheduled run's surface in the first place.

  The call returns as soon as the meeting has a session. Joining, admission,
  capture, the summary, and its delivery all happen afterwards.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Meetings
  alias FermixCore.Memory.Repo
  alias FermixCore.Temporal.Access
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @impl true
  @spec name() :: String.t()
  def name, do: "join_meeting"

  @impl true
  @spec description() :: String.t()
  def description do
    "Send Fermix's notetaker into a Google Meet or Zoom meeting to take notes. " <>
      "Use it only when the owner explicitly asks for it: the notetaker joins as a " <>
      "visible participant under its own name and announces itself in the meeting " <>
      "chat, so everyone in the room can see it, and joining a meeting nobody asked " <>
      "it to join is not a small mistake. It never speaks and keeps no audio. " <>
      "The call returns while the notetaker is still on its way in, so say it is " <>
      "joining rather than that it has joined; the notes arrive as a message when " <>
      "the meeting ends."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["url"],
      properties: %{
        url: %{
          type: "string",
          description:
            "The meeting link the owner gave, verbatim — a meet.google.com link or a " <>
              "zoom.us join link. Do not construct one from a meeting id."
        },
        title: %{
          type: "string",
          description: "Optional name for the meeting, used in the notes the owner receives."
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "The owner explicitly asks Fermix to sit in on a meeting and take notes, and gives " <>
      "the meeting link."
  end

  @impl true
  def examples do
    [
      %{
        args: %{"url" => "https://meet.google.com/abc-defg-hij", "title" => "Design review"},
        note: "a Google Meet the owner asked the notetaker to attend"
      },
      %{
        args: %{"url" => "https://zoom.us/j/98765432101"},
        note: "a Zoom meeting hosted on the owner's own account"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "meetings_disabled", description: "the meetings subsystem is turned off"},
      %{tag: "unrecognized_meeting_url", description: "the link is not a Meet or Zoom meeting"},
      %{tag: "sidecar_not_installed", description: "the Google Meet notetaker is not installed"},
      %{
        tag: "meet_browser_not_installed",
        description: "the Google Meet notetaker has no browser to drive"
      },
      %{tag: "zoom_rtms_not_configured", description: "the Zoom RTMS credentials are incomplete"},
      %{tag: "max_concurrent", description: "the notetaker is already in another meeting"},
      %{tag: "not_attended", description: "the turn is not an attended top-level owner turn"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :scheduling

  @doc "Attended-owner-only; the same predicate re-runs inside `execute/2` and in `Meetings.join/2`."
  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context), do: Access.attended_operator_turn?(context)

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    start = System.monotonic_time(:millisecond)
    result = gated(args, context)
    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    ToolTelemetry.exec(name(), context, success, duration, input: args, result: result)
    result
  end

  @doc """
  The operator-facing sentence for a `t:FermixCore.Meetings.join_error/0`
  (C2 §1.2).

  Public so the copy has a test of its own: `{:max_concurrent, id}` is only
  reachable with a meeting actually running, and copy that says the wrong thing
  to turn on is exactly the failure this wording exists to prevent.
  """
  @spec describe_error(Meetings.join_error()) :: String.t()
  def describe_error(:meetings_disabled) do
    "The meeting notetaker is turned off. Open fermix setup (web) → Meetings to enable it."
  end

  def describe_error(:operator_only), do: refusal()

  def describe_error(:unrecognized_meeting_url) do
    "That is not a meeting link Fermix can place. Send the meeting URL itself — a " <>
      "meet.google.com link or a zoom.us join link."
  end

  def describe_error(:sidecar_not_installed) do
    "The Google Meet notetaker isn't installed yet. Open fermix setup (web) → Meetings " <>
      "and enable it there to install the meetbot sidecar."
  end

  def describe_error(:meet_browser_not_installed) do
    "The Google Meet notetaker is installed but has no browser to drive, so it cannot join " <>
      "a Meet call yet. Open fermix setup (web) → Meetings and it installs the browser."
  end

  def describe_error(:zoom_rtms_not_configured) do
    "Zoom meetings use Zoom RTMS, which isn't configured. RTMS works for meetings hosted " <>
      "by your own Zoom account (or a host who has enabled your RTMS app): create a Zoom " <>
      "Server-to-Server OAuth app with RTMS scopes and set its credentials in fermix setup " <>
      "→ Meetings. Meetings hosted by other accounts can't be joined this way — that's a " <>
      "Zoom platform limit, not a missing key."
  end

  def describe_error({:max_concurrent, id}) when is_binary(id) do
    "I'm already in a meeting (#{id}). Ask me to leave it first — I join one meeting at a time."
  end

  def describe_error(reason), do: "Joining that meeting failed: #{inspect(reason)}."

  defp gated(args, context) do
    if Access.attended_operator_turn?(context) do
      requested(args, context)
    else
      {:ok, Tool.error(refusal())}
    end
  end

  defp requested(args, context) do
    case Map.get(args, "url") do
      url when is_binary(url) and url != "" -> join(url, args, context)
      _missing -> {:ok, Tool.error("Missing required parameter: url")}
    end
  end

  defp join(url, args, context) do
    opts = [
      title: title(args),
      context: context,
      store_opts: [server: Map.get(context, :memory_repo, Repo)]
    ]

    case Meetings.join(url, opts) do
      {:ok, joining} -> {:ok, Tool.success(Jason.encode!(view(joining)))}
      {:error, reason} -> {:ok, Tool.error(describe_error(reason))}
    end
  end

  # `status` is the state the meeting is in when this call returns, not the
  # state it will reach: the acknowledgement must not claim the notetaker is in
  # the room before it has been admitted.
  defp view(%{id: id, status: status}) do
    %{
      "id" => id,
      "status" => Atom.to_string(status),
      "note" =>
        "The notetaker is on its way in and has not been admitted yet. Say it is joining, " <>
          "not that it has joined. The notes are delivered as a message once the meeting ends."
    }
  end

  defp title(args) do
    case Map.get(args, "title") do
      title when is_binary(title) and title != "" -> title
      _absent -> nil
    end
  end

  defp refusal do
    "#{name()} is available only on an attended, top-level turn the owner is present " <>
      "for. Guest, scheduled, background, delegated, and coding-continuation runs cannot " <>
      "use the meeting notetaker."
  end
end
