defmodule FermixChannels.Mobile.Lanes do
  @moduledoc """
  The lanes of a session's outbound frames (M97 §5.1): the one table of which
  lane each event of the mobile wire rides, whichever end sends it.

  | Lane | Carries | Rule |
  |---|---|---|
  | `live` | a call's frames (`call_*`) | written first |
  | `interactive` | chat, management calls and results, sign-in forwards, invocations (`invoke_*`), a computer's `offers` and `link_path`, `hello`, `ping`, `pong`, `error`, `ack` and every other event | written before bulk |
  | `bulk` | the frames of a stream: media, attachments, snapshot copies, the move; an invocation's large file bytes and a history sitting | written when the other two are empty, one frame at a time |

  A lane is a function of an event's type and its header (`lane/2`), so one
  type can ride two lanes by what its header says. The header fields the
  table reads are named here alone (`header_fields/0`):

  - `invoke_part` is interactive up to 256 KiB of announced bytes
    (`size_bytes`) and bulk above it; a part that announces none has no lane;
  - `invoke_open` is bulk when it submits a history sitting (`capability`
    `history`, `op` `submit`), interactive otherwise.

  Every other type rides one lane whatever its header. A family's events
  share one lane, so lanes never reorder a family's own events: a snapshot's
  answer (`snapshot_stored`) rides bulk with its chunks, and a blob's request
  (`media_fetch`) with its bytes. Lanes are an order inside one session, not
  a second connection.

  `event_part` is no event of its own: a run carries one event whole, in that
  event's lane, and is never split. The `invoke_*` events are named here
  before any session sends them (M97 §6), so they cannot ship without a lane.
  An event the table does not name has no lane (`{:error, {:no_lane,
  type}}`), and every event the codec knows has one, which its test holds.

  The guards `live?/2`, `interactive?/2` and `bulk?/2` are the table itself,
  so a selective receive can take one lane's events (`Mobile.Session` drains
  the interactive lane ahead of every bulk frame); `Desktop.Relay` keeps a
  queue per lane (`Desktop.Relay.Outbox`).

  Pure.
  """

  @typedoc "A lane, in the order lanes are written."
  @type lane :: :live | :interactive | :bulk

  @lanes [:live, :interactive, :bulk]

  # The header fields the table reads, and what they decide.
  @size_field "size_bytes"
  @capability_field "capability"
  @op_field "op"
  @interactive_part_bytes 256 * 1_024
  @header_fields %{
    "invoke_part" => [@size_field],
    "invoke_open" => [@capability_field, @op_field]
  }

  @live ~w(call_open call_attached call_line call_audio call_frame call_close)

  @bulk ~w(
    media_fetch media_begin media_chunk media_end
    attach_begin attach_chunk attach_end attach_status
    snapshot_begin snapshot_chunk snapshot_end snapshot_stored snapshot_refused
    move_offer move_chunk move_end move_commit move_resume move_accept move_ready move_done
  )

  @interactive ~w(
    hello hello_ack ping pong error ack
    msg command cancel history_pull history_page read_state request_status request_status_page
    push_register push_unregister unpair pair_request pair_approved pair_denied
    accepted turn_started text_delta tool_event text_done turn_done turn_error row reaction
    approval approval_resolved link_preview notice
    companion_open companion_line companion_close manage manage_result
    loopback_open loopback_request loopback_response loopback_close loopback_failed
    enroll_request enroll_accepted
    invoke_cancel invoke_result invoke_status
    offers link_path
  )

  @by_header Map.keys(@header_fields)
  @fixed @live ++ @interactive ++ @bulk

  if length(Enum.uniq(@fixed ++ @by_header)) != length(@fixed ++ @by_header) do
    raise CompileError, description: "Lanes: an event is named in more than one lane"
  end

  @doc "Whether an event of `type` with `header` rides the live lane."
  defguard live?(type, header) when is_binary(type) and is_map(header) and type in @live

  @doc "Whether an event of `type` with `header` rides the interactive lane."
  defguard interactive?(type, header)
           when is_binary(type) and is_map(header) and
                  (type in @interactive or
                     (type == "invoke_part" and is_map_key(header, @size_field) and
                        is_integer(:erlang.map_get(@size_field, header)) and
                        :erlang.map_get(@size_field, header) <= @interactive_part_bytes) or
                     (type == "invoke_open" and
                        not (is_map_key(header, @capability_field) and
                               :erlang.map_get(@capability_field, header) == "history" and
                               is_map_key(header, @op_field) and
                               :erlang.map_get(@op_field, header) == "submit")))

  @doc "Whether an event of `type` with `header` rides the bulk lane."
  defguard bulk?(type, header)
           when is_binary(type) and is_map(header) and
                  (type in @bulk or
                     (type == "invoke_part" and is_map_key(header, @size_field) and
                        is_integer(:erlang.map_get(@size_field, header)) and
                        :erlang.map_get(@size_field, header) > @interactive_part_bytes) or
                     (type == "invoke_open" and is_map_key(header, @capability_field) and
                        :erlang.map_get(@capability_field, header) == "history" and
                        is_map_key(header, @op_field) and
                        :erlang.map_get(@op_field, header) == "submit"))

  @doc "Every lane, in the order lanes are written."
  @spec lanes() :: [lane(), ...]
  def lanes, do: @lanes

  @doc """
  The lane an event of `type` rides, given its `header` (its fields, `t` and
  the raw tail beside them or not), or `{:error, {:no_lane, type}}` for one
  the table does not name, or whose header the table cannot read.
  """
  @spec lane(String.t(), map()) :: {:ok, lane()} | {:error, {:no_lane, String.t()}}
  def lane(type, header) when live?(type, header), do: {:ok, :live}
  def lane(type, header) when interactive?(type, header), do: {:ok, :interactive}
  def lane(type, header) when bulk?(type, header), do: {:ok, :bulk}

  def lane(type, header) when is_binary(type) and is_map(header),
    do: {:error, {:no_lane, type}}

  @doc "The header fields the table reads, by the event type that has them."
  @spec header_fields() :: %{String.t() => [String.t(), ...]}
  def header_fields, do: @header_fields

  @doc "Every event the table names, whatever its header."
  @spec types() :: [String.t()]
  def types, do: @fixed ++ @by_header
end
