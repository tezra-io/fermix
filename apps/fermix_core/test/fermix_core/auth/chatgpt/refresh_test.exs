defmodule FermixCore.Auth.ChatGPT.RefreshTest do
  # The `chatgpt` refresh (M57 §4.3) on both refresh paths: the supervised
  # TokenManager and the tree-less `TokenSupervisor.refresh_entry/3`. Sync: the
  # tree-less path reads `Store.path/0`, so the test points FERMIX_HOME at its
  # own home and restores it.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias FermixCore.Auth.ChatGPT
  alias FermixCore.Auth.ChatGPT.Refresh
  alias FermixCore.Auth.Store
  alias FermixCore.Auth.TokenManager
  alias FermixCore.Auth.TokenSupervisor
  alias FermixTestSupport.SafeRm

  @full_scope ~w(chatgpt.tokens.use.direct email offline_access openid profile resource.invoke)
  @terminal ~w(invalid_grant invalid_refresh_token token_expired refresh_token_expired
               refresh_token_invalidated refresh_token_reused)

  setup do
    home = SafeRm.make_tmp_dir!("chatgpt-refresh")
    prior = System.get_env("FERMIX_HOME")
    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      if prior, do: System.put_env("FERMIX_HOME", prior), else: System.delete_env("FERMIX_HOME")
      SafeRm.rm_rf!(home)
    end)

    %{path: Path.join(home, "auth.json")}
  end

  defp entry(overrides) do
    Map.merge(
      %{
        auth_mode: "oauth_siwc",
        provider: "chatgpt",
        client_id: "oaiapp_A1",
        subject: "user-sub-1",
        account: %{email: "ada@example.test"},
        granted_scopes: @full_scope,
        tokens: %{access_token: "AT-0", refresh_token: "RT-0"},
        expires_at: DateTime.add(DateTime.utc_now(), 5, :second),
        last_refresh: nil,
        status: "ready"
      },
      overrides
    )
  end

  defp stored(path, overrides \\ %{}) do
    :ok = Store.write("chatgpt", entry(overrides), path)
    {:ok, entry} = Store.read("chatgpt", path)
    entry
  end

  defp answering(status, body, test \\ self()) do
    fn conn ->
      {:ok, form, conn} = Plug.Conn.read_body(conn)
      send(test, {:refresh_form, conn.request_path, URI.decode_query(form)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end
  end

  defp rotated(extra \\ %{}) do
    Map.merge(
      %{"access_token" => "AT-1", "refresh_token" => "RT-1", "expires_in" => 3_600},
      extra
    )
  end

  defp never_called, do: fn _conn -> flunk("no refresh request may be sent") end

  describe "a refresh" do
    test "sends the stored client, the resource and no scope, and stores the rotation", %{
      path: path
    } do
      entry = stored(path)
      at = DateTime.utc_now() |> DateTime.add(1_800, :second) |> DateTime.truncate(:second)
      plug = answering(200, rotated(%{"earliest_refresh_at" => DateTime.to_iso8601(at)}))

      assert {:ok, refreshed} = Refresh.refresh_entry("chatgpt", entry, path, plug: plug)

      assert_received {:refresh_form, "/api/accounts/oauth/token", form}

      assert form == %{
               "grant_type" => "refresh_token",
               "client_id" => "oaiapp_A1",
               "refresh_token" => "RT-0",
               "resource" => "https://api.openai.com/v1"
             }

      assert refreshed.tokens == %{access_token: "AT-1", refresh_token: "RT-1"}

      assert {:ok, on_disk} = Store.read("chatgpt", path)
      assert on_disk.tokens == %{access_token: "AT-1", refresh_token: "RT-1"}
      assert on_disk.earliest_refresh_at == at
      assert on_disk.granted_scopes == @full_scope
      assert on_disk.client_id == "oaiapp_A1"
      assert on_disk.subject == "user-sub-1"
      assert DateTime.diff(on_disk.expires_at, DateTime.utc_now()) > 3_500
    end

    test "takes a granted scope and Unix-seconds earliest_refresh_at from the answer", %{
      path: path
    } do
      entry = stored(path)
      at = System.system_time(:second) + 900
      plug = answering(200, rotated(%{"scope" => "openid email", "earliest_refresh_at" => at}))

      assert {:ok, _refreshed} = Refresh.refresh_entry("chatgpt", entry, path, plug: plug)

      assert {:ok, on_disk} = Store.read("chatgpt", path)
      assert on_disk.granted_scopes == ["openid", "email"]
      assert on_disk.earliest_refresh_at == DateTime.from_unix!(at)
      assert ChatGPT.route_status(fermix_path: path) == {:error, :plan_usage_off}
    end

    test "an answer without earliest_refresh_at clears the old one", %{path: path} do
      past = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)
      entry = stored(path, %{earliest_refresh_at: past})

      assert {:ok, _refreshed} =
               Refresh.refresh_entry("chatgpt", entry, path, plug: answering(200, rotated()))

      assert {:ok, %{earliest_refresh_at: nil}} = Store.read("chatgpt", path)
    end

    test "an ID token naming the same account is accepted", %{path: path} do
      entry = stored(path)
      plug = answering(200, rotated(%{"id_token" => unsigned_id_token("user-sub-1")}))

      assert {:ok, %{tokens: %{access_token: "AT-1"}}} =
               Refresh.refresh_entry("chatgpt", entry, path, plug: plug)
    end

    test "an ID token naming another account needs a new sign-in and stores nothing", %{
      path: path
    } do
      entry = stored(path)
      plug = answering(200, rotated(%{"id_token" => unsigned_id_token("user-sub-OTHER")}))

      {result, _log} =
        with_log(fn -> Refresh.refresh_entry("chatgpt", entry, path, plug: plug) end)

      assert result == {:error, {:reconnect_needed, :account_mismatch}}
      assert {:ok, %{tokens: %{access_token: "AT-0"}}} = Store.read("chatgpt", path)
    end
  end

  describe "earliest_refresh_at" do
    test "before it, an unexpired token is served as it is and nothing is sent", %{path: path} do
      later = DateTime.add(DateTime.utc_now(), 600, :second)
      entry = stored(path, %{earliest_refresh_at: later})

      assert {:ok, %{tokens: %{access_token: "AT-0"}}} =
               Refresh.refresh_entry("chatgpt", entry, path, plug: never_called())
    end

    test "before it, an expired token is not ready to refresh", %{path: path} do
      later = DateTime.add(DateTime.utc_now(), 600, :second)

      entry =
        stored(path, %{
          earliest_refresh_at: later,
          expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
        })

      {result, _log} =
        with_log(fn -> Refresh.refresh_entry("chatgpt", entry, path, plug: never_called()) end)

      assert result == {:error, :refresh_not_ready}
    end

    test "an unreadable value is refused, and the old token set kept", %{path: path} do
      entry = stored(path)
      plug = answering(200, rotated(%{"earliest_refresh_at" => "soon"}))

      {result, _log} =
        with_log(fn -> Refresh.refresh_entry("chatgpt", entry, path, plug: plug) end)

      assert result == {:error, :invalid_token_response}
      assert {:ok, %{tokens: %{access_token: "AT-0"}}} = Store.read("chatgpt", path)
    end
  end

  describe "a refused refresh" do
    for code <- @terminal do
      test "#{code} needs a new sign-in and keeps nothing new", %{path: path} do
        entry = stored(path)
        plug = answering(400, %{"error" => unquote(code)})

        {result, _log} =
          with_log(fn -> Refresh.refresh_entry("chatgpt", entry, path, plug: plug) end)

        assert result == {:error, {:reconnect_needed, unquote(code)}}
        assert {:ok, %{tokens: %{access_token: "AT-0"}}} = Store.read("chatgpt", path)
      end
    end

    test "another 4xx keeps the tokens and names the code", %{path: path} do
      entry = stored(path)
      plug = answering(400, %{"error" => "invalid_client"})

      {result, _log} =
        with_log(fn -> Refresh.refresh_entry("chatgpt", entry, path, plug: plug) end)

      assert result == {:error, {:refresh_refused, 400, "invalid_client"}}

      assert {:ok, %{tokens: %{access_token: "AT-0"}, status: "ready"}} =
               Store.read("chatgpt", path)
    end

    test "5xx and network failures keep the tokens after bounded retries", %{path: path} do
      entry = stored(path)
      test = self()
      sleep = fn ms -> send(test, {:slept, ms}) end

      for plug <- [
            answering(503, %{"error" => "unavailable"}),
            fn conn -> Req.Test.transport_error(conn, :econnrefused) end
          ] do
        {result, _log} =
          with_log(fn ->
            Refresh.refresh_entry("chatgpt", entry, path, plug: plug, retry_sleep: sleep)
          end)

        assert {:error, _transient} = result
        refute match?({:error, {:reconnect_needed, _}}, result)
        assert_received {:slept, 350}
        assert_received {:slept, 700}
      end

      assert {:ok, %{tokens: %{access_token: "AT-0"}, status: "ready"}} =
               Store.read("chatgpt", path)
    end
  end

  describe "the tree-less refresh path" do
    test "records a terminal refusal as reconnect needed", %{path: path} do
      entry = stored(path)

      {result, _log} =
        with_log(fn ->
          TokenSupervisor.refresh_entry("chatgpt", entry,
            plug: answering(400, %{"error" => "refresh_token_reused"})
          )
        end)

      assert result == {:error, :reauthorization_required}
      assert {:ok, %{status: "reauthorization_required"}} = Store.read("chatgpt", path)

      assert ChatGPT.summary(fermix_path: path) == %{
               state: :reconnect,
               account: "ada@example.test"
             }

      assert ChatGPT.route_status(fermix_path: path) == {:error, :reconnect_needed}
    end

    test "refreshes and persists a due token", %{path: path} do
      entry = stored(path)

      assert {:ok, %{tokens: %{access_token: "AT-1"}}} =
               TokenSupervisor.refresh_entry("chatgpt", entry, plug: answering(200, rotated()))

      assert {:ok, %{tokens: %{access_token: "AT-1"}}} = Store.read("chatgpt", path)
    end
  end

  describe "the supervised manager" do
    defp start_manager(path, plug, opts \\ []) do
      name = :"chatgpt_tm_#{System.unique_integer([:positive])}"

      start_supervised!(
        {TokenManager,
         [name: name, auth_profile: "chatgpt", fermix_auth_path: path, req_options: [plug: plug]] ++
           opts}
      )

      name
    end

    test "rotates on refresh and refuses for good after a terminal code", %{path: path} do
      stored(path)
      {:ok, agent} = Agent.start_link(fn -> answering(200, rotated()) end)
      server = start_manager(path, fn conn -> Agent.get(agent, & &1).(conn) end)

      assert {:ok, "AT-1"} = TokenManager.refresh(server)
      assert {:ok, %{tokens: %{refresh_token: "RT-1"}}} = Store.read("chatgpt", path)

      Agent.update(agent, fn _plug -> answering(400, %{"error" => "invalid_grant"}) end)
      {result, _log} = with_log(fn -> TokenManager.refresh(server) end)

      assert result == {:error, :reauthorization_required}
      assert {:error, :reauthorization_required} = TokenManager.get_token(server)
      assert {:ok, %{status: "reauthorization_required"}} = Store.read("chatgpt", path)
    end

    test "drops its tokens when the stored registration was signed out", %{path: path} do
      entry = stored(path)
      server = start_manager(path, never_called())
      :ok = Store.write("chatgpt", ChatGPT.Registration.signed_out(entry), path)

      {result, _log} = with_log(fn -> TokenManager.refresh(server) end)

      assert result == {:error, :reauthorization_required}
      assert {:ok, %{loaded?: false}} = TokenManager.status(server)
    end

    test "arms its proactive refresh no earlier than earliest_refresh_at", %{path: path} do
      now = DateTime.utc_now()

      stored(path, %{
        expires_at: DateTime.add(now, 20 * 60, :second),
        earliest_refresh_at: DateTime.add(now, 18 * 60, :second)
      })

      server = start_manager(path, never_called())
      timer = :sys.get_state(server).refresh_timer

      assert Process.read_timer(timer) > 17 * 60 * 1_000
    end
  end

  defp unsigned_id_token(sub) do
    header = Base.url_encode64(~s({"alg":"RS256","kid":"kid-1"}), padding: false)
    claims = Base.url_encode64(Jason.encode!(%{"sub" => sub}), padding: false)
    header <> "." <> claims <> "." <> Base.url_encode64("sig", padding: false)
  end
end
