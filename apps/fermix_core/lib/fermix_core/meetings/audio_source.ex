defmodule FermixCore.Meetings.AudioSource do
  @moduledoc """
  One normalized message set from either capture lane to the Session.

  `FermixCore.Meetings.SidecarSource` (Google Meet, via the meetbot sidecar) and
  `FermixCore.Meetings.RtmsSource` (Zoom, via Zoom RTMS) both implement this
  behaviour, so the Session's state machine never branches on the platform. A
  source process is *monitored*, not linked: its death is an event the Session
  classifies, not a crash it inherits.

  `args` is a map built by the Session from `Meetings.Link.parse/1` and the
  `Meetings.Config` snapshot — `%{meeting_id, url, meeting_no/meet_code,
  passcode, config}` — and each implementation documents the keys it requires.

  ## Messages sent to the Session

  Plain `send/2` to the session pid:

  | Message | Meaning |
  |---|---|
  | `{:meeting_audio, pcm :: binary()}` | 16 kHz mono s16le audio, in capture order |
  | `{:meeting_roster, [%{id: String.t(), name: String.t()}]}` | Full participant snapshot, not a delta; sources cap it at 200 entries |
  | `{:meeting_active_speaker, id :: String.t(), t_ms :: non_neg_integer()}` | The speaker who started at `t_ms` |
  | `{:meeting_phase, phase :: :joining \\| :knocking, meta :: map()}` | Join-choreography progress |
  | `{:meeting_join_result, status, meta :: map()}` | `:admitted \\| :denied \\| :login_required \\| :signin_required \\| :bot_blocked \\| :knock_timeout`, sent once |
  | `{:meeting_chat_posted}` | The consent announcement landed in the meeting chat |
  | `{:meeting_ended, reason :: :host_removed \\| :meeting_closed \\| :left}` | The bot is out of the meeting |
  | `{:meeting_source_error, reason :: term()}` | Fatal for the source; the Session decides what it means for the meeting |

  Audio frames carry no timestamp: the Session's cumulative sample count is the
  clock (`t_ms = div(samples_seen, 16)`). A source MUST deliver audio in capture
  order and MUST derive every `t_ms` it emits from that same clock base, or
  speaker attribution silently drifts against the transcript.
  """

  @doc "Starts the source, linked to its caller, streaming to `session`."
  @callback start_link(session :: pid(), args :: map()) :: {:ok, pid()} | {:error, term()}

  @doc "Politely leaves the meeting (async — the source reports `{:meeting_ended, :left}`)."
  @callback leave(source :: pid()) :: :ok

  @doc "Forces teardown of the source and anything it spawned. Idempotent."
  @callback stop(source :: pid()) :: :ok

  @doc """
  Roster entries that are the notetaker itself, so the Session's alone-timer
  counts other participants the same way on both lanes: the Meet bot appears in
  its own roster (1), the RTMS app does not (0).
  """
  @callback self_count() :: non_neg_integer()

  @doc """
  Whether an empty roster means the room is empty. The Meet sidecar scrapes
  presence, so a roster that falls back to the bot's own seat is everyone having
  left; the RTMS roster is speech-recency (a participant ages out after 30 s of
  silence), so on Zoom an empty roster means nobody transmitting — a muted room
  — and the Session must not read it as the meeting being over.
  """
  @callback presence_roster?() :: boolean()
end
