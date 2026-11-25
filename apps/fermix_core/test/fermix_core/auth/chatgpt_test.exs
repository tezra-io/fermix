defmodule FermixCore.Auth.ChatGPTTest do
  # The facade's sign-out, standing and sentences (M57 §6.3, §7.1, §8). Sync: a
  # sign-out tells the shared TokenSupervisor to let go of `chatgpt`.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias FermixCore.Auth.ChatGPT
  alias FermixCore.Auth.ChatGPT.HostId
  alias FermixCore.Auth.ChatGPT.Logout
  alias FermixCore.Auth.ChatGPT.Registration
  alias FermixCore.Auth.Store
  alias FermixTestSupport.SafeRm

  @full_scope ~w(chatgpt.tokens.use.direct email offline_access openid profile resource.invoke)

  setup do
    home = SafeRm.make_tmp_dir!("chatgpt-facade")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{path: Path.join(home, "auth.json")}
  end

  defp ready(overrides \\ %{}) do
    Map.merge(
      %{
        auth_mode: "oauth_siwc",
        provider: "chatgpt",
        client_id: "oaiapp_A1",
        subject: "user-sub-1",
        account: %{email: "ada@example.test"},
        granted_scopes: @full_scope,
        tokens: %{access_token: "AT-0", refresh_token: "RT-0"},
        expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
        last_refresh: nil,
        status: "ready"
      },
      overrides
    )
  end

  defp revoke_plug(status, test \\ self()) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:revoke, conn.method, conn.request_path, URI.decode_query(body)})
      Plug.Conn.send_resp(conn, status, "")
    end
  end

  # What a sign-out left in a home before a sign-out forgot the registration:
  # no tokens and no sign-in under way, the client and the account kept.
  defp leftover do
    ready(%{
      tokens: %{access_token: nil, refresh_token: nil},
      expires_at: nil,
      status: "signed_out"
    })
  end

  defp other_profile do
    %{
      auth_mode: "oauth_pkce",
      provider: "xai",
      tokens: %{access_token: "XAI-AT", refresh_token: "XAI-RT"},
      expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
      last_refresh: nil
    }
  end

  describe "logout/1" do
    test "revokes the refresh token upstream, then forgets the registration", %{path: path} do
      :ok = Store.write("chatgpt", ready(), path)
      :ok = Store.write("xai_oauth", other_profile(), path)
      {:ok, host_id} = HostId.fetch_or_create(path)
      host_file = File.read!(HostId.path(path))

      assert {:ok, %{revoked: true}} =
               ChatGPT.logout(fermix_path: path, req_options: [plug: revoke_plug(200)])

      assert_received {:revoke, "POST", "/api/accounts/oauth/revoke", form}

      assert form == %{
               "token" => "RT-0",
               "token_type_hint" => "refresh_token",
               "client_id" => "oaiapp_A1"
             }

      assert {:ok, nil} = Registration.read(path)
      refute Map.has_key?(Jason.decode!(File.read!(path))["providers"], "chatgpt")
      assert {:error, {:provider_missing, "chatgpt"}} = Store.read("chatgpt", path)
      assert {:ok, %{tokens: %{access_token: "XAI-AT"}}} = Store.read("xai_oauth", path)
      assert ChatGPT.summary(fermix_path: path) == %{state: :not_connected, account: nil}

      # The host id names this install, not the account, so it stays.
      assert File.read!(HostId.path(path)) == host_file
      assert {:ok, ^host_id} = HostId.fetch_or_create(path)
    end

    test "unconfirmed after the retries forgets it locally and says so", %{path: path} do
      :ok = Store.write("chatgpt", ready(), path)
      test = self()
      sleep = fn ms -> send(test, {:slept, ms}) end

      {result, log} =
        with_log(fn ->
          ChatGPT.logout(
            fermix_path: path,
            req_options: [plug: revoke_plug(503), retry_sleep: sleep]
          )
        end)

      assert result == {:ok, %{revoked: false}}
      assert_received {:revoke, _method, _path, _form}
      assert_received {:revoke, _method, _path, _form}
      assert_received {:revoke, _method, _path, _form}
      refute_received {:revoke, _method, _path, _form}
      assert_received {:slept, 350}
      assert_received {:slept, 700}
      assert {:ok, nil} = Registration.read(path)
      assert log =~ "revoke_not_confirmed"
      refute log =~ "RT-0"
    end

    test "a network failure is retried, then reported unconfirmed", %{path: path} do
      :ok = Store.write("chatgpt", ready(), path)
      down = fn conn -> Req.Test.transport_error(conn, :econnrefused) end

      {result, _log} =
        with_log(fn ->
          ChatGPT.logout(
            fermix_path: path,
            req_options: [plug: down, retry_sleep: fn _ -> :ok end]
          )
        end)

      assert result == {:ok, %{revoked: false}}
      assert {:ok, nil} = Registration.read(path)
    end

    test "a 4xx is not retried and is not confirmation", %{path: path} do
      :ok = Store.write("chatgpt", ready(), path)

      {result, _log} =
        with_log(fn ->
          ChatGPT.logout(fermix_path: path, req_options: [plug: revoke_plug(400)])
        end)

      assert result == {:ok, %{revoked: false}}
      assert_received {:revoke, _method, _path, _form}
      refute_received {:revoke, _method, _path, _form}
      assert {:ok, nil} = Registration.read(path)
    end

    test "with nothing signed in there is nothing to revoke or forget", %{path: path} do
      never = fn _conn -> flunk("nothing to revoke") end

      assert {:ok, %{revoked: true}} =
               ChatGPT.logout(fermix_path: path, req_options: [plug: never])

      refute File.exists?(path)

      # An unfinished sign-in is not a sign-in: it stays for its retry.
      :ok = Store.write("chatgpt", Registration.pending("oaiapp_P"), path)

      assert {:ok, %{revoked: true}} =
               ChatGPT.logout(fermix_path: path, req_options: [plug: never])

      assert {:ok, %{client_id: "oaiapp_P", status: "pending"}} = Registration.read(path)
    end

    test "its locked section ends inside the profile lock's stale threshold" do
      stale_after = Keyword.fetch!(Store.lock_opts(:profile), :stale_after_ms)
      assert Logout.worst_case_ms() + 1_000 < stale_after
    end
  end

  describe "summary/1 and route_status/1" do
    test "no auth file is not connected", %{path: path} do
      assert ChatGPT.summary(fermix_path: path) == %{state: :not_connected, account: nil}
      assert ChatGPT.route_status(fermix_path: path) == {:error, :not_signed_in}
    end

    test "a pending registration is not connected", %{path: path} do
      :ok = Store.write("chatgpt", Registration.pending("oaiapp_P"), path)
      assert ChatGPT.summary(fermix_path: path) == %{state: :not_connected, account: nil}
      assert ChatGPT.route_status(fermix_path: path) == {:error, :not_signed_in}
    end

    test "a signed-in registration with plan usage is connected", %{path: path} do
      :ok = Store.write("chatgpt", ready(), path)

      assert ChatGPT.summary(fermix_path: path) == %{
               state: :connected,
               account: "ada@example.test"
             }

      assert ChatGPT.route_status(fermix_path: path) == :ok
    end

    test "one without the plan scope is plan off", %{path: path} do
      :ok =
        Store.write("chatgpt", ready(%{granted_scopes: ~w(openid email offline_access)}), path)

      assert ChatGPT.summary(fermix_path: path) == %{
               state: :plan_off,
               account: "ada@example.test"
             }

      assert ChatGPT.route_status(fermix_path: path) == {:error, :plan_usage_off}
    end

    test "a quarantined grant needs reconnecting", %{path: path} do
      for status <- ["reauthorization_required", "client_rejected"] do
        :ok = Store.write("chatgpt", ready(%{status: status}), path)

        assert ChatGPT.summary(fermix_path: path) == %{
                 state: :reconnect,
                 account: "ada@example.test"
               }

        assert ChatGPT.route_status(fermix_path: path) == {:error, :reconnect_needed}
      end
    end

    test "a registration with no tokens and no sign-in under way is not connected", %{
      path: path
    } do
      :ok = Store.write("chatgpt", leftover(), path)
      assert ChatGPT.summary(fermix_path: path) == %{state: :not_connected, account: nil}
      assert ChatGPT.route_status(fermix_path: path) == {:error, :not_signed_in}
    end

    test "an unreadable auth file is not connected, and logged", %{path: path} do
      File.write!(path, "{not json")

      {summary, log} = with_log(fn -> ChatGPT.summary(fermix_path: path) end)

      assert summary == %{state: :not_connected, account: nil}
      assert log =~ "could not read the registration"
    end
  end

  describe "failure_sentence/1" do
    test "carries the spec's sentences word for word" do
      assert ChatGPT.failure_sentence(:plan_usage_off) ==
               "You're signed in, but ChatGPT plan usage is off. Turn it on to use your plan in Fermix."

      assert ChatGPT.failure_sentence(:access_denied) == "Sign-in was cancelled in the browser."

      for reason <- [:client_mismatch, :account_mismatch] do
        assert ChatGPT.failure_sentence(reason) ==
                 "The browser returned a different ChatGPT account than the one Fermix is " <>
                   "connected to. Nothing was changed. To use a different account or " <>
                   "workspace, sign out of ChatGPT in Fermix, then sign in again."
      end

      assert ChatGPT.failure_sentence(:revoke_not_confirmed) ==
               "Signed out on this computer, but ChatGPT didn't confirm the disconnect. You can " <>
                 "disconnect Fermix in ChatGPT Settings > Security and login."

      assert ChatGPT.failure_sentence(:reconnect_needed) ==
               "Your ChatGPT connection needs to be renewed. Sign in again."
    end

    test "gives every sign-in failure its own sentence" do
      reasons = [
        :not_signed_in,
        :registration_incomplete,
        :identity_verification_unavailable,
        :invalid_id_token,
        :profile_busy,
        :callback_timeout,
        {:port_in_use, 1455},
        {:token_exchange_failed, "Token exchange failed (400)"},
        :invalid_token_response,
        :missing_code,
        {:authorization_error, "server_error"},
        {:host_id_insecure_permissions, "/h/chatgpt_host.json", 0o644},
        {:host_id_symlink, "/h/chatgpt_host.json"},
        {:host_id_invalid, "/h/chatgpt_host.json"}
      ]

      sentences = Enum.map(reasons, &ChatGPT.failure_sentence/1)

      assert length(Enum.uniq(sentences)) == length(reasons)
      refute Enum.any?(sentences, &String.starts_with?(&1, "ChatGPT sign-in failed ("))
      assert ChatGPT.failure_sentence(:profile_busy) == Store.busy_sentence()
    end

    test "names an unknown reason without ever repeating a token" do
      sentence = ChatGPT.failure_sentence({:surprise, %{"access_token" => "AT-SECRET"}})

      assert sentence =~ "ChatGPT sign-in failed ("
      assert sentence =~ ":surprise"
      refute sentence =~ "AT-SECRET"
    end
  end

  test "login refuses a port that is not one" do
    assert_raise ArgumentError, fn -> ChatGPT.login(port: "1455") end
  end
end
