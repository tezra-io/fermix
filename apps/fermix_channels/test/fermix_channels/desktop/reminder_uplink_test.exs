defmodule FermixChannels.Desktop.ReminderUplinkTest do
  # M99 §10.1: a Snooze pressed on a reminder's notification on a computer
  # whose home is on its server goes up the link as one `reminders.snooze`
  # request, and its answer comes back to the uplink by its id's prefix. The
  # link is stood in for: each event the uplink sends comes to the test as
  # `{:sent, event, payload}`, each timer it sets as `{:timer, message,
  # delay}`, delivered by hand. async: false: Admission hands a history
  # answer to the one waiter name `HistoryUplink` registers.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias FermixChannels.Desktop.HistoryUplink
  alias FermixChannels.Desktop.Invoke
  alias FermixChannels.Desktop.ReminderUplink
  alias FermixChannels.Mobile.Lanes
  alias FermixChannels.Mobile.Protocol
  alias FermixCore.Computers.Switches
  alias FermixCore.Sandbox.Config
  alias FermixTestSupport.SafeRm

  @ok_fields %{"id" => nil, "status" => "ok", "duration_ms" => 4}

  defp start_uplink!(more \\ []) do
    test = self()
    name = :"reminder_uplink_#{System.unique_integer([:positive])}"

    opts =
      [
        name: name,
        relay: :no_relay,
        epoch: fn -> {:ok, 3} end,
        send: fn :no_relay, event, payload ->
          send(test, {:sent, event, payload})
          :ok
        end,
        timer: fn message, delay ->
          send(test, {:timer, message, delay})
          make_ref()
        end
      ]
      |> Keyword.merge(more)

    pid = start_supervised!({ReminderUplink, opts}, id: name)
    %{name: name, pid: pid}
  end

  defp decode(open) do
    header =
      open
      |> Map.merge(%{
        "v" => Protocol.protocol_version(),
        "seq" => 1,
        "index" => 0,
        "last" => true
      })
      |> Jason.encode!()

    Protocol.decode_client_frame(<<byte_size(header)::32, header::binary, "{}">>)
  end

  defp opened do
    assert_receive {:sent, %{"t" => "invoke_open"} = event, payload}
    {event, Jason.decode!(payload)}
  end

  describe "snooze/3" do
    test "sends one reminders.snooze toward the home, with origin computer and a deadline" do
      uplink = start_uplink!()

      assert ReminderUplink.snooze("rem_1", 10, uplink.name) == :ok
      {event, args} = opened()

      assert %{
               "capability" => "reminders",
               "op" => "snooze",
               "deadline_ms" => 15_000,
               "epoch" => 3,
               "origin" => "computer"
             } = event

      assert event["id"] =~ ~r/\Asnz-[0-9a-f]{24}\z/
      assert args == %{"reminder_id" => "rem_1", "minutes" => 10}
      id = event["id"]
      assert_receive {:timer, {:deadline, ^id}, 20_000}
    end

    test "every open is one the wire's codec takes, in the interactive lane" do
      for _request <- 1..200 do
        open = ReminderUplink.request(7)
        assert {:ok, %{type: "invoke_open"}} = decode(open), inspect(open)
        assert {:ok, :interactive} = Lanes.lane("invoke_open", open)
      end

      refute ReminderUplink.request(7)["id"] == ReminderUplink.request(7)["id"]
    end

    test "with no uplink running the press is said, and nothing waits" do
      assert ReminderUplink.snooze("rem_1", 10, :no_uplink_here) == {:error, :not_running}
    end

    test "at most sixteen wait on the server; a seventeenth is dropped" do
      uplink = start_uplink!()

      for n <- 1..17, do: :ok = ReminderUplink.snooze("rem_#{n}", 10, uplink.name)
      in_flight = :sys.get_state(uplink.pid).in_flight

      assert map_size(in_flight) == 16
      for _n <- 1..16, do: opened()
      refute_received {:sent, %{"t" => "invoke_open"}, _payload}
    end
  end

  describe "the home's answer" do
    test "ends the wait: a later deadline sends nothing" do
      uplink = start_uplink!()
      :ok = ReminderUplink.snooze("rem_1", 10, uplink.name)
      {%{"id" => id}, _args} = opened()

      fields = %{@ok_fields | "id" => id}
      assert ReminderUplink.answer(id, fields, ~s({"status":"created"}), uplink.name) == :ok
      assert :sys.get_state(uplink.pid).in_flight == %{}

      send(uplink.pid, {:deadline, id})
      _state = :sys.get_state(uplink.pid)
      refute_received {:sent, %{"t" => "invoke_cancel"}, _payload}
    end

    test "a refusal is logged in the server's words" do
      uplink = start_uplink!()
      :ok = ReminderUplink.snooze("rem_1", 10, uplink.name)
      {%{"id" => id}, _args} = opened()

      fields = %{
        "id" => id,
        "status" => "failed",
        "message" => "That reminder was not delivered to this computer.",
        "duration_ms" => 3
      }

      log =
        capture_log(fn ->
          :ok = ReminderUplink.answer(id, fields, "{}", uplink.name)
          _state = :sys.get_state(uplink.pid)
        end)

      assert log =~ "reminder rem_1 was not snoozed"
      assert log =~ "That reminder was not delivered to this computer."
    end

    test "with no uplink running it is unknown" do
      assert ReminderUplink.answer("snz-0", %{}, "{}", :no_uplink_here) == :unknown
    end
  end

  describe "no answer" do
    test "past its deadline the server is asked to cancel it, on its own lane" do
      uplink = start_uplink!()
      :ok = ReminderUplink.snooze("rem_1", 10, uplink.name)
      {%{"id" => id}, _args} = opened()
      assert_receive {:timer, {:deadline, ^id} = deadline, _delay}

      send(uplink.pid, deadline)

      assert_receive {:sent, cancel, <<>>}

      assert cancel == %{
               "t" => "invoke_cancel",
               "id" => id,
               "capability" => "reminders",
               "op" => "snooze"
             }

      assert :sys.get_state(uplink.pid).in_flight == %{}
    end

    test "a press the relay did not take waits for nothing" do
      test = self()

      uplink =
        start_uplink!(
          send: fn :no_relay, _event, _payload ->
            send(test, {:sending, self()})
            receive do: (:go -> {:error, :busy})
          end
        )

      :ok = ReminderUplink.snooze("rem_1", 10, uplink.name)
      assert_receive {:sending, sender}
      ref = Process.monitor(sender)
      send(sender, :go)
      assert_receive {:DOWN, ^ref, :process, ^sender, _reason}

      assert :sys.get_state(uplink.pid).in_flight == %{}
    end
  end

  describe "Admission routes the home's answers by their prefix" do
    setup do
      home = SafeRm.make_tmp_dir!("reminder_uplink_routes")
      on_exit(fn -> SafeRm.rm_rf!(home) end)
      name = :"reminder_uplink_routes_#{System.unique_integer([:positive])}"
      uplink = :"reminder_uplink_routes_uplink_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Invoke,
         name: name,
         home: home,
         switches: fn -> Switches.only([]) end,
         sandbox: fn -> Config.normalize(mode: :strict, home: home, os_home: home) end,
         capabilities: %{},
         clock: &DateTime.utc_now/0,
         relay: :no_relay,
         send: fn _relay, _event, _payload -> :ok end,
         timer: fn _message, _delay -> make_ref() end,
         link_epoch: fn -> {:ok, 3} end,
         reminder_uplink: uplink}
      )

      %{admission: Invoke.admission(name), uplink: uplink}
    end

    test "a snooze's answer reaches the reminder uplink", ctx do
      Process.register(self(), ctx.uplink)
      fields = %{"id" => "snz-0a", "status" => "ok", "duration_ms" => 1}

      Invoke.handle(ctx.admission, "invoke_result", fields, ~s({"status":"existing"}))
      assert_receive {:answer, "snz-0a", ^fields, ~s({"status":"existing"})}
    end

    test "a history answer reaches the history uplink's waiter", ctx do
      Process.register(self(), HistoryUplink.Waiter)
      fields = %{"id" => "hist-0a", "status" => "ok", "duration_ms" => 1}

      Invoke.handle(ctx.admission, "invoke_result", fields, "{}")
      assert_receive {HistoryUplink, "hist-0a", ^fields, "{}"}
    end

    test "any other id was never sent by this computer, and says so", ctx do
      log =
        capture_log(fn ->
          Invoke.handle(ctx.admission, "invoke_result", %{"id" => "inv-0a"}, "{}")
          _state = :sys.get_state(ctx.admission)
        end)

      assert log =~ "an answer came for a request this computer never sent"
    end
  end
end
