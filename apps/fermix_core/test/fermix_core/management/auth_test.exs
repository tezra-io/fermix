defmodule FermixCore.Management.AuthTest do
  use ExUnit.Case, async: true

  alias FermixCore.Management.Auth
  alias FermixCore.Management.Jobs

  @entry %{
    auth_mode: "chatgpt",
    tokens: %{access_token: "a", refresh_token: "r"},
    expires_at: nil,
    last_refresh: nil,
    account: %{email: "owner@example.com"}
  }

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
        :ok = Keyword.fetch!(opts, :oauth_opener).("https://auth.example/authorize?state=opaque")
        send(owner, {:opened, self()})

        receive do
          :finish -> {:ok, @entry}
        end
      end

      assert {:ok, view} =
               Auth.start("openai_codex",
                 jobs: jobs,
                 login: login,
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
        :ok = Keyword.fetch!(opts, :oauth_opener).("https://auth.example/authorize")
        send(owner, :opened)

        receive do
          :finish -> {:ok, @entry}
        end
      end

      assert {:ok, _first} = Auth.start("openai_codex", jobs: jobs, login: login)
      assert_receive :opened

      assert {:error, {:busy, "auth"}} = Auth.start("openai_codex", jobs: jobs, login: login)
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

    test "a Codex import reports the provider it adopted", %{jobs: jobs} do
      importer = fn -> {:ok, Map.delete(@entry, :account)} end

      assert {:ok, started} =
               Auth.import_start("codex_cli",
                 jobs: jobs,
                 importer: importer,
                 reload: fn -> :ok end,
                 promote: fn _provider -> :ok end
               )

      assert {:ok, done} = terminal(jobs, started["job_id"])

      assert done["result"] == %{"provider" => "openai_codex", "account_label" => nil}
    end

    test "an import with nothing to adopt fails with the daemon's sentence", %{jobs: jobs} do
      importer = fn -> {:error, :not_found} end

      assert {:ok, started} = Auth.import_start("claude_code", jobs: jobs, importer: importer)
      assert {:ok, done} = terminal(jobs, started["job_id"])

      assert done["status"] == "failed"
      assert done["failure"]["sentence"] == "No existing sign-in was found on this Mac."
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

      forget = fn "openai_codex" ->
        send(owner, :forgotten)
        :ok
      end

      assert {:ok, result} = Auth.logout("openai_codex", forget: forget, drop_live_tokens: drop)
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

    test "a single-mode provider has no route to revert", %{drop: drop} do
      route = fn _provider, _mode -> flunk("a single-mode provider has no route to revert") end

      assert {:ok, _result} =
               Auth.logout("openai_codex",
                 forget: fn _profile -> :ok end,
                 set_auth_mode: route,
                 drop_live_tokens: drop
               )
    end

    # Forgetting a session that is already gone is the state the caller asked
    # for, not a failure.
    test "signing out twice is not an error", %{drop: drop} do
      assert {:ok, _result} =
               Auth.logout("openai_codex",
                 forget: fn _profile -> {:error, :no_auth_file} end,
                 drop_live_tokens: drop
               )

      assert {:ok, _again} =
               Auth.logout("openai_codex",
                 forget: fn _profile -> {:error, {:provider_missing, "openai_codex"}} end,
                 drop_live_tokens: drop
               )
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
