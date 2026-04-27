defmodule Fermix.CLI.Upgrade.ManifestTest do
  use ExUnit.Case, async: true

  alias Fermix.CLI.Upgrade.Manifest

  @valid_manifest %{
    "schema_version" => 1,
    "latest" => "0.2.0",
    "releases" => [
      %{
        "version" => "0.2.0",
        "published_at" => "2026-04-26T18:00:00Z",
        "artifacts" => [
          %{
            "target" => "macos-aarch64",
            "url" => "https://example.com/fermix_macos_aarch64",
            "sha256" => "deadbeef",
            "sig_url" => "https://example.com/fermix_macos_aarch64.sig",
            "cert_url" => "https://example.com/fermix_macos_aarch64.pem"
          },
          %{
            "target" => "linux-x86_64",
            "url" => "https://example.com/fermix_linux_x86_64",
            "sha256" => "cafef00d",
            "sig_url" => "https://example.com/fermix_linux_x86_64.sig",
            "cert_url" => "https://example.com/fermix_linux_x86_64.pem"
          }
        ]
      }
    ]
  }

  describe "fetch/1" do
    test "parses a valid manifest" do
      assert {:ok, manifest} =
               Manifest.fetch(req_options: [plug: &__MODULE__.valid_plug/1])

      assert manifest.schema_version == 1
      assert manifest.latest == "0.2.0"
      assert [%{version: "0.2.0", artifacts: [_, _]}] = manifest.releases
    end

    test "rejects schema mismatch" do
      assert {:error, :manifest_schema_mismatch} =
               Manifest.fetch(req_options: [plug: &__MODULE__.schema_mismatch_plug/1])
    end

    test "surfaces non-200 statuses verbatim" do
      assert {:error, {:manifest_http_status, 404}} =
               Manifest.fetch(req_options: [plug: &__MODULE__.not_found_plug/1])
    end
  end

  describe "compare_versions/2" do
    test "lt when current < latest" do
      assert Manifest.compare_versions("0.1.0", "0.2.0") == :lt
    end

    test "eq when equal" do
      assert Manifest.compare_versions("0.2.0", "0.2.0") == :eq
    end

    test "gt when current > latest (e.g. local dev build)" do
      assert Manifest.compare_versions("0.3.0", "0.2.0") == :gt
    end

    test "errors on garbage" do
      assert {:error, _} = Manifest.compare_versions("not-semver", "0.2.0")
    end
  end

  describe "select_artifact/2" do
    test "picks the matching target" do
      release = parsed_release()

      assert {:ok, %{target: "linux-x86_64"}} =
               Manifest.select_artifact(release, {:linux, :x86_64})
    end

    test "errors when no artifact matches" do
      release = parsed_release()

      assert {:error, {:no_artifact_for_target, "linux-aarch64"}} =
               Manifest.select_artifact(release, {:linux, :aarch64})
    end
  end

  describe "latest_release/1" do
    test "returns the release matching latest" do
      {:ok, manifest} =
        Manifest.fetch(req_options: [plug: &__MODULE__.valid_plug/1])

      assert {:ok, %{version: "0.2.0"}} = Manifest.latest_release(manifest)
    end

    test "errors when latest is missing from releases" do
      manifest = %{schema_version: 1, latest: "9.9.9", releases: []}
      assert {:error, {:latest_not_in_releases, "9.9.9"}} = Manifest.latest_release(manifest)
    end
  end

  def valid_plug(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(@valid_manifest))
  end

  def schema_mismatch_plug(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"unexpected" => "shape"}))
  end

  def not_found_plug(conn) do
    Plug.Conn.send_resp(conn, 404, "")
  end

  defp parsed_release do
    {:ok, manifest} = Manifest.fetch(req_options: [plug: &__MODULE__.valid_plug/1])
    {:ok, release} = Manifest.latest_release(manifest)
    release
  end
end
