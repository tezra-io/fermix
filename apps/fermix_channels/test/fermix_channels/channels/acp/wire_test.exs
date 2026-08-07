defmodule FermixChannels.Channels.Acp.WireTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Channels.Acp.Wire
  alias FermixChannels.Channels.Acp.Wire.Error

  # Every client -> agent method the ACP surface dispatches on. Pinned here as a
  # whole set (not per-method asserts) so a method added to the codec without a
  # dispatch decision fails this test. The upstream half of the pin lives in
  # contract_test.exs.
  @known_methods ~w(
    initialize
    authenticate
    session/new
    session/load
    session/list
    session/resume
    session/close
    session/delete
    session/set_mode
    session/set_config_option
    logout
    session/prompt
    session/cancel
    $/cancel_request
  )

  describe "constants" do
    test "advertise wire version 1, the vendored schema tag, and the 10 MiB line cap" do
      assert Wire.protocol_version() == 1
      assert Wire.schema_version() == "schema-v1.20.0"
      assert Wire.max_line_bytes() == 10_485_760
    end

    test "known_methods is exactly the dispatch table" do
      assert Wire.known_methods() == MapSet.new(@known_methods)
    end
  end

  describe "negotiate/1" do
    test "replies with the latest version we support, whatever the client sent" do
      # Spec: an agent that does not support the client's version replies with the
      # latest it does; the CLIENT decides whether to disconnect. Version 0 gets 1
      # back, not an error, and Buzz's `2` squat gets 1 back and proceeds.
      for client_version <- [0, 1, 2, 3, 99, -7] do
        assert Wire.negotiate(client_version) == 1
      end
    end

    test "refuses a non-integer version" do
      assert_raise FunctionClauseError, fn -> Wire.negotiate("1") end
    end
  end

  describe "decode_line/1 classification" do
    test "id + method is a request" do
      line = ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}})

      assert {:ok, message} = Wire.decode_line(line)

      assert message == %{
               type: :request,
               id: 1,
               method: "initialize",
               params: %{"protocolVersion" => 1},
               result: nil,
               error: nil
             }
    end

    test "method without id is a notification" do
      line = ~s({"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"s-1"}})

      assert {:ok, message} = Wire.decode_line(line)
      assert message.type == :notification
      assert message.id == nil
      assert message.method == "session/cancel"
      assert message.params == %{"sessionId" => "s-1"}
    end

    test "an explicit null id is a notification, not a request" do
      line = ~s({"jsonrpc":"2.0","id":null,"method":"session/cancel","params":{}})

      assert {:ok, %{type: :notification, id: nil}} = Wire.decode_line(line)
    end

    test "a method with both id and params present is a request even when a result rides along" do
      line = ~s({"jsonrpc":"2.0","id":9,"method":"session/prompt","result":{"ignored":true}})

      assert {:ok, %{type: :request, id: 9, method: "session/prompt"}} = Wire.decode_line(line)
    end

    test "no method with a result is a response" do
      line = ~s({"jsonrpc":"2.0","id":4,"result":{"outcome":"selected"}})

      assert {:ok, message} = Wire.decode_line(line)

      assert message == %{
               type: :response,
               id: 4,
               method: nil,
               params: %{},
               result: %{"outcome" => "selected"},
               error: nil
             }
    end

    test "no method with an error is a response carrying the error" do
      line = ~s({"jsonrpc":"2.0","id":4,"error":{"code":-32601,"message":"Method not found"}})

      assert {:ok, message} = Wire.decode_line(line)
      assert message.type == :response
      assert message.result == nil
      assert message.error == %{"code" => -32_601, "message" => "Method not found"}
    end

    test "params default to an empty map when absent" do
      assert {:ok, %{params: %{}}} =
               Wire.decode_line(~s({"jsonrpc":"2.0","id":1,"method":"logout"}))
    end
  end

  describe "decode_line/1 ids" do
    test "string and numeric ids survive verbatim" do
      for id <- [1, 0, -3, 4_294_967_296, 1.5, "req-7", "0"] do
        line = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => "logout"})

        assert {:ok, %{id: ^id}} = Wire.decode_line(line)
      end
    end

    test "an id that is neither string nor number is an invalid request" do
      for id <- [true, %{"a" => 1}, [1, 2]] do
        line = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => "logout"})

        assert {:error, %Error{code: -32_600}} = Wire.decode_line(line)
      end
    end
  end

  describe "decode_line/1 rejections" do
    test "junk is a parse error" do
      for junk <- ["", "   ", "not json", "{", ~s({"jsonrpc":"2.0",}), "\n"] do
        assert {:error, %Error{code: -32_700, message: "Parse error"}} = Wire.decode_line(junk)
      end
    end

    test "a non-object frame is an invalid request" do
      for line <- ["[]", "12", ~s("hello"), "null", "true"] do
        assert {:error, %Error{code: -32_600}} = Wire.decode_line(line)
      end
    end

    test "a wrong or missing jsonrpc version is an invalid request" do
      for line <- [
            ~s({"id":1,"method":"logout"}),
            ~s({"jsonrpc":"1.0","id":1,"method":"logout"}),
            ~s({"jsonrpc":2.0,"id":1,"method":"logout"})
          ] do
        assert {:error, %Error{code: -32_600}} = Wire.decode_line(line)
      end
    end

    test "a non-response with no method is an invalid request" do
      assert {:error, %Error{code: -32_600}} = Wire.decode_line(~s({"jsonrpc":"2.0","id":1}))
      assert {:error, %Error{code: -32_600}} = Wire.decode_line(~s({"jsonrpc":"2.0"}))
    end

    test "an empty or non-string method is an invalid request" do
      assert {:error, %Error{code: -32_600}} =
               Wire.decode_line(~s({"jsonrpc":"2.0","id":1,"method":""}))

      assert {:error, %Error{code: -32_600}} =
               Wire.decode_line(~s({"jsonrpc":"2.0","id":1,"method":7}))
    end

    test "params that are not an object are invalid params" do
      # ACP never uses positional params; coercing them to %{} would hand the
      # dispatcher a silently empty request, so the codec refuses instead.
      line = ~s({"jsonrpc":"2.0","id":1,"method":"session/prompt","params":["a"]})

      assert {:error, %Error{code: -32_602}} = Wire.decode_line(line)
    end

    test "refuses a non-binary line" do
      assert_raise FunctionClauseError, fn -> Wire.decode_line(%{}) end
    end
  end

  describe "decode_line/1 framing and encoding" do
    test "a trailing newline is tolerated" do
      assert {:ok, %{method: "logout"}} =
               Wire.decode_line(~s({"jsonrpc":"2.0","id":1,"method":"logout"}\n))
    end

    test "UTF-8 text survives a decode" do
      text = "héllo — 日本語 🌱"

      line =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "session/update",
          "params" => %{"text" => text}
        })

      assert {:ok, %{params: %{"text" => ^text}}} = Wire.decode_line(line)
    end
  end

  describe "encode_response/2" do
    test "emits one complete line, newline-terminated, that decodes back" do
      line = Wire.encode_response(3, %{"stopReason" => "end_turn"})

      assert String.ends_with?(line, "\n")
      assert one_line?(line)

      assert {:ok, message} = Wire.decode_line(line)
      assert message.type == :response
      assert message.id == 3
      assert message.result == %{"stopReason" => "end_turn"}
    end

    test "preserves a string id exactly" do
      assert {:ok, %{id: "req-7"}} = Wire.decode_line(Wire.encode_response("req-7", %{}))
    end

    test "refuses an id the wire cannot carry" do
      assert_raise FunctionClauseError, fn -> Wire.encode_response(nil, %{}) end
      assert_raise FunctionClauseError, fn -> Wire.encode_response(1, "result") end
    end
  end

  describe "encode_error/2" do
    test "emits a JSON-RPC error response that decodes back" do
      line = Wire.encode_error(5, Wire.method_not_found())

      assert one_line?(line)
      assert {:ok, message} = Wire.decode_line(line)
      assert message.type == :response
      assert message.id == 5
      assert message.error == %{"code" => -32_601, "message" => "Method not found"}
    end

    test "carries data only when the error has some" do
      with_data =
        Wire.encode_error(5, Wire.invalid_params("cwd must be absolute", %{"cwd" => "rel/path"}))

      assert {:ok, %{error: error}} = Wire.decode_line(with_data)
      assert error["data"] == %{"cwd" => "rel/path"}

      assert {:ok, %{error: bare}} = Wire.decode_line(Wire.encode_error(5, Wire.invalid_params()))
      refute Map.has_key?(bare, "data")
    end

    test "a nil id encodes as JSON null (the unparseable-frame case)" do
      line = Wire.encode_error(nil, Wire.parse_error())

      assert Jason.decode!(line)["id"] == nil
      assert {:ok, %{type: :response, id: nil}} = Wire.decode_line(line)
    end

    test "refuses anything but an error struct" do
      # A look-alike plain map must not encode: the struct is what keeps a code
      # and its message from being assembled by hand at a call site.
      look_alike = Map.from_struct(Wire.internal_error())

      assert_raise FunctionClauseError, fn -> Wire.encode_error(1, look_alike) end
    end
  end

  describe "encode_notification/2" do
    test "emits a method + params line with no id" do
      line =
        Wire.encode_notification("session/update", %{
          "sessionId" => "s-1",
          "update" => %{"sessionUpdate" => "agent_message_chunk"}
        })

      assert one_line?(line)
      assert {:ok, message} = Wire.decode_line(line)
      assert message.type == :notification
      assert message.method == "session/update"
      assert message.params["sessionId"] == "s-1"
      refute Map.has_key?(Jason.decode!(line), "id")
    end

    test "refuses a non-binary method or non-map params" do
      assert_raise FunctionClauseError, fn -> Wire.encode_notification(:session_update, %{}) end
      assert_raise FunctionClauseError, fn -> Wire.encode_notification("session/update", []) end
    end
  end

  describe "framing safety" do
    test "raw newlines in content are escaped, never break the frame" do
      text = "line one\nline two\r\nline three"
      line = Wire.encode_notification("session/update", %{"text" => text})

      assert one_line?(line)
      assert {:ok, %{params: %{"text" => ^text}}} = Wire.decode_line(line)
    end

    test "every encoder keeps UTF-8 text intact through a round-trip" do
      text = "héllo — 日本語 🌱"

      assert {:ok, %{result: %{"text" => ^text}}} =
               Wire.decode_line(Wire.encode_response(1, %{"text" => text}))

      assert {:ok, %{params: %{"text" => ^text}}} =
               Wire.decode_line(Wire.encode_notification("m", %{"text" => text}))

      assert {:ok, %{error: %{"message" => ^text}}} =
               Wire.decode_line(Wire.encode_error(1, Wire.internal_error(text)))
    end
  end

  describe "error constructors" do
    # Enumerated as a table: a constructor added without a code decision fails here.
    @constructors [
      {:parse_error, -32_700, "Parse error"},
      {:invalid_request, -32_600, "Invalid Request"},
      {:method_not_found, -32_601, "Method not found"},
      {:invalid_params, -32_602, "Invalid params"},
      {:internal_error, -32_603, "Internal error"},
      {:auth_required, -32_000, "Authentication required"},
      {:request_cancelled, -32_800, "Request cancelled"}
    ]

    test "carry their JSON-RPC code and a default message" do
      for {name, code, message} <- @constructors do
        assert %Error{code: ^code, message: ^message, data: nil} = apply(Wire, name, [])
      end
    end

    test "accept a message override and optional data" do
      for {name, code, _default} <- @constructors do
        assert %Error{code: ^code, message: "custom", data: nil} = apply(Wire, name, ["custom"])

        assert %Error{code: ^code, message: "custom", data: %{"k" => 1}} =
                 apply(Wire, name, ["custom", %{"k" => 1}])
      end
    end
  end

  defp one_line?(encoded) do
    String.ends_with?(encoded, "\n") and length(String.split(encoded, "\n")) == 2
  end
end
