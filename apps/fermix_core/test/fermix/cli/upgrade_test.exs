defmodule Fermix.CLI.UpgradeTest do
  use ExUnit.Case, async: true

  alias Fermix.CLI.Upgrade

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "fermix-upgrade-orch-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    %{tmp: tmp}
  end

  describe "check/1" do
    test "reports available when manifest latest > current" do
      assert {:ok, %{available: true, latest: latest, current: current}} =
               Upgrade.check(req_options: [plug: &__MODULE__.future_manifest_plug/1])

      assert latest == "99.0.0"
      assert is_binary(current)
    end

    test "reports unavailable when current >= latest" do
      assert {:ok, %{available: false}} =
               Upgrade.check(req_options: [plug: &__MODULE__.zero_manifest_plug/1])
    end
  end

  describe "run/1" do
    test "refuses managed installs with the right hint", %{tmp: tmp} do
      File.mkdir_p!(Path.join(tmp, "Cellar/fermix/0.1.0/bin"))
      managed_path = Path.join(tmp, "Cellar/fermix/0.1.0/bin/fermix")
      File.write!(managed_path, "current")

      assert {:error, {:managed_install, :homebrew, "brew upgrade fermix"}} =
               Upgrade.run(binary_path: managed_path)
    end

    test "performs a full upgrade with verify+swap (skipping cosign + restart)", %{tmp: tmp} do
      installed = Path.join(tmp, "fermix")
      File.write!(installed, "old-bin")

      blob = "the new fermix binary content"
      sha = :sha256 |> :crypto.hash(blob) |> Base.encode16(case: :lower)

      Process.put({__MODULE__, :stub_blob}, blob)
      Process.put({__MODULE__, :stub_sha}, sha)

      result =
        Upgrade.run(
          binary_path: installed,
          req_options: [plug: &__MODULE__.upgrade_plug/1],
          staging_dir: Path.join(tmp, "staging"),
          previous_path: Path.join(tmp, ".previous"),
          audit_path: Path.join(tmp, "upgrades.jsonl"),
          skip_restart: true,
          cosign_path: stub_cosign_path()
        )

      assert result == :ok
      assert File.read!(installed) == blob
      assert File.read!(Path.join(tmp, ".previous")) == "old-bin"
      assert File.read!(Path.join(tmp, "upgrades.jsonl")) =~ "\"status\":\"ok\""
    end
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

  def zero_manifest_plug(conn) do
    body = %{
      "schema_version" => 1,
      "latest" => "0.0.0",
      "releases" => [
        %{"version" => "0.0.0", "published_at" => "1970-01-01T00:00:00Z", "artifacts" => []}
      ]
    }

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  def upgrade_plug(%Plug.Conn{request_path: path} = conn) do
    blob = Process.get({__MODULE__, :stub_blob})
    sha = Process.get({__MODULE__, :stub_sha})
    {os, arch} = host_target()
    target_str = "#{os}-#{arch}"

    cond do
      String.ends_with?(path, "releases.json") ->
        body = %{
          "schema_version" => 1,
          "latest" => "99.0.0",
          "releases" => [
            %{
              "version" => "99.0.0",
              "published_at" => "2099-01-01T00:00:00Z",
              "artifacts" => [
                %{
                  "target" => target_str,
                  "url" => "https://example.com/fermix_#{target_str}",
                  "sha256" => sha,
                  "sig_url" => "https://example.com/fermix_#{target_str}.sig",
                  "cert_url" => "https://example.com/fermix_#{target_str}.pem"
                }
              ]
            }
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))

      String.ends_with?(path, ".sig") ->
        Plug.Conn.send_resp(conn, 200, "stub-sig")

      String.ends_with?(path, ".pem") ->
        Plug.Conn.send_resp(conn, 200, "stub-cert")

      true ->
        Plug.Conn.send_resp(conn, 200, blob)
    end
  end

  defp host_target do
    {_family, name} = :os.type()

    os_str =
      case name do
        :darwin -> "macos"
        :linux -> "linux"
      end

    arch =
      case to_string(:erlang.system_info(:system_architecture)) do
        "aarch64" <> _ -> "aarch64"
        "arm64" <> _ -> "aarch64"
        "x86_64" <> _ -> "x86_64"
        "amd64" <> _ -> "x86_64"
      end

    {os_str, arch}
  end

  defp stub_cosign_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "stub-cosign-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
