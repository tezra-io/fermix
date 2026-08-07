defmodule Fermix.CLI.Upgrade.ManifestTest do
  use ExUnit.Case, async: true

  alias Fermix.CLI.Upgrade.Manifest

  # The exact base `scripts/release/build_releases_json.sh` emits.
  @release_base "https://github.com/tezra-io/fermix/releases/download/v0.2.0"
  @off_origin "https://evil.example.invalid/fermix_macos_aarch64"

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
            "url" => "#{@release_base}/fermix_macos_aarch64",
            "sha256" => "deadbeef",
            "sig_url" => "#{@release_base}/fermix_macos_aarch64.sig",
            "cert_url" => "#{@release_base}/fermix_macos_aarch64.pem"
          },
          %{
            "target" => "linux-x86_64",
            "url" => "#{@release_base}/fermix_linux_x86_64",
            "sha256" => "cafef00d",
            "sig_url" => "#{@release_base}/fermix_linux_x86_64.sig",
            "cert_url" => "#{@release_base}/fermix_linux_x86_64.pem"
          }
        ]
      }
    ]
  }

  @sample_artifact @valid_manifest
                   |> Map.fetch!("releases")
                   |> hd()
                   |> Map.fetch!("artifacts")
                   |> hd()

  # Enumerated from the fixture rather than hand-listed, so a URL-bearing field
  # added to the artifact shape later joins the origin-pin invariant instead of
  # escaping it — the fixture must carry every key `normalize_artifact/1`
  # destructures or nothing in this file parses.
  @url_fields for {key, value} <- @sample_artifact,
                  is_binary(value) and String.starts_with?(value, "http"),
                  do: key

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

  describe "artifact origin pin" do
    test "the pinned surface covers every URL field the artifact shape carries" do
      assert Enum.sort(@url_fields) == ["cert_url", "sig_url", "url"]
    end

    for field <- @url_fields do
      test "refuses a manifest whose artifact #{field} is off-origin, before any download" do
        body = poison(unquote(field), @off_origin)

        assert {:error, {:artifact_origin_rejected, @off_origin}} =
                 Manifest.fetch(req_options: [plug: recording_plug(body)])

        # Exactly one request was issued — the manifest itself. The off-origin
        # URL never reached a caller, so nothing could fetch it.
        assert_received {:manifest_request, _path}
        refute_received {:manifest_request, _path}
      end
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

  # Replaces `field` on the first artifact only — the second artifact stays
  # on-origin, so the rejection cannot be attributed to a wholesale bad fixture.
  defp poison(field, value) do
    [release | rest] = @valid_manifest["releases"]
    [artifact | others] = release["artifacts"]
    release = Map.put(release, "artifacts", [Map.put(artifact, field, value) | others])
    Map.put(@valid_manifest, "releases", [release | rest])
  end

  defp recording_plug(body) do
    test_pid = self()

    fn conn ->
      send(test_pid, {:manifest_request, conn.request_path})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end
  end
end
