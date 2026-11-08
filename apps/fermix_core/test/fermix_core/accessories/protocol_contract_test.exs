defmodule FermixCore.Accessories.ProtocolContractTest do
  @moduledoc """
  Holds the accessory link's canonical export under `priv/accessory/` to the
  modules that speak it. The firmware vendors that directory byte for byte, so
  a fixture these modules cannot reproduce is a wire the robot would speak and
  the daemon would not. The fixtures come from `scripts/dev/accessory_fixtures.py`,
  an implementation of `PROTOCOL.md` that shares no code with these modules.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Accessories.Capabilities
  alias FermixCore.Accessories.Control
  alias FermixCore.Accessories.Frame
  alias FermixCore.Accessories.P256
  alias FermixCore.Accessories.Parser
  alias FermixCore.Accessories.Reassembler
  alias FermixCore.Accessories.Transcript

  defmodule SchemaRender do
    @moduledoc false
    # What `control.schema.json` must say for one message spec: the contract
    # test renders it from `Control.spec/1` and compares it with the file.

    def message(type, %{required: required, optional: optional}) do
      fields = [{:type, {:const, type}}, {:gen, :gen}] ++ required

      %{
        "type" => "object",
        "required" => Enum.map(fields, fn {name, _type} -> Atom.to_string(name) end),
        "properties" =>
          Map.new(fields ++ optional, fn {name, type} -> {Atom.to_string(name), field(type)} end)
      }
    end

    def field({:const, value}), do: %{"const" => value}
    def field(:gen), do: %{"type" => "integer", "minimum" => 1, "maximum" => 4_294_967_295}
    def field(:bool), do: %{"type" => "boolean"}
    def field({:int, min, max}), do: %{"type" => "integer", "minimum" => min, "maximum" => max}
    def field({:enum, values}), do: %{"enum" => values}
    def field({:hex, bytes}), do: hex_pattern(bytes)
    def field({:hex_string, bytes}), do: hex_pattern(bytes)

    def field({:hex_up_to, bytes}),
      do: %{"type" => "string", "pattern" => "^([0-9a-f]{2}){1,#{bytes}}$"}

    def field({:token, max}),
      do: %{"type" => "string", "pattern" => "^[a-z][a-z0-9_]{0,#{max - 1}}$"}

    def field({:text, max}), do: %{"type" => "string", "pattern" => "^[\\x21-\\x7e]{1,#{max}}$"}
    def field({:nullable, type}), do: %{"anyOf" => [field(type), %{"type" => "null"}]}

    def field({:object, fields}) do
      %{
        "type" => "object",
        "required" => Enum.map(fields, fn {name, _type} -> Atom.to_string(name) end),
        "properties" =>
          Map.new(fields, fn {name, type} -> {Atom.to_string(name), field(type)} end)
      }
    end

    defp hex_pattern(bytes), do: %{"type" => "string", "pattern" => "^[0-9a-f]{#{bytes * 2}}$"}
  end

  defmodule SchemaEval do
    @moduledoc false
    # Just the JSON Schema keywords the cross-field rules use (if, then, else,
    # required, properties, const, type, anyOf, not), so the test can ask the
    # schema the same question it asks `Control`.

    def valid?(rules, object) when is_list(rules), do: Enum.all?(rules, &valid?(&1, object))

    def valid?(%{} = schema, object) do
      Enum.all?(schema, fn {keyword, value} -> keyword?(keyword, value, schema, object) end)
    end

    defp keyword?("if", condition, schema, object) do
      branch = if valid?(condition, object), do: schema["then"], else: schema["else"]
      branch == nil or valid?(branch, object)
    end

    defp keyword?(keyword, _value, _schema, _object)
         when keyword in ["then", "else", "description"],
         do: true

    defp keyword?("required", names, _schema, object),
      do: Enum.all?(names, &Map.has_key?(object, &1))

    defp keyword?("anyOf", options, _schema, object), do: Enum.any?(options, &valid?(&1, object))
    defp keyword?("not", inner, _schema, object), do: not valid?(inner, object)

    defp keyword?("properties", properties, _schema, object) do
      Enum.all?(properties, fn {name, inner} ->
        not Map.has_key?(object, name) or value?(inner, object[name])
      end)
    end

    defp value?(%{"const" => const}, value), do: value == const
    defp value?(%{"type" => "null"}, value), do: is_nil(value)
    defp value?(%{"type" => "string"}, value), do: is_binary(value)
    defp value?(%{"not" => inner}, value), do: not value?(inner, value)
  end

  @dir Application.app_dir(:fermix_core, "priv/accessory")

  defp fixture(name), do: @dir |> Path.join("fixtures/#{name}") |> File.read!() |> Jason.decode!()

  defp lines(name) do
    @dir
    |> Path.join("fixtures/#{name}")
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  defp hex!(text), do: Base.decode16!(text, case: :lower)

  describe "framing" do
    test "the CRC is the IEEE CRC-32 every vector names, written little-endian" do
      for %{"input" => input, "value" => value, "wire" => wire} <-
            fixture("crc32.json")["vectors"] do
        crc = :erlang.crc32(hex!(input))
        assert Base.encode16(<<crc::32>>, case: :lower) == value
        assert Base.encode16(<<crc::32-little>>, case: :lower) == wire
      end
    end

    test "every frame encodes to its fixture bytes and parses back to its fields" do
      for row <- fixture("frames.json")["frames"] do
        frame = frame_from(row)
        assert Base.encode16(Frame.encode(frame), case: :lower) == row["frame"], row["name"]

        from = if frame.type == :speaker, do: :host, else: :accessory
        assert {[{:frame, ^frame}], parser} = Parser.feed(Parser.new(from), hex!(row["frame"]), 0)
        assert Parser.pending_bytes(parser) == 0
      end
    end

    test "the corpus's stall bound is the parser's" do
      assert fixture("stream_corpus.json")["stall_ms"] == Parser.stall_ms()
    end

    test "every corpus stream gives its frames, faults, discarded and leftover bytes" do
      for %{"name" => name, "from" => from} = row <- fixture("stream_corpus.json")["cases"] do
        parser = Parser.new(String.to_existing_atom(from))

        {events, parser} =
          row["chunks"]
          |> Enum.zip(row["times_ms"])
          |> Enum.reduce({[], parser}, fn {chunk, now_ms}, {acc, parser} ->
            {events, parser} = Parser.feed(parser, hex!(chunk), now_ms)
            {acc ++ events, parser}
          end)

        assert Enum.map(events, &event_json/1) == row["events"], name
        assert Parser.resync_bytes(parser) == row["resync_bytes"], name
        assert Parser.pending_bytes(parser) == row["pending_bytes"], name
      end
    end

    test "every reassembly case delivers its messages and faults" do
      for %{"name" => name, "frames" => frames, "events" => expected} <-
            fixture("reassembly.json")["cases"] do
        {events, _reassembler} =
          Enum.reduce(frames, {[], Reassembler.new()}, fn row, {acc, reassembler} ->
            frame = %Frame{
              type: :control,
              flags: row["flags"],
              stream: row["stream"],
              seq: row["seq"],
              payload: payload(row)
            }

            case Reassembler.feed(reassembler, frame) do
              {:more, next} -> {acc, next}
              {:message, stream, message, next} -> {acc ++ [{:message, stream, message}], next}
              {:fault, reason, next} -> {acc ++ [{:fault, reason}], next}
            end
          end)

        assert Enum.map(events, &reassembly_json/1) == Enum.map(expected, &expand_message/1), name
      end
    end
  end

  describe "control messages" do
    test "every valid message decodes for its sender, on its stream, and re-encodes to itself" do
      for {file, sender} <- [
            {"host_messages.jsonl", :host},
            {"accessory_messages.jsonl", :accessory}
          ],
          line <- lines(file) do
        stream = line |> Jason.decode!() |> Map.get("stream", 0)
        assert {:ok, message} = Control.decode(sender, stream, line), line
        assert Control.stream(message) == stream
        assert {:ok, encoded} = Control.encode(sender, message)
        assert Control.decode(sender, stream, encoded) == {:ok, message}
        known = Map.take(Jason.decode!(line), Enum.map(Map.keys(message), &Atom.to_string/1))
        assert Jason.decode!(encoded) == known, line
      end
    end

    test "every invalid payload is refused with its error, whoever receives it" do
      for line <- lines("invalid_messages.jsonl") do
        %{"sender" => sender, "stream" => stream, "payload" => payload, "error" => error} =
          Jason.decode!(line)

        assert {:error, reason} = Control.decode(String.to_existing_atom(sender), stream, payload)
        assert error_json(reason) == error, payload
      end
    end

    test "the fixtures carry every message of both senders" do
      for {file, sender} <- [
            {"host_messages.jsonl", :host},
            {"accessory_messages.jsonl", :accessory}
          ] do
        types = file |> lines() |> Enum.map(&Jason.decode!(&1)["type"]) |> MapSet.new()
        assert types == MapSet.new(Control.messages(sender)), file
      end
    end

    test "the schema publishes the module's wire version and window" do
      schema = schema()
      {min, max} = Control.supported_wire_range()

      assert schema["x-wire-version"] == Control.wire_version()
      assert schema["x-supported-wire-range"] == %{"min" => min, "max" => max}
      assert schema["x-framing-version"] == Frame.framing_version()
    end

    test "each sender's discriminator names exactly its closed set and wires every def" do
      defs = schema()["$defs"]

      for {sender, name} <- [{:host, "hostMessage"}, {:accessory, "accessoryMessage"}] do
        discriminator = defs[name]

        assert MapSet.new(discriminator["properties"]["type"]["enum"]) ==
                 MapSet.new(Control.messages(sender))

        wired =
          for %{
                "if" => %{"properties" => %{"type" => %{"const" => type}}},
                "then" => %{"$ref" => ref}
              } <-
                discriminator["allOf"],
              into: %{},
              do: {type, ref}

        assert Map.keys(wired) |> MapSet.new() == MapSet.new(Control.messages(sender))
        for {type, ref} <- wired, do: assert(ref == "#/$defs/#{type}")
      end
    end

    test "every message def has the module's fields, types and required set" do
      defs = schema()["$defs"]

      for type <- Enum.uniq(Control.messages(:host) ++ Control.messages(:accessory)) do
        definition = defs[type] || flunk("no schema def for #{type}")
        expected = SchemaRender.message(type, Control.spec(type))
        assert Map.take(definition, ["type", "required", "properties"]) == expected, type
      end
    end

    test "the schema's rules across fields say what Control.decode/3 says" do
      defs = schema()["$defs"]

      with_rules =
        for {type, %{"allOf" => _}} <- defs,
            type not in ["hostMessage", "accessoryMessage"],
            do: type

      # The one rule a schema cannot state: wire_min is at most wire_max.
      assert MapSet.new(with_rules) == MapSet.new(Control.relation_types() -- ["hello"])
      assert defs["hello"]["description"] =~ "wire_min is at most wire_max"
      refute Map.has_key?(defs["hello"], "allOf")

      for {sender, stream, type, fields, valid?} <- relation_probes() do
        object = Map.merge(%{"type" => type, "gen" => 1}, fields)
        verdict = Control.decode(sender, stream, Jason.encode!(object))
        schema_verdict = type == "hello" or SchemaEval.valid?(defs[type]["allOf"], object)

        assert match?({:ok, _}, verdict) == valid?, "Control: #{inspect(object)}"
        if type != "hello", do: assert(schema_verdict == valid?, "schema: #{inspect(object)}")
        unless valid?, do: assert({:error, {:invalid_message, ^type, _field}} = verdict)
      end
    end

    test "the capability bits are the ones the contract names" do
      assert Capabilities.bits() == [
               mic: 0,
               speaker: 1,
               screen: 2,
               touch: 3,
               pet: 4,
               motion: 5,
               battery: 6,
               wake_word: 7,
               link_update: 8
             ]

      assert Capabilities.host() == 0x7F
    end
  end

  describe "identity" do
    test "every fixture key is the seed's key and its ID is the SHA-256 of its public point" do
      for {_role, %{"private" => private, "public" => public, "id" => id}} <-
            fixture("keys.json")["keys"] do
        assert {:ok, hex!(public)} == P256.public_key(hex!(private))
        assert P256.id(hex!(public)) == id
      end
    end

    test "every attach transcript is built from its fields and both signatures verify" do
      keys = fixture("keys.json")["keys"]

      for %{"fields" => fields} = vector <- fixture("attach.json")["vectors"] do
        transcript = Transcript.attach(attach_fields(fields))
        assert Base.encode16(transcript, case: :lower) == vector["transcript"], vector["name"]

        assert Base.encode16(:crypto.hash(:sha256, transcript), case: :lower) ==
                 vector["transcript_sha256"]

        assert P256.verify(
                 transcript,
                 hex!(vector["accessory_sig"]),
                 hex!(keys["accessory"]["public"])
               )

        assert P256.verify(transcript, hex!(vector["host_sig"]), hex!(keys["host"]["public"]))
      end
    end

    test "every signature check gives the fixture's verdict" do
      keys = fixture("keys.json")["keys"]

      for %{
            "name" => name,
            "public" => role,
            "transcript" => t,
            "sig" => sig,
            "verifies" => verdict
          } <-
            fixture("attach.json")["verify"] do
        assert P256.verify(hex!(t), hex!(sig), hex!(keys[role]["public"])) == verdict, name
      end
    end

    test "every enrollment transcript gives its compare code, and both signatures verify" do
      keys = fixture("keys.json")["keys"]

      for %{"fields" => fields} = vector <- fixture("enroll.json")["vectors"] do
        transcript =
          Transcript.enroll(%{
            host_pk: hex!(fields["host_pk"]),
            accessory_pk: hex!(fields["accessory_pk"]),
            host_nonce: hex!(fields["host_nonce"]),
            accessory_nonce: hex!(fields["accessory_nonce"])
          })

        assert Base.encode16(transcript, case: :lower) == vector["transcript"], vector["name"]
        assert :crypto.hash(:sha256, hex!(fields["host_nonce"])) == hex!(vector["host_commit"])
        assert Transcript.compare_code(transcript) == vector["compare_code"]
        assert String.length(vector["compare_code"]) == 6

        assert P256.verify(
                 transcript,
                 hex!(vector["accessory_sig"]),
                 hex!(keys["accessory"]["public"])
               )

        assert P256.verify(transcript, hex!(vector["host_sig"]), hex!(keys["host"]["public"]))
      end
    end

    test "the fixtures hold a compare code with leading zeros" do
      assert Enum.any?(
               fixture("enroll.json")["vectors"],
               &String.starts_with?(&1["compare_code"], "00")
             )
    end
  end

  defp schema, do: @dir |> Path.join("control.schema.json") |> File.read!() |> Jason.decode!()

  # Field-valid messages that keep or break each rule across fields.
  defp relation_probes do
    id = String.duplicate("ab", 32)
    nonce = String.duplicate("07", 32)
    sig = String.duplicate("01", 64)

    ack =
      &%{
        "wire" => 1,
        "kind" => "stackchan",
        "accessory_id" => &1,
        "firmware" => "0.1.0",
        "pack" => nil,
        "caps" => 127,
        "accessory_nonce" => nonce,
        "sig" => &2
      }

    hello =
      &%{
        "wire_min" => &1,
        "wire_max" => &2,
        "host_id" => id,
        "host_nonce" => nonce,
        "caps" => 127
      }

    [
      {:host, 0, "hello", hello.(1, 1), true},
      {:host, 0, "hello", hello.(2, 1), false},
      {:accessory, 0, "hello_ack", ack.(id, sig), true},
      {:accessory, 0, "hello_ack", ack.(nil, nil), true},
      {:accessory, 0, "hello_ack", ack.(id, nil), false},
      {:accessory, 0, "hello_ack", ack.(nil, sig), false},
      {:host, 0, "refuse", %{"code" => "wire_version", "wire_min" => 1, "wire_max" => 2}, true},
      {:host, 0, "refuse", %{"code" => "wire_version", "wire_min" => 1}, false},
      {:host, 0, "refuse", %{"code" => "bad_proof"}, true},
      {:host, 0, "call.result", %{"request" => 1, "result" => "refused", "code" => "busy"}, true},
      {:host, 0, "call.result", %{"request" => 1, "result" => "refused"}, false},
      {:host, 0, "call.result", %{"request" => 1, "result" => "accepted"}, true},
      {:host, 0, "accessory.set", %{}, false},
      {:host, 0, "accessory.set", %{"volume" => 10}, true},
      {:host, 0, "accessory.set", %{"motion" => true}, true},
      {:host, 0, "accessory.set", %{"brightness" => 10}, true},
      {:host, 0, "accessory.calibrate", %{"op" => "nudge", "axis" => "pan", "steps" => 3}, true},
      {:host, 0, "accessory.calibrate", %{"op" => "nudge", "axis" => "pan"}, false},
      {:host, 0, "accessory.calibrate", %{"op" => "nudge", "steps" => 3}, false},
      {:host, 0, "accessory.calibrate", %{"op" => "nudge", "axis" => "pan", "steps" => 0}, false},
      {:host, 0, "accessory.calibrate", %{"op" => "begin"}, true},
      {:host, 0, "accessory.calibrate", %{"op" => "begin", "axis" => "pan"}, false},
      {:host, 0, "accessory.calibrate", %{"op" => "cancel", "steps" => 2}, false}
    ]
  end

  defp frame_from(row) do
    %Frame{
      type: String.to_existing_atom(row["type"]),
      flags: row["flags"],
      stream: row["stream"],
      seq: row["seq"],
      payload: hex!(row["payload"])
    }
  end

  defp event_json({:fault, reason}), do: %{"fault" => Atom.to_string(reason)}

  defp event_json({:frame, %Frame{} = frame}) do
    %{
      "frame" => %{
        "type" => Atom.to_string(frame.type),
        "flags" => frame.flags,
        "stream" => frame.stream,
        "seq" => frame.seq,
        "payload" => Base.encode16(frame.payload, case: :lower)
      }
    }
  end

  defp payload(%{"payload" => hex}), do: hex!(hex)

  defp payload(%{"fill" => %{"byte" => byte, "count" => count}}),
    do: :binary.copy(<<byte>>, count)

  defp reassembly_json({:fault, reason}), do: %{"fault" => Atom.to_string(reason)}

  defp reassembly_json({:message, stream, message}),
    do: %{"message" => %{"stream" => stream, "payload" => Base.encode16(message, case: :lower)}}

  defp expand_message(%{"message" => message}) do
    %{
      "message" => %{
        "stream" => message["stream"],
        "payload" => Base.encode16(payload(message), case: :lower)
      }
    }
  end

  defp expand_message(fault), do: fault

  defp error_json(:invalid_json), do: "invalid_json"
  defp error_json({:unknown_message, _type}), do: "unknown_message"
  defp error_json({:wrong_stream, _type}), do: "wrong_stream"
  defp error_json({:invalid_message, _type, field}), do: "invalid_message:#{field}"

  defp attach_fields(fields) do
    %{
      host_id: fields["host_id"],
      accessory_id: fields["accessory_id"],
      host_nonce: hex!(fields["host_nonce"]),
      accessory_nonce: hex!(fields["accessory_nonce"]),
      wire: fields["wire"],
      host_caps: fields["host_caps"],
      accessory_caps: fields["accessory_caps"],
      gen: fields["gen"],
      kind: fields["kind"]
    }
  end
end
