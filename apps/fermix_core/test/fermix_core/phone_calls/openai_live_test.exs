defmodule FermixCore.PhoneCalls.OpenAILiveTest do
  @moduledoc """
  The create and hangup requests of `PhoneCalls.OpenAILive` against local
  stand-ins only: a Bandit server answering as the vendor documents, a
  loopback listener that reads a request and drops it unanswered, and a port
  nothing listens on. Every key, password and number is invented.

  The create request, its body and the documented answers come from the wire
  fixture the eval runners' simulated endpoint is held to as well
  (`test/fixtures/phone_calls/gpt_live_wire.json`), so the two cannot drift;
  the cases that file does not hold are typed here.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Net.Egress
  alias FermixCore.PhoneCalls.OpenAILive

  @fixture Path.expand("../../fixtures/phone_calls/gpt_live_wire.json", __DIR__)
  @external_resource @fixture
  @wire @fixture |> File.read!() |> Jason.decode!()

  @arrival_ms 10_000
  @api_key "sk-invented-key-0001"
  @password "pw-Invented-7731"
  @direct Egress.new([])
  @max_accepts 8
  @max_reads 64

  # Answers every request with the status, body and content type the test
  # chose, after telling the test what arrived.
  defmodule FakeVendor do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, %{test: test, status: status, body: body, content_type: content_type}) do
      {:ok, raw, conn} = read_body(conn)

      send(test, {:vendor_saw, conn.method, conn.request_path, conn.req_headers, raw})

      conn
      |> put_resp_content_type(content_type)
      |> send_resp(status, body)
    end
  end

  defp vendor!(status, body, content_type \\ "application/json") do
    state = %{test: self(), status: status, body: body, content_type: content_type}

    server =
      start_supervised!(
        {Bandit, plug: {FakeVendor, state}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
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
    test "the fixture's request is sent as the fixture's body, and its 201 returns the id unchanged" do
      %{"status" => 201, "body" => answer} = @wire["create"]["answers"]["accepted"]
      base = vendor!(201, Jason.encode!(answer))
      wire_request = fixture_request(@wire["create"]["request"])

      assert {:ok, %{session_id: id, http_status: 201, transport_type: "sip"}} =
               OpenAILive.create_session(wire_request, origins(base))

      assert id == answer["session"]["id"]

      assert_receive {:vendor_saw, "POST", "/v1/live/sessions", headers, raw}, @arrival_ms
      assert {"authorization", "Bearer " <> wire_request.api_key} in headers
      assert {"content-type", "application/json"} in headers
      assert Jason.decode!(raw) == @wire["create"]["body"]
    end

    test "an id with a path character is returned exactly as sent" do
      base = vendor!(201, ~s({"session":{"id":"live_u0_Inv/01"},"transport":{"type":"sip"}}))

      assert {:ok, %{session_id: "live_u0_Inv/01", http_status: 201}} = create(base)
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

    test "the fixture's refused and malformed answers are refusals in the vendor's words" do
      for name <- ["refused", "malformed"] do
        %{"status" => status, "body" => %{"error" => error}} = @wire["create"]["answers"][name]
        base = vendor!(status, Jason.encode!(%{"error" => error}))

        assert {:error, {:rejected, ^status, vendor}} = create(base), name
        assert vendor == %{message: error["message"], code: error["code"], type: error["type"]}
      end
    end

    # A 4xx is the answer deciding: whoever sent it, the call was not placed.
    test "a 4xx is a refusal whatever its body, an edge's own page included" do
      base = vendor!(403, "<html><body>Access denied</body></html>", "text/html")

      assert {:error, {:rejected, 403, %{message: "<html><body>Access denied</body></html>"}}} =
               create(base)

      base = vendor!(400, "")
      assert {:error, {:rejected, 400, %{message: nil, code: nil, type: nil}}} = create(base)
    end

    # The origin saying, in its own error envelope, that the request failed; the
    # SIP guide's transport-setup failure (502) among them.
    test "a 5xx carrying the vendor's error envelope is a refusal" do
      for status <- [500, 502, 503] do
        base = vendor!(status, ~s({"error":{"message":"trunk setup failed","code":"sip_error"}}))

        assert {:error, {:rejected, ^status, %{message: "trunk setup failed", code: "sip_error"}}} =
                 create(base)
      end
    end

    # A gateway standing in for a lost origin answer is the lost answer: the
    # call may be ringing with no session id to hang up.
    test "a 5xx without the vendor's error envelope is unknown, never a refusal" do
      bodies = [
        {500, "", "application/json"},
        {500, "{not json", "application/json"},
        {500, ~s({"error":"Internal Server Error"}), "application/json"},
        {502, ~s({"message":"no error object"}), "application/json"},
        {502, "<html><body>502 Bad Gateway</body></html>", "text/html"},
        {503, "Service Unavailable", "text/plain"}
      ]

      for {status, body, content_type} <- bodies do
        base = vendor!(status, body, content_type)

        assert {:error, {:unknown, {:http_status, ^status, %{code: nil, type: nil}}}} =
                 create(base),
               "#{status} #{inspect(body)} was read as a refusal"
      end
    end

    # An edge's own codes, which Plug cannot send: read through the classifier
    # the request's answer goes to.
    test "an edge's 520 or 524 page is unknown" do
      for {status, body} <- [
            {520, "<html><title>Web server is returning an unknown error</title></html>"},
            {524, "<html><title>A timeout occurred</title></html>"}
          ] do
        answer = {:ok, Req.Response.new(status: status, body: body)}

        assert {:error, {:unknown, {:http_status, ^status, %{message: ^body}}}} =
                 OpenAILive.classify_create(answer, [@api_key, @password])

        assert {:error, {:unknown, {:http_status, ^status, %{message: ^body}}}} =
                 OpenAILive.classify_hangup(answer, [@api_key])
      end
    end

    test "a gateway's page is kept as its words, bounded" do
      base = vendor!(503, String.duplicate("x", 5_000), "text/plain")

      assert {:error, {:unknown, {:http_status, 503, %{message: message}}}} = create(base)
      assert String.length(message) == 1_000
    end

    test "the fixture's 504 initialization timeout is unknown, with the vendor's words" do
      %{"status" => 504, "body" => body} = @wire["create"]["answers"]["initialization_timeout"]
      base = vendor!(504, Jason.encode!(body))

      assert {:error, {:unknown, {:http_status, 504, %{message: message}}}} = create(base)
      assert message == body["error"]["message"]
    end

    test "a 504 is unknown even with the vendor's envelope" do
      base = vendor!(504, ~s({"error":{"message":"initialization timed out"}}))

      assert {:error, {:unknown, {:http_status, 504, %{message: "initialization timed out"}}}} =
               create(base)
    end

    test "vendor words never carry the trunk password or the API key back" do
      echo = ~s({"error":{"message":"bad auth #{@password} for #{@api_key}"}})
      base = vendor!(400, echo)

      assert {:error, {:rejected, 400, %{message: message}}} = create(base)
      refute message =~ @password
      refute message =~ @api_key
      assert message =~ "[REDACTED]"
    end

    # OpenAI's refused-key message quotes the key back, masked but with its
    # last characters, which an exact-match scrub cannot see. The engine's own
    # sentence stands in for it, as `Realtime.SessionServer` does.
    test "a refused key's message is withheld, with the vendor's code kept" do
      masked =
        ~s({"error":{"message":"Incorrect API key provided: sk-inve************0001. ) <>
          ~s(You can find your API key at https://platform.openai.com/account/api-keys.",) <>
          ~s("type":"invalid_request_error","param":null,"code":"invalid_api_key"}})

      for status <- [401, 403] do
        base = vendor!(status, masked)

        assert {:error, {:rejected, ^status, vendor}} = create(base)

        assert vendor == %{
                 message: "OpenAI did not accept the API key (invalid_api_key).",
                 code: "invalid_api_key",
                 type: "invalid_request_error"
               }
      end

      base = vendor!(401, "<html>Incorrect API key provided: sk-inve****0001</html>", "text/html")

      assert {:error, {:rejected, 401, %{message: "OpenAI did not accept the API key."}}} =
               create(base)
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
        # A key no request could carry: the HTTP/1 client would raise on the
        # header and quote it back. A stored secret's trailing newline is the
        # common one.
        {%{api_key: @api_key <> "\n"}, :api_key},
        {%{api_key: @api_key <> "\r\nX-Injected: 1"}, :api_key},
        {%{api_key: "sk-invented key-0001"}, :api_key},
        {%{api_key: "sk-invénted-key-0001"}, :api_key},
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

  # Every reason this module returns becomes a call's failure words: the
  # owner's chat, the model, the ledger, the management list, telemetry. So
  # every shape is grepped for both invented secrets, in the forms they can
  # take inside a message (as stored, trimmed, and as `inspect/1` prints them).
  describe "no result carries a secret" do
    @stored_key @api_key <> "\n"

    defp secret_answers do
      echo = "#{@api_key} #{@password} #{inspect(@stored_key)}"
      envelope = Jason.encode!(%{"error" => %{"message" => echo, "code" => echo, "type" => echo}})

      [
        {:ok, Req.Response.new(status: 400, body: envelope)},
        {:ok, Req.Response.new(status: 404, body: envelope)},
        {:ok, Req.Response.new(status: 500, body: envelope)},
        {:ok, Req.Response.new(status: 502, body: "<html>#{echo}</html>")},
        {:ok, Req.Response.new(status: 504, body: envelope)},
        {:error,
         {:unknown,
          %Req.HTTPError{
            protocol: :http1,
            reason: {:invalid_header_value, "authorization", "Bearer " <> @stored_key}
          }}},
        {:error, {:unknown, %Req.TransportError{reason: {:unexpected, "Bearer " <> @api_key}}}},
        {:error, {:not_sent, RuntimeError.exception("pool for #{@api_key} #{@password} broke")}}
      ]
    end

    test "create: every error shape is free of the key and the trunk password" do
      for answer <- secret_answers() do
        printed = inspect(OpenAILive.classify_create(answer, [@stored_key, @password]))

        refute printed =~ @api_key, printed
        refute printed =~ @password, printed
      end
    end

    test "hangup: every error shape is free of the key" do
      for answer <- secret_answers() do
        printed = inspect(OpenAILive.classify_hangup(answer, [@stored_key]))

        refute printed =~ @api_key, printed
      end
    end

    test "a transport reason with no secret in it is kept as it was" do
      alert = {:tls_alert, {:unknown_ca, ~c"invented"}}

      assert {:error, {:unknown, {:transport, ^alert}}} =
               OpenAILive.classify_create(
                 {:error, {:unknown, %Req.TransportError{reason: alert}}},
                 [@api_key, @password]
               )
    end
  end

  # The one scrub the sideband passes every message through (`scrubber/1`).
  describe "scrubber/1" do
    # A password with characters `inspect/1` and JSON write escaped.
    @odd_password ~s(pw"In\\vent/é-7731)

    test "every form a message can carry a secret in is scrubbed" do
      scrub = OpenAILive.scrubber([@api_key <> "\n", @odd_password])

      for carried <- [
            @api_key,
            "Bearer " <> @api_key,
            @odd_password,
            inspect(@odd_password),
            Jason.encode!(%{"password" => @odd_password}),
            Jason.encode!(%{"password" => @odd_password}, escape: :unicode_safe),
            Jason.encode!(%{"password" => @odd_password}, escape: :html_safe),
            Jason.encode!(%{"auth" => "Bearer " <> @api_key})
          ] do
        scrubbed = scrub.("vendor said: " <> carried)
        assert scrubbed =~ "[REDACTED]", carried
        refute scrubbed =~ @api_key, carried
        refute scrubbed =~ "In", carried
      end
    end

    test "every string of a term is scrubbed, its keys too, and its shape kept" do
      scrub = OpenAILive.scrubber([@api_key, @password])

      event =
        {:unknown, "vendor.#{@api_key}",
         %{
           "detail" => ["ok", %{@password => {:nested, "Bearer #{@api_key}"}}],
           "count" => 3
         }}

      assert scrub.(event) ==
               {:unknown, "vendor.[REDACTED]",
                %{
                  "detail" => ["ok", %{"[REDACTED]" => {:nested, "Bearer [REDACTED]"}}],
                  "count" => 3
                }}

      error = %RuntimeError{message: "refused #{@password}"}

      assert scrub.({:transport, error}) ==
               {:transport, %RuntimeError{message: "refused [REDACTED]"}}

      assert scrub.({:closed, :local_close, 1000, self()}) ==
               {:closed, :local_close, 1000, self()}
    end

    test "a part nested past the bound is replaced whole, never passed on unread" do
      scrub = OpenAILive.scrubber([@api_key])
      deep = Enum.reduce(1..40, @api_key, fn _level, inner -> [inner] end)

      refute inspect(scrub.(deep), limit: :infinity) =~ @api_key
      assert inspect(scrub.(deep), limit: :infinity) =~ "[REDACTED]"
    end

    test "the function prints none of the secrets it scrubs" do
      scrub = OpenAILive.scrubber([@api_key, @password])
      printed = inspect(scrub, limit: :infinity, printable_limit: :infinity)

      refute printed =~ @api_key
      refute printed =~ @password
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

    test "the fixture's answers: 200 accepted, its 404 already ended in the vendor's words" do
      %{"status" => 200, "body" => ""} = @wire["hangup"]["accepted"]
      base = vendor!(200, "")
      assert {:ok, :accepted} = hangup(base)

      %{"status" => 404, "body" => %{"error" => error}} = @wire["hangup"]["ended"]
      base = vendor!(404, Jason.encode!(%{"error" => error}))

      assert {:ok, {:already_ended, 404, %{message: message, code: code}}} = hangup(base)
      assert {message, code} == {error["message"], error["code"]}
    end

    test "409 and 410 in the vendor's envelope read as already ended too" do
      for status <- [409, 410] do
        base = vendor!(status, ~s({"error":{"message":"session not found","code":"not_found"}}))

        assert {:ok, {:already_ended, ^status, %{message: "session not found"}}} = hangup(base)
      end
    end

    # Only the origin can say the session is gone. An edge's 404 is a refusal
    # to act: the call may still be up.
    test "a 404 without the vendor's envelope is a refusal, not an ended session" do
      base = vendor!(404, "<html><body>Not Found</body></html>", "text/html")

      assert {:error, {:rejected, 404, %{message: "<html><body>Not Found</body></html>"}}} =
               hangup(base)
    end

    test "any other refusal keeps its words; a refused key's are withheld" do
      base = vendor!(400, ~s({"error":{"message":"Hangup is only for SIP sessions."}}))

      assert {:error, {:rejected, 400, %{message: "Hangup is only for SIP sessions."}}} =
               hangup(base)

      base = vendor!(401, ~s({"error":{"message":"Incorrect API key provided: sk-i***0001"}}))

      assert {:error, {:rejected, 401, %{message: "OpenAI did not accept the API key."}}} =
               hangup(base)
    end

    test "a 5xx is a refusal only in the vendor's envelope; otherwise, and a 504, unknown" do
      base = vendor!(500, ~s({"error":{"message":"hangup failed","type":"server_error"}}))
      assert {:error, {:rejected, 500, %{message: "hangup failed"}}} = hangup(base)

      for {status, body} <- [{500, ""}, {502, "<html>Bad Gateway</html>"}, {503, "busy"}] do
        base = vendor!(status, body, "text/html")
        assert {:error, {:unknown, {:http_status, ^status, _vendor}}} = hangup(base)
      end

      base = vendor!(504, ~s({"error":{"message":"upstream timed out"}}))

      assert {:error, {:unknown, {:http_status, 504, %{message: "upstream timed out"}}}} =
               hangup(base)
    end

    test "a key no request could carry is refused before any I/O" do
      assert {:error, {:not_sent, {:invalid, :api_key}}} =
               OpenAILive.hangup("live_123",
                 api_key: @api_key <> "\n",
                 base_url: "http://127.0.0.1:1",
                 egress: @direct
               )
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

  defp origins(base), do: [base_url: base, ws_base_url: "ws://127.0.0.1:1", egress: @direct]

  defp hangup(base),
    do: OpenAILive.hangup("live_123", api_key: @api_key, base_url: base, egress: @direct)

  defp fixture_request(raw) do
    trunk = raw["trunk"]

    %{
      api_key: raw["api_key"],
      model: raw["model"],
      instructions: raw["instructions"],
      input: raw["input"],
      voice: raw["voice"],
      destination: raw["destination"],
      trunk: %{
        provider_url: trunk["provider_url"],
        username: trunk["username"],
        password: trunk["password"],
        caller_number: trunk["caller_number"]
      }
    }
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
