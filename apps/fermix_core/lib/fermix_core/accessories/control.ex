defmodule FermixCore.Accessories.Control do
  @moduledoc """
  The accessory link's control messages: the closed set each end may send,
  their fields, and the JSON rules every message keeps
  (`priv/accessory/PROTOCOL.md`, *Control messages*, *Message reference*).
  `control.schema.json` is this table's export, held to it by the contract
  test.

  `decode/3` is the daemon's receive side: one reassembled payload, the frame
  stream it came on, and who sent it, to a message with atom keys, binary
  values for hex fields (keys, nonces, signatures, data) and string IDs. A
  field the table does not name is dropped, so an additive optional field
  needs no new wire version. `encode/2` writes only what `decode/3` would
  read back unchanged. Pure.

  Errors name what the receiver answers with `error {code, message_type}`:
  `:invalid_json` (not one UTF-8 object of at most 8 KiB and 8 levels, or a
  key repeated), `{:unknown_message, type}` (outside the sender's set),
  `{:invalid_message, type, field}` (the first field that breaks the table;
  `type` is `nil` when the type itself is missing), `{:wrong_stream, type}`.
  """

  @wire_version 1
  @min_wire_version 1
  # Every wire version 1 message fits in one frame; the cap leaves the
  # accessory's 16 KiB JSON parse arena room to parse the largest.
  @max_bytes 8_192
  @max_depth 8
  @senders [:host, :accessory]

  @u32 4_294_967_295
  @wire {:int, 1, 65_535}
  @stream {:int, 1, 65_535}
  @counter {:int, 1, @u32}
  @attempt {:hex_string, 16}
  @round {:int, 1, 3}
  @code {:token, 48}
  @id {:hex_string, 32}
  @source {:enum, ~w(log coredump)}

  @refusals ~w(wire_version unknown_accessory unknown_host bad_proof capability_missing
               unsupported_kind auth_timeout stale_generation)
  @errors ~w(unknown_message invalid_message not_now capability_missing credit_overgrant
             credit_exceeded segment_limit segment_sequence)
  @cancel_reasons ~w(owner expired mismatch_limit invalid_offer invalid_reveal link_reset)
  @call_states ~w(connecting listening thinking speaking muted reconnecting)
  @task_statuses ~w(running completed failed cancelled)

  @state [
    battery: {:nullable, {:int, 0, 100}},
    power: {:enum, ~w(usb battery low critical)},
    brownout: :bool,
    volume: {:int, 0, 100},
    brightness: {:int, 0, 100},
    motion: {:enum, ~w(absent off homing ready paused fault)},
    calibration: {:enum, ~w(absent missing valid calibrating failed)}
  ]

  @counters for name <- ~w(uptime_s frames_rx frames_tx crc_errors resync_bytes pcm_seq_gaps
                           mic_overflows spk_underflows)a,
                do: {name, {:int, 0, @u32}}

  # type => {senders, required fields, optional fields}; `type` and `gen` are
  # required of every message and not listed. Field order is validation order.
  @specs %{
    "hello" =>
      {[:host],
       [
         wire_min: @wire,
         wire_max: @wire,
         host_id: @id,
         host_nonce: {:hex, 32},
         caps: {:int, 0, @u32}
       ], []},
    "host_proof" => {[:host], [sig: {:hex, 64}], []},
    "ping" => {[:host], [], []},
    "hello_ack" =>
      {[:accessory],
       [
         wire: @wire,
         kind: {:token, 16},
         accessory_id: {:nullable, @id},
         firmware: {:text, 32},
         pack: {:nullable, {:hex_string, 32}},
         caps: {:int, 0, @u32},
         accessory_nonce: {:hex, 32},
         sig: {:nullable, {:hex, 64}}
       ], []},
    "attached" => {[:accessory], [state: {:object, @state}], []},
    "pong" => {[:accessory], [uptime_ms: {:int, 0, 9_007_199_254_740_991}], []},
    "refuse" =>
      {[:host, :accessory], [code: {:enum, @refusals}], [wire_min: @wire, wire_max: @wire]},
    "error" => {[:host, :accessory], [code: {:enum, @errors}], [message_type: {:text, 32}]},
    "enroll.begin" =>
      {[:host],
       [
         attempt: @attempt,
         round: @round,
         host_pk: {:hex, 65},
         host_id: @id,
         host_commit: {:hex, 32}
       ], []},
    "enroll.reveal" => {[:host], [attempt: @attempt, round: @round, host_nonce: {:hex, 32}], []},
    "enroll.commit" => {[:host], [attempt: @attempt, round: @round, host_sig: {:hex, 64}], []},
    "enroll.cancel" =>
      {[:host, :accessory], [attempt: @attempt, reason: {:enum, @cancel_reasons}], []},
    "enroll.offer" =>
      {[:accessory],
       [attempt: @attempt, round: @round, accessory_pk: {:hex, 65}, accessory_nonce: {:hex, 32}],
       []},
    "enroll.confirmed" => {[:accessory], [attempt: @attempt, round: @round, sig: {:hex, 64}], []},
    "enroll.done" => {[:accessory], [attempt: @attempt, accessory_id: @id], []},
    "call.start" => {[:host], [stream: @stream, call: {:text, 64}], []},
    "call.result" =>
      {[:host], [request: @counter, result: {:enum, ~w(accepted refused)}], [code: @code]},
    "call.state" => {[:host], [stream: @stream, state: {:enum, @call_states}], []},
    "call.end" => {[:host], [stream: @stream], [reason: @code]},
    "mute.set" => {[:host], [stream: @stream, muted: :bool], []},
    "call.request" =>
      {[:accessory], [request: @counter, source: {:enum, ~w(screen_tap head_swipe)}], []},
    "call.end_request" => {[:accessory], [stream: @stream], []},
    "mic.state" =>
      {[:accessory], [stream: @stream, state: {:enum, ~w(live muted off)}], [reason: @code]},
    "check.tone" => {[:host], [], []},
    "check.mic" => {[:host], [seconds: {:int, 1, 10}], []},
    "check.face" => {[:host], [pose: {:token, 32}], []},
    "check.motion" => {[:host], [gesture: {:token, 32}], []},
    "check.stop" => {[:host], [], []},
    "accessory.calibrate" =>
      {[:host], [op: {:enum, ~w(begin nudge set_zero cancel)}],
       [axis: {:enum, ~w(pan tilt)}, steps: {:int, -64, 64}]},
    "check.level" => {[:accessory], [rms: {:int, 0, 32_767}], []},
    "check.result" =>
      {[:accessory], [check: {:enum, ~w(tone mic face motion)}, result: {:enum, ~w(ok fault)}],
       [code: @code]},
    "spk.begin" =>
      {[:host], [stream: @stream, segment: @counter, playback_id: {:nullable, {:text, 64}}], []},
    "spk.end" => {[:host], [stream: @stream, segment: @counter], []},
    "spk.flush" => {[:host], [stream: @stream], []},
    "credit" => {[:accessory], [stream: @stream, bytes: {:int, 1, 8_192}], []},
    "playback.progress" =>
      {[:accessory],
       [stream: @stream, playback_id: {:text, 64}, played_ms: {:int, 0, @u32}, drained: :bool],
       []},
    "spk.drained" => {[:accessory], [stream: @stream, segment: @counter], []},
    "spk.flushed" =>
      {[:accessory], [stream: @stream, played_ms: {:int, 0, @u32}], [segment: @counter]},
    "task.event" =>
      {[:host],
       [
         stream: @stream,
         task: {:text, 64},
         revision: @counter,
         status: {:enum, @task_statuses},
         in_chat: :bool
       ], []},
    "voice.readiness" => {[:host], [ready: :bool], [code: @code]},
    "accessory.set" =>
      {[:host], [], [volume: {:int, 0, 100}, motion: :bool, brightness: {:int, 0, 100}]},
    "accessory.forget" => {[:host], [], []},
    "accessory.state" => {[:accessory], @state, []},
    "diag.fetch" => {[:host], [source: @source, chunk: {:int, 0, 65_535}], []},
    "diag.counters" => {[:accessory], [counters: {:object, @counters}], []},
    "diag.fault" => {[:accessory], [code: @code], []},
    "diag.chunk" =>
      {[:accessory],
       [source: @source, chunk: {:int, 0, 65_535}, last: :bool, data: {:hex_up_to, 1_536}], []}
  }

  # One entry per `relation/2` clause below that names a type.
  @relation_types ~w(hello hello_ack refuse call.result accessory.set accessory.calibrate)

  # The capability an accessory must report before the host sends the message.
  @capabilities %{
    "check.tone" => :speaker,
    "spk.begin" => :speaker,
    "spk.end" => :speaker,
    "spk.flush" => :speaker,
    "check.mic" => :mic,
    "mute.set" => :mic,
    "check.face" => :screen,
    "check.motion" => :motion,
    "accessory.calibrate" => :motion
  }

  @type sender :: :host | :accessory
  @type field_type ::
          :gen
          | :bool
          | {:int, integer(), integer()}
          | {:enum, [String.t()]}
          | {:hex, pos_integer()}
          | {:hex_string, pos_integer()}
          | {:hex_up_to, pos_integer()}
          | {:token, pos_integer()}
          | {:text, pos_integer()}
          | {:nullable, field_type()}
          | {:object, [{atom(), field_type()}]}
  @type spec :: %{
          senders: [sender()],
          required: [{atom(), field_type()}],
          optional: [{atom(), field_type()}]
        }
  @type message :: %{
          required(:type) => String.t(),
          required(:gen) => pos_integer(),
          optional(atom()) => term()
        }
  @type error ::
          :invalid_json
          | {:unknown_message, String.t()}
          | {:invalid_message, String.t() | nil, String.t()}
          | {:wrong_stream, String.t()}

  @doc "The current wire version: the message set this table is."
  @spec wire_version() :: pos_integer()
  def wire_version, do: @wire_version

  @doc "The inclusive range of wire versions the host speaks, sent in `hello`."
  @spec supported_wire_range() :: {pos_integer(), pos_integer()}
  def supported_wire_range, do: {@min_wire_version, @wire_version}

  @doc "The closed set of message types `sender` sends, sorted."
  @spec messages(sender()) :: [String.t()]
  def messages(sender) when sender in @senders do
    for {type, {senders, _required, _optional}} <- @specs, sender in senders, do: type
  end

  @doc "One message type's fields."
  @spec spec(String.t()) :: spec()
  def spec(type) when is_map_key(@specs, type) do
    {senders, required, optional} = Map.fetch!(@specs, type)
    %{senders: senders, required: required, optional: optional}
  end

  @doc """
  The messages with a rule across their fields (`decode/3` refuses a message
  that breaks one): the schema states each but `hello`'s as an `allOf`.
  """
  @spec relation_types() :: [String.t()]
  def relation_types, do: @relation_types

  @doc "The capability the accessory must report before the host sends `type`, or `nil`."
  @spec capability(String.t()) :: atom() | nil
  def capability(type) when is_binary(type), do: Map.get(@capabilities, type)

  @doc "The frame stream a message travels on: its `stream` field, or the link's 0."
  @spec stream(message()) :: 0..65_535
  def stream(%{type: type} = message) when is_binary(type), do: Map.get(message, :stream, 0)

  @doc "Reads one reassembled payload `sender` sent on frame stream `stream`."
  @spec decode(sender(), 0..65_535, binary()) :: {:ok, message()} | {:error, error()}
  def decode(sender, stream, payload)
      when sender in @senders and stream in 0..65_535 and is_binary(payload) do
    with {:ok, object} <- parse_json(payload),
         {:ok, type} <- message_type(object),
         {:ok, spec} <- sender_spec(sender, type),
         {:ok, message} <- message_fields(type, spec, object),
         :ok <- relations(type, message) do
      on_stream(message, stream)
    end
  end

  @doc "Writes a message `sender` sends, refusing one `decode/3` would not read back unchanged."
  @spec encode(sender(), message()) :: {:ok, binary()} | {:error, error()}
  def encode(sender, %{type: type} = message) when sender in @senders and is_binary(type) do
    with {:ok, {_senders, required, optional}} <- sender_spec(sender, type),
         {:ok, object} <- to_object(type, [{:gen, :gen} | required] ++ optional, message),
         {:ok, json} <- json(type, object),
         {:ok, ^message} <- decode(sender, stream(message), json) do
      {:ok, json}
    else
      # A nested map with keys the table does not name reads back without them.
      {:ok, _different} -> {:error, {:invalid_message, type, "fields"}}
      {:error, _reason} = error -> error
    end
  end

  # -- JSON ----------------------------------------------------------------------

  defp parse_json(payload) when byte_size(payload) > @max_bytes, do: {:error, :invalid_json}

  defp parse_json(payload) do
    with true <- String.valid?(payload),
         {:ok, %Jason.OrderedObject{} = object} <-
           Jason.decode(payload, objects: :ordered_objects),
         {:ok, map} <- plain(object, 1) do
      {:ok, map}
    else
      _not_one_object -> {:error, :invalid_json}
    end
  end

  # Ordered objects keep a repeated key, so it can be refused rather than
  # silently resolved one way here and another on the firmware.
  defp plain(%Jason.OrderedObject{}, depth) when depth > @max_depth, do: :error
  defp plain(list, depth) when is_list(list) and depth > @max_depth, do: :error

  defp plain(%Jason.OrderedObject{values: pairs}, depth) do
    keys = Enum.map(pairs, &elem(&1, 0))
    if length(Enum.uniq(keys)) == length(keys), do: plain_pairs(pairs, depth), else: :error
  end

  defp plain(list, depth) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
      case plain(value, depth + 1) do
        {:ok, plain_value} -> {:cont, {:ok, [plain_value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> then(fn
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end)
  end

  defp plain(scalar, _depth), do: {:ok, scalar}

  defp plain_pairs(pairs, depth) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case plain(value, depth + 1) do
        {:ok, plain_value} -> {:cont, {:ok, Map.put(acc, key, plain_value)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp json(type, object) do
    case Jason.encode(object) do
      {:ok, json} -> {:ok, json}
      {:error, _reason} -> {:error, {:invalid_message, type, "fields"}}
    end
  end

  # -- the table -------------------------------------------------------------------

  defp message_type(%{"type" => type}) when is_binary(type), do: {:ok, type}
  defp message_type(_object), do: {:error, {:invalid_message, nil, "type"}}

  defp sender_spec(sender, type) do
    case Map.fetch(@specs, type) do
      {:ok, {senders, _required, _optional} = spec} ->
        if sender in senders, do: {:ok, spec}, else: {:error, {:unknown_message, type}}

      :error ->
        {:error, {:unknown_message, type}}
    end
  end

  defp message_fields(type, {_senders, required, optional}, object) do
    with {:ok, message} <- take([{:gen, :gen} | required], :required, object, %{type: type}),
         {:ok, message} <- take(optional, :optional, object, message) do
      {:ok, message}
    else
      {:error, field} -> {:error, {:invalid_message, type, field}}
    end
  end

  defp take(fields, presence, object, acc) do
    Enum.reduce_while(fields, {:ok, acc}, fn {name, field_type}, {:ok, acc} ->
      key = Atom.to_string(name)

      case take_one(field_type, presence, object, key) do
        :absent -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
        :error -> {:halt, {:error, key}}
        {:error, inner} -> {:halt, {:error, key <> "." <> inner}}
      end
    end)
  end

  defp take_one(field_type, presence, object, key) do
    case Map.fetch(object, key) do
      {:ok, value} -> value(field_type, value)
      :error when presence == :optional -> :absent
      :error -> :error
    end
  end

  defp value(:gen, value), do: value({:int, 1, @u32}, value)
  defp value(:bool, value) when is_boolean(value), do: {:ok, value}

  defp value({:int, min, max}, value) when is_integer(value) and value >= min and value <= max,
    do: {:ok, value}

  defp value({:enum, values}, value) when is_binary(value),
    do: if(value in values, do: {:ok, value}, else: :error)

  defp value({:hex, bytes}, value) when is_binary(value) and byte_size(value) == bytes * 2,
    do: decode_hex(value)

  defp value({:hex_string, bytes}, value) when is_binary(value) and byte_size(value) == bytes * 2,
    do: with({:ok, _raw} <- decode_hex(value), do: {:ok, value})

  defp value({:hex_up_to, bytes}, value)
       when is_binary(value) and byte_size(value) in 2..(bytes * 2)//2,
       do: decode_hex(value)

  defp value({:token, max}, <<first, rest::binary>> = value)
       when first in ?a..?z and byte_size(rest) < max,
       do: if(token_tail?(rest), do: {:ok, value}, else: :error)

  defp value({:text, max}, value) when is_binary(value) and byte_size(value) in 1..max//1,
    do: if(printable?(value), do: {:ok, value}, else: :error)

  defp value({:nullable, _type}, nil), do: {:ok, nil}
  defp value({:nullable, type}, value), do: value(type, value)
  defp value({:object, fields}, value) when is_map(value), do: take(fields, :required, value, %{})
  defp value(_type, _value), do: :error

  defp decode_hex(value) do
    case Base.decode16(value, case: :lower) do
      {:ok, raw} -> {:ok, raw}
      :error -> :error
    end
  end

  defp token_tail?(<<char, rest::binary>>) when char in ?a..?z or char in ?0..?9 or char == ?_,
    do: token_tail?(rest)

  defp token_tail?(<<>>), do: true
  defp token_tail?(_other), do: false

  defp printable?(<<char, rest::binary>>) when char in 0x21..0x7E, do: printable?(rest)
  defp printable?(<<>>), do: true
  defp printable?(_other), do: false

  # -- rules across fields ------------------------------------------------------------

  defp relations(type, message) do
    case relation(type, message) do
      :ok -> :ok
      {:error, field} -> {:error, {:invalid_message, type, field}}
    end
  end

  defp relation("hello", %{wire_min: min, wire_max: max}) when min > max, do: {:error, "wire_max"}

  defp relation("hello_ack", %{accessory_id: id, sig: sig}) when is_nil(id) != is_nil(sig),
    do: {:error, "sig"}

  defp relation("refuse", %{code: "wire_version"} = message),
    do: present(message, [:wire_min, :wire_max])

  defp relation("call.result", %{result: "refused"} = message), do: present(message, [:code])

  defp relation("accessory.set", message) do
    if Enum.any?([:volume, :motion, :brightness], &Map.has_key?(message, &1)),
      do: :ok,
      else: {:error, "volume"}
  end

  defp relation("accessory.calibrate", %{op: "nudge"} = message) do
    with :ok <- present(message, [:axis, :steps]) do
      if message.steps == 0, do: {:error, "steps"}, else: :ok
    end
  end

  defp relation("accessory.calibrate", message), do: absent(message, [:axis, :steps])
  defp relation(_type, _message), do: :ok

  defp present(message, fields) do
    case Enum.find(fields, &(not Map.has_key?(message, &1))) do
      nil -> :ok
      missing -> {:error, Atom.to_string(missing)}
    end
  end

  defp absent(message, fields) do
    case Enum.find(fields, &Map.has_key?(message, &1)) do
      nil -> :ok
      extra -> {:error, Atom.to_string(extra)}
    end
  end

  defp on_stream(%{type: type} = message, stream) do
    if stream(message) == stream, do: {:ok, message}, else: {:error, {:wrong_stream, type}}
  end

  # -- encoding ----------------------------------------------------------------------

  defp to_object(type, fields, message) do
    known = MapSet.new([:type | Enum.map(fields, &elem(&1, 0))])

    case Enum.find(Map.keys(message), &(not MapSet.member?(known, &1))) do
      nil -> {:ok, encode_fields(fields, message, %{"type" => type})}
      unknown -> {:error, {:invalid_message, type, to_string(unknown)}}
    end
  end

  defp encode_fields(fields, message, acc) do
    Enum.reduce(fields, acc, fn {name, field_type}, acc ->
      case Map.fetch(message, name) do
        {:ok, value} -> Map.put(acc, Atom.to_string(name), encode_value(field_type, value))
        :error -> acc
      end
    end)
  end

  defp encode_value({:nullable, _type}, nil), do: nil
  defp encode_value({:nullable, type}, value), do: encode_value(type, value)

  defp encode_value({kind, _bytes}, value) when kind in [:hex, :hex_up_to] and is_binary(value),
    do: Base.encode16(value, case: :lower)

  defp encode_value({:object, fields}, value) when is_map(value),
    do: encode_fields(fields, value, %{})

  defp encode_value(_type, value), do: value
end
