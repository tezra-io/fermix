defmodule FermixChannels.Mobile.PeerEvents do
  @moduledoc """
  The fields of the events M75 adds to the mobile wire: a desktop's session,
  a candidate's enrollment and the move (`PROTOCOL.md`: *Desktop sessions*,
  *Enrollment and the move*); M87's call channel on a phone's session
  (*Calls from the phone*); and M97's computer record on a desktop's session
  (`offers`, `link_path`) and a computer's join on an enrollment session
  (`join_request`, `join_approved`, `join_denied`), and the invocation, the
  same five events either way (`invoke_open`, `invoke_part`,
  `invoke_cancel`, `invoke_result`, `invoke_status`, M97 §6.1).

  One declarative table per direction, `client` for what the initiator sends
  (a phone, a desktop, a candidate, the source of a move) and `server` for what
  the responder sends. Each event names its fields, each with the rule its
  value must meet (optional ones are absent, never null), and its raw tail:
  `:none`, `:required` (one to 60 KiB), `{:optional, max}` (empty, or at most
  `max` bytes), `{:pcm16, max}` (whole PCM16 samples, two to `max` bytes) or
  `{:jpeg, max}` (one JPEG, its start-of-image marker first, at most `max`
  bytes). `Mobile.Protocol` owns the frame and the catalogs and asks this
  module about these events alone. Pure.
  """

  alias FermixCore.Home.DesktopLink

  @max_u64 18_446_744_073_709_551_615
  @max_raw 60 * 1_024
  @id ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/
  @method ~r/\A[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*\z/
  @http_method ~r/\A[A-Z]{1,16}\z/
  @header_name ~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]{1,256}\z/
  @header_value_forbidden ~r/[\r\n\x00]/
  @node_id ~r/\A[0-9a-f]{64}\z/
  @relay_url ~r/\Ahttps:\/\/[a-z0-9]([a-z0-9.-]*[a-z0-9])?\/\z/
  @recipient ~r/\Afxsnap1\.[A-Za-z0-9_-]{1,128}\.[A-Za-z0-9_-]{43}\z/
  @sha256 ~r/\A[0-9a-fA-F]{64}\z/
  @rev ~r/\A[0-9a-f]{16}\z/
  @controls ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u
  @blank ~r/\s/u

  @playback_id ~r/\A[A-Za-z0-9._:-]{1,64}\z/
  # A call's audio frame: 100 ms of 24 kHz mono PCM16.
  @call_audio_bytes 4_800
  # A camera still (M87 Phase 2): the phone scales it to a 768-pixel long edge
  # and steps its quality down until it fits; the sides' bound is generous.
  @call_frame_side {:range, 1, 4_096}
  # A JPEG opens with its start-of-image marker and the next marker's first byte.
  @jpeg_magic <<0xFF, 0xD8, 0xFF>>

  @loopback_failures ~w(port_in_use not_permitted failed)
  @link_paths ~w(direct relay)
  @snapshot_refusals ~w(disk_floor space_unknown mismatch out_of_order invalid_name write_failed)
  @computer_platforms ~w(macos linux)
  @join_denials ~w(denied timeout cancelled device_disconnected)

  @relay {:object, [{"url", :relay_url}, {"quic_port", :port}]}

  # The invocation (M97 §6.1): the same five events either way, a server
  # asking its computer and a computer asking its server.
  @capability ~r/\A[a-z][a-z0-9_]{0,31}\z/
  @max_op_bytes 64
  @max_deadline_ms 900_000
  @max_part_bytes 20 * 1_024 * 1_024
  @origins Enum.map(FermixCore.Computers.Origin.wire_origins(), &Atom.to_string/1)
  @statuses Enum.map(FermixCore.Computers.Outcome.statuses(), &Atom.to_string/1)
  @refusals Enum.map(FermixCore.Computers.Outcome.refusals(), &Atom.to_string/1)
  @part {:object,
         [
           {"size_bytes", {:range, 1, @max_part_bytes}},
           {"sha256", :sha256},
           {"mime", :mime}
         ]}
  @invoke %{
    "invoke_open" =>
      {[
         {"id", :id},
         {"capability", :capability},
         {"op", :op},
         {"deadline_ms", {:range, 0, @max_deadline_ms}},
         {"epoch", :positive},
         {"origin", {:enum, @origins}},
         {"turn", {:optional, {:object, [{"session_id", :name}, {"tool_call_id", :name}]}}},
         {"part", {:optional, @part}},
         {"index", :count},
         {"last", :boolean}
       ], :required},
    "invoke_part" =>
      {[
         {"id", :id},
         {"index", :count},
         {"last", :boolean},
         {"size_bytes", {:range, 1, @max_part_bytes}}
       ], :required},
    # A cancel and a status ask name their request's capability and op, which
    # decide their lane: the request's own (`Mobile.Lanes`).
    "invoke_cancel" => {[{"id", :id}, {"capability", :capability}, {"op", :op}], :none},
    "invoke_status" => {[{"id", :id}, {"capability", :capability}, {"op", :op}], :none},
    "invoke_result" =>
      {[
         {"id", :id},
         {"status", {:enum, @statuses}},
         {"refusal", {:optional, {:enum, @refusals}}},
         {"message", {:optional, :text}},
         {"receipt", {:optional, {:object, [{"at", :instant}, {"target", :target_text}]}}},
         {"part", {:optional, @part}},
         {"duration_ms", :count},
         {"index", :count},
         {"last", :boolean}
       ], :required}
  }
  @invoke_events ~w(invoke_open invoke_part invoke_cancel invoke_result invoke_status)

  @client %{
    "companion_open" => {[{"channel", :channel}], :none},
    "companion_line" =>
      {[{"channel", :channel}, {"index", :count}, {"last", :boolean}], :required},
    "companion_close" => {[{"channel", :channel}], :none},
    "manage" =>
      {[
         {"call_id", :id},
         {"method", :method},
         {"protocol_version", :positive},
         {"index", :count},
         {"last", :boolean}
       ], :required},
    "loopback_request" =>
      {[
         {"loopback_id", :id},
         {"request_id", :id},
         {"method", :http_method},
         {"target", :target},
         {"headers", :headers}
       ], {:optional, 16 * 1_024}},
    "loopback_failed" =>
      {[
         {"loopback_id", :id},
         {"port", :port},
         {"reason", {:enum, @loopback_failures}}
       ], :none},
    "snapshot_stored" => {[{"snapshot_id", :id}, {"sha256", :sha256}], :none},
    "snapshot_refused" =>
      {[{"snapshot_id", :id}, {"reason", {:enum, @snapshot_refusals}}], :none},
    "enroll_request" =>
      {[
         {"host",
          {:object, [{"name", :name}, {"os", :name}, {"arch", :name}, {"version", :name}]}},
         {"candidate",
          {:object,
           [
             {"node_id", :node_id},
             {"relays", {:list, @relay, 1, 8}},
             {"recipient", :x25519},
             {"addrs", {:optional, {:list, :hint, 1, 8}}}
           ]}},
         {"snapshots", {:optional, {:object, [{"s3_bucket", :name}, {"s3_region", :name}]}}}
       ], :none},
    "join_request" =>
      {[
         {"host",
          {:object, [{"name", :name}, {"os", :name}, {"arch", :name}, {"version", :name}]}},
         {"platform", {:enum, @computer_platforms}}
       ], :none},
    "move_offer" =>
      {[
         {"move_id", :id},
         {"size_bytes", :count},
         {"sha256", :sha256},
         {"source_epoch", :positive},
         {"recovery_recipient", {:optional, :recipient}},
         {"attempt", :positive}
       ], :none},
    "move_chunk" => {[{"move_id", :id}, {"index", :count}], :required},
    "move_end" => {[{"move_id", :id}], :none},
    "move_commit" => {[{"move_id", :id}], :none},
    "move_resume" => {[{"move_id", :id}], :none},
    "call_open" => {[{"call_id", :id}, {"resume", :boolean}], :none},
    "call_line" => {[{"call_id", :id}, {"control_seq", {:optional, :positive}}], :required},
    "call_audio" => {[{"call_id", :id}], {:pcm16, @call_audio_bytes}},
    "call_frame" =>
      {[
         {"call_id", :id},
         {"width", @call_frame_side},
         {"height", @call_frame_side},
         {"captured_ms", :count}
       ], {:jpeg, @max_raw}},
    "call_close" => {[{"call_id", :id}, {"reason", {:optional, :text}}], :none},
    "offers" => {[{"rev", :rev}, {"index", :count}, {"last", :boolean}], :required},
    "link_path" => {[{"path", {:enum, @link_paths}}], :none}
  }

  @server %{
    "companion_line" =>
      {[{"channel", :channel}, {"index", :count}, {"last", :boolean}], :required},
    "companion_close" => {[{"channel", :channel}, {"reason", {:optional, :text}}], :none},
    "manage_result" => {[{"call_id", :id}, {"index", :count}, {"last", :boolean}], :required},
    "loopback_open" =>
      {[
         {"loopback_id", :id},
         {"ports", {:list, :port, 1, 8}},
         {"expires_in_s", {:range, 1, 900}}
       ], :none},
    "loopback_response" =>
      {[
         {"request_id", :id},
         {"status", {:range, 100, 599}},
         {"headers", :headers},
         {"index", :count},
         {"last", :boolean}
       ], {:optional, @max_raw}},
    "loopback_close" => {[{"loopback_id", :id}], :none},
    "snapshot_begin" =>
      {[{"snapshot_id", :id}, {"name", :name}, {"size_bytes", :count}, {"sha256", :sha256}],
       :none},
    "snapshot_chunk" => {[{"snapshot_id", :id}, {"index", :count}], :required},
    "snapshot_end" => {[{"snapshot_id", :id}], :none},
    "enroll_accepted" => {[{"candidate_id", :id}, {"primary_name", :name}], :none},
    "join_approved" =>
      {[
         {"device_id", :id},
         {"name", :name},
         {"primary_epoch", :positive},
         {"primary",
          {:object,
           [
             {"name", :name},
             {"node_id", :node_id},
             {"relays", {:list, @relay, 1, 8}},
             {"relays_rev", :rev},
             {"addrs", {:optional, {:list, :hint, 0, 8}}}
           ]}}
       ], :none},
    "join_denied" => {[{"reason", {:enum, @join_denials}}], :none},
    "move_accept" => {[{"move_id", :id}, {"recipient", :x25519}], :none},
    "move_ready" => {[{"move_id", :id}, {"epoch", :positive}], :none},
    "move_done" => {[{"move_id", :id}, {"epoch", :positive}], :none},
    "call_attached" =>
      {[
         {"call_id", :id},
         {"resumed", :boolean},
         {"muted", :boolean},
         {"camera", :boolean},
         {"control_seq", :count}
       ], :none},
    "call_line" => {[{"call_id", :id}], :required},
    "call_audio" =>
      {[{"call_id", :id}, {"playback_id", :playback_id}], {:pcm16, @call_audio_bytes}},
    # A string, as `error.code` is: a later primary may end a call for a reason
    # this one does not name (`PROTOCOL.md`), and a phone reads it as an end.
    "call_close" => {[{"call_id", :id}, {"reason", :nonempty}], :none}
  }

  @client_events ~w(
    companion_open companion_line companion_close manage loopback_request loopback_failed
    snapshot_stored snapshot_refused enroll_request move_offer move_chunk move_end move_commit
    move_resume call_open call_line call_audio call_frame call_close offers link_path
    join_request
  )
  @server_events ~w(
    companion_line companion_close manage_result loopback_open loopback_response
    loopback_close snapshot_begin snapshot_chunk snapshot_end enroll_accepted move_accept
    move_ready move_done call_attached call_line call_audio call_close join_approved
    join_denied
  )

  # The invocation rides both directions with one table.
  @client Map.merge(@client, @invoke)
  @server Map.merge(@server, @invoke)
  @client_events @client_events ++ @invoke_events
  @server_events @server_events ++ @invoke_events

  if Enum.sort(@client_events) != Enum.sort(Map.keys(@client)) or
       Enum.sort(@server_events) != Enum.sort(Map.keys(@server)) do
    raise CompileError, description: "PeerEvents: a catalog and its field table disagree"
  end

  @type direction :: :client | :server
  @type raw ::
          :none
          | :required
          | {:optional, pos_integer()}
          | {:pcm16, pos_integer()}
          | {:jpeg, pos_integer()}

  @doc "The M75 events the initiator sends, in catalog order."
  @spec client_events() :: [String.t()]
  def client_events, do: @client_events

  @doc "The M75 events the responder sends, in catalog order."
  @spec server_events() :: [String.t()]
  def server_events, do: @server_events

  @doc "Whether `type` is an M75 event of `direction`."
  @spec event?(direction(), String.t()) :: boolean()
  def event?(:client, type) when is_binary(type), do: Map.has_key?(@client, type)
  def event?(:server, type) when is_binary(type), do: Map.has_key?(@server, type)

  @doc "The fields an M75 event requires, in table order."
  @spec required(direction(), String.t()) :: [String.t()]
  def required(direction, type) do
    {fields, _raw} = spec(direction, type)
    for {name, rule} <- fields, not match?({:optional, _rule}, rule), do: name
  end

  @doc "What an M75 event's raw tail may be."
  @spec raw(direction(), String.t()) :: raw()
  def raw(direction, type), do: direction |> spec(type) |> elem(1)

  @doc "Every M75 event of `direction` that carries a raw tail, required or optional."
  @spec raw_events(direction()) :: [String.t()]
  def raw_events(direction) do
    for type <- events(direction), raw(direction, type) != :none, do: type
  end

  @doc """
  Checks an M75 event's payload against its table: every required field
  present and each field's value within its rule. The first field that fails
  names the refusal (`{:missing_field, name}` or `{:invalid_field, name}`).
  """
  @spec validate(direction(), String.t(), map()) :: :ok | {:error, term()}
  def validate(direction, type, payload) when is_map(payload) do
    {fields, _raw} = spec(direction, type)
    check_fields(fields, payload, "")
  end

  @doc "Checks an M75 event's raw tail against its table."
  @spec validate_raw(direction(), String.t(), binary()) :: :ok | {:error, term()}
  def validate_raw(direction, type, bytes) when is_binary(bytes),
    do: check_raw(raw(direction, type), type, bytes)

  defp check_raw(:none, _type, <<>>), do: :ok
  defp check_raw(:none, type, _bytes), do: {:error, {:unexpected_binary, type}}
  defp check_raw(:required, _type, <<>>), do: {:error, {:missing_field, "bytes"}}
  defp check_raw(:required, _type, bytes), do: at_most(byte_size(bytes), @max_raw)
  defp check_raw({:optional, max}, _type, bytes), do: at_most(byte_size(bytes), max)
  defp check_raw({:pcm16, max}, _type, bytes), do: pcm16(byte_size(bytes), max)
  defp check_raw({:jpeg, max}, _type, bytes), do: jpeg(bytes, byte_size(bytes), max)

  defp at_most(size, max) when size > max, do: {:error, {:raw_chunk_too_large, size, max}}
  defp at_most(_size, _max), do: :ok

  # One JPEG: its markers first, at most `max` bytes.
  defp jpeg(_bytes, 0, _max), do: {:error, {:missing_field, "bytes"}}
  defp jpeg(_bytes, size, max) when size > max, do: {:error, {:raw_chunk_too_large, size, max}}
  defp jpeg(@jpeg_magic <> _rest, _size, _max), do: :ok
  defp jpeg(_bytes, _size, _max), do: {:error, {:invalid_field, "bytes"}}

  # Whole PCM16 samples: one to `max` bytes, an even count.
  defp pcm16(0, _max), do: {:error, {:missing_field, "bytes"}}
  defp pcm16(size, max) when size > max, do: {:error, {:raw_chunk_too_large, size, max}}
  defp pcm16(size, _max) when rem(size, 2) == 1, do: {:error, {:invalid_field, "bytes"}}
  defp pcm16(_size, _max), do: :ok

  defp events(:client), do: @client_events
  defp events(:server), do: @server_events

  defp spec(:client, type), do: Map.fetch!(@client, type)
  defp spec(:server, type), do: Map.fetch!(@server, type)

  defp check_fields(fields, payload, prefix) do
    Enum.reduce_while(fields, :ok, fn {name, rule}, :ok ->
      case check_field(Map.fetch(payload, name), rule, prefix <> name) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp check_field(:error, {:optional, _rule}, _name), do: :ok
  defp check_field(:error, _rule, name), do: {:error, {:missing_field, name}}

  defp check_field({:ok, value}, {:optional, rule}, name),
    do: check_field({:ok, value}, rule, name)

  defp check_field({:ok, value}, {:object, fields}, name) when is_map(value),
    do: check_fields(fields, value, name <> ".")

  defp check_field({:ok, value}, {:list, rule, min, max}, name) when is_list(value) do
    if length(value) in min..max and Enum.all?(value, &valid?(rule, &1)),
      do: :ok,
      else: {:error, {:invalid_field, name}}
  end

  defp check_field({:ok, value}, rule, name) do
    if valid?(rule, value), do: :ok, else: {:error, {:invalid_field, name}}
  end

  defp valid?({:object, fields}, value) when is_map(value),
    do: check_fields(fields, value, "") == :ok

  defp valid?({:enum, values}, value), do: value in values
  defp valid?({:range, min, max}, value), do: is_integer(value) and value >= min and value <= max
  defp valid?(:channel, value), do: valid?({:range, 1, 64}, value)
  defp valid?(:count, value), do: valid?({:range, 0, @max_u64}, value)
  defp valid?(:positive, value), do: valid?({:range, 1, @max_u64}, value)
  defp valid?(:port, value), do: valid?({:range, 1, 65_535}, value)
  defp valid?(:boolean, value), do: is_boolean(value)
  defp valid?(:nonempty, value), do: is_binary(value) and value != ""
  defp valid?(:id, value), do: matches?(@id, value)
  defp valid?(:playback_id, value), do: matches?(@playback_id, value)
  defp valid?(:method, value), do: matches?(@method, value) and byte_size(value) <= 128
  defp valid?(:http_method, value), do: matches?(@http_method, value)
  defp valid?(:node_id, value), do: matches?(@node_id, value)
  defp valid?(:hint, value), do: DesktopLink.hint?(value)
  defp valid?(:relay_url, value), do: matches?(@relay_url, value) and byte_size(value) <= 261
  defp valid?(:recipient, value), do: matches?(@recipient, value)
  defp valid?(:sha256, value), do: matches?(@sha256, value)
  defp valid?(:rev, value), do: matches?(@rev, value)
  defp valid?(:capability, value), do: matches?(@capability, value)
  defp valid?(:op, value), do: matches?(@method, value) and byte_size(value) <= @max_op_bytes
  defp valid?(:instant, value), do: instant?(value)
  defp valid?(:target_text, value), do: printable?(value, 256)
  defp valid?(:mime, value), do: printable?(value, 127) and not Regex.match?(@blank, value)
  defp valid?(:name, value), do: printable?(value, 128)
  defp valid?(:text, value), do: printable?(value, 512)
  defp valid?(:target, value), do: target?(value)
  defp valid?(:x25519, value), do: x25519?(value)
  defp valid?(:headers, value), do: headers?(value)
  defp valid?(_rule, _value), do: false

  defp matches?(regex, value), do: is_binary(value) and Regex.match?(regex, value)

  # Text a person reads: valid UTF-8, no control characters, within its bound.
  defp printable?(value, max) when is_binary(value) do
    byte_size(value) in 1..max and String.valid?(value) and not Regex.match?(@controls, value)
  end

  defp printable?(_value, _max), do: false

  # A moment in UTC, as ISO 8601 writes it.
  defp instant?(value) when is_binary(value) and byte_size(value) <= 64,
    do: match?({:ok, _at, 0}, DateTime.from_iso8601(value))

  defp instant?(_value), do: false

  # An HTTP request target in origin form: a path and its query.
  defp target?("/" <> _rest = value),
    do: printable?(value, 2_048) and not Regex.match?(@blank, value)

  defp target?(_value), do: false

  defp x25519?(value) when is_binary(value) do
    match?({:ok, <<_key::binary-size(32)>>}, Base.decode64(value))
  end

  defp x25519?(_value), do: false

  # A request's or a response's headers, in order, as `[name, value]` pairs.
  defp headers?(headers) when is_list(headers) and length(headers) <= 64,
    do: Enum.all?(headers, &header?/1)

  defp headers?(_headers), do: false

  defp header?([name, value]) when is_binary(name) and is_binary(value) do
    Regex.match?(@header_name, name) and byte_size(value) <= 4_096 and String.valid?(value) and
      not Regex.match?(@header_value_forbidden, value)
  end

  defp header?(_header), do: false
end
