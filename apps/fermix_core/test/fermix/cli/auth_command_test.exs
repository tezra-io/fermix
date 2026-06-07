defmodule Fermix.CLI.AuthCommandTest do
  use ExUnit.Case, async: false

  alias Fermix.CLI.AuthCommand
  alias FermixCore.Auth.Store
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.Wizard

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

      assert 0 ==
               capture_out_status(fn ->
                 AuthCommand.run(["logout", "--provider", "anthropic"])
               end)

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

  defp provider_auth_mode(provider) do
    {:ok, snapshot} = ConfigStore.load_runtime_config()

    snapshot.fermix_core
    |> Keyword.get(:providers, [])
    |> Keyword.get(provider, [])
    |> Keyword.get(:auth_mode)
  end

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
