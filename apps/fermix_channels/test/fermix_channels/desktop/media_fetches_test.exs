defmodule FermixChannels.Desktop.MediaFetchesTest do
  @moduledoc """
  The desktop's media family in its own process (M97 §5.1): each blob the
  relay hands it is written to the staging directory and its end told to the
  relay; one nobody waits for, or one the relay gave up on, is let go.
  """

  use ExUnit.Case, async: true

  alias FermixChannels.Desktop.MediaFetches
  alias FermixChannels.Desktop.Relay.Media
  alias FermixTestSupport.SafeRm

  @blob String.duplicate("a blob's bytes ", 10_000)
  @ref :sha256 |> :crypto.hash(@blob) |> Base.encode16(case: :lower)

  setup do
    home = SafeRm.make_tmp_dir!("media_fetches")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    name = :"media_fetches_#{System.unique_integer([:positive])}"
    start_supervised!({MediaFetches, name: name, home: home})
    %{server: name, staging: Media.staging_dir(home)}
  end

  test "a blob it was handed is staged under its ref, and the relay told", ctx do
    stream(ctx.server, @ref, @blob)

    assert_receive {:relay_media_done, @ref, {:ok, media}}
    assert media == %{ref: @ref, kind: "image", mime: "image/png", size_bytes: byte_size(@blob)}
    assert {:ok, %{size_bytes: size}} = Media.staged_blob(ctx.staging, @ref)
    assert size == byte_size(@blob)

    :ok = MediaFetches.discard(ctx.server, @ref)
    _state = :sys.get_state(ctx.server)
    assert Media.staged_blob(ctx.staging, @ref) == {:error, :media_gone}
  end

  test "a blob nobody waits for is left unstaged, and its frames with it", ctx do
    :ok = MediaFetches.begin(ctx.server, self(), begin(@ref, @blob), false, 1_048_576)
    :ok = MediaFetches.chunk(ctx.server, @ref, 0, @blob)
    :ok = MediaFetches.finish(ctx.server, @ref)

    _state = :sys.get_state(ctx.server)
    refute_received {:relay_media_done, @ref, _result}
    assert Media.staged_blob(ctx.staging, @ref) == {:error, :media_gone}
  end

  test "a blob the relay gave up on goes, with no word back", ctx do
    :ok = MediaFetches.begin(ctx.server, self(), begin(@ref, @blob), true, 1_048_576)
    :ok = MediaFetches.chunk(ctx.server, @ref, 0, binary_part(@blob, 0, 100))
    :ok = MediaFetches.drop(ctx.server, @ref)
    :ok = MediaFetches.finish(ctx.server, @ref)

    assert %{transfer: nil} = :sys.get_state(ctx.server)
    refute_received {:relay_media_done, @ref, _result}
    assert File.ls!(ctx.staging) == []
  end

  test "a blob past the bound it was given is refused by name", ctx do
    :ok = MediaFetches.begin(ctx.server, self(), begin(@ref, @blob), true, 10)
    assert_receive {:relay_media_done, @ref, {:error, {:too_large, _size, 10}}}
  end

  test "a session's end abandons the blob in progress", ctx do
    :ok = MediaFetches.begin(ctx.server, self(), begin(@ref, @blob), true, 1_048_576)
    :ok = MediaFetches.abort(ctx.server)

    assert %{transfer: nil} = :sys.get_state(ctx.server)
    assert File.ls!(ctx.staging) == []
  end

  defp stream(server, ref, blob) do
    :ok = MediaFetches.begin(server, self(), begin(ref, blob), true, 1_048_576)

    blob
    |> chunks()
    |> Enum.with_index()
    |> Enum.each(fn {bytes, index} -> :ok = MediaFetches.chunk(server, ref, index, bytes) end)

    :ok = MediaFetches.finish(server, ref)
  end

  defp chunks(<<bytes::binary-size(61_440), rest::binary>>), do: [bytes | chunks(rest)]
  defp chunks(<<>>), do: []
  defp chunks(bytes), do: [bytes]

  defp begin(ref, blob),
    do: %{"ref" => ref, "kind" => "image", "mime" => "image/png", "size_bytes" => byte_size(blob)}
end
