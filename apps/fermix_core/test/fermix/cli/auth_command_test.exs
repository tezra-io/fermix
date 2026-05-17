defmodule Fermix.CLI.AuthCommandTest do
  use ExUnit.Case, async: false

  alias Fermix.CLI.AuthCommand
  alias FermixCore.Auth.Store

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
