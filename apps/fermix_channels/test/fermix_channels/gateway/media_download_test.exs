defmodule FermixChannels.Gateway.MediaDownloadTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Gateway.MediaDownload

  @max 10 * 1_024 * 1_024

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

  describe "write_temp/3" do
    test "writes the body to a unique temp path with a mime-derived extension" do
      assert {:ok, path} = MediaDownload.write_temp("PNG", "discord", %{mime_type: "image/png"})
      assert String.ends_with?(path, ".png")
      assert File.read!(path) == "PNG"
    end

    test "falls back to .bin when the mime is missing" do
      assert {:ok, path} = MediaDownload.write_temp("x", "slack", %{})
      assert String.ends_with?(path, ".bin")
    end
  end
end
