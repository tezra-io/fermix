defmodule Fermix.CLI.ServiceTest do
  use ExUnit.Case, async: true

  alias Fermix.CLI.Service

  describe "spec/2 (linux)" do
    test "user-scope writes to ~/.config/systemd/user" do
      tmp = mkdir!()
      {:ok, spec} = Service.spec(:user, fixture_opts(:linux, tmp))

      assert spec.os == :linux
      assert spec.scope == :user
      assert spec.linux_unit == "fermix.service"
      assert spec.fermix_home == tmp
      assert String.ends_with?(spec.unit_path, ".config/systemd/user/fermix.service")
    end

    test "system-scope writes to /etc/systemd/system" do
      tmp = mkdir!()
      {:ok, spec} = Service.spec(:system, fixture_opts(:linux, tmp))

      assert spec.unit_path == "/etc/systemd/system/fermix.service"
    end
  end

  describe "spec/2 (darwin)" do
    test "user-scope writes to ~/Library/LaunchAgents" do
      tmp = mkdir!()
      {:ok, spec} = Service.spec(:user, fixture_opts(:darwin, tmp))

      assert spec.os == :darwin
      assert spec.label == "io.tezra.fermix"
      assert String.ends_with?(spec.unit_path, "Library/LaunchAgents/io.tezra.fermix.plist")
    end

    test "system-scope writes to /Library/LaunchDaemons" do
      tmp = mkdir!()
      {:ok, spec} = Service.spec(:system, fixture_opts(:darwin, tmp))

      assert spec.unit_path == "/Library/LaunchDaemons/io.tezra.fermix.plist"
    end
  end

  describe "render_unit/2" do
    test "darwin renders a launchd plist" do
      tmp = mkdir!()
      {:ok, body} = Service.render_unit(:user, fixture_opts(:darwin, tmp))

      assert body =~ "<key>Label</key><string>io.tezra.fermix</string>"
      assert body =~ "<key>FERMIX_HOME</key><string>#{tmp}</string>"
    end

    test "linux renders a systemd unit" do
      tmp = mkdir!()
      {:ok, body} = Service.render_unit(:user, fixture_opts(:linux, tmp))

      assert body =~ "Type=simple"
      assert body =~ "Environment=FERMIX_HOME=#{tmp}"
    end
  end

  describe "spec/2 service_env" do
    test "includes allowlisted observability vars from explicit env, FERMIX_HOME baseline" do
      tmp = mkdir!()

      opts =
        Keyword.put(fixture_opts(:linux, tmp), :env, %{
          "FERMIX_OPIK_ENABLED" => "1",
          "FERMIX_OPIK_BASE_URL" => "http://localhost:5173/api",
          "FERMIX_OPIK_PROJECT" => "fermix",
          "FERMIX_TRACE_CONTENT" => "1"
        })

      {:ok, spec} = Service.spec(:user, opts)

      assert spec.service_env["FERMIX_HOME"] == tmp
      assert spec.service_env["FERMIX_OPIK_ENABLED"] == "1"
      assert spec.service_env["FERMIX_OPIK_BASE_URL"] == "http://localhost:5173/api"
      assert spec.service_env["FERMIX_OPIK_PROJECT"] == "fermix"
      assert spec.service_env["FERMIX_TRACE_CONTENT"] == "1"
    end

    test "never persists FERMIX_OPIK_API_KEY even when present in env" do
      tmp = mkdir!()

      opts =
        Keyword.put(fixture_opts(:linux, tmp), :env, %{
          "FERMIX_OPIK_ENABLED" => "1",
          "FERMIX_OPIK_API_KEY" => "sk-secret"
        })

      {:ok, spec} = Service.spec(:user, opts)

      refute Map.has_key?(spec.service_env, "FERMIX_OPIK_API_KEY")
      assert spec.service_env["FERMIX_OPIK_ENABLED"] == "1"
    end

    test "filters non-allowlisted env keys, keeping only the FERMIX_HOME baseline" do
      tmp = mkdir!()
      opts = Keyword.put(fixture_opts(:linux, tmp), :env, %{"PATH" => "/x", "FOO" => "bar"})
      {:ok, spec} = Service.spec(:user, opts)

      assert Map.keys(spec.service_env) == ["FERMIX_HOME"]
    end

    test "drops blank observability values" do
      tmp = mkdir!()
      opts = Keyword.put(fixture_opts(:linux, tmp), :env, %{"FERMIX_OPIK_ENABLED" => ""})
      {:ok, spec} = Service.spec(:user, opts)

      refute Map.has_key?(spec.service_env, "FERMIX_OPIK_ENABLED")
    end

    test "render_unit carries allowlisted env and omits the api key (darwin)" do
      tmp = mkdir!()

      opts =
        Keyword.put(fixture_opts(:darwin, tmp), :env, %{
          "FERMIX_OPIK_ENABLED" => "1",
          "FERMIX_OPIK_API_KEY" => "sk-secret"
        })

      {:ok, body} = Service.render_unit(:user, opts)

      assert body =~ "<key>FERMIX_OPIK_ENABLED</key><string>1</string>"
      refute body =~ "FERMIX_OPIK_API_KEY"
      refute body =~ "sk-secret"
    end
  end

  describe "installed?/2" do
    test "false when unit-path file is absent" do
      tmp = mkdir!()
      opts = fixture_opts(:linux, tmp) ++ [unit_path: Path.join(tmp, "missing.service")]

      refute Service.installed?(:user, opts)
    end

    test "true once a file exists at unit-path" do
      tmp = mkdir!()
      unit_path = Path.join(tmp, "fermix.service")
      File.write!(unit_path, "stub\n")
      opts = fixture_opts(:linux, tmp) ++ [unit_path: unit_path]

      assert Service.installed?(:user, opts)
    end
  end

  describe "spec/2 fermix_path (Homebrew)" do
    test "rewrites a Homebrew Cellar path to the stable bin symlink" do
      tmp = mkdir!()
      cellar = Path.join([tmp, "Cellar", "fermix", "0.1.0", "bin", "fermix"])
      symlink = Path.join([tmp, "bin", "fermix"])
      File.mkdir_p!(Path.dirname(cellar))
      File.write!(cellar, "stub")
      File.mkdir_p!(Path.dirname(symlink))
      File.write!(symlink, "stub")

      opts = Keyword.put(fixture_opts(:darwin, tmp), :fermix_path, cellar)
      {:ok, spec} = Service.spec(:user, opts)

      assert spec.fermix_path == symlink
    end

    test "keeps the Cellar path when the stable bin symlink is missing" do
      tmp = mkdir!()
      cellar = Path.join([tmp, "Cellar", "fermix", "0.1.0", "bin", "fermix"])
      File.mkdir_p!(Path.dirname(cellar))
      File.write!(cellar, "stub")

      opts = Keyword.put(fixture_opts(:darwin, tmp), :fermix_path, cellar)
      {:ok, spec} = Service.spec(:user, opts)

      assert spec.fermix_path == cellar
    end

    test "leaves a non-Cellar path unchanged" do
      tmp = mkdir!()
      {:ok, spec} = Service.spec(:user, fixture_opts(:darwin, tmp))

      assert spec.fermix_path == Path.join(tmp, "fermix")
    end
  end

  # Explicit empty `:env` keeps tests hermetic — the spec snapshots the process
  # env only when `:env` is absent, and a dev shell already exports
  # FERMIX_OPIK_ENABLED. Tests that exercise env propagation pass `:env` directly.
  defp fixture_opts(os, tmp) do
    [
      os: os,
      fermix_path: Path.join(tmp, "fermix"),
      fermix_home: tmp,
      log_path: Path.join(tmp, "logs/fermix.log"),
      env: %{}
    ]
  end

  defp mkdir! do
    path =
      Path.join(
        System.tmp_dir!(),
        "fermix-service-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit_cleanup(path)
    path
  end

  defp on_exit_cleanup(path) do
    ExUnit.Callbacks.on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(path) end)
  end
end
