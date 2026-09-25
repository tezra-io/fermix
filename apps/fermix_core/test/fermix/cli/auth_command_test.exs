defmodule Fermix.CLI.AuthCommandTest do
  use ExUnit.Case, async: false

  alias Fermix.CLI.AuthCommand
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

  describe "auth status" do
    test "reports not-logged-in when the auth file is missing" do
      output = capture_out(fn -> AuthCommand.run(["status"]) end)
      assert output =~ "not logged in"
    end

    test "prints stored entry fields when present", %{dir: dir} do
      seed_codex_entry(dir, "AT", "RT", future_iso(3600))

      output = capture_out(fn -> AuthCommand.run(["status"]) end)
      assert output =~ "provider: openai_codex"
      assert output =~ "auth_mode: chatgpt"
      assert output =~ "expires_at: "
    end
  end

  describe "auth logout" do
    test "removes the openai_codex entry but keeps other providers", %{dir: dir} do
      seed_full_doc(dir)

      assert 0 == capture_out_status(fn -> AuthCommand.run(["logout"]) end)

      path = Path.join(dir, "auth.json")
      data = path |> File.read!() |> Jason.decode!()
      refute Map.has_key?(data["providers"], "openai_codex")
      assert Map.has_key?(data["providers"], "openai")
      assert {:ok, %{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    test "is a no-op when the auth file is missing" do
      output = capture_out(fn -> AuthCommand.run(["logout"]) end)
      assert output =~ "Already logged out"
    end

    # No daemon answers in this home, so the logout is the local one alone. Codex
    # has no auth-mode route, so nothing waits for a daemon restart and no
    # restart is asked for.
    test "with no daemon running, the logout and its message are the local ones", %{dir: dir} do
      seed_codex_entry(dir, "AT", "RT", future_iso(3600))
      path = Path.join(dir, "auth.json")

      stderr =
        capture_err(fn ->
          output = capture_out(fn -> assert AuthCommand.run(["logout"]) == 0 end)

          assert output == "Logged out. Removed openai_codex entry from #{path}.\n"
        end)

      assert stderr == ""
      assert {:error, {:provider_missing, _}} = Store.read(:openai_codex, path)
    end
  end

  # TOKEN-6: the CLI deletes the entry itself, then tells a running daemon to
  # drop the tokens it still holds for that profile, the way the plugin verbs
  # ask it to re-apply their config.
  describe "auth logout with a running daemon" do
    setup do
      %{home: FakeDaemonSocket.fermix_home!()}
    end

    test "tells the daemon to forget the signed-out profile", %{home: home} do
      seed_codex_entry(home, "AT", "RT", future_iso(3600))
      daemon = FakeDaemonSocket.serve_once(home, %{"status" => "ok"})

      stderr =
        capture_err(fn ->
          output = capture_out(fn -> assert AuthCommand.run(["logout"]) == 0 end)
          assert output =~ "Logged out. Removed openai_codex entry"
        end)

      assert_receive {:fake_daemon_request,
                      %{"method" => "auth_forget", "params" => %{"profile" => "openai_codex"}}}

      Task.await(daemon)
      assert stderr =~ "daemon dropped any tokens it held for openai_codex"
      assert {:error, {:provider_missing, _}} = Store.read(:openai_codex)
    end

    # A previous logout whose daemon call failed leaves the entry gone and the
    # daemon holding the account; running the logout again must reach it.
    test "tells the daemon even when the entry is already gone", %{home: home} do
      daemon = FakeDaemonSocket.serve_once(home, %{"status" => "ok"})

      capture_err(fn ->
        output = capture_out(fn -> assert AuthCommand.run(["logout"]) == 0 end)
        assert output =~ "Already logged out"
      end)

      assert_receive {:fake_daemon_request,
                      %{"method" => "auth_forget", "params" => %{"profile" => "openai_codex"}}}

      Task.await(daemon)
    end

    test "a daemon that cannot forget fails the logout loudly, and says the entry is gone",
         %{home: home} do
      seed_codex_entry(home, "AT", "RT", future_iso(3600))
      path = Path.join(home, "auth.json")
      daemon = FakeDaemonSocket.serve_once(home, %{"status" => "error", "reason" => "wedged"})

      stderr =
        capture_err(fn ->
          capture_out(fn -> assert AuthCommand.run(["logout"]) == 1 end)
        end)

      assert_receive {:fake_daemon_request, %{"method" => "auth_forget"}}
      Task.await(daemon)

      assert stderr =~ "fermix auth: removed the openai_codex entry from #{path}"
      assert stderr =~ "the running daemon could not drop its openai_codex tokens: wedged"

      # Production runs the daemon from the macOS app, so the CLI restart is
      # offered only for a daemon the operator runs.
      assert stderr =~
               "Restart the daemon (from the Fermix app, or `fermix restart` for a daemon " <>
                 "you run yourself)."

      assert {:error, {:provider_missing, _}} = Store.read(:openai_codex, path)
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
    # fails in seconds and says to retry, instead of waiting minutes.
    test "login meeting a busy profile fails with the try-again sentence", %{dir: dir} do
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

  defp seed_codex_entry(dir, access, refresh, expires_iso) do
    path = Path.join(dir, "auth.json")

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "providers" => %{
          "openai_codex" => %{
            "auth_mode" => "chatgpt",
            "tokens" => %{"access_token" => access, "refresh_token" => refresh},
            "expires_at" => expires_iso,
            "last_refresh" => future_iso(0)
          }
        }
      })
    )

    {:ok, _} = Store.read(:openai_codex, path)
    path
  end

  defp seed_full_doc(dir) do
    File.write!(
      Path.join(dir, "auth.json"),
      Jason.encode!(%{
        "version" => 1,
        "providers" => %{
          "openai" => %{
            "auth_mode" => "api_key",
            "tokens" => %{"access_token" => "sk-test", "refresh_token" => nil}
          },
          "openai_codex" => %{
            "auth_mode" => "chatgpt",
            "tokens" => %{"access_token" => "AT", "refresh_token" => "RT"},
            "expires_at" => future_iso(3600)
          }
        }
      })
    )
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
