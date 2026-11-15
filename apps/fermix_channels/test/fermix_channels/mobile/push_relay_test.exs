defmodule FermixChannels.Mobile.PushRelayTest do
  # async: false — the log tests assert what a line does NOT contain, and an
  # absence assert must not see another test's lines.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias FermixChannels.Mobile.PushRelay
  alias FermixChannels.Mobile.WebPush.Payload
  alias FermixChannels.Test.WebPushDecrypt

  @stub __MODULE__
  # An invented Firebase Installation ID, in the shape Google issues one.
  @address "cQ4vT8pLmX2bR7wZ_k1-Ns"
  @preview "Your table at Orvane is booked for 19:30."
  @bug_words ~w(malformed service address ttl body too_large refused not_found)

  setup {Req.Test, :verify_on_exit!}

  setup do
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
      req_options: [plug: {Req.Test, @stub}],
      now_ms: fn -> :counters.get(clock, 1) end,
      sleep: fn ms ->
        send(test_pid, {:slept, ms})
        :counters.add(clock, 1, ms)
      end
    ]

    %{
      subscription: %{service: "fcm", address: @address, p256dh: phone_public, auth: auth},
      phone_private: phone_private,
      plaintext: plaintext,
      opts: opts,
      clock: clock
    }
  end

  defp respond(status, headers \\ [], body \\ "") do
    fn conn ->
      conn
      |> Plug.Conn.merge_resp_headers(headers)
      |> Plug.Conn.send_resp(status, body)
    end
  end

  # The relay's own answer: its error word in a JSON body.
  defp relay(status, word, headers \\ []),
    do: respond(status, [{"content-type", "application/json"} | headers], ~s({"error":"#{word}"}))

  # The API gateway's own answer when a ceiling refuses a request: no error
  # word and no Retry-After, as seen live (M99 §16).
  defp gateway(status, message),
    do: respond(status, [{"content-type", "application/json"}], ~s({"message":"#{message}"}))

  defp slept do
    receive do
      {:slept, ms} -> [ms | slept()]
    after
      0 -> []
    end
  end

  describe "the subscription" do
    test "names fcm, the one service, and an address of letters, digits, _ and -" do
      assert PushRelay.services() == ["fcm"]

      for address <- [@address, "a", String.duplicate("A", 256), "-_09azAZ"] do
        assert PushRelay.valid_address?(address), address
      end

      for address <- [
            "",
            String.duplicate("a", 257),
            "dK3vQ8pLmX2:APA91bH7xZ",
            "a/b",
            "../x",
            "a?b=c",
            "a#b",
            "a b",
            "a%2Fb",
            "a@evil.example",
            "abc\n",
            "abc.def",
            "é"
          ] do
        refute PushRelay.valid_address?(address), inspect(address)
      end
    end
  end

  describe "send/4, the request" do
    test "one POST of JSON to the relay's one address, the address in the body", ctx do
      test_pid = self()

      Req.Test.expect(@stub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, conn, body})
        Plug.Conn.send_resp(conn, 204, "")
      end)

      assert :ok = PushRelay.send(ctx.subscription, ctx.plaintext, 86_400, ctx.opts)
      assert_received {:request, conn, body}

      assert conn.method == "POST"
      assert conn.scheme == :https
      assert conn.host == "push.fermix.ai"
      assert conn.port == 443
      assert conn.request_path == "/v1/push"
      assert conn.query_string == ""
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      assert Plug.Conn.get_req_header(conn, "accept-encoding") == []

      assert [~s({"service":"fcm","address":"#{@address}","ttl":86400,"body":"), _rest] =
               String.split(body, ~r/(?<="body":")/, parts: 2)

      assert %{"service" => "fcm", "address" => @address, "ttl" => 86_400, "body" => sealed} =
               Jason.decode!(body)

      assert map_size(Jason.decode!(body)) == 4
      assert String.length(sealed) == 2_867
      assert sealed =~ ~r/\A[A-Za-z0-9_-]+\z/
      assert {:ok, bytes} = Base.url_decode64(sealed, padding: false)
      assert byte_size(bytes) == 2_150

      assert {:ok, %{plaintext: plaintext}} =
               WebPushDecrypt.decrypt(bytes, ctx.phone_private, ctx.subscription.auth)

      assert plaintext == ctx.plaintext
      assert slept() == []
    end

    test "the request follows no redirect, retries nothing itself and waits 15 s at most", ctx do
      test_pid = self()

      adapter = fn request ->
        send(test_pid, {:request, request})
        {request, Req.Response.new(status: 204)}
      end

      opts = Keyword.put(ctx.opts, :req_options, adapter: adapter)

      assert :ok = PushRelay.send(ctx.subscription, ctx.plaintext, 300, opts)
      assert_received {:request, request}

      assert request.method == :post
      assert URI.to_string(request.url) == "https://push.fermix.ai/v1/push"
      refute URI.to_string(request.url) =~ @address
      assert request.options.redirect == false
      assert request.options.retry == false
      assert request.options.receive_timeout == 15_000
      assert Jason.decode!(request.body)["ttl"] == 300
    end

    test "204 is delivered, and a delivered push logs nothing", ctx do
      Req.Test.expect(@stub, respond(204))

      {result, log} =
        with_log(fn -> PushRelay.send(ctx.subscription, ctx.plaintext, 60, ctx.opts) end)

      assert result == :ok
      refute log =~ "push relay"
    end

    test "a subscription it cannot send is refused before any request", ctx do
      for {field, value, reason} <- [
            {:address, "has:colon", :invalid_address},
            {:address, "", :invalid_address},
            {:address, String.duplicate("a", 257), :invalid_address},
            {:service, "apns", :unknown_service},
            {:service, "FCM", :unknown_service},
            {:p256dh, <<4, 0::512>>, :invalid_p256dh},
            {:auth, "short", :invalid_auth}
          ] do
        subscription = Map.put(ctx.subscription, field, value)

        assert {:error, {:invalid, ^reason}} =
                 PushRelay.send(subscription, ctx.plaintext, 60, ctx.opts)
      end

      assert {:error, {:invalid, :plaintext_too_large}} =
               PushRelay.send(ctx.subscription, :binary.copy("a", 2_048), 60, ctx.opts)
    end

    test "an unknown option is refused", ctx do
      assert {:error, {:invalid, {:unknown_options, [:retries]}}} =
               PushRelay.send(ctx.subscription, ctx.plaintext, 60, [retries: 5] ++ ctx.opts)
    end
  end

  describe "send/4, the relay's answers" do
    test "gone drops the subscription's address, with no second try", ctx do
      Req.Test.expect(@stub, relay(410, "gone"))
      assert {:error, :gone} = PushRelay.send(ctx.subscription, ctx.plaintext, 60, ctx.opts)
      assert slept() == []
    end

    test "a word that names a bug is refused by that word, logged once as an error, never retried",
         ctx do
      for word <- @bug_words do
        status = if word == "refused", do: 502, else: 400
        Req.Test.expect(@stub, relay(status, word))

        {result, log} =
          with_log(fn -> PushRelay.send(ctx.subscription, ctx.plaintext, 60, ctx.opts) end)

        assert {:error, {:rejected, atom}} = result
        assert Atom.to_string(atom) == word
        assert [line] = log |> String.split("\n") |> Enum.filter(&(&1 =~ "push relay"))
        assert line =~ "[error]"
        assert line =~ word
        assert line =~ "not tried again"
      end

      assert slept() == []
    end

    test "with no relay word, any answer but 429 and a 5xx is refused by its status", ctx do
      for {status, response} <- [
            {400, gateway(400, "Bad Request")},
            {403, gateway(403, "Forbidden")},
            {404, respond(404)},
            {410, respond(410)},
            {301, respond(301, [{"location", "https://evil.example/collect"}])},
            {200, respond(200)},
            {201, respond(201)}
          ] do
        Req.Test.expect(@stub, response)

        assert {:error, {:refused, ^status}} =
                 PushRelay.send(ctx.subscription, ctx.plaintext, 60, ctx.opts)
      end

      assert slept() == []
    end

    test "a word the relay does not have is no relay word, and is never logged", ctx do
      Req.Test.expect(@stub, relay(400, "brand_new_word"))
      Req.Test.expect(@stub, relay(503, "brand_new_word"))
      Req.Test.expect(@stub, respond(204))

      {results, log} =
        with_log(fn ->
          for _send <- 1..2, do: PushRelay.send(ctx.subscription, ctx.plaintext, 60, ctx.opts)
        end)

      assert results == [{:error, {:refused, 400}}, :ok]
      assert slept() == [2_000]
      refute log =~ "brand_new_word"
    end
  end

  describe "send/4, trying again" do
    test "busy, unavailable and permission wait as long as the relay asks", ctx do
      Req.Test.expect(@stub, relay(503, "unavailable", [{"retry-after", "7"}]))
      Req.Test.expect(@stub, relay(429, "busy", [{"retry-after", "0"}]))
      Req.Test.expect(@stub, respond(204))

      assert :ok = PushRelay.send(ctx.subscription, ctx.plaintext, 60, ctx.opts)
      assert slept() == [7_000, 0]

      Req.Test.expect(@stub, 3, relay(503, "permission", [{"retry-after", "1"}]))

      assert {:error, {:unavailable, {:relay, :permission}}} =
               PushRelay.send(ctx.subscription, ctx.plaintext, 60, ctx.opts)

      assert slept() == [1_000, 1_000]
    end

    test "the gateway's own 429 and 503 wait 2 s then 10 s, no wait after the last", ctx do
      Req.Test.expect(@stub, 3, gateway(429, "Too Many Requests"))

      assert {:error, {:unavailable, {:http, 429}}} =
               PushRelay.send(ctx.subscription, ctx.plaintext, 60, ctx.opts)

      assert slept() == [2_000, 10_000]

      Req.Test.expect(@stub, gateway(503, "Service Unavailable"))
      Req.Test.expect(@stub, respond(500))
      Req.Test.expect(@stub, respond(204))

      assert :ok = PushRelay.send(ctx.subscription, ctx.plaintext, 60, ctx.opts)
      assert slept() == [2_000, 10_000]
    end

    test "the last attempt's failure is the one kept", ctx do
      Req.Test.expect(@stub, relay(429, "busy"))
      Req.Test.expect(@stub, gateway(503, "Service Unavailable"))
      Req.Test.expect(@stub, relay(503, "unavailable"))

      assert {:error, {:unavailable, {:relay, :unavailable}}} =
               PushRelay.send(ctx.subscription, ctx.plaintext, 60, ctx.opts)

      assert slept() == [2_000, 10_000]
    end

    test "a Retry-After past the minute stops at once", ctx do
      Req.Test.expect(@stub, relay(429, "busy", [{"retry-after", "61"}]))

      assert {:error, {:unavailable, {:relay, :busy}}} =
               PushRelay.send(ctx.subscription, ctx.plaintext, 60, ctx.opts)

      assert slept() == []
    end

    test "no attempt starts past 60 seconds from the first", ctx do
      slow_503 = fn conn ->
        :counters.add(ctx.clock, 1, 50_000)
        Plug.Conn.send_resp(conn, 503, "")
      end

      Req.Test.expect(@stub, 2, slow_503)

      assert {:error, {:unavailable, {:http, 503}}} =
               PushRelay.send(ctx.subscription, ctx.plaintext, 60, ctx.opts)

      assert slept() == [2_000]
    end

    test "a transport error is tried again, and its reason is the last one kept", ctx do
      Req.Test.expect(@stub, 3, &Req.Test.transport_error(&1, :timeout))

      assert {:error, {:unavailable, {:transport, :timeout}}} =
               PushRelay.send(ctx.subscription, ctx.plaintext, 60, ctx.opts)

      Req.Test.expect(@stub, &Req.Test.transport_error(&1, :nxdomain))
      Req.Test.expect(@stub, respond(204))

      assert :ok = PushRelay.send(ctx.subscription, ctx.plaintext, 60, ctx.opts)
      assert slept() == [2_000, 10_000, 2_000]
    end
  end

  describe "send/4, logs" do
    test "each failed attempt is logged once, never the address, a key, the body or its words",
         ctx do
      test_pid = self()

      Req.Test.expect(@stub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:sealed, Jason.decode!(body)["body"]})
        gateway(503, "Service Unavailable at #{@address}").(conn)
      end)

      Req.Test.expect(@stub, relay(429, "busy", [{"retry-after", "1"}]))
      Req.Test.expect(@stub, relay(400, "address"))

      {result, log} =
        with_log(fn -> PushRelay.send(ctx.subscription, ctx.plaintext, 60, ctx.opts) end)

      assert {:error, {:rejected, :address}} = result
      assert_received {:sealed, sealed}

      lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "push relay"))
      assert length(lines) == 3
      assert Enum.all?(lines, &(&1 =~ "fcm"))
      assert Enum.count(lines, &(&1 =~ "[warning]")) == 2
      assert log =~ "HTTP 503"
      assert log =~ "HTTP 429 busy"
      assert log =~ "HTTP 400 address"

      secrets = [
        @address,
        @preview,
        "Service Unavailable",
        String.slice(sealed, 0, 40),
        Base.url_encode64(ctx.subscription.p256dh, padding: false),
        Base.url_encode64(ctx.subscription.auth, padding: false)
      ]

      for secret <- secrets, do: refute(log =~ secret, secret)
    end
  end
end
