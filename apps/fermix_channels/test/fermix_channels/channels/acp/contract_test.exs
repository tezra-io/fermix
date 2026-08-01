defmodule FermixChannels.Channels.Acp.ContractTest do
  @moduledoc """
  Pins the ACP codec to the vendored upstream contract under `priv/acp/`.

  The vendored `schema.json` + `meta.json` are the release artifacts of
  `schema-v1.20.0` (provenance and checksums in `PROVENANCE.md`). This test is
  the drift guard: if a method name, the schema tag, or the vendored bytes move
  without the codec moving with them, it fails and names what moved.

  Scope, deliberately: it pins **structure, not full JSON-Schema validation** —
  Fermix's ACP surface carries no new dependencies, so no JSON-Schema validator
  is available to check frames field by field. What is pinned is the method
  table, the version string, the vendored bytes, the presence of the definitions
  the surface depends on, and golden frames in both directions.
  """

  use ExUnit.Case, async: true

  alias FermixChannels.Channels.Acp.Wire

  @priv_dir Application.app_dir(:fermix_channels, "priv/acp")
  @schema_path Path.join(@priv_dir, "schema.json")
  @meta_path Path.join(@priv_dir, "meta.json")
  @provenance_path Path.join(@priv_dir, "PROVENANCE.md")
  @client_frames_path Path.expand("../../../fixtures/acp/client_frames.jsonl", __DIR__)
  @agent_frames_path Path.expand("../../../fixtures/acp/agent_frames.jsonl", __DIR__)

  setup_all do
    %{
      schema: @schema_path |> File.read!() |> Jason.decode!(),
      meta: @meta_path |> File.read!() |> Jason.decode!(),
      provenance: File.read!(@provenance_path),
      client_frames: read_frames(@client_frames_path),
      agent_frames: read_frames(@agent_frames_path)
    }
  end

  describe "vendored method table" do
    test "every method the codec dispatches on exists upstream", %{meta: meta} do
      upstream = upstream_agent_methods(meta)

      refute Enum.empty?(Wire.known_methods()),
             "the dispatch table is empty — this pin would be vacuous"

      for method <- Wire.known_methods() do
        assert MapSet.member?(upstream, method),
               "#{method} is in Wire.known_methods/0 but not in the vendored meta.json " <>
                 "(#{Wire.schema_version()}) — it is not a client -> agent method upstream defines"
      end
    end

    test "the vendored table is the agent side, not the client side", %{meta: meta} do
      # `session/update` and `session/request_permission` travel agent -> client;
      # dispatching on them would mean answering our own notifications.
      client_methods = MapSet.new(Map.values(meta["clientMethods"]))

      assert MapSet.disjoint?(Wire.known_methods(), client_methods)
    end
  end

  describe "vendored artifacts" do
    test "PROVENANCE.md records the schema version the codec advertises", %{
      provenance: provenance
    } do
      assert provenance =~ Wire.schema_version()
    end

    test "PROVENANCE.md checksums match the vendored bytes", %{provenance: provenance} do
      for path <- [@schema_path, @meta_path] do
        digest =
          path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

        assert provenance =~ digest,
               "#{Path.basename(path)} does not match the sha256 recorded in PROVENANCE.md — " <>
                 "re-vendor from the release URL and update the checksum, never hand-edit"
      end
    end

    test "the schema defines the shapes this surface depends on", %{schema: schema} do
      defs = Map.fetch!(schema, "$defs")

      for name <- ["SessionUpdate", "StopReason", "SessionNotification", "PromptRequest"] do
        assert Map.has_key?(defs, name), "vendored schema.json has no $defs/#{name}"
      end
    end

    test "the schema's protocol version matches the codec", %{schema: schema} do
      versions = get_in(schema, ["$defs", "ProtocolVersion"])

      assert versions["type"] == "integer"
      assert Wire.protocol_version() == 1
    end
  end

  describe "golden client -> agent frames" do
    test "initialize decodes as a request carrying the client's version", %{client_frames: frames} do
      assert {:ok, message} = Wire.decode_line(Enum.at(frames, 0))
      assert message.type == :request
      assert message.id == 1
      assert message.method == "initialize"
      assert message.params["protocolVersion"] == 1
      assert Wire.negotiate(message.params["protocolVersion"]) == Wire.protocol_version()
    end

    test "session/new decodes with its cwd and empty mcpServers", %{client_frames: frames} do
      assert {:ok, message} = Wire.decode_line(Enum.at(frames, 1))
      assert message.type == :request
      assert message.method == "session/new"
      assert message.params["cwd"] == "/Users/operator/.buzz"
      assert message.params["mcpServers"] == []
      assert message.params["_meta"]["sessionTitle"] == "Fermix · #engineering"
    end

    test "session/prompt decodes text and resource_link blocks in order", %{client_frames: frames} do
      assert {:ok, message} = Wire.decode_line(Enum.at(frames, 2))
      assert message.type == :request
      assert message.method == "session/prompt"
      assert [text_block, link_block] = message.params["prompt"]
      assert text_block["type"] == "text"
      assert text_block["text"] =~ "summarise the deploy log"
      assert link_block["type"] == "resource_link"
      assert link_block["uri"] == "file:///Users/operator/.buzz/deploy.log"
      assert link_block["name"] == "deploy.log"
    end

    test "session/cancel decodes as a notification", %{client_frames: frames} do
      assert {:ok, message} = Wire.decode_line(Enum.at(frames, 3))
      assert message.type == :notification
      assert message.id == nil
      assert message.method == "session/cancel"
      assert message.params["sessionId"] == "018f3b7e-3f1a-7c2d-9c1e-2f0b6a5d4e3c"
    end

    test "$/cancel_request decodes as a notification naming the request id", %{
      client_frames: frames
    } do
      assert {:ok, message} = Wire.decode_line(Enum.at(frames, 4))
      assert message.type == :notification
      assert message.method == "$/cancel_request"
      assert message.params["requestId"] == 3
      assert MapSet.member?(Wire.known_methods(), message.method)
    end

    test "every golden client frame is a known method", %{client_frames: frames} do
      for frame <- frames do
        assert {:ok, %{method: method}} = Wire.decode_line(frame)
        assert MapSet.member?(Wire.known_methods(), method)
      end
    end
  end

  describe "golden agent -> client frames" do
    test "the mcpServers refusal encodes byte-for-byte content", %{agent_frames: frames} do
      encoded =
        Wire.encode_error(
          2,
          Wire.invalid_params(
            "session-scoped MCP servers are not supported yet; configure MCP in Fermix's own config"
          )
        )

      assert one_line?(encoded)
      assert Jason.decode!(encoded) == Jason.decode!(Enum.at(frames, 0))
    end

    test "an agent_message_chunk update encodes as a single notification line", %{
      agent_frames: frames
    } do
      encoded =
        Wire.encode_notification("session/update", %{
          "sessionId" => "018f3b7e-3f1a-7c2d-9c1e-2f0b6a5d4e3c",
          "update" => %{
            "sessionUpdate" => "agent_message_chunk",
            "content" => %{"type" => "text", "text" => "The deploy failed at step 3.\n"}
          }
        })

      # The chunk text ends in a newline: the frame must still be one line.
      assert one_line?(encoded)
      assert Jason.decode!(encoded) == Jason.decode!(Enum.at(frames, 1))
      assert {:ok, %{type: :notification, method: "session/update"}} = Wire.decode_line(encoded)
    end

    test "a completed turn encodes the stopReason the schema enumerates", %{schema: schema} do
      stop_reasons = for variant <- schema["$defs"]["StopReason"]["oneOf"], do: variant["const"]

      assert "end_turn" in stop_reasons
      assert "cancelled" in stop_reasons

      assert {:ok, %{result: %{"stopReason" => "end_turn"}}} =
               Wire.decode_line(Wire.encode_response(3, %{"stopReason" => "end_turn"}))
    end
  end

  defp upstream_agent_methods(meta) do
    meta
    |> Map.take(["agentMethods", "protocolMethods"])
    |> Map.values()
    |> Enum.flat_map(&Map.values/1)
    |> MapSet.new()
  end

  defp read_frames(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  defp one_line?(encoded) do
    String.ends_with?(encoded, "\n") and length(String.split(encoded, "\n")) == 2
  end
end
