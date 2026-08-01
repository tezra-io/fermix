defmodule FermixChannels.Gateway.MediaDownloadTest do
  use ExUnit.Case, async: true

  import Bitwise
  import ExUnit.CaptureLog

  alias FermixChannels.Gateway.MediaDownload

  @max 10 * 1_024 * 1_024

  defp media_request do
    Req.new(
      url: "https://media.test/attachment",
      method: :get,
      plug: {Req.Test, :media_download}
    )
  end

  describe "preflight_cap/2" do
    test "rejects an over-cap declared size before any fetch" do
      assert {:error, {:byte_cap_exceeded, _, @max}} =
               MediaDownload.preflight_cap(%{size_bytes: @max + 1}, @max)
    end

    test "passes when under cap or size unknown" do
      assert :ok = MediaDownload.preflight_cap(%{size_bytes: 100}, @max)
      assert :ok = MediaDownload.preflight_cap(%{}, @max)
    end
  end

  describe "enforce_cap/2" do
    test "rejects an over-cap body and passes an under-cap body" do
      assert {:error, {:byte_cap_exceeded, _, @max}} =
               MediaDownload.enforce_cap(:binary.copy("x", @max + 1), @max)

      assert {:ok, "bytes"} = MediaDownload.enforce_cap("bytes", @max)
    end
  end

  describe "get_capped/3" do
    test "returns the body when it stays under the cap" do
      Req.Test.stub(:media_download, fn conn ->
        Plug.Conn.send_resp(conn, 200, "media-bytes")
      end)

      assert {:ok, "media-bytes"} = MediaDownload.get_capped(media_request(), @max, "test media")
    end

    test "halts at the cap and reports the size that crossed it" do
      Req.Test.stub(:media_download, fn conn ->
        Plug.Conn.send_resp(conn, 200, :binary.copy("x", 64))
      end)

      assert {:error, {:byte_cap_exceeded, 64, 32}} =
               MediaDownload.get_capped(media_request(), 32, "test media")
    end

    test "accepts a body exactly at the cap" do
      Req.Test.stub(:media_download, fn conn ->
        Plug.Conn.send_resp(conn, 200, :binary.copy("x", 32))
      end)

      assert {:ok, body} = MediaDownload.get_capped(media_request(), 32, "test media")
      assert byte_size(body) == 32
    end

    # Req only advertises `accept-encoding` when `into:` is nil, so an absent
    # request header is proof the fetch runs through the streaming collector —
    # and that the decompression amplifier is gone with it.
    test "streams: never advertises accept-encoding" do
      Req.Test.stub(:media_download, fn conn ->
        assert Plug.Conn.get_req_header(conn, "accept-encoding") == []
        Plug.Conn.send_resp(conn, 200, "media-bytes")
      end)

      assert {:ok, "media-bytes"} = MediaDownload.get_capped(media_request(), @max, "test media")
    end

    test "refuses a compressed body by name rather than returning bytes nobody can parse" do
      Req.Test.stub(:media_download, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "gzip")
        |> Plug.Conn.send_resp(200, :zlib.gzip("media-bytes"))
      end)

      assert {:error, {:unexpected_content_encoding, "gzip"}} =
               MediaDownload.get_capped(media_request(), @max, "test media")
    end

    test "treats content-encoding: identity as no encoding" do
      Req.Test.stub(:media_download, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "identity")
        |> Plug.Conn.send_resp(200, "media-bytes")
      end)

      assert {:ok, "media-bytes"} = MediaDownload.get_capped(media_request(), @max, "test media")
    end

    test "hands a non-2xx back to the caller with its status and body" do
      Req.Test.stub(:media_download, fn conn ->
        Plug.Conn.send_resp(conn, 404, "gone")
      end)

      assert {:error, {:http_status, 404, "gone"}} =
               MediaDownload.get_capped(media_request(), @max, "test media")
    end

    test "returns the transport error unchanged" do
      Req.Test.stub(:media_download, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               MediaDownload.get_capped(media_request(), @max, "test media")
    end
  end

  describe "write_temp/3" do
    test "writes the body to a unique owner-only temp path with a mime-derived extension" do
      assert {:ok, path} = MediaDownload.write_temp("PNG", "discord", %{mime_type: "image/png"})
      on_exit(fn -> FermixTestSupport.SafeRm.rm!(path) end)

      assert String.ends_with?(path, ".png")
      assert File.read!(path) == "PNG"
      assert (File.stat!(path).mode &&& 0o777) == 0o600
    end

    test "falls back to .bin when the mime is missing" do
      assert {:ok, path} = MediaDownload.write_temp("x", "slack", %{})
      on_exit(fn -> FermixTestSupport.SafeRm.rm!(path) end)

      assert String.ends_with?(path, ".bin")
    end
  end

  describe "write_temp_bytes/3" do
    test "uses the caller's extension and stays owner-only" do
      assert {:ok, path} = MediaDownload.write_temp_bytes("ID3", "telegram", ".mp3")
      on_exit(fn -> FermixTestSupport.SafeRm.rm!(path) end)

      assert String.ends_with?(path, ".mp3")
      assert File.read!(path) == "ID3"
      assert (File.stat!(path).mode &&& 0o777) == 0o600
    end

    test "never reuses a path" do
      assert {:ok, first} = MediaDownload.write_temp_bytes("a", "telegram", ".bin")
      assert {:ok, second} = MediaDownload.write_temp_bytes("b", "telegram", ".bin")

      on_exit(fn ->
        FermixTestSupport.SafeRm.rm!(first)
        FermixTestSupport.SafeRm.rm!(second)
      end)

      refute first == second
    end
  end

  # The write and close failures (ENOSPC, a device error) cannot be provoked
  # from ExUnit — every filesystem failure a test can force deterministically
  # lands on `File.open/2`, before a file exists — so the cleanup is driven
  # through its own seam. A full /tmp is exactly when the write fails, and a
  # zero-byte orphan per failed inbound attachment is what nothing reaps.
  describe "write_result/3" do
    defp created_temp_file! do
      assert {:ok, path} = MediaDownload.write_temp_bytes("", "discord", ".bin")
      assert File.exists?(path)
      path
    end

    test "a failed write removes the file it created" do
      path = created_temp_file!()

      assert {:error, {:temp_write_failed, :enospc}} =
               MediaDownload.write_result({:error, :enospc}, :ok, path)

      refute File.exists?(path)
    end

    test "a failed close removes the file it created" do
      path = created_temp_file!()

      assert {:error, {:temp_close_failed, :eio}} =
               MediaDownload.write_result(:ok, {:error, :eio}, path)

      refute File.exists?(path)
    end

    test "reports the removal failure without replacing the reason the caller needs" do
      path = Path.join(System.tmp_dir!(), "fermix-discord-never-created.bin")
      refute File.exists?(path)

      {result, log} =
        with_log(fn -> MediaDownload.write_result({:error, :enospc}, :ok, path) end)

      assert result == {:error, {:temp_write_failed, :enospc}}
      assert log =~ "Could not remove failed temp media file"
      assert log =~ "enoent"
    end

    test "a successful write keeps the file" do
      path = created_temp_file!()
      on_exit(fn -> FermixTestSupport.SafeRm.rm!(path) end)

      assert {:ok, ^path} = MediaDownload.write_result(:ok, :ok, path)
      assert File.exists?(path)
    end
  end
end
