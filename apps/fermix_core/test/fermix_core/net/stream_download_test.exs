defmodule FermixCore.Net.StreamDownloadTest do
  use ExUnit.Case, async: true

  alias FermixCore.Net.StreamDownload

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "fermix-stream-download-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(tmp) end)
    %{tmp: tmp}
  end

  def body_plug(%Plug.Conn{} = conn) do
    Plug.Conn.send_resp(conn, 200, "artifact-bytes")
  end

  def not_found_plug(%Plug.Conn{} = conn) do
    Plug.Conn.send_resp(conn, 404, "nope")
  end

  describe "download/3" do
    test "streams a 200 response to disk", %{tmp: tmp} do
      path = Path.join(tmp, "out.bin")

      assert :ok =
               StreamDownload.download("https://example.com/a", path,
                 plug: &__MODULE__.body_plug/1
               )

      assert File.read!(path) == "artifact-bytes"
    end

    test "returns an error tuple on a non-200 status", %{tmp: tmp} do
      path = Path.join(tmp, "out.bin")

      assert {:error, {:download_status, 404, "https://example.com/a"}} =
               StreamDownload.download("https://example.com/a", path,
                 plug: &__MODULE__.not_found_plug/1
               )
    end

    test "wraps a transport error as {:download_failed, reason, url}", %{tmp: tmp} do
      path = Path.join(tmp, "out.bin")
      adapter = fn req -> {req, %Req.TransportError{reason: :timeout}} end

      assert {:error,
              {:download_failed, %Req.TransportError{reason: :timeout}, "https://example.com/a"}} =
               StreamDownload.download("https://example.com/a", path, adapter: adapter)
    end
  end

  describe "check_sha256/2" do
    test "accepts a matching hash (case-insensitive)", %{tmp: tmp} do
      path = Path.join(tmp, "blob")
      File.write!(path, "the artifact")
      hex = :sha256 |> :crypto.hash("the artifact") |> Base.encode16(case: :lower)

      assert :ok = StreamDownload.check_sha256(path, hex)
      assert :ok = StreamDownload.check_sha256(path, String.upcase(hex))
    end

    test "rejects a mismatching hash with expected/actual", %{tmp: tmp} do
      path = Path.join(tmp, "blob")
      File.write!(path, "the artifact")

      assert {:error, {:sha256_mismatch, expected: "deadbeef", actual: actual}} =
               StreamDownload.check_sha256(path, "deadbeef")

      assert actual == :sha256 |> :crypto.hash("the artifact") |> Base.encode16(case: :lower)
    end

    test "hashes a file larger than the 64 KB chunk size correctly", %{tmp: tmp} do
      path = Path.join(tmp, "big.bin")
      # 200 KB exercises the streaming reduce over multiple 64 KB chunks.
      content = :binary.copy(<<0xAB>>, 200 * 1024)
      File.write!(path, content)
      hex = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

      assert :ok = StreamDownload.check_sha256(path, hex)
    end
  end
end
