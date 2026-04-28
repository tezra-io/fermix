defmodule Fermix.CLI.Upgrade.SwapperTest do
  use ExUnit.Case, async: true

  alias Fermix.CLI.Upgrade.Swapper

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "fermix-upgrade-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    %{tmp: tmp}
  end

  describe "stage_artifact/2" do
    test "downloads, sha256-verifies, and chmods 0755", %{tmp: tmp} do
      blob = "the new fermix binary content"
      sha = :sha256 |> :crypto.hash(blob) |> Base.encode16(case: :lower)

      artifact = %{
        url: "https://example.com/bin",
        sig_url: "https://example.com/sig",
        cert_url: "https://example.com/cert",
        sha256: sha
      }

      {:ok, staged} =
        Swapper.stage_artifact(artifact,
          staging_dir: Path.join(tmp, "staging"),
          req_options: [plug: &__MODULE__.body_plug/1]
        )

      assert File.read!(staged.blob_path) == blob
      assert File.read!(staged.sig_path) == "sig-content"
      assert File.read!(staged.cert_path) == "cert-content"
      {:ok, %File.Stat{mode: mode}} = File.stat(staged.blob_path)
      assert Bitwise.band(mode, 0o777) == 0o755
    end

    test "errors loud on sha256 mismatch", %{tmp: tmp} do
      artifact = %{
        url: "https://example.com/bin",
        sig_url: "https://example.com/sig",
        cert_url: "https://example.com/cert",
        sha256: "0000000000000000000000000000000000000000000000000000000000000000"
      }

      assert {:error, {:sha256_mismatch, _}} =
               Swapper.stage_artifact(artifact,
                 staging_dir: Path.join(tmp, "staging"),
                 req_options: [plug: &__MODULE__.body_plug/1]
               )
    end
  end

  describe "swap/3 + rollback/2" do
    test "snapshots current binary into recovery slot then renames into place", %{tmp: tmp} do
      installed = Path.join(tmp, "fermix")
      File.write!(installed, "old-binary")

      staged = make_staged!(tmp, "new-binary")
      previous = Path.join(tmp, ".previous")

      {:ok, %{installed_path: ^installed, previous_path: ^previous}} =
        Swapper.swap(staged, installed, previous_path: previous)

      assert File.read!(installed) == "new-binary"
      assert File.read!(previous) == "old-binary"
      refute File.exists?(staged.blob_path)
    end

    test "rollback brings back the previous binary", %{tmp: tmp} do
      installed = Path.join(tmp, "fermix")
      File.write!(installed, "broken-new-binary")
      previous = Path.join(tmp, ".previous")
      File.write!(previous, "old-but-working")

      assert :ok = Swapper.rollback(previous, installed)
      assert File.read!(installed) == "old-but-working"
      refute File.exists?(previous)
    end

    test "rollback errors loud when no recovery slot exists", %{tmp: tmp} do
      installed = Path.join(tmp, "fermix")
      File.write!(installed, "current")
      missing = Path.join(tmp, "no-recovery")

      assert {:error, {:no_recovery_slot, ^missing}} = Swapper.rollback(missing, installed)
    end
  end

  def body_plug(%Plug.Conn{request_path: path} = conn) do
    {status, body} =
      cond do
        String.contains?(path, "sig") -> {200, "sig-content"}
        String.contains?(path, "cert") -> {200, "cert-content"}
        true -> {200, "the new fermix binary content"}
      end

    Plug.Conn.send_resp(conn, status, body)
  end

  defp make_staged!(tmp, blob_content) do
    staging_dir = Path.join(tmp, "staging")
    File.mkdir_p!(staging_dir)

    blob_path = Path.join(staging_dir, "fermix.upgrade.tmp")
    sig_path = Path.join(staging_dir, "fermix.upgrade.sig")
    cert_path = Path.join(staging_dir, "fermix.upgrade.pem")

    File.write!(blob_path, blob_content)
    File.write!(sig_path, "sig")
    File.write!(cert_path, "cert")
    File.chmod!(blob_path, 0o755)

    %{
      blob_path: blob_path,
      sig_path: sig_path,
      cert_path: cert_path,
      staging_dir: staging_dir
    }
  end
end
