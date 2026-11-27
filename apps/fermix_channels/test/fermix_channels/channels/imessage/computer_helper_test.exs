defmodule FermixChannels.Channels.IMessage.ComputerHelperTest do
  @moduledoc """
  The watch of `IMessage.ComputerHelper` (M97 §6.4) while the Mac that
  carries Messages cannot answer it, with the link stood in for: the test
  plays the Mac, is told each `imessage.watch` the helper opens and answers
  it through `Computers.Calls`, so nothing reaches a network. Why the watch
  ended is logged once for each change of reason; it is asked again after
  twice the last wait, at most twelve first waits, and never given up; an
  answer, or the watch starting afresh, brings both back.

  async: false: the cases capture the log and raise the helper's log level.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixChannels.Channels.IMessage.ComputerHelper
  alias FermixCore.Computers.Calls
  alias FermixCore.Computers.Computer
  alias FermixTestSupport.SafeRm

  # Every name and id here is invented.
  @studio "5d2c7a91-3e4f-4b6a-8c1d-2f9e0a7b6c35"
  @imessage_on %{id: "imessage", state: :on, sentence: nil, detail: nil}
  @not_running "Fermix Messages is not running on this Mac."
  @unreadable "The Messages database could not be read."
  @refused %{"status" => "refused", "refusal" => "unavailable", "message" => @not_running}
  @failed %{"status" => "failed", "message" => @unreadable}
  @ended "the Messages watch ended: "
  @works "the Messages watch works again"

  # A link that tells the test each request it was asked to send.
  defmodule Link do
    @moduledoc false
    @behaviour FermixCore.Computers.Transport

    @impl true
    def open(_device_id, header, _payload, _part, opts) do
      send(Keyword.fetch!(opts, :test), {:opened, header})
      :ok
    end

    @impl true
    def cancel(_device_id, _about, _opts), do: :ok

    @impl true
    def status(_device_id, _about, _opts), do: :ok
  end

  setup do
    calls = :"imessage_computer_calls_#{System.unique_integer([:positive])}"
    start_supervised!({Calls, name: calls})
    connected = start_supervised!({Agent, fn -> true end})
    home = SafeRm.make_tmp_dir!("imessage_computer_helper")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    Logger.put_module_level(ComputerHelper, :info)
    on_exit(fn -> Logger.delete_module_level(ComputerHelper) end)
    %{calls: calls, connected: connected, home: home}
  end

  # The server's helper, whose one computer is the studio Mac, connected while
  # the test says so. It never polls on its own: the test sends `:poll`.
  defp helper!(ctx, retry_ms) do
    name = :"imessage_computer_helper_#{System.unique_integer([:positive])}"
    connected = ctx.connected

    start_supervised!(
      {ComputerHelper,
       name: name,
       home: ctx.home,
       computers: fn -> [studio(Agent.get(connected, & &1))] end,
       call_opts: [calls: ctx.calls, transport: {Link, test: self()}, epoch: 3],
       poll_ms: :timer.hours(1),
       retry_ms: retry_ms}
    )

    name
  end

  defp studio(connected) do
    %Computer{
      device_id: @studio,
      name: "studio Mac",
      platform: :macos,
      connected: connected,
      offers: [@imessage_on]
    }
  end

  # The id of the next watch the helper opens.
  defp opened! do
    assert_receive {:opened, %{"id" => id, "op" => "imessage.watch"}}, 10_000
    id
  end

  # The Mac's answer to the watch `id`.
  defp answer!(ctx, id, fields, payload \\ "{}") do
    :ok =
      Calls.deliver(
        ctx.calls,
        @studio,
        id,
        {Map.merge(%{"id" => id, "duration_ms" => 3}, fields), payload}
      )
  end

  # Answers the open watch with `fields`, `times` over, each time once the
  # helper has opened the next: the wait it kept before each, and the watch
  # open after the last.
  defp answer_each!(ctx, helper, id, fields, times) do
    Enum.map_reduce(1..times, id, fn _attempt, open ->
      answer!(ctx, open, fields)
      next = opened!()
      {last_wait(helper), next}
    end)
  end

  # The wait before the helper last asked for the watch again, as it keeps it.
  defp last_wait(helper), do: get_in(:sys.get_state(helper), [:retry, :delay_ms])

  defp link_drops_and_returns!(ctx, helper) do
    :ok = Agent.update(ctx.connected, fn _up -> false end)
    send(helper, :poll)
    # The poll the test sent is taken before the link comes back.
    _state = :sys.get_state(helper)
    :ok = Agent.update(ctx.connected, fn _down -> true end)
    send(helper, :poll)
  end

  defp watch_lines(log), do: log |> String.split("\n") |> Enum.filter(&(&1 =~ "Messages watch"))

  defp count(log, line), do: log |> watch_lines() |> Enum.count(&String.contains?(&1, line))

  test "a watch the Mac keeps refusing for one reason is said once, and asked again after " <>
         "longer and longer waits, up to twelve first waits, and never given up",
       ctx do
    helper = helper!(ctx, 1)

    {{waits, _open}, log} =
      with_log(fn -> answer_each!(ctx, helper, opened!(), @refused, 7) end)

    assert count(log, @ended <> @not_running) == 1
    assert waits == [1, 2, 4, 8, 12, 12, 12]
    refute log =~ @works
  end

  test "a new reason is said once more; an answer says the watch works, and the next end " <>
         "waits the first wait again",
       ctx do
    helper = helper!(ctx, 1)
    working = Jason.encode!(%{"boot" => "b7q2", "seq" => 4, "events" => []})

    {{refused, failed, after_working}, log} =
      with_log(fn ->
        {refused, open} = answer_each!(ctx, helper, opened!(), @refused, 2)
        {failed, open} = answer_each!(ctx, helper, open, @failed, 2)
        answer!(ctx, open, %{"status" => "ok"}, working)
        {after_working, _open} = answer_each!(ctx, helper, opened!(), @refused, 1)
        {refused, failed, after_working}
      end)

    assert [said_refused, said_failed, said_works, said_again] = watch_lines(log)
    assert said_refused =~ "[warning] " <> @ended <> @not_running
    assert said_failed =~ "[warning] " <> @ended <> "studio Mac: " <> @unreadable
    assert said_works =~ "[info] " <> @works
    assert said_again =~ "[warning] " <> @ended <> @not_running

    # A new reason goes on waiting longer; the watch working starts it over.
    assert refused ++ failed == [1, 2, 4, 8]
    assert after_working == [1]
  end

  test "the Mac's link coming back starts the watch afresh: its end is said again, after " <>
         "the first wait",
       ctx do
    helper = helper!(ctx, 1)

    {{before, afresh}, log} =
      with_log(fn ->
        {before, _open} = answer_each!(ctx, helper, opened!(), @refused, 3)
        link_drops_and_returns!(ctx, helper)
        {afresh, _open} = answer_each!(ctx, helper, opened!(), @refused, 1)
        {before, afresh}
      end)

    assert count(log, @ended <> @not_running) == 2
    assert before == [1, 2, 4]
    assert afresh == [1]
  end

  test "a wait under way when the link comes back is called off, so one watch is asked for " <>
         "at a time",
       ctx do
    helper = helper!(ctx, :timer.hours(1))

    capture_log(fn ->
      answer!(ctx, opened!(), @refused)
      assert_eventually(fn -> match?(%{retry: %{timer: _}}, :sys.get_state(helper)) end)
      %{retry: %{timer: timer, delay_ms: delay}} = :sys.get_state(helper)
      assert delay == :timer.hours(1)

      link_drops_and_returns!(ctx, helper)
      _fresh = opened!()

      assert Process.read_timer(timer) == false
      assert :sys.get_state(helper).retry == nil
    end)
  end

  defp assert_eventually(fun, attempts \\ 1_000)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      # sleep: polls the helper's state, which announces nothing to the test
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
