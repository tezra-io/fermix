defmodule FermixCore.PhoneCalls.OpenAILiveTest do
  @moduledoc """
  The create and hangup requests of `PhoneCalls.OpenAILive` against local
  stand-ins only: a Bandit server answering as the vendor documents, a
  loopback listener that reads a request and drops it unanswered, and a port
  nothing listens on. Every key, password and number is invented.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Net.Egress
  alias FermixCore.PhoneCalls.OpenAILive

  @arrival_ms 10_000
  @api_key "sk-invented-key-0001"
  @password "pw-Invented-7731"
  @direct Egress.new([])
  @max_accepts 8
  @max_reads 64

  # Answers every request with the status and body the test chose, after
  # telling the test what arrived.
  defmodule FakeVendor do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, %{test: test, status: status, body: body}) do
      {:ok, raw, conn} = read_body(conn)

      send(test, {:vendor_saw, conn.method, conn.request_path, conn.req_headers, raw})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, body)
    end
  end

  defp vendor!(status, body) do
    server =
      start_supervised!(
        {Bandit,
         plug: {FakeVendor, %{test: self(), status: status, body: body}},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end

  defp request(overrides \\ %{}) do
    Map.merge(
      %{
        api_key: @api_key,
        model: "gpt-live-1",
        instructions: "Ask whether a table for two is free at seven tonight.",
        input: [],
        voice: "marin",
        destination: "+15555550123",
        trunk: %{
          provider_url: "sips:sip.invented-carrier.test:5061",
          username: "invented-user",
          password: @password,
          caller_number: "+15555550100"
        }
      },
      overrides
    )
  end

  defp create(base_url, overrides \\ %{}, opts \\ []) do
    OpenAILive.create_session(
      request(overrides),
      Keyword.merge([base_url: base_url, ws_base_url: "ws://127.0.0.1:1", egress: @direct], opts)
    )
  end

  describe "create_session/2 on success" do
    test "the create reference's 201 returns the session id unchanged" do
      base = vendor!(201, ~s({"session":{"id":"live_u0_Inv/01"},"transport":{"type":"sip"}}))

      assert {:ok, %{session_id: "live_u0_Inv/01", http_status: 201, transport_type: "sip"}} =
               create(base)

      assert_receive {:vendor_saw, "POST", "/v1/live/sessions", headers, raw}, @arrival_ms
      assert {"authorization", "Bearer " <> @api_key} in headers
      assert {"content-type", "application/json"} in headers

      assert Jason.decode!(raw) == %{
               "session" => %{
                 "model" => "gpt-live-1",
                 "instructions" => "Ask whether a table for two is free at seven tonight.",
                 "audio" => %{"output" => %{"voice" => "marin"}},
                 "delegation" => %{"type" => "client"},
                 "store" => false
               },
               "transport" => %{
                 "type" => "sip",
                 "destination" => "+15555550123",
                 "trunk" => %{
                   "provider_url" => "sips:sip.invented-carrier.test:5061",
                   "auth" => %{
                     "type" => "digest",
                     "username" => "invented-user",
                     "password" => @password
                   },
                   "caller_number" => "+15555550100"
                 }
               }
             }
    end

    test "the SIP guide's 200 is the same success" do
      base = vendor!(200, ~s({"session":{"id":"live_123"},"transport":{"type":"sip"}}))

      assert {:ok, %{session_id: "live_123", http_status: 200}} = create(base)
    end

    test "scoped input rides as session.input; no audio.format is ever sent" do
      base = vendor!(201, ~s({"session":{"id":"live_123"},"transport":{"type":"sip"}}))

      input = [
        %{
          "type" => "message",
          "role" => "developer",
          "content" => [%{"type" => "input_text", "text" => "Party of two, 19:00."}]
        }
      ]

      assert {:ok, _created} = create(base, %{input: input})
      assert_receive {:vendor_saw, "POST", _path, _headers, raw}, @arrival_ms

      session = Jason.decode!(raw)["session"]
      assert session["input"] == input
      refute Map.has_key?(session["audio"], "format")
    end
  end

  describe "create_session/2 when a success is not one" do
    test "a 2xx without a session id is unknown: the call may exist" do
      for body <- [~s({"session":{},"transport":{"type":"sip"}}), "", "not json"] do
        base = vendor!(201, body)

        assert {:error, {:unknown, {:success_without_session_id, 201}}} = create(base)
      end
    end

    test "an undocumented 2xx is unknown" do
      base = vendor!(202, ~s({"session":{"id":"live_123"}}))

      assert {:error, {:unknown, {:unexpected_status, 202}}} = create(base)
    end
  end

  describe "create_session/2 refused by the vendor" do
    test "429 keeps the vendor's own words" do
      body =
        ~s({"error":{"message":"Rate limit reached for invented-org.","type":"requests",) <>
          ~s("code":"rate_limit_exceeded"}})

      base = vendor!(429, body)

      assert {:error,
              {:rejected, 429,
               %{
                 message: "Rate limit reached for invented-org.",
                 code: "rate_limit_exceeded",
                 type: "requests"
               }}} = create(base)
    end

    test "500 and the documented 502 transport-setup failure are refusals" do
      for status <- [500, 502] do
        base = vendor!(status, ~s({"error":{"message":"trunk setup failed","code":"sip_error"}}))

        assert {:error, {:rejected, ^status, %{message: "trunk setup failed", code: "sip_error"}}} =
                 create(base)
      end
    end

    test "the documented 504 initialization timeout is unknown, with the vendor's words" do
      base = vendor!(504, ~s({"error":{"message":"initialization timed out"}}))

      assert {:error, {:unknown, {:http_status, 504, %{message: "initialization timed out"}}}} =
               create(base)
    end

    test "a body that is not the vendor's envelope is kept as its words, bounded" do
      base = vendor!(503, String.duplicate("x", 5_000))

      assert {:error, {:rejected, 503, %{message: message, code: nil}}} = create(base)
      assert String.length(message) == 1_000
    end

    test "vendor words never carry the trunk password or the API key back" do
      echo = ~s({"error":{"message":"bad auth #{@password} for #{@api_key}"}})
      base = vendor!(400, echo)

      assert {:error, {:rejected, 400, %{message: message}}} = create(base)
      refute message =~ @password
      refute message =~ @api_key
      assert message =~ "[REDACTED]"
    end
  end

  describe "create_session/2 when the request may or may not have left" do
    setup do
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      on_exit(fn -> :gen_tcp.close(listener) end)
      {:ok, {_address, port}} = :inet.sockname(listener)
      posts = start_supervised!({Agent, fn -> 0 end})
      start_supervised!({Task, fn -> drop_after_reading(listener, posts, 0) end})

      %{base: "http://127.0.0.1:#{port}", posts: posts}
    end

    test "a dropped response is unknown, and the dial was sent exactly once", ctx do
      result = create(ctx.base)

      assert Agent.get(ctx.posts, & &1) == 1
      assert {:error, {:unknown, {:transport, :closed}}} = result
    end
  end

  describe "create_session/2 when nothing was sent" do
    # Port 1 on loopback: nothing listens there and no test can bind it.
    @nowhere "http://127.0.0.1:1"

    test "a refused connection provably never sent the dial" do
      assert {:error, {:not_sent, {:transport, :econnrefused}}} = create(@nowhere)
    end

    # Each would otherwise reach port 1 and come back refused, so `:invalid`
    # proves the check ran before any I/O. The value itself is never echoed.
    test "an argument off the documented shape is refused before any I/O, by name only" do
      cases = [
        {%{destination: "5555550123"}, :destination},
        {%{destination: "sip:front-desk@invented.test"}, :destination},
        {%{api_key: ""}, :api_key},
        {%{model: nil}, :model},
        {%{instructions: "  "}, :instructions},
        {%{voice: ""}, :voice},
        {%{input: List.duplicate(%{}, 129)}, :input},
        {%{trunk: :none}, :trunk},
        {%{trunk: %{request().trunk | provider_url: "sip:sip.invented.test"}}, :provider_url},
        {%{trunk: %{request().trunk | provider_url: "sips:u:p@sip.invented.test"}},
         :provider_url},
        {%{trunk: %{request().trunk | provider_url: "sips:sip.invented.test;lr"}}, :provider_url},
        {%{trunk: %{request().trunk | username: ""}}, :username},
        {%{trunk: %{request().trunk | password: "pw\r\nInjected: 1"}}, :password},
        {%{trunk: %{request().trunk | password: String.duplicate("p", 4_097)}}, :password},
        {%{trunk: %{request().trunk | caller_number: "+0555"}}, :caller_number}
      ]

      for {overrides, field} <- cases do
        assert {:error, {:not_sent, {:invalid, ^field}}} = create(@nowhere, overrides),
               "#{inspect(field)} was not refused before sending"
      end
    end

    test "the documented provider_url forms are accepted" do
      for url <- ["sips:sip.invented.test", "sips:sip.invented.test:5061;transport=tcp"] do
        overrides = %{trunk: %{request().trunk | provider_url: url}}

        assert {:error, {:not_sent, {:transport, :econnrefused}}} = create(@nowhere, overrides)
      end
    end

    # The sideband cannot tunnel, so a call created behind a proxy could not be
    # controlled: the dial is refused before it is sent.
    test "a sideband route through the proxy refuses the dial" do
      proxied = Egress.new(proxy: "http://proxy.invented.test:3128")

      assert {:error, {:not_sent, :proxy_unsupported_transport}} =
               create(@nowhere, %{}, ws_base_url: "wss://api.openai.com", egress: proxied)
    end
  end

  describe "classify_create/2 for transport failures" do
    test "a timeout is unknown, a pool with no connection is not sent" do
      assert {:error, {:unknown, {:transport, :timeout}}} =
               OpenAILive.classify_create(
                 {:error, {:unknown, %Req.TransportError{reason: :timeout}}},
                 []
               )

      pool =
        RuntimeError.exception(
          "Finch was unable to provide a connection within the timeout due to " <>
            "excess queuing for connections."
        )

      assert {:error, {:not_sent, :connection_unavailable}} =
               OpenAILive.classify_create({:error, {:not_sent, pool}}, [])
    end
  end

  describe "hangup/2" do
    test "200 with an empty body is accepted; one POST, no body, the session's path" do
      base = vendor!(200, "")

      assert {:ok, :accepted} =
               OpenAILive.hangup("live_u0_Inv/01",
                 api_key: @api_key,
                 base_url: base,
                 egress: @direct
               )

      assert_receive {:vendor_saw, "POST", path, headers, ""}, @arrival_ms
      assert path == "/v1/live/sessions/live_u0_Inv%2F01/hangup"
      assert {"authorization", "Bearer " <> @api_key} in headers
    end

    test "404, 409 and 410 read as already ended, with the vendor's words" do
      for status <- [404, 409, 410] do
        base = vendor!(status, ~s({"error":{"message":"session not found","code":"not_found"}}))

        assert {:ok, {:already_ended, ^status, %{message: "session not found"}}} =
                 OpenAILive.hangup("live_123", api_key: @api_key, base_url: base, egress: @direct)
      end
    end

    test "any other refusal keeps its words; a 504 is unknown" do
      base = vendor!(401, ~s({"error":{"message":"Incorrect API key provided."}}))

      assert {:error, {:rejected, 401, %{message: "Incorrect API key provided."}}} =
               OpenAILive.hangup("live_123", api_key: @api_key, base_url: base, egress: @direct)

      base = vendor!(504, ~s({"error":{"message":"upstream timed out"}}))

      assert {:error, {:unknown, {:http_status, 504, %{message: "upstream timed out"}}}} =
               OpenAILive.hangup("live_123", api_key: @api_key, base_url: base, egress: @direct)
    end

    test "a refused connection was never sent; an empty id is refused before any I/O" do
      assert {:error, {:not_sent, {:transport, :econnrefused}}} =
               OpenAILive.hangup("live_123",
                 api_key: @api_key,
                 base_url: "http://127.0.0.1:1",
                 egress: @direct
               )

      assert {:error, {:not_sent, {:invalid, :session_id}}} =
               OpenAILive.hangup("", api_key: @api_key, base_url: "http://127.0.0.1:1")
    end
  end

  describe "redact/1" do
    test "a redacted create body holds neither secret anywhere, and keeps the rest" do
      redacted = request() |> OpenAILive.create_body() |> OpenAILive.redact()
      encoded = Jason.encode!(redacted)

      refute encoded =~ @password
      assert redacted["transport"]["trunk"]["auth"]["password"] == "[REDACTED]"
      assert redacted["transport"]["trunk"]["auth"]["username"] == "invented-user"
      assert redacted["transport"]["destination"] == "+15555550123"
      assert redacted["session"]["model"] == "gpt-live-1"
    end

    test "atom-keyed requests and nested auth are redacted the same way" do
      redacted = OpenAILive.redact(%{transport: %{trunk: %{auth: %{password: @password}}}})

      refute inspect(redacted) =~ @password
    end

    test "headers lose the bearer token in every shape Req keeps them" do
      pairs = [{"Authorization", "Bearer " <> @api_key}, {"content-type", "application/json"}]
      map = %{"authorization" => ["Bearer " <> @api_key]}

      for headers <- [pairs, map] do
        redacted = OpenAILive.redact(headers)
        refute inspect(redacted) =~ @api_key
      end

      assert {"content-type", "application/json"} in OpenAILive.redact(pairs)
    end
  end

  defp drop_after_reading(_listener, _posts, accepted) when accepted >= @max_accepts, do: :ok

  defp drop_after_reading(listener, posts, accepted) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, _request} = read_request(socket, "", 0)
        Agent.update(posts, &(&1 + 1))
        :ok = :gen_tcp.close(socket)
        drop_after_reading(listener, posts, accepted + 1)

      {:error, :closed} ->
        :ok
    end
  end

  defp read_request(_socket, _buffer, reads) when reads >= @max_reads,
    do: {:error, :request_too_fragmented}

  defp read_request(socket, buffer, reads) do
    {:ok, data} = :gen_tcp.recv(socket, 0, @arrival_ms)
    buffer = buffer <> data

    if complete?(buffer), do: {:ok, buffer}, else: read_request(socket, buffer, reads + 1)
  end

  defp complete?(buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, body] -> byte_size(body) >= content_length(head)
      [_head] -> false
    end
  end

  defp content_length(head) do
    case Regex.run(~r/\r\ncontent-length:\s*(\d+)/i, head) do
      [_line, length] -> String.to_integer(length)
      nil -> 0
    end
  end
end
