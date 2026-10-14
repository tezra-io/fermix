defmodule FermixCore.Attachments.FramesConfigTest do
  # Sets the `:fermix_core, :ffmpeg` app env, which every test in the VM reads.
  use ExUnit.Case, async: false

  alias FermixCore.Attachments.Frames

  setup do
    previous = Application.fetch_env(:fermix_core, :ffmpeg)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:fermix_core, :ffmpeg, value)
        :error -> Application.delete_env(:fermix_core, :ffmpeg)
      end
    end)
  end

  test "the configuration says where to look, never a binary to run" do
    Application.put_env(:fermix_core, :ffmpeg, :missing)
    assert Frames.ffmpeg([]) == :missing

    Application.put_env(:fermix_core, :ffmpeg, "/opt/tools/ffmpeg")
    assert_raise ArgumentError, ~r/:path or :missing/, fn -> Frames.ffmpeg([]) end
  end
end
