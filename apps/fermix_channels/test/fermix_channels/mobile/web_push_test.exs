defmodule FermixChannels.Mobile.WebPushTest do
  # async: false — the log tests assert what a warning does NOT contain, and an
  # absence assert must not see another test's lines.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias FermixChannels.Mobile.WebPush
  alias FermixChannels.Mobile.WebPush.Key
  alias FermixChannels.Mobile.WebPush.Payload
  alias FermixChannels.Test.WebPushDecrypt

  @stub __MODULE__
  @token "eX4mpleT0ken:APA91b_Fx-9qLm"
  @now_unix 1_794_268_800
  @preview "Your table at Orvane is booked for 19:30."

  setup {Req.Test, :verify_on_exit!}

  setup do
    {public, private} = :crypto.generate_key(:ecdh, :secp256r1)
    {phone_public, phone_private} = :crypto.generate_key(:ecdh, :secp256r1)
    auth = :crypto.strong_rand_bytes(16)
    clock = :counters.new(1, [])
    test_pid = self()

    {:ok, plaintext} =
      Payload.encode(%{
        kind: :message,
        profile_id: "main",
        server_seq: 42,
        preview_text: @preview
      })

    opts = [
      key: %Key{private: private, public: public},
      req_options: [plug: {Req.Test, @stub}],
      now_ms: fn -> :counters.get(clock, 1) end,
      now_unix: fn -> @now_unix end,
      sleep: fn ms ->
        send(test_pid, {:slept, ms})
        :counters.add(clock, 1, ms)
      end
    ]

    %{
      subscription: %{service: "fcm", token: @token, p256dh: phone_public, auth: auth},
      phone_private: phone_private,
      plaintext: plaintext,
      opts: opts,
      clock: clock,
      key: %Key{private: private, public: public}
    }
  end

  defp respond(status, headers \\ [], body \\ "") do
    fn conn ->
      conn
      |> Plug.Conn.merge_resp_headers(headers)
      |> Plug.Conn.send_resp(status, body)
    end
  end

  defp claims(authorization) do
    [_whole, token] = Regex.run(~r/\Avapid t=([^,]+), k=/, authorization)
    [_header, claims, _signature] = String.split(token, ".")
    claims |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  defp slept do
    receive do
      {:slept, ms} -> [ms | slept()]
    after
      0 -> []
    end
  end

  describe "endpoint/2" do
    test "builds Google's address from the token, and names the services it knows" do
      assert WebPush.services() == ["fcm"]

      assert {:ok, "https://fcm.googleapis.com/fcm/send/" <> @token} =
               WebPush.endpoint("fcm", @token)

      assert {:ok, _url} = WebPush.endpoint("fcm", String.duplicate("a", 4_096))
    end

    test "refuses a token that could point the engine at another path or host" do
      for token <- [
            "",
            "a/b",
            "../x",
            "a?b=c",
            "a#b",
            "a b",
            "a%2Fb",
            "a@evil.example",
            "abc\n",
            "abc.def",
            String.duplicate("a", 4_097)
          ] do
        assert {:error, :invalid_token} = WebPush.endpoint("fcm", token)
      end
    end

    test "refuses a service it does not know" do
      assert {:error, :unknown_service} = WebPush.endpoint("apns", @token)
      assert {:error, :unknown_service} = WebPush.endpoint("FCM", @token)
    end
  end

  describe "send/4, the request" do
    test "one POST to Google with the Web Push headers and a sealed 2,150-byte body", ctx do
      test_pid = self()

      Req.Test.expect(@stub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, conn, body})
        Plug.Conn.send_resp(conn, 201, "")
      end)

      assert :ok = WebPush.send(ctx.subscription, ctx.plaintext, 86_400, ctx.opts)
      assert_received {:request, conn, body}

      assert conn.method == "POST"
      assert conn.scheme == :https
      assert conn.host == "fcm.googleapis.com"
      assert conn.port == 443
      assert conn.request_path == "/fcm/send/" <> @token
      assert conn.query_string == ""

      assert Plug.Conn.get_req_header(conn, "ttl") == ["86400"]
      assert Plug.Conn.get_req_header(conn, "urgency") == ["high"]
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/octet-stream"]
      assert Plug.Conn.get_req_header(conn, "accept-encoding") == []

      assert [authorization] = Plug.Conn.get_req_header(conn, "authorization")
      assert String.ends_with?(authorization, ", k=" <> Key.public_text(ctx.key))

      assert claims(authorization) == %{
               "aud" => "https://fcm.googleapis.com",
               "exp" => @now_unix + 43_200,
               "sub" => "https://fermix.ai"
             }

      assert byte_size(body) == 2_150

      assert {:ok, %{plaintext: plaintext}} =
               WebPushDecrypt.decrypt(body, ctx.phone_private, ctx.subscription.auth)

      assert plaintext == ctx.plaintext
      assert slept() == []
    end

    # Req's test plug reads a request `content-encoding` as a compression and
    # strips it before the plug runs, so the request is read here at the
    # adapter, as Finch is handed it.
    test "the request leaves with content-encoding aes128gcm and follows no redirect", ctx do
      test_pid = self()

      adapter = fn request ->
        send(test_pid, {:request, request})
        {request, Req.Response.new(status: 201)}
      end

      opts = Keyword.put(ctx.opts, :req_options, adapter: adapter)

      assert :ok = WebPush.send(ctx.subscription, ctx.plaintext, 3_600, opts)
      assert_received {:request, request}

      assert request.method == :post
      assert URI.to_string(request.url) == "https://fcm.googleapis.com/fcm/send/" <> @token
      assert Req.Request.get_header(request, "content-encoding") == ["aes128gcm"]
      assert Req.Request.get_header(request, "ttl") == ["3600"]
      assert Req.Request.get_header(request, "urgency") == ["high"]
      assert Req.Request.get_header(request, "accept-encoding") == []
      assert request.options.redirect == false
      assert request.options.retry == false
      assert byte_size(request.body) == 2_150
    end

    test "any 2xx is delivered", ctx do
      for status <- [200, 201, 202, 204] do
        Req.Test.expect(@stub, respond(status))
        assert :ok = WebPush.send(ctx.subscription, ctx.plaintext, 60, ctx.opts)
      end
    end

    test "a subscription the engine cannot address is refused before any request", ctx do
      assert {:error, {:invalid, :invalid_token}} =
               WebPush.send(%{ctx.subscription | token: "a/b"}, ctx.plaintext, 60, ctx.opts)

      assert {:error, {:invalid, :unknown_service}} =
               WebPush.send(%{ctx.subscription | service: "apns"}, ctx.plaintext, 60, ctx.opts)

      assert {:error, {:invalid, :invalid_p256dh}} =
               WebPush.send(
                 %{ctx.subscription | p256dh: <<4, 0::512>>},
                 ctx.plaintext,
                 60,
                 ctx.opts
               )

      assert {:error, {:invalid, :invalid_auth}} =
               WebPush.send(%{ctx.subscription | auth: "short"}, ctx.plaintext, 60, ctx.opts)

      assert {:error, {:invalid, :plaintext_too_large}} =
               WebPush.send(ctx.subscription, :binary.copy("a", 2_048), 60, ctx.opts)
    end

    test "a key whose halves do not match is refused before any request", ctx do
      {other_public, _other_private} = :crypto.generate_key(:ecdh, :secp256r1)
      %Key{} = key = ctx.key
      opts = Keyword.put(ctx.opts, :key, %{key | public: other_public})

      assert {:error, {:invalid, :key_mismatch}} =
               WebPush.send(ctx.subscription, ctx.plaintext, 60, opts)
    end

    test "an unknown option is refused", ctx do
      assert {:error, {:invalid, {:unknown_options, [:retries]}}} =
               WebPush.send(ctx.subscription, ctx.plaintext, 60, [retries: 5] ++ ctx.opts)
    end
  end

  describe "send/4, Google's answers" do
    test "404 and 410 say the subscription is gone, with no second try", ctx do
      for status <- [404, 410] do
        Req.Test.expect(@stub, respond(status))
        assert {:error, :gone} = WebPush.send(ctx.subscription, ctx.plaintext, 60, ctx.opts)
      end

      assert slept() == []
    end

    test "401 and 403 say the sender was refused, with no second try", ctx do
      for status <- [401, 403] do
        Req.Test.expect(@stub, respond(status))

        assert {:error, :sender_refused} =
                 WebPush.send(ctx.subscription, ctx.plaintext, 60, ctx.opts)
      end

      assert slept() == []
    end

    test "any other 4xx is refused with the service's own words, never retried", ctx do
      Req.Test.expect(@stub, respond(400, [], "UnauthorizedRegistration\r\n\tbad \e[31mrequest"))

      assert {:error, {:refused, 400, "UnauthorizedRegistration bad [31mrequest"}} =
               WebPush.send(ctx.subscription, ctx.plaintext, 60, ctx.opts)

      Req.Test.expect(@stub, respond(413, [], "payload too large"))

      assert {:error, {:refused, 413, "payload too large"}} =
               WebPush.send(ctx.subscription, ctx.plaintext, 60, ctx.opts)

      assert slept() == []
    end

    test "the service's words are cut to 200 bytes and never carry the token", ctx do
      Req.Test.expect(
        @stub,
        respond(400, [], "token " <> @token <> " " <> String.duplicate("x", 5_000))
      )

      assert {:error, {:refused, 400, excerpt}} =
               WebPush.send(ctx.subscription, ctx.plaintext, 60, ctx.opts)

      assert byte_size(excerpt) <= 200
      refute excerpt =~ @token
      assert excerpt =~ ~r/\A[\x20-\x7E]*\z/
    end

    test "a redirect is not followed", ctx do
      Req.Test.expect(@stub, respond(301, [{"location", "https://evil.example/collect"}]))

      assert {:error, {:refused, 301, ""}} =
               WebPush.send(ctx.subscription, ctx.plaintext, 60, ctx.opts)
    end
  end

  describe "send/4, trying again" do
    test "5xx three times: three attempts, 2 s then 10 s between them, no wait after the last",
         ctx do
      Req.Test.expect(@stub, 3, respond(503))

      assert {:error, {:unavailable, {:http, 503}}} =
               WebPush.send(ctx.subscription, ctx.plaintext, 60, ctx.opts)

      assert slept() == [2_000, 10_000]
    end

    test "429 then 201 is delivered on the second attempt", ctx do
      Req.Test.expect(@stub, respond(429))
      Req.Test.expect(@stub, respond(201))

      assert :ok = WebPush.send(ctx.subscription, ctx.plaintext, 60, ctx.opts)
      assert slept() == [2_000]
    end

    test "Retry-After is honoured when it fits the minute", ctx do
      Req.Test.expect(@stub, respond(503, [{"retry-after", "7"}]))
      Req.Test.expect(@stub, respond(429, [{"retry-after", "0"}]))
      Req.Test.expect(@stub, respond(201))

      assert :ok = WebPush.send(ctx.subscription, ctx.plaintext, 60, ctx.opts)
      assert slept() == [7_000, 0]
    end

    test "a Retry-After past the minute stops at once", ctx do
      Req.Test.expect(@stub, respond(429, [{"retry-after", "61"}]))

      assert {:error, {:unavailable, {:http, 429}}} =
               WebPush.send(ctx.subscription, ctx.plaintext, 60, ctx.opts)

      assert slept() == []
    end

    test "no attempt starts past 60 seconds from the first", ctx do
      slow_503 = fn conn ->
        :counters.add(ctx.clock, 1, 50_000)
        Plug.Conn.send_resp(conn, 503, "")
      end

      Req.Test.expect(@stub, 2, slow_503)

      assert {:error, {:unavailable, {:http, 503}}} =
               WebPush.send(ctx.subscription, ctx.plaintext, 60, ctx.opts)

      assert slept() == [2_000]
    end

    test "a transport error is tried again, and its reason is the last one kept", ctx do
      Req.Test.expect(@stub, 3, &Req.Test.transport_error(&1, :timeout))

      assert {:error, {:unavailable, {:transport, :timeout}}} =
               WebPush.send(ctx.subscription, ctx.plaintext, 60, ctx.opts)

      Req.Test.expect(@stub, &Req.Test.transport_error(&1, :timeout))
      Req.Test.expect(@stub, respond(201))

      assert :ok = WebPush.send(ctx.subscription, ctx.plaintext, 60, ctx.opts)
      assert slept() == [2_000, 10_000, 2_000]
    end
  end

  describe "send/4, logs" do
    test "each failed attempt is logged once, naming the service, never the token, keys or text",
         ctx do
      Req.Test.expect(@stub, 2, respond(503, [], "Service Unavailable"))
      Req.Test.expect(@stub, respond(400, [], "InvalidTtl"))

      {result, log} =
        with_log(fn -> WebPush.send(ctx.subscription, ctx.plaintext, 60, ctx.opts) end)

      assert {:error, {:refused, 400, "InvalidTtl"}} = result

      lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "Web Push"))
      assert length(lines) == 3
      assert Enum.all?(lines, &(&1 =~ "[warning]"))
      assert Enum.all?(lines, &(&1 =~ "fcm"))
      assert log =~ "HTTP 503"
      assert log =~ "Service Unavailable"
      assert log =~ "HTTP 400"
      assert log =~ "InvalidTtl"

      secrets = [
        @token,
        @preview,
        Base.url_encode64(ctx.subscription.p256dh, padding: false),
        Base.url_encode64(ctx.subscription.auth, padding: false),
        Base.url_encode64(ctx.key.private, padding: false),
        Base.encode16(ctx.key.private, case: :lower)
      ]

      for secret <- secrets, do: refute(log =~ secret)
    end

    test "a delivered push logs nothing", ctx do
      Req.Test.expect(@stub, respond(201))

      {result, log} =
        with_log(fn -> WebPush.send(ctx.subscription, ctx.plaintext, 60, ctx.opts) end)

      assert result == :ok
      refute log =~ "Web Push"
    end
  end
end
