defmodule FermixChannels.Mobile.Push.FcmDispatcherTest do
  # Asserts what the log leaves out, so it runs alone (AGENTS.md, tests under load).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias FermixChannels.Mobile.Push.FcmConfig
  alias FermixChannels.Mobile.Push.FcmDispatcher

  @token_url "https://www.googleapis.com/oauth2/v4/token"
  @send_url "https://fcm.googleapis.com/v1/projects/fermix-owner-123/messages:send"
  @wait_ms 10_000

  setup_all do
    private_key = X509.PrivateKey.new_rsa(2048)

    account =
      Jason.encode!(%{
        "type" => "service_account",
        "private_key" => X509.PrivateKey.to_pem(private_key, wrap: true),
        "client_email" => "push@fermix-owner-123.iam.gserviceaccount.com"
      })

    {:ok, config} =
      FcmConfig.new(enabled: true, project_id: "fermix-owner-123", service_account: account)

    %{config: config, public_key: X509.PublicKey.derive(private_key)}
  end

  test "mints one token through Goth and sends each message with it, in order",
       %{config: config, public_key: public_key} do
    test = self()

    request = fn %Req.Request{} = req ->
      send(test, {:request, URI.to_string(req.url), req})

      case URI.to_string(req.url) do
        @token_url ->
          token_response("ya29.first", 3_599)

        @send_url ->
          {:ok, Req.Response.new(status: 200, body: %{"name" => "projects/x/messages/1"})}
      end
    end

    server = start_dispatcher(config, request: request)
    messages = [message("token-a"), message("token-b")]

    assert {:ok, [:ok, :ok]} = FcmDispatcher.dispatch(server, messages, config)
    assert {:ok, [:ok]} = FcmDispatcher.dispatch(server, [message("token-c")], config)

    assert_receive {:request, @token_url, token_req}, @wait_ms
    assert %{"grant_type" => grant, "assertion" => jwt} = URI.decode_query(token_req.body)
    assert grant == "urn:ietf:params:oauth:grant-type:jwt-bearer"
    assert {true, %JOSE.JWT{fields: claims}, _jws} = JOSE.JWT.verify(jose_key(public_key), jwt)
    assert claims["scope"] == "https://www.googleapis.com/auth/firebase.messaging"
    assert claims["iss"] == "push@fermix-owner-123.iam.gserviceaccount.com"

    for token <- ["token-a", "token-b", "token-c"] do
      assert_receive {:request, @send_url, send_req}, @wait_ms
      assert Req.Request.get_header(send_req, "authorization") == ["Bearer ya29.first"]
      assert send_req.options.json["message"]["token"] == token
    end

    refute_received {:request, @token_url, _req}
    assert FcmDispatcher.status(server) == :ready
  end

  test "answers each message with FCM's own error class", %{config: config} do
    answers = %{
      "unregistered" => fcm_error(404, "UNREGISTERED"),
      "bare-404" => {:ok, Req.Response.new(status: 404, body: "")},
      "invalid" => fcm_error(400, "INVALID_ARGUMENT"),
      "quota" => fcm_error(429, "QUOTA_EXCEEDED"),
      "forbidden" => {:ok, Req.Response.new(status: 403, body: %{})},
      "teapot" => {:ok, Req.Response.new(status: 418, body: %{})},
      "offline" => {:error, %Req.TransportError{reason: :econnrefused}},
      "fine" => {:ok, Req.Response.new(status: 200, body: %{})}
    }

    request = fn req -> Map.fetch!(answers, req.options.json["message"]["token"]) end
    server = start_dispatcher(config, request: request, fetch_token: fn _ -> fresh_token() end)
    tokens = Map.keys(answers)

    assert {:ok, results} =
             FcmDispatcher.dispatch(server, Enum.map(tokens, &message/1), config)

    assert Enum.zip(tokens, results) |> Map.new() == %{
             "unregistered" => {:error, :unregistered},
             "bare-404" => {:error, :unregistered},
             "invalid" => {:error, :invalid_argument},
             "quota" => {:error, :quota_exceeded},
             "forbidden" => {:error, :permission_denied},
             "teapot" => {:error, :rejected},
             "offline" => {:error, :unreachable},
             "fine" => :ok
           }

    assert FcmDispatcher.status(server) == :ready
  end

  test "a 401 drops the token, so the next batch mints another", %{config: config} do
    test = self()
    statuses = :counters.new(1, [])

    fetch_token = fn _config ->
      send(test, :minted)
      fresh_token()
    end

    request = fn _req ->
      :counters.add(statuses, 1, 1)
      status = if :counters.get(statuses, 1) == 1, do: 401, else: 200
      {:ok, Req.Response.new(status: status, body: %{})}
    end

    server = start_dispatcher(config, request: request, fetch_token: fetch_token)

    assert {:ok, [{:error, :unauthenticated}]} =
             FcmDispatcher.dispatch(server, [message("a")], config)

    assert FcmDispatcher.status(server) == {:degraded, :auth_failed}
    assert {:ok, [:ok]} = FcmDispatcher.dispatch(server, [message("a")], config)
    assert_receive :minted, @wait_ms
    assert_receive :minted, @wait_ms
    assert FcmDispatcher.status(server) == :ready
  end

  test "a token within a minute of its expiry is minted again", %{config: config} do
    test = self()
    now = 1_800_000_000

    fetch_token = fn _config ->
      send(test, :minted)
      {:ok, %{value: "ya29.short", expires_at: now + 90}}
    end

    request = fn _req -> {:ok, Req.Response.new(status: 200, body: %{})} end
    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, now)

    server =
      start_dispatcher(config,
        request: request,
        fetch_token: fetch_token,
        clock: fn -> :atomics.get(clock, 1) end
      )

    assert {:ok, [:ok]} = FcmDispatcher.dispatch(server, [message("a")], config)
    assert {:ok, [:ok]} = FcmDispatcher.dispatch(server, [message("a")], config)
    assert_receive :minted, @wait_ms
    refute_received :minted

    :atomics.put(clock, 1, now + 31)
    assert {:ok, [:ok]} = FcmDispatcher.dispatch(server, [message("a")], config)
    assert_receive :minted, @wait_ms
  end

  test "a token Google refuses fails the batch and says so", %{config: config} do
    request = fn req ->
      case URI.to_string(req.url) do
        @token_url -> {:ok, Req.Response.new(status: 400, body: ~s({"error":"invalid_grant"}))}
      end
    end

    server = start_dispatcher(config, request: request)

    log =
      capture_log(fn ->
        assert {:error, {:fcm_token_failed, :rejected}} =
                 FcmDispatcher.dispatch(server, [message("a")], config)
      end)

    assert log =~ "could not get an access token"
    refute log =~ "PRIVATE KEY"
    assert FcmDispatcher.status(server) == {:degraded, :auth_failed}
  end

  test "Google out of reach is told apart from Google refusing the account", %{config: config} do
    offline = fn _req -> {:error, %Req.TransportError{reason: :econnrefused}} end
    server = start_dispatcher(config, request: offline)

    capture_log(fn ->
      assert {:error, {:fcm_token_failed, :unreachable}} =
               FcmDispatcher.dispatch(server, [message("a")], config)
    end)

    assert FcmDispatcher.status(server) == {:degraded, :unreachable}

    server = start_dispatcher(config, request: offline, fetch_token: fn _ -> fresh_token() end)

    assert {:ok, [{:error, :unreachable}, {:error, :unreachable}]} =
             FcmDispatcher.dispatch(server, [message("a"), message("b")], config)

    assert FcmDispatcher.status(server) == {:degraded, :unreachable}
  end

  # Batches overlap: one that started with a token FCM has since refused must
  # not put it back when it ends last.
  test "a refused token is never cached again by a slower batch that held it",
       %{config: config} do
    test = self()
    tokens = :counters.new(1, [])

    fetch_token = fn _config ->
      :counters.add(tokens, 1, 1)
      value = "ya29.t#{:counters.get(tokens, 1)}"
      {:ok, %{value: value, expires_at: System.os_time(:second) + 3_600}}
    end

    request = fn req ->
      [bearer] = Req.Request.get_header(req, "authorization")
      device = req.options.json["message"]["token"]
      send(test, {:sent, device, bearer, self()})

      case device do
        "slow" -> receive(do: (:release -> {:ok, Req.Response.new(status: 200, body: %{})}))
        "revoked" -> {:ok, Req.Response.new(status: 401, body: %{})}
        _other -> {:ok, Req.Response.new(status: 200, body: %{})}
      end
    end

    server = start_dispatcher(config, request: request, fetch_token: fetch_token)

    assert {:ok, [:ok]} = FcmDispatcher.dispatch(server, [message("first")], config)
    assert_receive {:sent, "first", "Bearer ya29.t1", _pid}, @wait_ms

    slow = Task.async(fn -> FcmDispatcher.dispatch(server, [message("slow")], config) end)
    assert_receive {:sent, "slow", "Bearer ya29.t1", slow_batch}, @wait_ms

    assert {:ok, [{:error, :unauthenticated}]} =
             FcmDispatcher.dispatch(server, [message("revoked")], config)

    # The slow batch ends after the refusal and before any new token, holding
    # the refused one; the next batch still mints a new token.
    send(slow_batch, :release)
    assert {:ok, [:ok]} = Task.await(slow, @wait_ms)

    assert {:ok, [:ok]} = FcmDispatcher.dispatch(server, [message("after")], config)
    assert_receive {:sent, "after", "Bearer ya29.t2", _pid}, @wait_ms

    # A later-expiring token is not given up for an older one.
    assert {:ok, [:ok]} = FcmDispatcher.dispatch(server, [message("last")], config)
    assert_receive {:sent, "last", "Bearer ya29.t2", _pid}, @wait_ms
  end

  test "status answers while a batch waits on the network, and batches are capped",
       %{config: config} do
    test = self()

    request = fn _req ->
      send(test, {:waiting, self()})

      receive do
        :release -> {:ok, Req.Response.new(status: 200, body: %{})}
      end
    end

    server = start_dispatcher(config, request: request, fetch_token: fn _ -> fresh_token() end)

    callers =
      for _batch <- 1..8 do
        Task.async(fn -> FcmDispatcher.dispatch(server, [message("a")], config) end)
      end

    waiting =
      for _batch <- 1..8 do
        assert_receive {:waiting, pid}, @wait_ms
        pid
      end

    assert FcmDispatcher.status(server) == :ready

    assert {:error, {:push_unavailable, :busy}} =
             FcmDispatcher.dispatch(server, [message("a")], config)

    Enum.each(waiting, &send(&1, :release))
    assert Enum.map(callers, &Task.await(&1, @wait_ms)) == List.duplicate({:ok, [:ok]}, 8)
  end

  test "a batch killed before it answers is answered as failed", %{config: config} do
    fetch_token = fn _config -> Process.exit(self(), :kill) end
    server = start_dispatcher(config, fetch_token: fetch_token)

    log =
      capture_log(fn ->
        assert {:error, {:push_dependency_exit, :fcm_batch, :killed}} =
                 FcmDispatcher.dispatch(server, [message("a")], config)
      end)

    assert log =~ "exited before it answered"
  end

  test "refuses a batch for another config, or of no or too many messages", %{config: config} do
    server = start_dispatcher(config, fetch_token: fn _ -> fresh_token() end)
    other = %{config | project_id: "another-project"}

    assert {:error, :push_dispatcher_config_mismatch} =
             FcmDispatcher.dispatch(server, [message("a")], other)

    assert {:error, {:invalid_dispatch_count, 0, 64}} = FcmDispatcher.dispatch(server, [], config)

    assert {:error, {:invalid_dispatch_count, 65, 64}} =
             FcmDispatcher.dispatch(server, List.duplicate(message("a"), 65), config)
  end

  test "will not start without an enabled config" do
    Process.flag(:trap_exit, true)

    assert {:error, {:fcm_dispatcher_start_failed, :missing_enabled_config}} =
             FcmDispatcher.start_link(name: nil, config: %FcmConfig{enabled: false})
  end

  defp start_dispatcher(config, opts) do
    spec = {FcmDispatcher, [name: nil, config: config] ++ opts}
    start_supervised!(Supervisor.child_spec(spec, id: make_ref()))
  end

  defp message(token) do
    %{"message" => %{"token" => token, "data" => %{"v" => "2", "n" => "", "c" => ""}}}
  end

  defp fresh_token, do: {:ok, %{value: "ya29.test", expires_at: System.os_time(:second) + 3_600}}

  defp token_response(value, expires_in) do
    body =
      Jason.encode!(%{
        "access_token" => value,
        "expires_in" => expires_in,
        "token_type" => "Bearer"
      })

    {:ok,
     Req.Response.new(status: 200, headers: %{"content-type" => ["application/json"]}, body: body)}
  end

  defp fcm_error(status, code) do
    body = %{
      "error" => %{
        "code" => status,
        "details" => [
          %{"@type" => "type.googleapis.com/google.firebase.fcm.v1.FcmError", "errorCode" => code}
        ]
      }
    }

    {:ok, Req.Response.new(status: status, body: body)}
  end

  defp jose_key(public_key), do: public_key |> X509.PublicKey.to_pem() |> JOSE.JWK.from_pem()
end
