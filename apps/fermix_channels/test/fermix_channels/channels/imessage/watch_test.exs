defmodule FermixChannels.Channels.IMessage.WatchTest do
  @moduledoc """
  `IMessage.Watch` on a Mac that carries Messages (M97 §6.4): what the
  helper says, held for the server and let go once taken; a watch the Mac
  does not know answered with the helper's state now; one watch waiting at
  a time; a bounded buffer that names what it let go; and a fetched file that
  must be the message's own.
  """
  use ExUnit.Case, async: true

  alias FermixChannels.Channels.IMessage.Watch
  alias FermixChannels.Test.IMessageFakeHelper, as: FakeHelper
  alias FermixTestSupport.SafeRm

  setup do
    home = SafeRm.make_tmp_dir!("imessage_watch")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    unique = System.unique_integer([:positive])
    fake = :"imessage_watch_fake_#{unique}"
    watch = :"imessage_watch_#{unique}"
    start_supervised!({FakeHelper, name: fake, home: home}, id: :fake)
    start_supervised!({Watch, name: watch, helper: FakeHelper, server: fake, home: home})
    %{home: home, fake: fake, watch: watch}
  end

  defp message(rowid), do: %{"rowid" => rowid, "guid" => "g-#{rowid}"}

  defp synced!(ctx) do
    assert {:ok, %{"boot" => boot, "seq" => seq, "events" => [state]}} =
             Watch.next(ctx.watch, nil, nil)

    {boot, seq, state}
  end

  test "a watch it does not know is answered at once with the helper's state", ctx do
    {boot, seq, state} = synced!(ctx)

    assert %{"helper" => "up", "handshake" => handshake, "seq" => ^seq} = state
    assert handshake == FakeHelper.handshake()
    assert is_binary(boot)

    # A watch from before this Mac's watch started is one it does not know.
    assert {:ok, %{"boot" => ^boot, "events" => [%{"helper" => "up"}]}} =
             Watch.next(ctx.watch, seq, "an-older-watch")
  end

  test "events after the last one taken, as soon as there is one", ctx do
    {boot, seq, _state} = synced!(ctx)
    waiting = Task.async(fn -> Watch.next(ctx.watch, seq, boot) end)

    FakeHelper.push(ctx.fake, "message", message(41))

    assert {:ok, %{"seq" => next, "events" => [%{"event" => "message", "params" => params}]}} =
             Task.await(waiting, 10_000)

    assert params == message(41)
    assert next == seq + 1

    # Asked again from an older event (its answer was lost), it answers the
    # same; asked past it, that event is let go.
    FakeHelper.push(ctx.fake, "db.state", %{"state" => "available"})
    assert {:ok, %{"events" => [first, second]}} = Watch.next(ctx.watch, seq, boot)
    assert first["event"] == "message" and second["event"] == "db.state"
    assert {:ok, %{"events" => [only]}} = Watch.next(ctx.watch, next, boot)
    assert only["event"] == "db.state"
  end

  test "a newer watch ends the older one with nothing", ctx do
    {boot, seq, _state} = synced!(ctx)
    older = Task.async(fn -> Watch.next(ctx.watch, seq, boot) end)
    assert_eventually(fn -> waiting?(ctx.watch) end)
    newer = Task.async(fn -> Watch.next(ctx.watch, seq, boot) end)

    assert {:ok, %{"events" => []}} = Task.await(older, 10_000)
    FakeHelper.push(ctx.fake, "message", message(42))
    assert {:ok, %{"events" => [%{"event" => "message"}]}} = Task.await(newer, 10_000)
  end

  test "the helper going down and up is told in its place among the events", ctx do
    {boot, seq, _state} = synced!(ctx)
    FakeHelper.helper_down(ctx.fake, {:helper_exit, 75})
    FakeHelper.helper_up(ctx.fake)

    assert {:ok, %{"events" => [down, up]}} = Watch.next(ctx.watch, seq, boot)
    assert %{"helper" => "down", "class" => "helper_exit 75"} = down
    assert %{"helper" => "up", "handshake" => %{"protocol_version" => 1}} = up
  end

  test "past #{256} held, the oldest go and the next answer names how many", ctx do
    {boot, seq, _state} = synced!(ctx)
    for rowid <- 1..300, do: FakeHelper.push(ctx.fake, "message", message(rowid))

    assert {:ok, %{"seq" => last, "events" => [overflow | held]}} =
             Watch.next(ctx.watch, seq, boot)

    assert overflow["event"] == "watch.overflow"
    assert overflow["params"] == %{"dropped" => 44}
    assert length(held) == 256
    assert hd(held)["params"] == message(45)

    # Taken, the count is let go with the events.
    FakeHelper.push(ctx.fake, "message", message(301))
    assert {:ok, %{"events" => [%{"params" => newest}]}} = Watch.next(ctx.watch, last, boot)
    assert newest == message(301)
  end

  test "a fetched file outside the message's own inbox entry is refused", ctx do
    elsewhere = Path.join(ctx.home, "elsewhere.jpeg")
    File.write!(elsewhere, "not this one")

    FakeHelper.script(
      ctx.fake,
      "attachment.fetch",
      {:ok, %{"path" => elsewhere, "mime" => "image/jpeg"}}
    )

    assert {:error, {:path_refused, _message, %{}}} =
             Watch.request(
               ctx.watch,
               "attachment.fetch",
               %{"message_guid" => "G-1", "index" => 0, "convert" => false},
               nil,
               %{"timeout_ms" => 5_000}
             )

    assert File.read!(elsewhere) == "not this one"
  end

  test "a request that comes with no file for send.file is refused, nothing sent", ctx do
    assert {:unavailable, _sentence} =
             Watch.request(
               ctx.watch,
               "send.file",
               %{"to" => "+15550100", "mime" => "image/png", "idempotency_key" => "k"},
               nil,
               %{"timeout_ms" => 5_000}
             )

    assert FakeHelper.calls(ctx.fake, "send.file") == []
  end

  defp waiting?(watch), do: :sys.get_state(watch).waiter != nil

  defp assert_eventually(fun, attempts \\ 1_000)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      # sleep: polls the watch's state, which announces nothing to the test
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
