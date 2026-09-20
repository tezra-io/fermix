defmodule FermixCore.ComputerUse.NoticeTest do
  @moduledoc """
  The one sentence a computer-use session sends to its own conversation (M42
  slice 5 §4): the person pressed Stop on the on-screen indicator, which the
  model cannot see.
  """

  # async: false — the send runs in `ChannelSend`'s own watchdog process, so the
  # adapter answers to a registered name rather than to `self()`.
  use ExUnit.Case, async: false

  alias FermixCore.ComputerUse.Notice

  @sink :computer_use_notice_sink

  setup do
    Process.register(self(), @sink)
    on_exit(fn -> :ok end)
    :ok
  end

  defmodule Adapter do
    @moduledoc false

    def send_message(destination, text, opts) do
      send(:computer_use_notice_sink, {:sent, destination, text, opts})
      :ok
    end
  end

  defmodule RefusingAdapter do
    @moduledoc false

    def send_message(_destination, _text, _opts), do: {:error, :channel_down}
  end

  test "delivers to the conversation the session belongs to, in its own thread" do
    assert :ok =
             Notice.deliver({"telegram", "4242", "77"}, "Computer use stopped.", adapter: Adapter)

    assert_received {:sent, "4242", "Computer use stopped.", opts}
    assert Keyword.get(opts, :message_thread_id) == 77
  end

  test "a root conversation carries no thread option" do
    assert :ok = Notice.deliver({"telegram", "4242", :root}, "Stopped.", adapter: Adapter)

    assert_received {:sent, "4242", "Stopped.", opts}
    refute Keyword.has_key?(opts, :message_thread_id)
  end

  # A session started outside a conversation — a direct caller, a CLI run — has
  # nowhere to answer into. Said, never swallowed: the caller logs it.
  test "a key that is not a conversation says so rather than guessing a destination" do
    assert {:error, {:no_conversation, :anonymous}} =
             Notice.deliver(:anonymous, "Stopped.", adapter: Adapter)

    assert {:error, {:no_conversation, nil}} = Notice.deliver(nil, "Stopped.", adapter: Adapter)
  end

  test "a channel that refuses the send reports it" do
    assert {:error, _reason} =
             Notice.deliver({"telegram", "4242", :root}, "Stopped.", adapter: RefusingAdapter)
  end
end
