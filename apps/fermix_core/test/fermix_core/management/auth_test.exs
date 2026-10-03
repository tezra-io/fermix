defmodule FermixCore.Management.AuthTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias FermixCore.Auth.ChatGPT
  alias FermixCore.Auth.ClientRejection
  alias FermixCore.Auth.Store
  alias FermixCore.Auth.TokenManager
  alias FermixCore.Management.Auth
  alias FermixCore.Management.Copy
  alias FermixCore.Management.Jobs

  @entry %{
    auth_mode: "chatgpt",
    tokens: %{access_token: "a", refresh_token: "r"},
    expires_at: nil,
    last_refresh: nil,
    account: %{email: "owner@example.com"}
  }

  # What the ChatGPT sign-in answers once plan usage is granted.
  @signed_in %{account: "owner@example.com", plan_usage: :on}
  @kept_model {:ok, %{model: "gpt-test", changed?: false}}

  setup context do
    tasks = :"auth_tasks_#{:erlang.phash2(context.test)}"
    start_supervised!({Task.Supervisor, name: tasks}, id: tasks)

    server =
      start_supervised!(
        {Jobs, name: :"auth_jobs_#{:erlang.phash2(context.test)}", task_supervisor: tasks}
      )

    %{jobs: [server: server]}
  end

  describe "auth.start" do
    test "answers with the authorize url the flow minted, once", %{jobs: jobs} do
      owner = self()

      login = fn opts ->
        :ok = Keyword.fetch!(opts, :opener).("https://auth.example/authorize?state=opaque")
        send(owner, {:opened, self()})

        receive do
          :finish -> {:ok, @signed_in}
        end
      end

      assert {:ok, view} =
               Auth.start("openai_codex",
                 jobs: jobs,
                 login: login,
                 live_model: fn :openai_codex, [] -> @kept_model end,
                 reload: fn -> :ok end,
                 promote: fn _provider -> :ok end
               )

      assert view["authorize_url"] == "https://auth.example/authorize?state=opaque"
      assert view["expires_in_ms"] == Jobs.budget_ms(:auth)
      assert view["kind"] == "auth"
      assert view["status"] == "running"
      assert view["phase"] == "awaiting_browser"

      assert_receive {:opened, pid}

      # Returned once: polling the same job never repeats the url.
      assert {:ok, polled} = Jobs.get(view["job_id"], jobs)
      refute Map.has_key?(polled, "authorize_url")
      refute Map.has_key?(polled, "expires_in_ms")

      send(pid, :finish)
    end

    # The port is bound inside the run, so a flow that cannot bind it answers
    # with the job in its failed state — which is where the sentence lives.
    test "a flow that fails before minting a url answers with the failed job", %{jobs: jobs} do
      login = fn _opts -> {:error, {:port_in_use, 1455}} end

      assert {:ok, view} = Auth.start("openai_codex", jobs: jobs, login: login)

      assert view["status"] == "failed"
      assert view["failure"]["code"] == "unavailable"

      assert view["failure"]["sentence"] ==
               "Port 1455 is already in use, so the sign-in reply could not be received."
    end

    test "a provider with no browser flow is refused by field", %{jobs: jobs} do
      assert {:error, {:invalid_params, "provider", sentence}} =
               Auth.start("anthropic", jobs: jobs)

      assert sentence == "This provider has no browser sign-in."
      assert {:ok, []} = Jobs.list(jobs)
    end

    # A stored token is inert until the route selects it, so the two land
    # together or the job reports a failure.
    test "the xai flow switches the route with the token", %{jobs: jobs} do
      owner = self()

      login = fn opts ->
        :ok = Keyword.fetch!(opts, :opener).("https://x.example/authorize")
        {:ok, @entry}
      end

      route = fn :xai, :oauth ->
        send(owner, :route_switched)
        {:ok, %{}}
      end

      assert {:ok, view} =
               Auth.start("xai",
                 jobs: jobs,
                 login: login,
                 set_auth_mode: route,
                 reload: fn -> :ok end,
                 promote: fn _provider -> :ok end
               )

      assert {:ok, done} = terminal(jobs, view["job_id"])

      assert_receive :route_switched
      assert done["status"] == "completed"
      assert done["result"] == %{"account_label" => "owner@example.com"}
    end

    test "a second sign-in for the same provider is refused as busy", %{jobs: jobs} do
      owner = self()

      login = fn opts ->
        :ok = Keyword.fetch!(opts, :opener).("https://auth.example/authorize")
        send(owner, :opened)

        receive do
          :finish -> {:ok, @signed_in}
        end
      end

      assert {:ok, _first} = Auth.start("openai_codex", jobs: jobs, login: login)
      assert_receive :opened

      assert {:error, {:busy, "auth"}} = Auth.start("openai_codex", jobs: jobs, login: login)
    end

    # `openai_codex` signs in with ChatGPT: its sign-in answers the account and
    # plan usage, the model is checked against the account's own list, and
    # only then is the connection completed and promoted.
    test "openai_codex signs in with ChatGPT, checks the model, then connects", %{jobs: jobs} do
      owner = self()

      login = fn opts ->
        send(owner, {:login, Keyword.keys(opts)})
        :ok = Keyword.fetch!(opts, :opener).("https://auth.openai.com/api/accounts/authorize")
        {:ok, @signed_in}
      end

      live_model = fn provider, opts ->
        send(owner, {:live_model, provider, opts})
        {:ok, %{model: "gpt-test", changed?: true}}
      end

      assert {:ok, view} =
               Auth.start("openai_codex",
                 jobs: jobs,
                 login: login,
                 live_model: live_model,
                 reload: fn -> reply(owner, :reloaded) end,
                 promote: fn provider -> reply(owner, {:promoted, provider}) end
               )

      assert {:ok, done} = terminal(jobs, view["job_id"])
      assert done["status"] == "completed"
      assert done["result"] == %{"account_label" => "owner@example.com"}

      assert_received {:login, keys}
      assert Enum.sort(keys) == [:opener, :puts]
      assert_received {:live_model, :openai_codex, []}
      assert_received :reloaded
      assert_received {:promoted, :openai_codex}
    end

    # The account is connected whether or not its model list could be read, so
    # a listing that failed is logged and the sign-in still completes.
    test "a model list that cannot be read does not fail the sign-in", %{jobs: jobs} do
      owner = self()

      {done, log} =
        with_log(fn ->
          assert {:ok, view} =
                   Auth.start("openai_codex",
                     jobs: jobs,
                     login: fn _opts -> {:ok, @signed_in} end,
                     live_model: fn :openai_codex, [] -> {:error, "No models were listed."} end,
                     reload: fn -> :ok end,
                     promote: fn provider -> reply(owner, {:promoted, provider}) end
                   )

          assert {:ok, done} = terminal(jobs, view["job_id"])
          done
        end)

      assert done["status"] == "completed"
      assert_received {:promoted, :openai_codex}
      assert log =~ "the ChatGPT model list was not read: No models were listed."
    end

    # A grant without plan usage is one the route refuses: no model check, no
    # promotion, and the job says what to turn on.
    test "a ChatGPT sign-in without plan usage is not a connection", %{jobs: jobs} do
      refuse = fn _provider -> flunk("a grant the route refuses must not be promoted") end

      assert {:ok, view} =
               Auth.start("openai_codex",
                 jobs: jobs,
                 login: fn _opts -> {:ok, %{account: "owner@example.com", plan_usage: :off}} end,
                 live_model: fn _provider, _opts -> flunk("no model check without plan usage") end,
                 promote: refuse
               )

      assert {:ok, done} = terminal(jobs, view["job_id"])
      assert done["status"] == "failed"
      assert done["failure"]["sentence"] == ChatGPT.failure_sentence(:plan_usage_off)
    end

    # The sign-in's own refusals are worded once, by `Auth.ChatGPT`.
    test "a ChatGPT refusal fails the job with the sign-in's own sentence", %{jobs: jobs} do
      for reason <- [:access_denied, :account_mismatch, :callback_timeout] do
        assert {:ok, view} =
                 Auth.start("openai_codex", jobs: jobs, login: fn _opts -> {:error, reason} end)

        assert {:ok, done} = terminal(jobs, view["job_id"])
        assert done["status"] == "failed"
        assert done["failure"]["sentence"] == ChatGPT.failure_sentence(reason)
      end
    end

    # The browser half finished and the token request after it got no answer.
    # Logging that reason used to crash the job, so the client saw only "The
    # operation failed inside the daemon." instead of what went wrong.
    test "a sign-in whose provider does not answer in time says so", %{jobs: jobs} do
      done = failed_sign_in(jobs, %Req.TransportError{reason: :timeout})

      assert done["failure"]["code"] == "unavailable"

      assert done["failure"]["sentence"] ==
               "The provider's sign-in server did not answer in time. Check your connection and sign in again."

      assert Copy.violations(done["failure"]["sentence"], :prose) == []
    end

    test "a sign-in that cannot reach its provider says so", %{jobs: jobs} do
      done = failed_sign_in(jobs, %Req.TransportError{reason: :nxdomain})

      assert done["failure"]["code"] == "unavailable"

      assert done["failure"]["sentence"] ==
               "The provider's sign-in server could not be reached. Check your connection and sign in again."

      assert Copy.violations(done["failure"]["sentence"], :prose) == []
    end
  end

  describe "auth.import.start" do
    test "a Claude Code import names the keychain phase it can prompt in", %{jobs: jobs} do
      owner = self()

      importer = fn ->
        send(owner, {:importing, self()})

        receive do
          :finish -> {:ok, @entry}
        end
      end

      assert {:ok, started} =
               Auth.import_start("claude_code",
                 jobs: jobs,
                 importer: importer,
                 set_auth_mode: fn :anthropic, :oauth -> {:ok, %{}} end,
                 reload: fn -> :ok end,
                 promote: fn _provider -> :ok end
               )

      assert started["kind"] == "auth_import"
      assert started["budget_ms"] == Jobs.budget_ms(:auth_import)

      assert_receive {:importing, pid}
      assert {:ok, running} = Jobs.get(started["job_id"], jobs)
      assert running["phase"] == "reading_keychain"

      send(pid, :finish)
      assert {:ok, done} = terminal(jobs, started["job_id"])

      assert done["status"] == "completed"

      assert done["result"] == %{
               "provider" => "anthropic",
               "account_label" => "owner@example.com"
             }
    end

    test "an import with nothing to adopt fails with the daemon's sentence", %{jobs: jobs} do
      importer = fn -> {:error, :not_found} end

      assert {:ok, started} = Auth.import_start("claude_code", jobs: jobs, importer: importer)
      assert {:ok, done} = terminal(jobs, started["job_id"])

      assert done["status"] == "failed"
      assert done["failure"]["sentence"] == "No existing sign-in was found on this Mac."
    end

    # `codex_cli` is still a source the contract names. `openai_codex` signs in
    # with ChatGPT now, so the import is refused by field with the way in,
    # before any job starts.
    test "a Codex CLI import is refused with the sentence that names the way in", %{jobs: jobs} do
      assert {:error, {:invalid_params, "source", sentence}} =
               Auth.import_start("codex_cli", jobs: jobs, importer: fn -> flunk("no import") end)

      assert sentence ==
               "Importing a Codex sign-in is no longer supported. Sign in with ChatGPT instead."

      assert Copy.violations(sentence, :prose) == []
      assert {:ok, []} = Jobs.list(jobs)
    end

    test "an unknown source is refused by field", %{jobs: jobs} do
      assert {:error, {:invalid_params, "source", _sentence}} =
               Auth.import_start("gemini_cli", jobs: jobs)

      assert {:ok, []} = Jobs.list(jobs)
    end
  end

  describe "auth.logout" do
    setup do
      # Every case here injects the live-token drop: the real one reaches the
      # tree-wide `TokenManager`, and invalidating it would sign the rest of the
      # suite out too.
      %{drop: fn _provider, _profile -> :ok end}
    end

    test "forgets the stored session and answers with the restart state", %{drop: drop} do
      owner = self()

      forget = fn "xai_oauth" ->
        send(owner, :forgotten)
        :ok
      end

      assert {:ok, result} =
               Auth.logout("xai",
                 forget: forget,
                 set_auth_mode: fn :xai, :api_key -> {:ok, %{}} end,
                 drop_live_tokens: drop
               )

      assert_receive :forgotten
      assert Map.keys(result) == ["restart"]
      assert %{"required" => _required, "reasons" => _reasons} = result["restart"]
    end

    # The defect this closes: deleting the auth.json entry left the running
    # manager holding the access and refresh tokens, so Fermix kept serving
    # turns as the account the operator had just signed out of, while every
    # surface said signed out.
    test "drops the tokens the running daemon holds" do
      owner = self()

      drop = fn provider, profile ->
        send(owner, {:dropped, provider, profile})
        :ok
      end

      assert {:ok, _result} =
               Auth.logout("xai",
                 forget: fn _profile -> :ok end,
                 set_auth_mode: fn :xai, :api_key -> {:ok, %{}} end,
                 drop_live_tokens: drop
               )

      assert_receive {:dropped, "xai", "xai_oauth"}
    end

    # A stored token is inert until the route selects it, so signing out has to
    # put the route back or the provider stays selected with nothing behind it.
    test "reverts an auth-mode driven route to the key it came from", %{drop: drop} do
      owner = self()

      route = fn :xai, :api_key ->
        send(owner, :reverted)
        {:ok, %{}}
      end

      assert {:ok, _result} =
               Auth.logout("xai",
                 forget: fn "xai_oauth" -> :ok end,
                 set_auth_mode: route,
                 drop_live_tokens: drop
               )

      assert_receive :reverted
    end

    # `openai_codex` signs in with ChatGPT. Deleting its entry would lose the
    # issued client id and leave the session live at OpenAI: its own sign-out
    # revokes and keeps the registration, and it has no route to revert.
    test "openai_codex signs out through ChatGPT's revoking sign-out, never a delete" do
      owner = self()

      logout = fn [] ->
        send(owner, :chatgpt_signed_out)
        {:ok, %{revoked: false}}
      end

      assert {:ok, result} =
               Auth.logout("openai_codex",
                 chatgpt_logout: logout,
                 forget: fn _profile -> flunk("the ChatGPT registration must not be deleted") end,
                 drop_live_tokens: fn _provider, _profile -> flunk("its sign-out drops them") end,
                 set_auth_mode: fn _provider, _mode -> flunk("a single-mode provider") end
               )

      assert_receive :chatgpt_signed_out
      assert Map.keys(result) == ["restart"]
    end

    test "a ChatGPT sign-out that fails is refused" do
      {result, log} =
        with_log(fn ->
          Auth.logout("openai_codex", chatgpt_logout: fn [] -> {:error, :profile_busy} end)
        end)

      assert {:error, {:unavailable, "auth"}} = result
      assert log =~ "the ChatGPT sign-in could not be removed"
    end

    # There is no `chatgpt` provider: its sign-in is `openai_codex`'s.
    test "the retired chatgpt provider has no sign-in to remove" do
      assert {:error, {:invalid_params, "provider", "This daemon has no such provider."}} =
               Auth.logout("chatgpt", chatgpt_logout: fn [] -> flunk("not a provider") end)
    end

    # Forgetting a session that is already gone is the state the caller asked
    # for, not a failure.
    test "signing out twice is not an error", %{drop: drop} do
      route = fn :xai, :api_key -> {:ok, %{}} end

      assert {:ok, _result} =
               Auth.logout("xai",
                 forget: fn _profile -> {:error, :no_auth_file} end,
                 set_auth_mode: route,
                 drop_live_tokens: drop
               )

      assert {:ok, _again} =
               Auth.logout("xai",
                 forget: fn _profile -> {:error, {:provider_missing, "xai_oauth"}} end,
                 set_auth_mode: route,
                 drop_live_tokens: drop
               )
    end

    # TOKEN-4 (tla/specs/token_refresh, check 13): a sign-out during the
    # manager's own refresh was undone when that refresh renamed its rotation
    # after the delete; `forget` only queued behind it. The delete now takes
    # the profile lock, so it waits for the refresh, deletes after it, and
    # `forget` finds the manager idle.
    test "a sign-out waits for the refresh in flight, and sticks" do
      dir = FermixTestSupport.SafeRm.make_tmp_dir!("auth-logout-race")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)
      path = Path.join(dir, "auth.json")
      expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)
      entry = Map.put(%{@entry | expires_at: expires_at}, :provider, "xai")
      :ok = Store.write("xai_oauth", entry, path)
      owner = self()

      plug = fn conn ->
        send(owner, {:in_flight, self()})

        receive do
          :release -> :ok
        end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "new_at",
            "refresh_token" => "new_rt",
            "expires_in" => 3600
          })
        )
      end

      name = :"auth_logout_race_#{System.unique_integer([:positive])}"

      start_supervised!(
        {TokenManager,
         name: name, auth_profile: "xai_oauth", fermix_auth_path: path, req_options: [plug: plug]}
      )

      refresh = Task.async(fn -> TokenManager.refresh(name) end)
      assert_receive {:in_flight, plug_pid}

      forget = fn profile ->
        send(owner, :deleting)
        result = Store.delete_provider(profile, path)
        send(owner, :deleted)
        result
      end

      drop = fn "xai", _profile -> TokenManager.forget(name) end
      route = fn :xai, :api_key -> {:ok, %{}} end

      logout =
        Task.async(fn ->
          Auth.logout("xai", forget: forget, drop_live_tokens: drop, set_auth_mode: route)
        end)

      assert_receive :deleting
      refute_receive :deleted, 300

      send(plug_pid, :release)
      assert {:ok, "new_at"} = Task.await(refresh)
      assert {:ok, _result} = Task.await(logout)
      assert {:error, {:provider_missing, "xai_oauth"}} = Store.read("xai_oauth", path)
      assert {:error, :reauthorization_required} = TokenManager.get_token(name)
    end

    test "a provider with no stored sign-in at all is refused by field" do
      assert {:error, {:invalid_params, "provider", _sentence}} = Auth.logout("ollama")
      assert {:error, {:invalid_params, "provider", _sentence}} = Auth.logout("nope")
    end

    test "an outside edit during the route revert stays its own refusal", %{drop: drop} do
      changed = fn :xai, :api_key -> {:error, {:external_change, ["providers"]}} end

      assert {:error, {:external_change, ["providers"]}} =
               Auth.logout("xai",
                 forget: fn _profile -> :ok end,
                 set_auth_mode: changed,
                 drop_live_tokens: drop
               )
    end
  end

  # A plugin signs in through the same method, addressed by the one prefix the
  # contract publishes. Nothing about its client, scopes or loopback port is
  # repeated here: the flow is `Plugins.Auth`'s and only the job shape is this
  # module's.
  describe "auth.start for a plugin" do
    test "hands back the url the plugin's own flow minted", %{jobs: jobs} do
      owner = self()

      login = fn name, opts ->
        send(owner, {:signing_in, name})
        :ok = Keyword.fetch!(opts, :opener).("https://accounts.example/authorize")

        receive do
          :finish -> {:ok, @entry}
        end
      end

      assert {:ok, view} = Auth.start("plugin:gmail", jobs: jobs, plugin_login: login)

      assert view["kind"] == "auth"
      assert view["phase"] == "awaiting_browser"
      assert view["authorize_url"] == "https://accounts.example/authorize"
      assert_receive {:signing_in, "gmail"}
    end

    test "a name this daemon has never heard of is refused", %{jobs: jobs} do
      assert {:error, {:invalid_params, "provider", sentence}} =
               Auth.start("plugin:nope", jobs: jobs)

      assert sentence == "This daemon has no plugin by that name."
    end

    # The app used to collapse this into "See the daemon log", which is where
    # the operator could not look. The provider refusing the saved sign-in client
    # has a fix the sentence can name.
    test "a refused sign-in client fails the job with the sentence that names the fix", %{
      jobs: jobs
    } do
      detail = %{
        provider: "google",
        provider_name: "Google",
        status: 401,
        error: "invalid_client",
        description: "Unauthorized"
      }

      login = fn _name, _opts -> {:error, {:oauth_client_rejected, detail}} end

      assert {:ok, view} = Auth.start("plugin:gmail", jobs: jobs, plugin_login: login)
      assert {:ok, done} = terminal(jobs, view["job_id"])

      assert done["status"] == "failed"
      assert done["failure"]["code"] == "unavailable"
      assert done["failure"]["sentence"] == ClientRejection.sentence(detail)
      refute done["failure"]["sentence"] =~ "daemon log"
    end

    test "one sign-in per plugin at a time", %{jobs: jobs} do
      owner = self()

      # The first flow blocks until this test releases it, so the single-flight
      # refusal is asserted against a server that is provably still busy. A
      # sleeping flow would finish first under load and answer :ok instead.
      login = fn _name, opts ->
        :ok = Keyword.fetch!(opts, :opener).("https://accounts.example/authorize")
        send(owner, {:signing_in, self()})

        receive do
          :finish -> {:ok, @entry}
        end
      end

      assert {:ok, _view} = Auth.start("plugin:gmail", jobs: jobs, plugin_login: login)
      assert_receive {:signing_in, pid}

      assert {:error, {:busy, "auth"}} =
               Auth.start("plugin:gmail", jobs: jobs, plugin_login: login)

      send(pid, :finish)
    end
  end

  test "the published flow and source catalogs are closed" do
    assert Auth.browser_flows() == ~w(openai_codex xai)
    assert Auth.import_sources() == ~w(claude_code codex_cli)
    assert Auth.plugin_prefix() == "plugin:"
  end

  # A ChatGPT sign-in whose browser half finished and whose token request then
  # failed with `reason`, followed to its terminal view.
  defp failed_sign_in(jobs, reason) do
    login = fn opts ->
      :ok = Keyword.fetch!(opts, :opener).("https://auth.example/authorize")
      {:error, reason}
    end

    assert {:ok, view} = Auth.start("openai_codex", jobs: jobs, login: login)
    assert {:ok, done} = terminal(jobs, view["job_id"])
    assert done["status"] == "failed"
    done
  end

  defp reply(owner, message) do
    send(owner, message)
    :ok
  end

  defp terminal(jobs, job_id, attempts \\ 200)
  defp terminal(_jobs, job_id, 0), do: {:error, {:never_terminal, job_id}}

  defp terminal(jobs, job_id, attempts) do
    {:ok, view} = Jobs.get(job_id, jobs)

    if view["status"] == "running" do
      Process.sleep(10)
      terminal(jobs, job_id, attempts - 1)
    else
      {:ok, view}
    end
  end
end
