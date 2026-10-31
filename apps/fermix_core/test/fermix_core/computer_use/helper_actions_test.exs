defmodule FermixCore.ComputerUse.HelperActionsTest do
  @moduledoc """
  The tool offers what the installed helper says it has, and nothing more (M86
  F1).

  The action enum used to be the library's compiled-in list, so on Linux the
  model was offered `elements`, `inspect`, `press` and `set_value`, which always
  refuse there. These pin the reading the schema is now built from: what it holds
  before any helper has answered, what a `hello` makes of it, and what a read that
  goes wrong leaves behind.
  """

  # async: false: the holder is a named process and one case asserts a log line.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Compux.Protocol
  alias FermixCore.ComputerUse.Background
  alias FermixCore.ComputerUse.Capabilities
  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.HelperActions
  alias FermixCore.ComputerUse.Session

  # A helper that answers the handshake with the `hello` the test names, or not at
  # all when it names none.
  defmodule HelloDriver do
    @behaviour Compux.Driver

    @impl true
    def start(opts), do: {:ok, %{hello: Keyword.fetch!(opts, :hello)}}

    @impl true
    def execute(_state, %{"action" => "probe"}), do: {:ok, %{"input_control" => true}}
    def execute(%{hello: nil}, %{"action" => "hello"}), do: {:error, {:sidecar_exited, 1}}
    def execute(%{hello: hello}, %{"action" => "hello"}), do: {:ok, hello}

    @impl true
    def stop(_state), do: :ok
  end

  @pixel ~w(screenshot left_click right_click double_click mouse_move left_click_drag scroll
            type key wait wait_for_change paste windows)

  @accessibility ~w(elements inspect press set_value)

  setup do
    %{tasks: start_supervised!(Task.Supervisor)}
  end

  defp start_holder(opts) do
    start_supervised!({HelperActions, Keyword.put_new(opts, :read_at_boot?, false)})
  end

  # The boot read runs in a task the holder starts, so the closure reports which
  # process that is; the reading it returns is sent to the holder BEFORE that
  # process exits, so once it is down the holder has it queued ahead of the next
  # call.
  defp boot_read(test, reading) do
    fn ->
      send(test, {:boot_read, self()})
      reading
    end
  end

  defp await_boot_read do
    assert_receive {:boot_read, task}
    ref = Process.monitor(task)
    assert_receive {:DOWN, ^ref, :process, ^task, _reason}
  end

  defp helper_reading(actions),
    do: {:ok, Capabilities.from_identity(%{"actions" => actions, "capabilities" => %{}})}

  describe "before any helper has answered" do
    test "only the pixel actions are offered" do
      start_holder([])

      assert HelperActions.offered() == @pixel
      assert HelperActions.pixel() == @pixel
    end

    test "the pixel set names no accessibility action and no bound-window action" do
      for action <- @accessibility ++ Background.actions() do
        refute action in HelperActions.pixel(), "#{action} is offered before any reading"
      end
    end

    test "a holder that is not running answers the pixel set" do
      assert HelperActions.offered(:no_helper_actions_here) == @pixel
    end
  end

  describe "a session's reading" do
    test "a hello without the accessibility actions offers none of them" do
      holder = start_holder([])

      assert :ok = HelperActions.record(@pixel, holder)

      offered = HelperActions.offered(holder)
      assert offered == @pixel

      for action <- @accessibility do
        refute action in offered, "#{action} is offered by a helper that did not list it"
      end
    end

    test "a hello with them keeps them" do
      holder = start_holder([])

      assert :ok = HelperActions.record(Protocol.actions(), holder)

      assert HelperActions.offered(holder) == Protocol.actions()
    end

    test "an action the library does not encode is never offered, and the library's order holds" do
      holder = start_holder([])

      assert :ok = HelperActions.record(~w(left_click teleport screenshot), holder)

      assert HelperActions.offered(holder) == ~w(screenshot left_click)

      assert HelperActions.encodable(~w(left_click teleport screenshot)) ==
               ~w(screenshot left_click)
    end

    test "a later reading replaces an earlier one" do
      holder = start_holder([])

      :ok = HelperActions.record(Protocol.actions(), holder)
      :ok = HelperActions.record(@pixel, holder)

      assert HelperActions.offered(holder) == @pixel
    end

    # An empty enum is a schema providers refuse, and nothing a helper offers is
    # learnt from it, so it is treated as a reading that failed.
    test "a reading that offers nothing this build encodes leaves the offer as it was" do
      holder = start_holder([])
      :ok = HelperActions.record(@pixel, holder)

      log =
        capture_log(fn ->
          assert :ok = HelperActions.record([], holder)
          assert :ok = HelperActions.record(~w(teleport), holder)
        end)

      assert HelperActions.offered(holder) == @pixel
      assert log =~ "offers no action this build encodes"
    end

    test "recording into a holder that is not running is a no-op" do
      assert :ok = HelperActions.record(@pixel, :no_helper_actions_here)
    end
  end

  defp start_session(hello) do
    start_supervised!(
      {Session,
       [
         config: Config.current(),
         driver: {HelloDriver, [hello: hello]},
         origin: :interactive,
         session_id: "cua_helper_actions_#{System.unique_integer([:positive])}"
       ]},
      id: {:helper_actions_session, System.unique_integer([:positive])}
    )
  end

  defp hello(actions) do
    %{
      "protocol_version" => Protocol.protocol_version(),
      "actions" => actions,
      "capabilities" => %{}
    }
  end

  # The bound-window flag is off for every case here, which is how it ships: the
  # reading used to be taken only with it on.
  describe "a session's handshake" do
    setup do
      previous = Application.get_env(:fermix_core, :computer_use, [])
      Application.put_env(:fermix_core, :computer_use, enabled: true, background: false)
      on_exit(fn -> Application.put_env(:fermix_core, :computer_use, previous) end)
      :ok
    end

    test "records what this helper offers, whatever the flags" do
      start_holder([])

      start_session(hello(@pixel))
      assert HelperActions.offered() == @pixel

      start_session(hello(Protocol.actions()))
      assert HelperActions.offered() == Protocol.actions()
    end

    test "a helper that does not answer `hello` leaves the reading as it was" do
      holder = start_holder([])
      :ok = HelperActions.record(@pixel ++ ~w(elements), holder)

      capture_log(fn -> start_session(nil) end)

      assert HelperActions.offered() == HelperActions.encodable(@pixel ++ ~w(elements))
    end
  end

  describe "the boot read" do
    test "is the first reading", %{tasks: tasks} do
      holder =
        start_holder(
          read_at_boot?: true,
          task_supervisor: tasks,
          read: boot_read(self(), helper_reading(~w(screenshot left_click elements)))
        )

      await_boot_read()

      assert HelperActions.offered(holder) == ~w(screenshot left_click elements)
    end

    test "does not hold up boot: the holder answers while the helper has not", %{tasks: tasks} do
      test = self()

      holder =
        start_holder(
          read_at_boot?: true,
          task_supervisor: tasks,
          read: fn ->
            send(test, {:boot_read, self()})

            receive do
              :answer -> helper_reading(Protocol.actions())
            after
              10_000 -> {:error, :test_never_answered}
            end
          end
        )

      assert_receive {:boot_read, task}
      assert HelperActions.offered(holder) == @pixel

      send(task, :answer)
      ref = Process.monitor(task)
      assert_receive {:DOWN, ^ref, :process, ^task, _reason}

      assert HelperActions.offered(holder) == Protocol.actions()
    end

    test "that fails leaves the pixel set in place and says so", %{tasks: tasks} do
      log =
        capture_log(fn ->
          holder =
            start_holder(
              read_at_boot?: true,
              task_supervisor: tasks,
              read: boot_read(self(), {:error, {:sidecar_missing, "/nope"}})
            )

          await_boot_read()

          assert HelperActions.offered(holder) == @pixel
        end)

      assert log =~ "could not read which actions the computer-use helper offers"
      assert log =~ "sidecar_missing"
    end

    test "that crashes leaves the holder running on the pixel set", %{tasks: tasks} do
      test = self()

      log =
        capture_log(fn ->
          holder =
            start_holder(
              read_at_boot?: true,
              task_supervisor: tasks,
              read: fn ->
                send(test, {:boot_read, self()})
                raise "the helper read blew up"
              end
            )

          await_boot_read()

          assert Process.alive?(holder)
          assert HelperActions.offered(holder) == @pixel
        end)

      assert log =~ "the helper read blew up"
    end

    test "that answers after a session's reading does not replace it", %{tasks: tasks} do
      test = self()

      holder =
        start_holder(
          read_at_boot?: true,
          task_supervisor: tasks,
          read: fn ->
            send(test, {:boot_read, self()})

            receive do
              :answer -> helper_reading(Protocol.actions())
            after
              10_000 -> {:error, :test_never_answered}
            end
          end
        )

      assert_receive {:boot_read, task}
      :ok = HelperActions.record(@pixel, holder)

      send(task, :answer)
      ref = Process.monitor(task)
      assert_receive {:DOWN, ^ref, :process, ^task, _reason}

      assert HelperActions.offered(holder) == @pixel
    end

    # The read is started from `init/1`, so had it been started it would be a
    # child of the task supervisor by the time the holder is up, and this one
    # would still be waiting to be answered.
    test "still lands after a session reading that offered nothing", %{tasks: tasks} do
      test = self()

      holder =
        start_holder(
          read_at_boot?: true,
          task_supervisor: tasks,
          read: fn ->
            send(test, {:boot_read, self()})

            receive do
              :answer -> helper_reading(Protocol.actions())
            after
              10_000 -> {:error, :test_never_answered}
            end
          end
        )

      assert_receive {:boot_read, task}
      capture_log(fn -> :ok = HelperActions.record([], holder) end)

      send(task, :answer)
      ref = Process.monitor(task)
      assert_receive {:DOWN, ^ref, :process, ^task, _reason}

      assert HelperActions.offered(holder) == Protocol.actions()
    end

    test "is not started when the switch says not to", %{tasks: tasks} do
      holder =
        start_holder(
          read_at_boot?: false,
          task_supervisor: tasks,
          read: fn ->
            receive do
              :answer -> helper_reading(Protocol.actions())
            after
              10_000 -> {:error, :test_never_answered}
            end
          end
        )

      assert Task.Supervisor.children(tasks) == []
      assert HelperActions.offered(holder) == @pixel
    end
  end
end
