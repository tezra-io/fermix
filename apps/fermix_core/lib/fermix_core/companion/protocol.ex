defmodule FermixCore.Companion.Protocol do
  @moduledoc """
  Newline-delimited JSON protocol for the local companion chat socket, and the
  one owner of the chat vocabulary.

  This module is the single source of truth for the wire contract between the
  daemon and a native companion (the Mac app first). Its machine-readable export
  lives under `priv/companion/` (`PROTOCOL.md`, `protocol.schema.json`, and the
  golden `fixtures/*.jsonl`); `protocol_contract_test.exs` asserts the export
  never drifts from the values below, and a downstream consumer vendors those
  files pinned by checksum instead of hand-copying the shapes.

  The chat events are transport-neutral payload maps. This socket frames each
  one as a JSON object with a `type` discriminator on its own line; the mobile
  wire frames the same payloads inside its `{v, t, seq}` envelope and delegates
  their validation here (`shared_client_events/0`, `shared_server_events/0`).

  ## Versioning

  A connection opens with a mandatory handshake, exactly as the Realtime socket
  does it: the client sends `client_hello` carrying its `protocol_version`; the
  daemon replies `server_hello` with the inclusive `{min_version, max_version}`
  range it supports (an N/N-1 window derived from one constant). See
  `PROTOCOL.md` for the state machine and the rollout order.

  Version 2 adds `turn_done`, the ending of a turn that wrote no reply (M56
  §4.4), and `cancel.task_ref`, which stops a GPT-Live task that outlived its
  call by its three ids (§4.6). A client on version 1 would show such a turn as thinking until the
  next one began, so a server event names the version that brought it
  (`server_event_version/1`) and a connection is never sent one newer than the
  version its hello declared.

  Version 3 brings the phone's media to the Mac's chat (M66): `media_fetch`
  asks for a managed local file holding the bytes of a ref a row names,
  answered `media_path` (the grant) or `media_missing`, and `media_release`
  lets the file go; `row_updated` says a row already written changed (a voice
  note's transcript, a stored link preview). Those server events reach a
  version 3 connection only, and a client event names the version that brought
  it too (`client_event_version/1`), so a connection that sends one newer than
  its hello declared is refused. A `row` carries its `media_refs` and
  `link_previews` on every version: an additive field needs no gate. The
  window is now {2, 3}, so a version 1 client is refused as too old.

  A reply's `text_done`, its `row` and its history message carry `blocks`
  when the reply has one (M72): records its text links, drawn beside it
  (`FermixCore.ReplyBlocks`), and the lists its turn read or changed (M85),
  by id. Additive and optional, so on every version.

  Version 4 brings a mandate's proposals to the owner's Mac (M60 app surface
  §3.7, D28): `proposal` carries the card (Fermix's record, its sentence and
  the outside text apart, `Cues.ProposalView`), sent when a proposal is stored
  and again after `server_hello` for each still waiting; `proposal_resolved`
  says it left `waiting`; and the client's `proposal_answer` confirms or denies
  it by id. They reach, and are taken from, only a connection the daemon
  placed as the owner's (`FermixCore.SocketPeer`, `:independent`), and only on
  version 4. The window is now {3, 4}, so a version 2 client is refused as too
  old.

  Version 5 brings a watcher's follow-ups to the same card
  (M60_WATCHER_CODING_RUNS.md §6.2): a `proposal` whose card is a follow-up's
  waiting to run carries `follow_up` (its name, the owner's instructions, its
  tools, where it reports and what the card asks) in place of `mandate`,
  `tool` and the call's arguments, which a version 4 client requires, so such
  a card reaches a version 5 connection only (`server_payload_version/2`). It
  is answered with the same `proposal_answer`, and its end is the same
  `proposal_resolved`. A mandate's card gains `outside.args` (each argument as
  `name` and `value`) and `outside.reason` (the filter's reason) for the
  compact card (§6.3), additive, so on every version. The window is now
  {4, 5}.

  A follow-up's card also takes Always allow (the 2026-10-31 revision of
  §3.4): its `follow_up.offers_always_allow` says so, and `proposal_answer`
  takes the `decision` `always_allow` for it, which runs it as `confirm` does
  and lets the follow-up's later items run with no card. Both are additive and
  need no version: an older client ignores the field and answers with
  `confirm` and `deny` as before, and only a client that read the field sends
  the value, which this daemon refuses for a mandate's card.

  Version 6 says what a turn is doing while it runs, in words a person reads
  rather than a tool's name: `reasoning` carries the model's summary of one
  step of its reasoning, as the provider wrote it (at most
  `max_reasoning_bytes/0`), live-only like `text_delta`, and reaches a version
  6 connection only; a `tool_event` that starts a tool carries `activity`, the
  engine's sentence for the step (`FermixCore.Capabilities.Activity`, at most
  `max_activity_bytes/0`), additive, so on every version. `activity` is this
  wire's alone: the phone's `tool_event` does not carry it. Version 6 also
  lets the apps stop polling Always On (M75 lean v1 §7): `home_status_changed`
  carries nothing and says that `home.status`'s summary changed, so the client
  reads it again over management, the one source of its words
  (`FermixCore.Home.StatusWatch` decides when). It is sent once after
  `server_hello` unless Always On is off, and at every change after, and
  reaches a version 6 connection only. The window is now {5, 6}.

  Version 6 also brings the owner's lists (M85 §07): `checklists_pull` and
  `checklist_pull` ask for the index and one whole list, answered `checklists`
  and `checklist`, and `checklist_edit` changes one by row id, answered
  `accepted` once, by its `client_msg_id`, or `error: request_failed` with
  the engine's sentence. Every one is taken from, and sent to, only a version
  6 connection placed as the owner's, and the daemon sends a list event only
  to a connection that pulled: the index to one that pulled it, a list to one
  that holds it. The phone's wire does not carry lists yet.

  Version 7 brings the owner's files to the Mac's chat. The Mac and the daemon
  share a file system, so a file crosses by path, never in chunks:
  `server_hello.attachments` tells the owner's connection, while the media
  store runs, the inbox to write a file in (`dir`) and the largest file the
  store takes (`max_bytes`); the client writes `<dir>/<attach_id>` and sends
  `attach_file`, which the daemon reads into the store the phone's uploads
  use, removes, and answers `attach_status` (`present`) or `error:
  request_failed` with the engine's sentence and the `attach_id`. A `msg`
  then names those ids in `attach_ids`, and its turn and its row carry them
  as a phone message's do. `attach_file` and a `msg` that names an
  attachment are taken only from a version 7 connection placed as the
  owner's: such a `msg` from any other connection is refused
  `attachments_unsupported`, as every one was before, and an `attach_file`
  from a version 6 connection is an unknown event. `server_hello.commands`,
  the slash commands an app offers in its palette (the list the phone's
  `caps.commands` carries), is additive and optional, so on every version,
  and so is `attachments`. The window is now {6, 7}.

  Both hellos carry the primary epoch (M75 D14), additive and optional on
  every version: `server_hello.primary_epoch` is the home's, absent only from a
  home that has never booted as the primary, and `client_hello.primary_epoch`
  the highest the client has seen, which the primary refuses when it is greater
  than its own (`stale_primary`). `server_hello.role` names the engine's role,
  `primary` or `device`, on every hello from this daemon on, so a client
  compares the epoch of a primary only.
  """

  alias FermixCore.ReplyBlocks

  # The engine roles a `server_hello` names (`FermixCore.Home.Role`).
  @engine_roles ~w(primary device)

  # Bumped in lockstep with any wire-shape change. The supported range is an
  # N/N-1 window derived from this single constant.
  @protocol_version 7
  @min_supported_version max(1, @protocol_version - 1)

  # The inbound line cap, the same as the Realtime socket's.
  @max_line_bytes 65_536
  @max_u64 18_446_744_073_709_551_615
  @max_history_limit 200
  @max_search_limit 50
  @max_query_length 256
  @max_approval_command_length 1_024
  # The managed media files a `media_path` grants (version 3): kept within this
  # many bytes once nobody holds them, and each kept at least this long after
  # its last release, so a reconnect takes back what was playing.
  @media_budget_bytes 512 * 1_024 * 1_024
  @media_release_grace_s 60
  # A media ref is the sha256 of its bytes, in lowercase hex.
  @media_ref ~r/\A[0-9a-f]{64}\z/
  # A row holds at most this many link previews, as the timeline stores them.
  @max_link_previews 4
  # A proposal's card and its end (version 4): the outside text each carries
  # is bounded as `Cues.Proposals` bounds it.
  @max_proposal_args_chars 3_500
  @max_proposal_result_chars 2_000
  @proposal_states ~w(waiting confirmed denied expired refused)
  @proposal_end_states ~w(confirmed denied expired refused)
  @proposal_result_statuses ~w(ok error unknown)
  @proposal_surfaces ~w(telegram signal whatsapp imessage companion mobile management)
  @proposal_card_strings ~w(proposal_id created_at expires_at status_sentence summary)
  @proposal_card_optional ~w(watcher source_ref received_at decided_at)
  # A mandate's card names its call; a follow-up's card (version 5) names the
  # follow-up instead.
  @mandate_card_strings ~w(mandate tool)
  @follow_up_asks ~w(run)
  # What the automatic approval's prompt carried, which no card does now.
  @follow_up_gone ~w(daily_cap set_off_by)
  @follow_up_strings ~w(name instructions reports_to)
  @follow_up_card_version 5
  # What a turn is doing (version 6): a tool's step in the engine's words, and
  # the model's summary of a step of its reasoning, each bounded in bytes.
  @max_activity_bytes 120
  @max_reasoning_bytes 4_096
  # The owner's lists (version 6, M85 §07): ids as the engine mints them, and a
  # device edit's own id bounded as the store keeps it.
  @list_id ~r/\Ack_[0-9a-z]{10}\z/
  @row_id ~r/\Aci_[0-9a-z]{10}\z/
  @max_checklist_msg_id 128
  @row_kinds ~w(item section)
  # The owner's files (version 7): an attach id names a file in the inbox, so
  # it is a file name and never a path; a kind is a hint, as the phone's is;
  # a mime and a name are bounded as the media store keeps them.
  @attach_id ~r/\A[0-9A-Za-z_-]{1,64}\z/
  @attach_kinds ~w(image animation video audio voice document file)
  @max_attach_field_bytes 255

  @client_events ~w(
    client_hello msg command cancel history_pull history_search read_state media_fetch
    media_release proposal_answer checklists_pull checklist_pull checklist_edit attach_file
  )
  @server_events ~w(
    server_hello accepted turn_started text_delta tool_event reasoning text_done turn_error
    turn_done row row_updated approval approval_resolved read_state history_page search_results
    media_path media_missing proposal proposal_resolved home_status_changed checklists
    checklist attach_status error
  )

  # The events a version after 1 brought; every other one is version 1.
  @client_event_versions %{
    "media_fetch" => 3,
    "media_release" => 3,
    "proposal_answer" => 4,
    "checklists_pull" => 6,
    "checklist_pull" => 6,
    "checklist_edit" => 6,
    "attach_file" => 7
  }
  @server_event_versions %{
    "turn_done" => 2,
    "row_updated" => 3,
    "media_path" => 3,
    "media_missing" => 3,
    "proposal" => 4,
    "proposal_resolved" => 4,
    "reasoning" => 6,
    "home_status_changed" => 6,
    "checklists" => 6,
    "checklist" => 6,
    "attach_status" => 7
  }

  # The events only the owner's connection is sent or may send (versions 4 and 6).
  @owner_server_events ~w(proposal proposal_resolved checklists checklist)

  # A row a Live call writes carries `metadata.call` (M56 §6): what happened
  # on the call, and which task it was about.
  @call_events ~w(shared ended task_running task_done)
  @call_task_events ~w(shared task_running task_done)
  @call_task_end_states ~w(completed failed cancelled timed_out)
  @call_accounting ~w(complete incomplete)
  @call_gist_statuses ~w(written failed none)
  @call_keys ~w(
    uuid event task_id revision state duration_s voice_cost_cents accounting engine gist_status
  )
  @call_engine_max_bytes 64
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  # The chat events whose payload the mobile wire carries verbatim. `history_pull`
  # and `history_page` are not among them: this wire's version 1 adds the
  # backward cursor (`before_seq`, `next_before_seq`) the mobile wire lacks.
  # `cancel` stops one request's turn on either wire, and `row` announces a
  # timeline row to every client of the profile that did not stream its turn.
  @shared_client_events ~w(msg command cancel read_state)
  @shared_server_events ~w(
    accepted turn_started text_delta tool_event text_done turn_error row approval
    approval_resolved read_state
  )

  @client_required %{
    "msg" => ~w(client_msg_id profile_id text attach_ids),
    "command" => ~w(client_msg_id profile_id name),
    "cancel" => ~w(profile_id client_msg_id),
    "history_pull" => ~w(profile_id limit),
    "history_search" => ~w(profile_id query limit),
    "read_state" => ~w(profile_id read_up_to_seq),
    "media_fetch" => ~w(profile_id ref),
    "media_release" => ~w(profile_id ref),
    "proposal_answer" => ~w(client_msg_id profile_id proposal_id decision),
    "checklists_pull" => ~w(profile_id),
    "checklist_pull" => ~w(profile_id list_id),
    "checklist_edit" => ~w(client_msg_id profile_id op),
    "attach_file" => ~w(attach_id kind mime size_bytes sha256)
  }

  @server_required %{
    "server_hello" => ~w(min_version max_version role),
    "accepted" => ~w(client_msg_id duplicate),
    "turn_started" => ~w(profile_id turn_id in_reply_to),
    "text_delta" => ~w(turn_id text),
    "tool_event" => ~w(turn_id tool phase),
    "reasoning" => ~w(turn_id text),
    "text_done" => ~w(turn_id server_seq text),
    "turn_error" => ~w(turn_id code message),
    "turn_done" => ~w(turn_id),
    "row" => ~w(profile_id server_seq role text ts media_refs),
    "row_updated" => ~w(profile_id server_seq),
    "approval" => ~w(approval_id kind text token ttl_s approve_command deny_command),
    "approval_resolved" => ~w(approval_id outcome),
    "read_state" => ~w(profile_id read_up_to_seq),
    "history_page" => ~w(profile_id messages history_head_seq),
    "search_results" => ~w(profile_id query hits),
    "media_path" => ~w(ref path kind mime size_bytes sha256),
    "media_missing" => ~w(ref),
    "proposal" => ~w(profile_id proposal),
    "proposal_resolved" => ~w(profile_id proposal_id state sentence),
    "home_status_changed" => [],
    "checklists" => ~w(profile_id lists),
    "checklist" => ~w(profile_id list),
    "attach_status" => ~w(attach_id status),
    "error" => ~w(reason)
  }

  @type event :: %{type: String.t(), payload: map()}

  @doc "The daemon's current companion wire-protocol version."
  @spec protocol_version() :: pos_integer()
  def protocol_version, do: @protocol_version

  @doc "Inclusive `{min, max}` protocol versions the daemon accepts (an N/N-1 window)."
  @spec supported_version_range() :: {pos_integer(), pos_integer()}
  def supported_version_range, do: {@min_supported_version, @protocol_version}

  @doc "Ordered client event catalog."
  @spec client_events() :: [String.t()]
  def client_events, do: @client_events

  @doc "Ordered server event catalog."
  @spec server_events() :: [String.t()]
  def server_events, do: @server_events

  @doc """
  The protocol version that brought client event `type`: a connection whose
  hello declared an older one is refused it.
  """
  @spec client_event_version(String.t()) :: pos_integer()
  def client_event_version(type) when is_binary(type) do
    if type in @client_events,
      do: Map.get(@client_event_versions, type, 1),
      else: raise(ArgumentError, "unknown companion client event #{inspect(type)}")
  end

  @doc """
  The protocol version that brought server event `type`: a connection whose
  hello declared an older one is never sent it.
  """
  @spec server_event_version(String.t()) :: pos_integer()
  def server_event_version(type) when is_binary(type) do
    if type in @server_events,
      do: Map.get(@server_event_versions, type, 1),
      else: raise(ArgumentError, "unknown companion server event #{inspect(type)}")
  end

  @doc """
  The server events only a connection placed as the owner's is sent (version
  4's proposals): a process the daemon started never holds a proposal.
  """
  @spec owner_server_events() :: [String.t()]
  def owner_server_events, do: @owner_server_events

  @doc """
  The protocol version server event `type` needs with `payload` (string keys):
  its type's (`server_event_version/1`), or 5 for a `proposal` whose card is a
  watcher's follow-up, which a version 4 client could not read.
  """
  @spec server_payload_version(String.t(), map()) :: pos_integer()
  def server_payload_version("proposal", %{"proposal" => %{"follow_up" => _follow_up}}),
    do: @follow_up_card_version

  def server_payload_version(type, payload) when is_binary(type) and is_map(payload),
    do: server_event_version(type)

  @doc "The longest `outside.args_text` of a proposal's card, in characters."
  @spec max_proposal_args_chars() :: pos_integer()
  def max_proposal_args_chars, do: @max_proposal_args_chars

  @doc "The longest `result_text` of a `proposal_resolved`, in characters."
  @spec max_proposal_result_chars() :: pos_integer()
  def max_proposal_result_chars, do: @max_proposal_result_chars

  @doc """
  The longest `activity` a `tool_event` carries, in bytes (version 6): the
  engine's sentence for a tool's step.
  """
  @spec max_activity_bytes() :: pos_integer()
  def max_activity_bytes, do: @max_activity_bytes

  @doc "The longest `reasoning` text, in bytes (version 6)."
  @spec max_reasoning_bytes() :: pos_integer()
  def max_reasoning_bytes, do: @max_reasoning_bytes

  @doc "The longest `client_msg_id` of a `checklist_edit`, in characters (version 6)."
  @spec max_checklist_msg_id() :: pos_integer()
  def max_checklist_msg_id, do: @max_checklist_msg_id

  @doc "The kinds an `attach_file` may declare (version 7), a hint as the phone's `kind` is."
  @spec attach_kinds() :: [String.t()]
  def attach_kinds, do: @attach_kinds

  @doc "The most bytes an `attach_file`'s `mime` or `name` holds (version 7)."
  @spec max_attach_field_bytes() :: pos_integer()
  def max_attach_field_bytes, do: @max_attach_field_bytes

  @doc """
  Whether `value` is an attach id this wire takes (version 7): one to 64
  ASCII letters, digits, `_` or `-`, a file name in the inbox and never a
  path.
  """
  @spec attach_id?(term()) :: boolean()
  def attach_id?(value), do: is_binary(value) and Regex.match?(@attach_id, value)

  @doc "The client chat events whose payload the mobile wire shares verbatim."
  @spec shared_client_events() :: [String.t()]
  def shared_client_events, do: @shared_client_events

  @doc "The server chat events whose payload the mobile wire shares verbatim."
  @spec shared_server_events() :: [String.t()]
  def shared_server_events, do: @shared_server_events

  @doc "Maximum bytes of one inbound line, newline excluded."
  @spec max_line_bytes() :: pos_integer()
  def max_line_bytes, do: @max_line_bytes

  @doc "Largest `limit` a `history_pull` may ask for."
  @spec max_history_limit() :: pos_integer()
  def max_history_limit, do: @max_history_limit

  @doc "Largest `limit` a `history_search` may ask for."
  @spec max_search_limit() :: pos_integer()
  def max_search_limit, do: @max_search_limit

  @doc "Longest `history_search` query, in Unicode scalar values."
  @spec max_query_length() :: pos_integer()
  def max_query_length, do: @max_query_length

  @doc """
  The disk budget, in bytes, the daemon keeps its granted media files within
  once no connection holds them.
  """
  @spec media_budget_bytes() :: pos_integer()
  def media_budget_bytes, do: @media_budget_bytes

  @doc "How long, in seconds, a released media file is kept before it may be removed."
  @spec media_release_grace_s() :: pos_integer()
  def media_release_grace_s, do: @media_release_grace_s

  @doc """
  Negotiate a client's `protocol_version` against the daemon's supported range.

  `{:error, :client_too_old}` means the client must update, and
  `{:error, :client_too_new}` means the daemon must update.
  """
  @spec negotiate(integer()) :: :ok | {:error, :client_too_old | :client_too_new}
  def negotiate(client_version) when is_integer(client_version) do
    {min, max} = supported_version_range()

    cond do
      client_version < min -> {:error, :client_too_old}
      client_version > max -> {:error, :client_too_new}
      true -> :ok
    end
  end

  @doc "Decode and validate one client line (the newline already removed)."
  @spec decode_client_event(binary()) :: {:ok, event()} | {:error, term()}
  def decode_client_event(line) when is_binary(line) do
    with {:ok, decoded} <- decode_json(line),
         {:ok, type} <- fetch_type(decoded),
         :ok <- known_type(type, @client_events),
         payload = Map.delete(decoded, "type"),
         :ok <- validate_client_event(type, payload) do
      {:ok, %{type: type, payload: payload}}
    end
  end

  @doc "Encode and validate one server event as a newline-terminated line."
  @spec encode_server_event(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def encode_server_event(type, payload) when is_binary(type) and is_map(payload) do
    with :ok <- known_type(type, @server_events),
         {:ok, payload} <- stringify_top_level(payload),
         :ok <- reject_reserved(payload),
         :ok <- validate_server_payload(type, payload),
         {:ok, json} <- encode_json(Map.put(payload, "type", type)) do
      {:ok, json <> "\n"}
    end
  end

  @doc """
  Validate one client chat payload (envelope fields removed): its required
  fields first, in catalog order, then each field's constraint.
  """
  @spec validate_client_payload(String.t(), map()) :: :ok | {:error, term()}
  def validate_client_payload(type, payload) when is_binary(type) and is_map(payload) do
    with {:ok, required} <- fetch_required(@client_required, type),
         :ok <- require_fields(required, payload) do
      validate_client(type, payload)
    end
  end

  @doc """
  Validate one server chat payload (envelope fields removed): its required
  fields first, in catalog order, then each field's constraint.
  """
  @spec validate_server_payload(String.t(), map()) :: :ok | {:error, term()}
  def validate_server_payload(type, payload) when is_binary(type) and is_map(payload) do
    with {:ok, required} <- fetch_required(@server_required, type),
         :ok <- require_fields(required, payload) do
      validate_server(type, payload)
    end
  end

  @doc """
  Validate the `call` map a Live call's timeline row carries in its
  `metadata` (M56 §6), string keyed as the timeline stores it: `uuid` (the
  call's), `event` (`shared`, `ended`, `task_running` or `task_done`), and
  optional `task_id`, `revision`, `state` (a task's terminal state),
  `duration_s`, `voice_cost_cents`, `accounting` (`complete` or
  `incomplete`), `engine` and `gist_status` (`written`, `failed` or `none`).
  A task's event names its `task_id` and `revision`, and `task_done` its
  `state`; `ended`, the call's one row when it ends (M56 §4.2), names its
  `engine`, `duration_s`, `accounting` and `gist_status`. A key outside these
  is refused. The writer of a call row validates here, the one place the
  shape is held.
  """
  @spec validate_call_metadata(term()) :: :ok | {:error, term()}
  def validate_call_metadata(call) when is_map(call) do
    with :ok <- known_call_keys(call),
         :ok <- call_required(call, ["uuid", "event"]),
         :ok <- call_field(call, "uuid", &(is_binary(&1) and Regex.match?(@uuid, &1))),
         :ok <- call_field(call, "event", &(&1 in @call_events)),
         :ok <- call_event_fields(call),
         :ok <- call_field(call, "task_id", &(is_binary(&1) and &1 != "")),
         :ok <- call_field(call, "revision", &(is_integer(&1) and &1 > 0)),
         :ok <- call_field(call, "state", &(&1 in @call_task_end_states)),
         :ok <- call_field(call, "duration_s", &(is_integer(&1) and &1 >= 0)),
         :ok <- call_field(call, "voice_cost_cents", &(is_number(&1) and &1 >= 0)),
         :ok <- call_field(call, "accounting", &(&1 in @call_accounting)),
         :ok <- call_field(call, "engine", &call_engine?/1) do
      call_field(call, "gist_status", &(&1 in @call_gist_statuses))
    end
  end

  def validate_call_metadata(_call), do: {:error, {:invalid_field, "call"}}

  defp known_call_keys(call) do
    case Enum.find(Map.keys(call), &(&1 not in @call_keys)) do
      nil -> :ok
      key -> {:error, {:unknown_field, "call.#{key}"}}
    end
  end

  defp call_event_fields(%{"event" => "task_done"} = call),
    do: call_required(call, ["task_id", "revision", "state"])

  defp call_event_fields(%{"event" => event} = call) when event in @call_task_events,
    do: call_required(call, ["task_id", "revision"])

  defp call_event_fields(%{"event" => "ended"} = call),
    do: call_required(call, ["engine", "duration_s", "accounting", "gist_status"])

  defp call_engine?(engine),
    do: is_binary(engine) and engine != "" and byte_size(engine) <= @call_engine_max_bytes

  defp call_required(call, keys) do
    case Enum.find(keys, &(not Map.has_key?(call, &1))) do
      nil -> :ok
      key -> {:error, {:missing_field, "call." <> key}}
    end
  end

  defp call_field(call, key, valid?) do
    case Map.fetch(call, key) do
      :error -> :ok
      {:ok, value} -> if valid?.(value), do: :ok, else: {:error, {:invalid_field, "call." <> key}}
    end
  end

  # `client_hello` is transport, not chat: it has no payload rules beyond the
  # version, whose two errors are the Realtime socket's, verbatim, and the
  # optional highest primary epoch the client has seen (M75 D14).
  defp validate_client_event("client_hello", payload) do
    case Map.get(payload, "protocol_version") do
      version when is_integer(version) and version > 0 ->
        optional_positive_u64(payload, "primary_epoch")

      nil ->
        {:error, :missing_protocol_version}

      _other ->
        {:error, :invalid_protocol_version}
    end
  end

  # A `msg` that names an attachment is decoded here on every version; the
  # connection takes it only from a version 7 owner's connection, the only one
  # an `attach_file` is taken from (moduledoc).
  defp validate_client_event(type, payload), do: validate_client_payload(type, payload)

  defp validate_client("msg", payload) do
    with :ok <- nonempty(payload, "client_msg_id"),
         :ok <- nonempty(payload, "profile_id"),
         :ok <- binary_field(payload, "text"),
         :ok <- string_list(payload, "attach_ids") do
      has_text = String.trim(payload["text"]) != ""

      if has_text or payload["attach_ids"] != [],
        do: :ok,
        else: {:error, {:missing_field, "content"}}
    end
  end

  defp validate_client("command", payload) do
    with :ok <- nonempty(payload, "client_msg_id"),
         :ok <- nonempty(payload, "profile_id"),
         :ok <- nonempty(payload, "name") do
      optional_binary(payload, "args")
    end
  end

  defp validate_client("cancel", payload) do
    with :ok <- strings(payload, ~w(profile_id client_msg_id)) do
      optional_task_ref(payload)
    end
  end

  defp validate_client("history_pull", payload) do
    with :ok <- nonempty(payload, "profile_id"),
         :ok <- history_cursor(payload) do
      integer_range(payload, "limit", 1, @max_history_limit)
    end
  end

  defp validate_client("history_search", payload) do
    with :ok <- nonempty(payload, "profile_id"),
         :ok <- bounded_nonempty(payload, "query", @max_query_length),
         :ok <- integer_range(payload, "limit", 1, @max_search_limit) do
      optional_positive_u64(payload, "before_seq")
    end
  end

  defp validate_client("read_state", payload), do: validate_read_state(payload)

  defp validate_client(type, payload) when type in ["media_fetch", "media_release"] do
    with :ok <- nonempty(payload, "profile_id") do
      media_ref(payload, "ref")
    end
  end

  defp validate_client("proposal_answer", payload) do
    with :ok <- strings(payload, ~w(client_msg_id profile_id proposal_id)) do
      enum(payload, "decision", ~w(confirm deny always_allow))
    end
  end

  defp validate_client("checklists_pull", payload), do: nonempty(payload, "profile_id")

  # Version 7: the file is `<inbox>/<attach_id>`, so the payload names no path.
  defp validate_client("attach_file", payload) do
    with :ok <- attach_id(payload),
         :ok <- enum(payload, "kind", @attach_kinds),
         :ok <- bytes(payload, "mime", @max_attach_field_bytes),
         :ok <- nonnegative_u64(payload, "size_bytes"),
         :ok <- media_ref(payload, "sha256") do
      optional_bytes(payload, "name", @max_attach_field_bytes)
    end
  end

  defp validate_client("checklist_pull", payload) do
    with :ok <- nonempty(payload, "profile_id"),
         :ok <- pattern(payload, "list_id", @list_id) do
      optional_boolean(payload, "removed")
    end
  end

  # The op's shape is the engine's to judge (`Checklists.Registry`), which
  # refuses an op it cannot take with a sentence and keeps the connection; the
  # wire holds what an op is carried in.
  defp validate_client("checklist_edit", payload) do
    with :ok <- bounded_nonempty(payload, "client_msg_id", @max_checklist_msg_id),
         :ok <- nonempty(payload, "profile_id"),
         :ok <- optional_pattern(payload, "list_id", @list_id) do
      case payload["op"] do
        %{"op" => op} when is_binary(op) and op != "" -> :ok
        _other -> {:error, {:invalid_field, "op"}}
      end
    end
  end

  # Version 2 (M56 §4.6): a cancel may name a task that outlived its call by
  # exactly its three ids, the ones its `task_running` row carries.
  defp optional_task_ref(%{"task_ref" => task_ref}) do
    if task_ref?(task_ref), do: :ok, else: {:error, {:invalid_field, "task_ref"}}
  end

  defp optional_task_ref(_payload), do: :ok

  defp task_ref?(%{"call_uuid" => uuid, "task_id" => task_id, "revision" => revision} = ref)
       when map_size(ref) == 3 and is_binary(uuid) and is_binary(task_id) and task_id != "" and
              is_integer(revision) and revision > 0,
       do: Regex.match?(@uuid, uuid)

  defp task_ref?(_task_ref), do: false

  # Exactly one cursor: `after_seq` pages forward (the catch-up read), and
  # `before_seq` pages backward from it (scroll to the top).
  defp history_cursor(%{"after_seq" => _after, "before_seq" => _before}),
    do: {:error, {:invalid_field, "before_seq"}}

  defp history_cursor(%{"before_seq" => _before} = payload),
    do: integer_range(payload, "before_seq", 1, @max_u64)

  defp history_cursor(%{"after_seq" => _after} = payload),
    do: nonnegative_u64(payload, "after_seq")

  defp history_cursor(_payload), do: {:error, {:missing_field, "after_seq"}}

  # `primary_epoch` is absent only from a home that has never booted as the
  # primary (M75 D14); `role` is the engine's, which this daemon always names.
  # `commands` and `attachments` are additive (version 7's moduledoc).
  defp validate_server("server_hello", payload) do
    with :ok <- positive_u64(payload, "min_version"),
         :ok <- positive_u64(payload, "max_version"),
         :ok <- optional_positive_u64(payload, "primary_epoch"),
         :ok <- enum(payload, "role", @engine_roles),
         :ok <- optional_commands(payload),
         :ok <- optional_attachments(payload) do
      valid_version_range(payload)
    end
  end

  defp validate_server("accepted", payload) do
    with :ok <- nonempty(payload, "client_msg_id"),
         :ok <- boolean_field(payload, "duplicate") do
      optional_positive_u64(payload, "server_seq")
    end
  end

  defp validate_server("turn_started", payload),
    do: strings(payload, ~w(profile_id turn_id in_reply_to))

  defp validate_server("text_delta", payload), do: text_event(payload)

  defp validate_server("tool_event", payload) do
    with :ok <- nonempty(payload, "turn_id"),
         :ok <- nonempty(payload, "tool"),
         :ok <- enum(payload, "phase", ~w(start stop)),
         :ok <- optional_binary(payload, "detail") do
      optional_bytes(payload, "activity", @max_activity_bytes)
    end
  end

  defp validate_server("reasoning", payload) do
    with :ok <- nonempty(payload, "turn_id") do
      bytes(payload, "text", @max_reasoning_bytes)
    end
  end

  defp validate_server("text_done", payload) do
    with :ok <- text_event(payload),
         :ok <- positive_u64(payload, "server_seq") do
      optional_blocks(payload)
    end
  end

  defp validate_server("turn_error", payload), do: strings(payload, ~w(turn_id code message))

  defp validate_server("turn_done", payload), do: nonempty(payload, "turn_id")

  defp validate_server("row", payload) do
    with :ok <- strings(payload, ~w(profile_id role ts)),
         :ok <- positive_u64(payload, "server_seq"),
         :ok <- binary_field(payload, "text"),
         :ok <- list_field(payload, "media_refs"),
         :ok <- optional_link_previews(payload),
         :ok <- optional_blocks(payload),
         :ok <- optional_nonempty(payload, "kind"),
         :ok <- optional_map(payload, "metadata") do
      optional_nonempty(payload, "client_msg_id")
    end
  end

  defp validate_server("row_updated", payload) do
    with :ok <- nonempty(payload, "profile_id") do
      positive_u64(payload, "server_seq")
    end
  end

  defp validate_server("approval", payload) do
    with :ok <- strings(payload, ~w(approval_id kind text token)),
         :ok <- positive_u64(payload, "ttl_s"),
         :ok <- bounded_nonempty(payload, "approve_command", @max_approval_command_length),
         :ok <- bounded_nonempty(payload, "deny_command", @max_approval_command_length) do
      optional_binary(payload, "detail")
    end
  end

  defp validate_server("approval_resolved", payload) do
    with :ok <- nonempty(payload, "approval_id") do
      enum(payload, "outcome", ~w(approved denied expired))
    end
  end

  defp validate_server("read_state", payload), do: validate_read_state(payload)

  defp validate_server("history_page", payload) do
    with :ok <- nonempty(payload, "profile_id"),
         :ok <- list_field(payload, "messages"),
         :ok <- nonnegative_u64(payload, "history_head_seq"),
         :ok <- optional_nonnegative_u64(payload, "next_after_seq") do
      optional_positive_u64(payload, "next_before_seq")
    end
  end

  defp validate_server("search_results", payload) do
    with :ok <- nonempty(payload, "profile_id"),
         :ok <- binary_field(payload, "query"),
         :ok <- list_field(payload, "hits") do
      optional_positive_u64(payload, "next_before_seq")
    end
  end

  defp validate_server("media_path", payload) do
    with :ok <- media_ref(payload, "ref"),
         :ok <- absolute_path(payload, "path"),
         :ok <- strings(payload, ~w(kind mime)),
         :ok <- nonnegative_u64(payload, "size_bytes") do
      same_digest(payload)
    end
  end

  defp validate_server("media_missing", payload), do: media_ref(payload, "ref")

  defp validate_server("proposal", payload) do
    with :ok <- nonempty(payload, "profile_id") do
      if proposal_card?(payload["proposal"]),
        do: :ok,
        else: {:error, {:invalid_field, "proposal"}}
    end
  end

  defp validate_server("proposal_resolved", payload) do
    with :ok <- strings(payload, ~w(profile_id proposal_id sentence)),
         :ok <- enum(payload, "state", @proposal_end_states),
         :ok <- optional_enum(payload, "result_status", @proposal_result_statuses) do
      optional_bounded(payload, "result_text", @max_proposal_result_chars)
    end
  end

  # A notice with no content: the client reads `home.status` for what changed.
  defp validate_server("home_status_changed", payload) do
    case Map.keys(payload) do
      [] -> :ok
      [field | _more] -> {:error, {:invalid_field, field}}
    end
  end

  defp validate_server("checklists", payload) do
    with :ok <- nonempty(payload, "profile_id") do
      if is_list(payload["lists"]) and Enum.all?(payload["lists"], &checklist_entry?/1),
        do: :ok,
        else: {:error, {:invalid_field, "lists"}}
    end
  end

  defp validate_server("checklist", payload) do
    with :ok <- nonempty(payload, "profile_id"),
         :ok <- checklist_field(payload["list"]) do
      optional_made(payload)
    end
  end

  defp validate_server("attach_status", payload) do
    with :ok <- attach_id(payload) do
      enum(payload, "status", ~w(present))
    end
  end

  defp validate_server("error", payload) do
    with :ok <- nonempty(payload, "reason"),
         :ok <- optional_media_ref(payload, "ref") do
      if Map.has_key?(payload, "attach_id"), do: attach_id(payload), else: :ok
    end
  end

  # The slash commands an app offers, as the phone's `caps.commands` carries
  # them: each `{name, aliases, description}` and nothing else.
  defp optional_commands(%{"commands" => commands}) when is_list(commands) do
    if Enum.all?(commands, &command_descriptor?/1),
      do: :ok,
      else: {:error, {:invalid_field, "commands"}}
  end

  defp optional_commands(%{"commands" => _commands}), do: {:error, {:invalid_field, "commands"}}
  defp optional_commands(_payload), do: :ok

  defp command_descriptor?(
         %{"name" => name, "aliases" => aliases, "description" => text} = command
       )
       when map_size(command) == 3 and is_list(aliases) do
    nonempty_string?(name) and nonempty_string?(text) and Enum.all?(aliases, &nonempty_string?/1)
  end

  defp command_descriptor?(_command), do: false

  defp nonempty_string?(value), do: is_binary(value) and value != ""

  # The inbox the owner's connection writes a file in, and the largest file
  # the store takes: exactly those two.
  defp optional_attachments(%{"attachments" => %{"dir" => dir, "max_bytes" => max} = offer})
       when map_size(offer) == 2 and is_binary(dir) and is_integer(max) and max > 0 and
              max <= @max_u64 do
    if Path.type(dir) == :absolute, do: :ok, else: {:error, {:invalid_field, "attachments"}}
  end

  defp optional_attachments(%{"attachments" => _offer}),
    do: {:error, {:invalid_field, "attachments"}}

  defp optional_attachments(_payload), do: :ok

  defp attach_id(payload) do
    if attach_id?(Map.get(payload, "attach_id")),
      do: :ok,
      else: {:error, {:invalid_field, "attach_id"}}
  end

  defp optional_media_ref(payload, field),
    do: if(Map.has_key?(payload, field), do: media_ref(payload, field), else: :ok)

  # A list in the index: its id, title and counts, and its folder when it is
  # in one.
  defp checklist_entry?(%{"list_id" => id, "title" => title} = entry) do
    is_binary(id) and Regex.match?(@list_id, id) and is_binary(title) and title != "" and
      Enum.all?(~w(open done rev), &(nonnegative_u64(entry, &1) == :ok)) and
      optional_nonempty(entry, "folder") == :ok and not has_null?(entry)
  end

  defp checklist_entry?(_entry), do: false

  # A whole list, its rows in order; `removed` the rows removed in the last 30
  # days when asked for, and `removed_at` when the list itself was removed.
  defp checklist_field(%{"list_id" => id, "title" => title, "rows" => rows} = list)
       when is_binary(id) and is_binary(title) and is_list(rows) do
    ok =
      Regex.match?(@list_id, id) and title != "" and nonnegative_u64(list, "rev") == :ok and
        Enum.all?(rows, &checklist_row?(&1, false)) and removed_parts?(list)

    if ok, do: :ok, else: {:error, {:invalid_field, "list"}}
  end

  defp checklist_field(_list), do: {:error, {:invalid_field, "list"}}

  # What a removed row or list adds: the rows when asked for, the list's
  # `removed_at` when it was removed; no null anywhere.
  defp removed_parts?(list),
    do:
      removed_rows?(list) and optional_nonempty(list, "removed_at") == :ok and not has_null?(list)

  defp removed_rows?(%{"removed" => rows}) when is_list(rows),
    do: Enum.all?(rows, &checklist_row?(&1, true))

  defp removed_rows?(%{"removed" => _rows}), do: false
  defp removed_rows?(_list), do: true

  defp checklist_row?(%{"row_id" => id, "kind" => kind, "text" => text} = row, removed?)
       when is_binary(id) and kind in @row_kinds and is_binary(text) do
    Regex.match?(@row_id, id) and text != "" and optional_nonempty(row, "note") == :ok and
      optional_boolean(row, "done") == :ok and optional_nonempty(row, "done_at") == :ok and
      (not removed? or nonempty(row, "removed_at") == :ok)
  end

  defp checklist_row?(_row, _removed?), do: false

  # An add's or a create's `client_msg_id` to the id it made.
  defp optional_made(%{"made" => made}) when is_map(made) and map_size(made) > 0 do
    if Enum.all?(made, fn {key, value} -> is_binary(key) and is_binary(value) end),
      do: :ok,
      else: {:error, {:invalid_field, "made"}}
  end

  defp optional_made(%{"made" => _made}), do: {:error, {:invalid_field, "made"}}
  defp optional_made(_payload), do: :ok

  defp pattern(payload, field, regex) do
    case Map.get(payload, field) do
      value when is_binary(value) ->
        if Regex.match?(regex, value), do: :ok, else: {:error, {:invalid_field, field}}

      _other ->
        {:error, {:invalid_field, field}}
    end
  end

  defp optional_pattern(payload, field, regex),
    do: if(Map.has_key?(payload, field), do: pattern(payload, field, regex), else: :ok)

  defp optional_boolean(payload, field),
    do: if(Map.has_key?(payload, field), do: boolean_field(payload, field), else: :ok)

  # The card, string keyed as it travels, with no null anywhere: an absent
  # value is an absent key on this wire, nested as at the top.
  defp proposal_card?(%{} = card) do
    Enum.all?(@proposal_card_strings, &(nonempty(card, &1) == :ok)) and
      card["state"] in @proposal_states and
      proposal_task?(card["task"]) and
      card_call?(card) and
      Enum.all?(@proposal_card_optional, &(optional_nonempty(card, &1) == :ok)) and
      optional_enum(card, "decided_from", @proposal_surfaces) == :ok and
      optional_enum(card, "result_status", @proposal_result_statuses) == :ok and
      not has_null?(card)
  end

  defp proposal_card?(_card), do: false

  # What the card asks to run: a mandate's call, or a watcher's follow-up,
  # never both.
  defp card_call?(%{"follow_up" => follow_up} = card) do
    not Enum.any?(@mandate_card_strings, &Map.has_key?(card, &1)) and
      follow_up?(follow_up) and follow_up_outside?(card["outside"])
  end

  defp card_call?(card) do
    Enum.all?(@mandate_card_strings, &(nonempty(card, &1) == :ok)) and
      proposal_outside?(card["outside"])
  end

  defp follow_up?(%{"asks" => asks, "tools" => tools} = follow_up)
       when asks in @follow_up_asks and is_list(tools) do
    Enum.all?(@follow_up_strings, &(nonempty(follow_up, &1) == :ok)) and
      Enum.all?(tools, &(is_binary(&1) and &1 != "")) and
      is_boolean(Map.get(follow_up, "offers_always_allow", false)) and
      not Enum.any?(@follow_up_gone, &Map.has_key?(follow_up, &1))
  end

  defp follow_up?(_follow_up), do: false

  # A follow-up is handed nothing of the item, so its card carries no call's
  # arguments: only the item and the filter's reason.
  defp follow_up_outside?(%{} = outside) do
    not Map.has_key?(outside, "args_text") and not Map.has_key?(outside, "args") and
      optional_nonempty(outside, "reason") == :ok and
      proposal_cue?(Map.get(outside, "cue", %{}))
  end

  defp follow_up_outside?(_outside), do: false

  defp proposal_task?(%{} = task),
    do: nonempty(task, "job_id") == :ok and optional_nonempty(task, "name") == :ok

  defp proposal_task?(_task), do: false

  defp proposal_outside?(%{"args_text" => args} = outside) when is_binary(args) do
    String.length(args) <= @max_proposal_args_chars and
      proposal_args?(Map.get(outside, "args", [])) and
      optional_nonempty(outside, "reason") == :ok and
      proposal_cue?(Map.get(outside, "cue", %{}))
  end

  defp proposal_outside?(_outside), do: false

  defp proposal_args?(args) when is_list(args) do
    Enum.all?(args, fn
      %{"name" => name, "value" => value} = arg when map_size(arg) == 2 ->
        is_binary(name) and name != "" and is_binary(value)

      _other ->
        false
    end)
  end

  defp proposal_args?(_args), do: false

  defp proposal_cue?(%{} = cue),
    do:
      Enum.all?(cue, fn {key, value} ->
        key in ~w(type subject text occurred_at) and is_binary(value)
      end)

  defp proposal_cue?(_cue), do: false

  defp has_null?(%{} = map), do: Enum.any?(map, fn {_key, value} -> has_null?(value) end)
  defp has_null?(nil), do: true
  defp has_null?(_value), do: false

  defp optional_enum(payload, field, values) do
    if Map.has_key?(payload, field), do: enum(payload, field, values), else: :ok
  end

  defp optional_bounded(payload, field, max_length) do
    case Map.fetch(payload, field) do
      :error ->
        :ok

      {:ok, value} when is_binary(value) ->
        if String.length(value) <= max_length, do: :ok, else: {:error, {:invalid_field, field}}

      {:ok, _value} ->
        {:error, {:invalid_field, field}}
    end
  end

  defp validate_read_state(payload) do
    with :ok <- nonempty(payload, "profile_id") do
      nonnegative_u64(payload, "read_up_to_seq")
    end
  end

  defp text_event(payload) do
    with :ok <- nonempty(payload, "turn_id") do
      binary_field(payload, "text")
    end
  end

  defp valid_version_range(%{
         "min_version" => @min_supported_version,
         "max_version" => @protocol_version
       }),
       do: :ok

  defp valid_version_range(_payload), do: {:error, {:invalid_field, "version_range"}}

  defp decode_json(line) do
    case Jason.decode(line) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      {:ok, _other} -> {:error, :invalid_event}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp encode_json(map) do
    case Jason.encode(map) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:invalid_payload, reason}}
    end
  end

  defp fetch_type(%{"type" => type}) when is_binary(type) and type != "", do: {:ok, type}
  defp fetch_type(_decoded), do: {:error, :missing_type}

  defp known_type(type, known) do
    if type in known, do: :ok, else: {:error, {:unknown_event, type}}
  end

  defp fetch_required(required, type) do
    case Map.fetch(required, type) do
      {:ok, fields} -> {:ok, fields}
      :error -> {:error, {:unknown_event, type}}
    end
  end

  defp require_fields(required, payload) do
    missing = Enum.find(required, &(not Map.has_key?(payload, &1)))
    if is_nil(missing), do: :ok, else: {:error, {:missing_field, missing}}
  end

  defp stringify_top_level(payload) do
    Enum.reduce_while(payload, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, key} <- stringify_key(key),
           false <- Map.has_key?(acc, key) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        true -> {:halt, {:error, {:duplicate_field, to_string(key)}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp stringify_key(key) when is_binary(key), do: {:ok, key}
  defp stringify_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp stringify_key(key), do: {:error, {:invalid_field_name, key}}

  # An absent optional field is an absent key on this wire, never an explicit
  # null, and `type` is the discriminator this module writes itself.
  defp reject_reserved(%{"type" => _type}), do: {:error, {:reserved_field, "type"}}

  defp reject_reserved(payload) do
    case Enum.find(payload, fn {_field, value} -> is_nil(value) end) do
      nil -> :ok
      {field, nil} -> {:error, {:null_field, field}}
    end
  end

  defp strings(payload, fields) do
    Enum.reduce_while(fields, :ok, fn field, :ok ->
      case nonempty(payload, field) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp nonempty(payload, field) do
    case Map.get(payload, field) do
      value when is_binary(value) and value != "" -> :ok
      _value -> {:error, {:invalid_field, field}}
    end
  end

  defp bounded_nonempty(payload, field, max_length) do
    with :ok <- nonempty(payload, field) do
      if bounded_utf8?(payload[field], max_length),
        do: :ok,
        else: {:error, {:invalid_field, field}}
    end
  end

  defp bounded_utf8?(value, max_length) do
    byte_size(value) <= max_length * 4 and
      String.valid?(value) and
      length(String.codepoints(value)) <= max_length
  end

  defp binary_field(payload, field) do
    if is_binary(Map.get(payload, field)), do: :ok, else: {:error, {:invalid_field, field}}
  end

  defp optional_nonempty(payload, field) do
    if Map.has_key?(payload, field), do: nonempty(payload, field), else: :ok
  end

  defp optional_map(payload, field) do
    if is_map(Map.get(payload, field, %{})), do: :ok, else: {:error, {:invalid_field, field}}
  end

  defp optional_binary(payload, field) do
    value = Map.get(payload, field)
    if is_nil(value) or is_binary(value), do: :ok, else: {:error, {:invalid_field, field}}
  end

  # Nonempty UTF-8 text of at most `max_bytes` bytes.
  defp bytes(payload, field, max_bytes) do
    with :ok <- nonempty(payload, field) do
      value = Map.fetch!(payload, field)

      if String.valid?(value) and byte_size(value) <= max_bytes,
        do: :ok,
        else: {:error, {:invalid_field, field}}
    end
  end

  defp optional_bytes(payload, field, max_bytes) do
    if Map.has_key?(payload, field), do: bytes(payload, field, max_bytes), else: :ok
  end

  defp string_list(payload, field) do
    case Map.get(payload, field) do
      values when is_list(values) ->
        if Enum.all?(values, &(is_binary(&1) and &1 != "")),
          do: :ok,
          else: {:error, {:invalid_field, field}}

      _value ->
        {:error, {:invalid_field, field}}
    end
  end

  defp media_ref(payload, field) do
    value = Map.get(payload, field)

    if is_binary(value) and Regex.match?(@media_ref, value),
      do: :ok,
      else: {:error, {:invalid_field, field}}
  end

  # The file's bytes were checked against the ref when it was made, so the
  # digest a grant names is its ref.
  defp same_digest(%{"sha256" => ref, "ref" => ref}), do: :ok
  defp same_digest(_payload), do: {:error, {:invalid_field, "sha256"}}

  defp absolute_path(payload, field) do
    with :ok <- nonempty(payload, field) do
      if Path.type(payload[field]) == :absolute, do: :ok, else: {:error, {:invalid_field, field}}
    end
  end

  # A row has the key only when it has a preview, and holds at most four.
  defp optional_link_previews(%{"link_previews" => previews}) do
    if link_previews?(previews), do: :ok, else: {:error, {:invalid_field, "link_previews"}}
  end

  defp optional_link_previews(_payload), do: :ok

  defp link_previews?(previews) when is_list(previews) and previews != [],
    do: length(previews) <= @max_link_previews and Enum.all?(previews, &is_map/1)

  defp link_previews?(_previews), do: false

  # A reply has the key only when it carries a block, at most one of each
  # type: a `places` block holds one to ten places, and a `checklists` block one
  # to eight lists, each its id, title and row ids.
  defp optional_blocks(%{"blocks" => blocks}) do
    if blocks?(blocks), do: :ok, else: {:error, {:invalid_field, "blocks"}}
  end

  defp optional_blocks(_payload), do: :ok

  defp blocks?(blocks) when is_list(blocks) and blocks != [] do
    types = Enum.map(blocks, &block_type/1)
    Enum.all?(blocks, &block?/1) and Enum.uniq(types) == types
  end

  defp blocks?(_blocks), do: false

  defp block_type(%{"type" => type}), do: type
  defp block_type(_block), do: nil

  defp block?(%{"type" => "places", "places" => places}) when is_list(places) do
    places != [] and length(places) <= ReplyBlocks.max_places() and Enum.all?(places, &is_map/1)
  end

  defp block?(%{"type" => "checklists", "lists" => lists}) when is_list(lists) do
    lists != [] and length(lists) <= ReplyBlocks.max_checklists() and
      Enum.all?(lists, &checklist_ref?/1)
  end

  defp block?(_block), do: false

  defp checklist_ref?(%{"list_id" => "ck_" <> _id, "title" => title, "rows" => rows})
       when is_binary(title) and title != "" and is_list(rows),
       do: Enum.all?(rows, &match?("ci_" <> _id, &1))

  defp checklist_ref?(_list), do: false

  defp list_field(payload, field) do
    if is_list(Map.get(payload, field)), do: :ok, else: {:error, {:invalid_field, field}}
  end

  defp boolean_field(payload, field) do
    if is_boolean(Map.get(payload, field)), do: :ok, else: {:error, {:invalid_field, field}}
  end

  defp positive_u64(payload, field), do: integer_range(payload, field, 1, @max_u64)
  defp nonnegative_u64(payload, field), do: integer_range(payload, field, 0, @max_u64)

  defp optional_positive_u64(payload, field) do
    if Map.has_key?(payload, field), do: positive_u64(payload, field), else: :ok
  end

  defp optional_nonnegative_u64(payload, field) do
    if Map.has_key?(payload, field), do: nonnegative_u64(payload, field), else: :ok
  end

  defp integer_range(payload, field, min, max) do
    case Map.get(payload, field) do
      value when is_integer(value) and value >= min and value <= max -> :ok
      _value -> {:error, {:invalid_field, field}}
    end
  end

  defp enum(payload, field, values) do
    if Map.get(payload, field) in values, do: :ok, else: {:error, {:invalid_field, field}}
  end
end
