defmodule Fermix.CLI.AuthCommandTest do
  use ExUnit.Case, async: false

  alias Fermix.CLI.AuthCommand
  alias FermixCore.Auth.ChatGPT
  alias FermixCore.Auth.Store
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.Wizard
  alias FermixTestSupport.FakeDaemonSocket

  setup do
    dir = Path.join(System.tmp_dir!(), "fermix_auth_cli_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prior = System.get_env("FERMIX_HOME")
    System.put_env("FERMIX_HOME", dir)

    on_exit(fn ->
      case prior do
        nil -> System.delete_env("FERMIX_HOME")
        v -> System.put_env("FERMIX_HOME", v)
      end

      FermixTestSupport.SafeRm.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  # codex is `openai_codex`, which signs in with ChatGPT: status reads the
  # registration's standing, never its tokens.
  describe "auth status" do
    test "reports not-logged-in when the auth file is missing" do
      output = capture_out(fn -> AuthCommand.run(["status"]) end)
      assert output =~ "not logged in (no ChatGPT sign-in in "
    end

    test "prints the ChatGPT account and its state", %{dir: dir} do
      seed_chatgpt(dir)

      output = capture_out(fn -> AuthCommand.run(["status", "--provider", "codex"]) end)

      assert output ==
               "provider: openai_codex (Sign in with ChatGPT)\n" <>
                 "account: owner@example.com\nstate: connected\n"
    end

    test "a sign-in without plan usage says what to turn on", %{dir: dir} do
      seed_chatgpt(dir, granted_scopes: ["openid", "email", "offline_access"])

      output = capture_out(fn -> AuthCommand.run(["status"]) end)
      assert output =~ "state: plan_off\n"
      assert output =~ ChatGPT.failure_sentence(:plan_usage_off)
    end

    # A Codex-client sign-in an older build stored is not read any more.
    test "an old Codex-client entry is not a sign-in", %{dir: dir} do
      seed_old_codex_entry(dir)

      output = capture_out(fn -> AuthCommand.run(["status"]) end)
      assert output =~ "not logged in"
    end
  end

  describe "auth login (codex, Sign in with ChatGPT)" do
    # A host with no browser: the opener fails, the address is printed, and a
    # line typed at the prompt reaches the waiting sign-in as a pasted address.
    test "a pasted address reaches the sign-in when no browser opens" do
      parent = self()
      pasted = "http://127.0.0.1:1455/auth/callback?code=C&state=S"

      login = fn opts ->
        send(parent, {:login_opts, Keyword.delete(opts, :puts)})
        :ok = Keyword.fetch!(opts, :opener).("https://auth.openai.com/api/accounts/authorize?x=1")

        receive do
          {:chatgpt_callback, url} -> send(parent, {:pasted, url})
        after
          2_000 -> flunk("no pasted address reached the sign-in")
        end

        {:ok, %{account: "owner@example.com", plan_usage: :on}}
      end

      seams = [
        login: login,
        read_line: lines(["  #{pasted}  \n"]),
        browser: fn _url -> {:error, {:opener_failed, 3, "no display"}} end,
        live_model: &kept_model/2
      ]

      {status, output} = run_out(["login", "--port", "1455", "--timeout", "30"], seams)

      assert status == 0
      assert_received {:pasted, ^pasted}
      assert_received {:login_opts, opts}
      assert Keyword.fetch!(opts, :port) == 1455
      assert Keyword.fetch!(opts, :timeout_ms) == 30_000

      assert output =~
               "Open this address in a browser to sign in to ChatGPT:\n" <>
                 "  https://auth.openai.com/api/accounts/authorize?x=1\n" <>
                 "Or paste the address your browser ended on:\n"

      assert output =~ "Signed in to ChatGPT as owner@example.com."
    end

    test "--no-browser prints the address and opens nothing" do
      login = fn opts ->
        :ok = Keyword.fetch!(opts, :opener).("https://auth.openai.com/api/accounts/authorize")
        {:ok, %{account: nil, plan_usage: :on}}
      end

      seams = [
        login: login,
        read_line: lines([]),
        browser: fn _url -> flunk("--no-browser must open nothing") end,
        live_model: &kept_model/2
      ]

      {status, output} = run_out(["login", "--provider", "codex", "--no-browser"], seams)

      assert status == 0
      assert output =~ "Open this address in a browser to sign in to ChatGPT:\n"
      assert output =~ "Signed in to ChatGPT. Tokens saved to "
    end

    # The configured model must be one the signed-in account lists, so a
    # terminal sign-in checks it as the wizard and the apps' sign-in do.
    test "a sign-in replaces a model the account does not list, and says so" do
      seams = [
        login: fn _opts -> {:ok, %{account: nil, plan_usage: :on}} end,
        read_line: lines([]),
        browser: fn _url -> :ok end,
        live_model: fn :openai_codex, [] -> {:ok, %{model: "gpt-plan-one", changed?: true}} end
      ]

      {status, output} = run_out(["login"], seams)

      assert status == 0

      assert output =~
               "Default model set to gpt-plan-one, the first one your ChatGPT account lists."
    end

    test "a model listing that fails leaves the sign-in standing and says so" do
      seams = [
        login: fn _opts -> {:ok, %{account: nil, plan_usage: :on}} end,
        read_line: lines([]),
        browser: fn _url -> :ok end,
        live_model: fn :openai_codex, [] -> {:error, "ChatGPT did not answer."} end
      ]

      {status, output} = run_out(["login"], seams)

      assert status == 0
      assert output =~ "The default model was not checked against your ChatGPT account."
      assert output =~ "ChatGPT did not answer."
    end

    test "a sign-in without plan usage fails and says what to turn on" do
      seams = [
        login: fn _opts -> {:ok, %{account: "owner@example.com", plan_usage: :off}} end,
        read_line: lines([])
      ]

      {status, stderr} = run_err(["login"], seams)

      assert status == 1
      assert stderr == "fermix auth: #{ChatGPT.failure_sentence(:plan_usage_off)}\n"
    end

    test "a failed sign-in prints the sign-in's own sentence" do
      seams = [login: fn _opts -> {:error, :access_denied} end, read_line: lines([])]

      {status, stderr} = run_err(["login"], seams)

      assert status == 1
      assert stderr == "fermix auth: login failed: Sign-in was cancelled in the browser.\n"
    end
  end

  describe "auth logout" do
    # ChatGPT's own sign-out: the tokens go, the registration and every other
    # profile stay. With no refresh token there is no session to revoke, so
    # nothing leaves this machine.
    test "clears the ChatGPT tokens, keeps the registration and other providers", %{dir: dir} do
      path = seed_chatgpt(dir, tokens: %{access_token: "AT", refresh_token: nil})

      :ok =
        Store.write(
          "openai",
          %{
            auth_mode: "api_key",
            tokens: %{access_token: "sk-test", refresh_token: nil},
            expires_at: nil,
            last_refresh: nil
          },
          path
        )

      assert {0, output} = run_out(["logout"], [])

      assert output == "Logged out of ChatGPT. Cleared its tokens in #{path}.\n"
      data = path |> File.read!() |> Jason.decode!()
      assert data["providers"]["chatgpt"]["status"] == "signed_out"
      assert data["providers"]["chatgpt"]["client_id"] == "oaiapp_cli"
      assert data["providers"]["chatgpt"]["tokens"]["access_token"] == nil
      assert Map.has_key?(data["providers"], "openai")
      assert {:ok, %{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    test "a revoke OpenAI did not confirm still signs out, and says where to finish", %{
      dir: dir
    } do
      seed_chatgpt(dir)
      seams = [logout: fn [] -> {:ok, %{revoked: false}} end]

      assert {0, output} = run_out(["logout", "--provider", "codex"], seams)
      assert output == ChatGPT.failure_sentence(:revoke_not_confirmed) <> "\n"
    end

    test "a sign-out that fails says so and exits non-zero", %{dir: dir} do
      seed_chatgpt(dir)
      seams = [logout: fn [] -> {:error, :profile_busy} end]

      {status, stderr} = run_err(["logout"], seams)

      assert status == 1
      assert stderr == "fermix auth: logout failed: #{Store.busy_sentence()}\n"
    end

    test "is a no-op when the auth file is missing" do
      seams = [logout: fn [] -> flunk("nothing to sign out of") end]

      output = capture_out(fn -> AuthCommand.run(["logout"], seams) end)
      assert output =~ "Already logged out (no ChatGPT sign-in in "
    end

    # No daemon answers in this home, so the logout is the local one alone.
    # Codex has no auth-mode route, so no restart is asked for.
    test "with no daemon running, the logout and its message are the local ones", %{dir: dir} do
      path = seed_chatgpt(dir)
      seams = [logout: fn [] -> {:ok, %{revoked: true}} end]

      stderr =
        capture_err(fn ->
          output = capture_out(fn -> assert AuthCommand.run(["logout"], seams) == 0 end)

          assert output == "Logged out of ChatGPT. Cleared its tokens in #{path}.\n"
        end)

      assert stderr == ""
    end
  end

  # TOKEN-6: the CLI signs the profile out itself, then tells a running daemon
  # to drop the tokens it still holds for that profile, the way the plugin
  # verbs ask it to re-apply their config. The ChatGPT sign-in lives under
  # the `chatgpt` profile.
  describe "auth logout with a running daemon" do
    setup do
      %{home: FakeDaemonSocket.fermix_home!()}
    end

    test "tells the daemon to forget the signed-out profile", %{home: home} do
      seed_chatgpt(home)
      daemon = FakeDaemonSocket.serve_once(home, %{"status" => "ok"})
      seams = [logout: fn [] -> {:ok, %{revoked: true}} end]

      stderr =
        capture_err(fn ->
          output = capture_out(fn -> assert AuthCommand.run(["logout"], seams) == 0 end)
          assert output =~ "Logged out of ChatGPT."
        end)

      assert_receive {:fake_daemon_request,
                      %{"method" => "auth_forget", "params" => %{"profile" => "chatgpt"}}}

      Task.await(daemon)
      assert stderr =~ "daemon dropped any tokens it held for chatgpt"
    end

    # A previous logout whose daemon call failed leaves the tokens gone and the
    # daemon holding the account; running the logout again must reach it.
    test "tells the daemon even when no sign-in is stored", %{home: home} do
      daemon = FakeDaemonSocket.serve_once(home, %{"status" => "ok"})

      capture_err(fn ->
        output = capture_out(fn -> assert AuthCommand.run(["logout"]) == 0 end)
        assert output =~ "Already logged out"
      end)

      assert_receive {:fake_daemon_request,
                      %{"method" => "auth_forget", "params" => %{"profile" => "chatgpt"}}}

      Task.await(daemon)
    end

    test "a daemon that cannot forget fails the logout loudly, and says the tokens are gone",
         %{home: home} do
      path = seed_chatgpt(home)
      daemon = FakeDaemonSocket.serve_once(home, %{"status" => "error", "reason" => "wedged"})
      seams = [logout: fn [] -> {:ok, %{revoked: true}} end]

      stderr =
        capture_err(fn ->
          capture_out(fn -> assert AuthCommand.run(["logout"], seams) == 1 end)
        end)

      assert_receive {:fake_daemon_request, %{"method" => "auth_forget"}}
      Task.await(daemon)

      assert stderr =~ "fermix auth: cleared the ChatGPT tokens in #{path}"
      assert stderr =~ "the running daemon could not drop its chatgpt tokens: wedged"

      # Production runs the daemon from the macOS app, so the CLI restart is
      # offered only for a daemon the operator runs.
      assert stderr =~
               "Restart the daemon (from the Fermix app, or `fermix restart` for a daemon " <>
                 "you run yourself)."
    end
  end

  describe "auth --provider anthropic" do
    test "login --setup-token stores under the anthropic_oauth profile", %{dir: dir} do
      status =
        capture_out_status(fn ->
          AuthCommand.run(["login", "--provider", "anthropic", "--setup-token", "sk-ant-oat01"])
        end)

      assert status == 0

      {:ok, entry} = Store.read("anthropic_oauth", Path.join(dir, "auth.json"))
      assert entry.auth_mode == "setup_token"
      assert entry.provider == "anthropic"
      assert entry.tokens.access_token == "sk-ant-oat01"

      # Never under an api-key-shaped profile (billing-flip guard, §12 #5).
      assert {:error, {:provider_missing, _}} =
               Store.read("anthropic", Path.join(dir, "auth.json"))
    end

    test "login --setup-token wins over CLAUDE_CODE_OAUTH_TOKEN in the environment", %{dir: dir} do
      prior = System.get_env("CLAUDE_CODE_OAUTH_TOKEN")
      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "env-token")

      on_exit(fn ->
        case prior do
          nil -> System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")
          value -> System.put_env("CLAUDE_CODE_OAUTH_TOKEN", value)
        end
      end)

      assert 0 ==
               capture_out_status(fn ->
                 AuthCommand.run([
                   "login",
                   "--provider",
                   "anthropic",
                   "--setup-token",
                   "flag-token"
                 ])
               end)

      {:ok, entry} = Store.read("anthropic_oauth", Path.join(dir, "auth.json"))
      assert entry.tokens.access_token == "flag-token"
    end

    # A sign-in takes the profile lock with the refreshers' bounded wait, so one
    # that meets another Fermix process refreshing or signing in the account
    # fails in seconds and says to retry, instead of waiting minutes. The test
    # shortens that wait.
    test "login meeting a busy profile fails with the try-again sentence", %{dir: dir} = ctx do
      FermixTestSupport.ProfileLockWait.shorten!(ctx)
      path = Path.join(dir, "auth.json")
      File.write!(Store.profile_lock_path("anthropic_oauth", path), "0 a-refresh\n")
      parent = self()

      login =
        Task.async(fn ->
          capture_err(fn ->
            status =
              AuthCommand.run(["login", "--provider", "anthropic", "--setup-token", "sk-ant-x"])

            send(parent, {:status, status})
          end)
        end)

      assert {:ok, stderr} = Task.yield(login, 15_000) || Task.shutdown(login, :brutal_kill)
      assert_received {:status, 1}

      assert stderr ==
               "fermix auth: anthropic login failed: Another Fermix process is refreshing " <>
                 "or signing in to this account. Try again shortly.\n"

      refute File.exists?(path)
    end

    test "login without any token source errors with guidance" do
      prior = System.get_env("CLAUDE_CODE_OAUTH_TOKEN")
      System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")

      on_exit(fn ->
        if prior, do: System.put_env("CLAUDE_CODE_OAUTH_TOKEN", prior)
      end)

      output = capture_err(fn -> AuthCommand.run(["login", "--provider", "anthropic"]) end)
      assert output =~ "--setup-token"
      assert output =~ "CLAUDE_CODE_OAUTH_TOKEN"
    end

    test "status and logout target the anthropic_oauth profile", %{dir: dir} do
      assert 0 ==
               capture_out_status(fn ->
                 AuthCommand.run([
                   "login",
                   "--provider",
                   "anthropic",
                   "--setup-token",
                   "sk-ant-x"
                 ])
               end)

      status_output =
        capture_out(fn -> AuthCommand.run(["status", "--provider", "anthropic"]) end)

      assert status_output =~ "provider: anthropic_oauth"
      assert status_output =~ "auth_mode: setup_token"

      assert 0 ==
               capture_out_status(fn ->
                 AuthCommand.run(["logout", "--provider", "anthropic"])
               end)

      assert {:error, {:provider_missing, _}} =
               Store.read("anthropic_oauth", Path.join(dir, "auth.json"))
    end

    test "rejects an unknown provider" do
      output =
        capture_err(fn -> AuthCommand.run(["login", "--provider", "gemini"]) end)

      assert output =~ "unknown login provider"
    end
  end

  describe "auth --provider xai" do
    test "status and logout target the xai_oauth profile", %{dir: dir} do
      path = Path.join(dir, "auth.json")

      :ok =
        Store.write(
          "xai_oauth",
          %{
            auth_mode: "oauth_pkce",
            provider: "xai",
            tokens: %{access_token: "xai-at", refresh_token: "xai-rt"},
            expires_at: nil,
            last_refresh: nil
          },
          path
        )

      status_output = capture_out(fn -> AuthCommand.run(["status", "--provider", "xai"]) end)
      assert status_output =~ "provider: xai_oauth"
      assert status_output =~ "auth_mode: oauth_pkce"

      assert 0 == capture_out_status(fn -> AuthCommand.run(["logout", "--provider", "xai"]) end)
      assert {:error, {:provider_missing, _}} = Store.read("xai_oauth", path)
    end
  end

  describe "auth login/logout config route (auth_mode)" do
    test "anthropic login sets config auth_mode to oauth; logout reverts to api_key" do
      assert 0 ==
               capture_out_status(fn ->
                 AuthCommand.run([
                   "login",
                   "--provider",
                   "anthropic",
                   "--setup-token",
                   "sk-ant-oat01"
                 ])
               end)

      assert provider_auth_mode(:anthropic) == :oauth

      output = capture_out(fn -> AuthCommand.run(["logout", "--provider", "anthropic"]) end)

      # The route revert is a config change the daemon reads at start, so the
      # logout says when it lands, and names no CLI restart the app-managed
      # daemon does not take.
      assert output =~ "The auth_mode change reaches the daemon on its next restart.\n"
      refute output =~ "fermix restart"
      assert provider_auth_mode(:anthropic) == :api_key
    end

    test "xai logout reverts config auth_mode to api_key", %{dir: dir} do
      {:ok, _report} = Wizard.set_provider_auth_mode(:xai, :oauth)
      assert provider_auth_mode(:xai) == :oauth

      :ok =
        Store.write(
          "xai_oauth",
          %{
            auth_mode: "oauth_pkce",
            provider: "xai",
            tokens: %{access_token: "xai-at", refresh_token: "xai-rt"},
            expires_at: nil,
            last_refresh: nil
          },
          Path.join(dir, "auth.json")
        )

      assert 0 == capture_out_status(fn -> AuthCommand.run(["logout", "--provider", "xai"]) end)
      assert provider_auth_mode(:xai) == :api_key
    end
  end

  # `fermix auth` runs without the supervision tree, so on an installed binary
  # no command host exists while it runs, and `mix test` always has one. The
  # route save that follows a login or a logout must keep its keychain calls
  # inline or the verb dies with the command host error after the token moved.
  describe "in the tree-less CLI world" do
    setup do
      providers = Application.get_env(:fermix_core, :providers, [])
      writer = Application.get_env(:fermix_core, :secret_writer)
      FermixTestSupport.SecretWriterStub.reset()

      on_exit(fn ->
        Application.put_env(:fermix_core, :providers, providers)
        restore_secret_writer(writer)
        FermixTestSupport.SecretWriterStub.reset()
      end)

      # The home keeps one provider key in the keychain, stored the way the
      # daemon stores one and read back when the verb's VM started.
      Application.put_env(
        :fermix_core,
        :providers,
        Keyword.put(providers, :openai, api_key: "sk-resolved")
      )

      :ok = ConfigStore.save_snapshot(ConfigStore.current_snapshot())

      Application.put_env(:fermix_core, :secret_writer, FermixTestSupport.TreeLessSecretWriter)
      :ok = FermixTestSupport.TreeLessSecretWriter.watch()
    end

    test "login and logout save the route with keychain calls inline" do
      assert 0 ==
               capture_out_status(fn ->
                 AuthCommand.run([
                   "login",
                   "--provider",
                   "anthropic",
                   "--setup-token",
                   "sk-ant-oat01"
                 ])
               end)

      assert_received {:tree_less_keychain, :get, :openai_api_key}
      assert provider_auth_mode(:anthropic) == :oauth

      assert 0 ==
               capture_out_status(fn ->
                 AuthCommand.run(["logout", "--provider", "anthropic"])
               end)

      assert_received {:tree_less_keychain, :get, :openai_api_key}
      assert provider_auth_mode(:anthropic) == :api_key
    end

    # The key could not be read when the verb's VM started, so the environment
    # still holds `@keyring` and the save's apply asks the keychain again.
    test "a key the keychain could not answer at start does not stop the route save" do
      providers = Application.get_env(:fermix_core, :providers, [])

      Application.put_env(
        :fermix_core,
        :providers,
        Keyword.put(providers, :openai, api_key: "@keyring")
      )

      FermixTestSupport.SecretWriterStub.reset()

      assert 0 ==
               capture_out_status(fn ->
                 AuthCommand.run([
                   "login",
                   "--provider",
                   "anthropic",
                   "--setup-token",
                   "sk-ant-oat01"
                 ])
               end)

      assert_received {:tree_less_keychain, :get, :openai_api_key}
      assert provider_auth_mode(:anthropic) == :oauth
    end
  end

  describe "auth (no args)" do
    test "prints usage and returns 2" do
      assert 2 == capture_err_status(fn -> AuthCommand.run([]) end)
    end
  end

  describe "auth (unknown subcommand)" do
    test "rejects" do
      output = capture_err(fn -> AuthCommand.run(["wat"]) end)
      assert output =~ "unknown subcommand: wat"
    end
  end

  # A finished Sign in with ChatGPT under the `chatgpt` profile, plan usage
  # granted unless `overrides` say otherwise.
  defp seed_chatgpt(dir, overrides \\ []) do
    path = Path.join(dir, "auth.json")

    entry =
      Map.merge(
        %{
          auth_mode: "oauth_siwc",
          provider: "chatgpt",
          client_id: "oaiapp_cli",
          subject: "user-cli",
          account: %{email: "owner@example.com"},
          granted_scopes: ["openid", "email", "offline_access", "chatgpt.tokens.use.direct"],
          tokens: %{access_token: "AT", refresh_token: "RT"},
          expires_at: nil,
          last_refresh: nil,
          status: "ready"
        },
        Map.new(overrides)
      )

    :ok = Store.write(Store.profile(:openai_codex), entry, path)
    path
  end

  defp seed_old_codex_entry(dir) do
    File.write!(
      Path.join(dir, "auth.json"),
      Jason.encode!(%{
        "version" => 1,
        "providers" => %{
          "openai_codex" => %{
            "auth_mode" => "chatgpt",
            "tokens" => %{"access_token" => "AT", "refresh_token" => "RT"},
            "expires_at" => future_iso(3600)
          }
        }
      })
    )
  end

  # Answers `lines` in order, then end of input, as standard input would.
  defp lines(lines) do
    {:ok, agent} = Agent.start_link(fn -> lines end)

    fn ->
      Agent.get_and_update(agent, fn
        [] -> {:eof, []}
        [line | rest] -> {line, rest}
      end)
    end
  end

  defp run_out(argv, seams) do
    parent = self()
    output = capture_out(fn -> send(parent, {:status, AuthCommand.run(argv, seams)}) end)
    assert_received {:status, status}
    {status, output}
  end

  defp run_err(argv, seams) do
    parent = self()

    stderr =
      capture_err(fn ->
        capture_out(fn -> send(parent, {:status, AuthCommand.run(argv, seams)}) end)
      end)

    assert_received {:status, status}
    {status, stderr}
  end

  defp future_iso(seconds) do
    DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.to_iso8601()
  end

  # An auth mode is not a secret, so reading it back resolves no keychain item.
  defp provider_auth_mode(provider) do
    {:ok, snapshot} = ConfigStore.load_runtime_config(resolve_secrets: false)

    snapshot.fermix_core
    |> Keyword.get(:providers, [])
    |> Keyword.get(provider, [])
    |> Keyword.get(:auth_mode)
  end

  defp restore_secret_writer(nil), do: Application.delete_env(:fermix_core, :secret_writer)
  defp restore_secret_writer(value), do: Application.put_env(:fermix_core, :secret_writer, value)

  defp kept_model(:openai_codex, []), do: {:ok, %{model: "gpt-plan-one", changed?: false}}

  defp capture_out(fun), do: ExUnit.CaptureIO.capture_io(:stdio, fun)

  defp capture_err(fun), do: ExUnit.CaptureIO.capture_io(:stderr, fun)

  defp capture_out_status(fun) do
    ref = make_ref()
    parent = self()

    ExUnit.CaptureIO.capture_io(:stdio, fn ->
      send(parent, {ref, fun.()})
    end)

    receive do
      {^ref, status} -> status
    after
      1_000 -> flunk("no status returned")
    end
  end

  defp capture_err_status(fun) do
    ref = make_ref()
    parent = self()

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      send(parent, {ref, fun.()})
    end)

    receive do
      {^ref, status} -> status
    after
      1_000 -> flunk("no status returned")
    end
  end
end
