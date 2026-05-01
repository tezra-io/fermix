defmodule Fermix.CLI.Doctor.ChecksTest do
  use ExUnit.Case, async: false

  alias Fermix.CLI.Doctor.Checks

  describe "workspace_layout/0" do
    test "ok when FERMIX_HOME directories exist" do
      result = Checks.workspace_layout()
      assert result.name == "workspace"
      assert result.status in [:ok, :warn]
      assert is_binary(result.detail)
    end
  end

  describe "service_unit/0" do
    test "warns when no unit is installed (test environment has none)" do
      result = Checks.service_unit()
      assert result.name == "service unit"
      assert result.status in [:ok, :warn]
    end
  end

  describe "daemon_socket/0" do
    test "warns when nothing is listening" do
      result = Checks.daemon_socket()
      assert result.name == "daemon socket"
      assert result.status in [:ok, :warn, :fail]
    end
  end

  describe "recent_log_activity/0" do
    test "returns a result map regardless of log presence" do
      result = Checks.recent_log_activity()
      assert result.name == "log activity"
      assert result.status in [:ok, :warn, :fail]
    end
  end

  describe "binary_integrity/1" do
    test "warns when fermix is not on PATH and no path is supplied" do
      result =
        Checks.binary_integrity(
          binary_path: "/definitely/does/not/exist/fermix",
          target: {:linux, :x86_64}
        )

      assert result.name == "binary integrity"
      assert result.status == :fail
      assert result.detail =~ "missing"
    end

    test "fails on sha mismatch against the manifest" do
      tmp = make_tmp_binary("not the real binary content")

      result =
        Checks.binary_integrity(
          binary_path: tmp,
          target: {:linux, :x86_64},
          req_options: [plug: &__MODULE__.bad_sha_manifest_plug/1]
        )

      assert result.status == :fail
      assert result.detail =~ "sha mismatch"
      File.rm(tmp)
    end

    test "ok on sha match" do
      blob = "exact-binary-content"
      sha = :sha256 |> :crypto.hash(blob) |> Base.encode16(case: :lower)
      tmp = make_tmp_binary(blob)

      Process.put({__MODULE__, :sha}, sha)

      result =
        Checks.binary_integrity(
          binary_path: tmp,
          target: {:linux, :x86_64},
          req_options: [plug: &__MODULE__.matching_sha_manifest_plug/1]
        )

      assert result.status == :ok
      assert result.detail =~ "matches"
      File.rm(tmp)
    end
  end

  describe "upgrade_available?/1" do
    test "warns when a newer version exists" do
      result =
        Checks.upgrade_available?(req_options: [plug: &__MODULE__.future_manifest_plug/1])

      assert result.name == "upgrade"
      assert result.status == :warn
      assert result.detail =~ "available"
    end
  end

  describe "auth_probe/1" do
    setup do
      original_providers = Application.get_env(:fermix_core, :providers, [])
      original_agent = Application.get_env(:fermix_core, :agent, [])

      on_exit(fn ->
        Application.put_env(:fermix_core, :providers, original_providers)
        Application.put_env(:fermix_core, :agent, original_agent)
      end)

      :ok
    end

    test "ok on probe pass" do
      Application.put_env(:fermix_core, :providers,
        openai: [api_key: "sk-test", default_model: "gpt-5.5"]
      )

      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai)

      plug = fn conn -> Plug.Conn.send_resp(conn, 200, "{}") end
      result = Checks.auth_probe(req_options: [plug: plug])

      assert result.name == "auth probe"
      assert result.status == :ok
      assert result.detail =~ "openai/gpt-5.5"
    end

    test "fail on auth_scope_mismatch" do
      Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-bad"])
      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai)

      plug = fn conn -> Plug.Conn.send_resp(conn, 401, "{}") end
      result = Checks.auth_probe(req_options: [plug: plug])

      assert result.status == :fail
      assert result.detail =~ "api.openai.com"
    end

    test "warn on misconfigured provider" do
      Application.put_env(:fermix_core, :providers, openai: [])
      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai)

      result = Checks.auth_probe()
      assert result.status == :warn
      assert result.detail =~ "api_key"
    end

    test "warn on transient 5xx" do
      Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-test"])
      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai)

      plug = fn conn -> Plug.Conn.send_resp(conn, 503, "service unavailable") end
      result = Checks.auth_probe(req_options: [plug: plug])

      assert result.status == :warn
      assert result.detail =~ "503"
    end
  end

  def bad_sha_manifest_plug(conn) do
    body = manifest_with_sha("0000000000000000000000000000000000000000000000000000000000000000")

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  def matching_sha_manifest_plug(conn) do
    sha = Process.get({__MODULE__, :sha})
    body = manifest_with_sha(sha)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  def future_manifest_plug(conn) do
    body = %{
      "schema_version" => 1,
      "latest" => "99.0.0",
      "releases" => [
        %{
          "version" => "99.0.0",
          "published_at" => "2099-01-01T00:00:00Z",
          "artifacts" => []
        }
      ]
    }

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  defp manifest_with_sha(sha) do
    %{
      "schema_version" => 1,
      "latest" => "1.0.0",
      "releases" => [
        %{
          "version" => "1.0.0",
          "published_at" => "2026-01-01T00:00:00Z",
          "artifacts" => [
            %{
              "target" => "linux-x86_64",
              "url" => "https://example.com/bin",
              "sha256" => sha,
              "sig_url" => "https://example.com/bin.sig",
              "cert_url" => "https://example.com/bin.pem"
            }
          ]
        }
      ]
    }
  end

  defp make_tmp_binary(content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "fermix-doctor-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.write!(path, content)
    path
  end
end
