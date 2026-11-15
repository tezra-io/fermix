defmodule FermixCore.Computers.Capabilities.ScreenTest do
  # M97 §6.4: what a computer decides of its own screen when its server drives
  # it: the origin again, the access level from its own sandbox mode, courtesy
  # from its own idle signal, and the person's Stop. The helper is a double.
  use ExUnit.Case, async: true

  alias Compux.Protocol
  alias FermixCore.Computers.Capabilities.Screen
  alias FermixCore.Computers.Switches
  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Seat
  alias FermixCore.Management.Copy
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.ScreenHelperDouble

  @unattended [:scheduled, :cue, :worker, :background]

  describe "what each op is" do
    test "an action is an effect and is never sent twice; looking, controls and the watch are not" do
      assert Screen.effect?("screen.act")
      refute Screen.effect?("screen.look")
      refute Screen.effect?("screen.control")
      refute Screen.effect?("screen.watch")
      assert Screen.long_lived?("screen.watch")
      refute Screen.long_lived?("screen.act")
      assert Screen.offer() == :computer_use
    end

    test "every read-only helper request is a look, every other model action is an act" do
      for action <- Protocol.actions() do
        args = %{"seat" => "cua_a", "request" => %{"action" => action}}

        if Protocol.read_only?(action) do
          assert Screen.validate("screen.look", args) == :ok, action
          assert {:error, _sentence} = Screen.validate("screen.act", args), action
        else
          assert Screen.validate("screen.act", args) == :ok, action
          assert {:error, _sentence} = Screen.validate("screen.look", args), action
        end
      end

      for action <- ~w(hello probe) do
        assert Screen.validate("screen.look", %{
                 "seat" => "cua_a",
                 "request" => %{"action" => action}
               }) ==
                 :ok
      end
    end

    test "a request names its seat, and a control and the watch take what they say" do
      assert {:error, _} =
               Screen.validate("screen.look", %{"request" => %{"action" => "screenshot"}})

      assert Screen.validate("screen.control", %{"seat" => "cua_a", "control" => "pause"}) == :ok

      assert {:error, _} =
               Screen.validate("screen.control", %{"seat" => "cua_a", "control" => "go"})

      assert Screen.validate("screen.watch", %{"seat" => "cua_a"}) == :ok
      assert {:error, _} = Screen.validate("screen.watch", %{"seat" => "cua_a", "more" => 1})
    end

    test "a target names the action, never what was typed or seen" do
      typed = %{"seat" => "cua_a", "request" => %{"action" => "type", "text" => "my passphrase"}}
      assert Screen.target("screen.act", typed) == "screen type"

      value = %{
        "seat" => "cua_a",
        "request" => %{"action" => "set_value", "element_ref" => "e1", "value" => "4111"}
      }

      assert Screen.target("screen.act", value) == "screen set_value"

      assert Screen.target("screen.control", %{"seat" => "cua_a", "control" => "pause"}) ==
               "screen pause"

      assert Screen.target("screen.watch", %{"seat" => "cua_a"}) == "screen"
    end
  end

  test "every sentence this computer says of its screen obeys the copy rules" do
    for text <- Screen.sentences() do
      assert Copy.violations(text, :prose, []) == [], text
      assert String.ends_with?(text, "."), text
      assert byte_size(text) <= 512, text
    end
  end

  describe "admit, on the computer" do
    test "strict refuses every action that changes something, and lets every look run" do
      context = context(:chat, :strict)

      for action <- Protocol.actions() do
        if Protocol.read_only?(action) do
          assert Screen.admit("screen.look", request(action), context) == :ok, action
        else
          assert {:refused, :outside_sandbox, sentence} =
                   Screen.admit("screen.act", request(action), context),
                 action

          assert sentence =~ "strict"
        end
      end
    end

    test "standard and open let actions run" do
      for mode <- [:standard, :open] do
        assert Screen.admit("screen.act", request("left_click"), context(:chat, mode)) == :ok
      end
    end

    test "only a chat or a call the owner is in may look or act; every other origin is refused" do
      for origin <- [:chat, :voice] do
        assert Screen.admit("screen.act", request("key"), context(origin, :open)) == :ok
        assert Screen.admit("screen.look", request("screenshot"), context(origin, :open)) == :ok
        assert Screen.admit("screen.watch", %{"seat" => "cua_a"}, context(origin, :open)) == :ok
      end

      for origin <- @unattended do
        for {op, args} <- [
              {"screen.act", request("key")},
              {"screen.look", request("screenshot")},
              {"screen.watch", %{"seat" => "cua_a"}}
            ] do
          assert {:refused, :not_attended, _sentence} =
                   Screen.admit(op, args, context(origin, :open)),
                 "#{origin} #{op}"
        end
      end
    end

    test "handing the screen back is always allowed" do
      for origin <- @unattended do
        assert Screen.admit(
                 "screen.control",
                 %{"seat" => "cua_a", "control" => "release"},
                 context(origin, :strict)
               ) == :ok
      end
    end
  end

  describe "run, on the computer" do
    setup do
      home = SafeRm.make_tmp_dir!("screen_capability")
      on_exit(fn -> SafeRm.rm_rf!(home) end)
      {spec, knobs} = ScreenHelperDouble.driver(self())
      name = :"screen_seat_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Seat,
         name: name,
         driver: fn -> {:ok, spec} end,
         config: fn ->
           Config.normalize(enabled: true, courtesy: "yield", courtesy_idle_ms: 1_000)
         end,
         switches: fn -> Switches.only([:computer_use]) end,
         home: home,
         changed: fn -> :ok end,
         timer: fn _message, _delay -> make_ref() end}
      )

      %{context: Map.put(context(:chat, :standard), :screen_seat, name), knobs: knobs, name: name}
    end

    test "a look answers with the helper's reply, its image as the part", %{context: context} do
      assert {:ok, %{"response" => response, "courtesy" => "off"}, png} =
               Screen.run("screen.look", request("screenshot"), nil, context)

      assert png == ScreenHelperDouble.png()
      refute Map.has_key?(response, "data")
      assert response["mime"] == "image/png"
      assert_received {:screen_helper, "screenshot", _request}
    end

    test "an action runs once the person is idle", %{context: context} do
      args = request("left_click", %{"x" => 1, "y" => 1, "observation_id" => "obs-1"})

      assert {:ok,
              %{"response" => %{"receipt" => %{"dispatch" => "sent"}}, "courtesy" => "proceeded"},
              nil} = Screen.run("screen.act", args, nil, context)

      assert_received {:screen_helper, "idle_ms", _probe}
      assert_received {:screen_helper, "left_click", _request}
    end

    test "courtesy steps aside for a person who is typing, and nothing is sent", %{
      context: context,
      knobs: knobs
    } do
      ScreenHelperDouble.set(knobs, :idle_ms, 10)
      ScreenHelperDouble.set(knobs, :idle, false)
      args = request("type", %{"text" => "hello"})

      assert {:failed, sentence, %{"error" => %{"kind" => "user_active"}}, nil} =
               Screen.run("screen.act", args, nil, context)

      assert sentence =~ "Someone is using this computer"
      assert_received {:screen_helper, "wait_for_idle", _wait}
      refute_received {:screen_helper, "type", _request}
    end

    test "the person's Stop during an action answers stopped_here", %{
      context: context,
      knobs: knobs,
      name: name
    } do
      ScreenHelperDouble.set(knobs, :hold, true)
      args = request("key", %{"chord" => "cmd+s"})
      task = Task.async(fn -> Screen.run("screen.act", args, nil, context) end)
      assert_receive {:screen_helper, "key", _request}

      assert Seat.stop(name) == :stopped

      assert {:refused, :stopped_here, _sentence} = Task.await(task)

      assert {:refused, :stopped_here, _sentence} =
               Screen.run("screen.look", request("screenshot"), nil, context)
    end

    test "a second server session is refused while one holds the screen", %{context: context} do
      {:ok, _result, _png} = Screen.run("screen.look", request("screenshot"), nil, context)
      other = %{"seat" => "cua_other", "request" => %{"action" => "screenshot"}}

      assert {:refused, :busy, sentence} = Screen.run("screen.look", other, nil, context)
      assert sentence =~ "another conversation"
    end

    test "the watch answers when the hold ends, and stopped_here for a Stop", %{
      context: context,
      name: name
    } do
      {:ok, _result, _png} = Screen.run("screen.look", request("screenshot"), nil, context)
      watch = Task.async(fn -> Screen.run("screen.watch", %{"seat" => "cua_a"}, nil, context) end)
      await_watch(name)

      assert Seat.stop(name) == :stopped
      assert {:refused, :stopped_here, _sentence} = Task.await(watch)
    end

    test "cancelling the watch lets go of the screen", %{context: context, name: name} do
      {:ok, _result, _png} = Screen.run("screen.look", request("screenshot"), nil, context)
      watch = Task.async(fn -> Screen.run("screen.watch", %{"seat" => "cua_a"}, nil, context) end)
      await_watch(name)

      :ok = GenServer.call(name, {:close, watch.pid, :closed})

      assert {:ok, %{"ended" => "closed"}, nil} = Task.await(watch)
      assert Seat.view(name) == nil
    end

    test "a control reaches the held helper, and nothing when none is held", %{context: context} do
      assert {:ok, %{"ack" => nil}, nil} =
               Screen.run(
                 "screen.control",
                 %{"seat" => "cua_a", "control" => "pause"},
                 nil,
                 context
               )

      refute_received {:screen_helper_control, _action}

      {:ok, _result, _png} = Screen.run("screen.look", request("screenshot"), nil, context)

      assert {:ok, %{"ack" => %{"in_flight_request_id" => nil}}, nil} =
               Screen.run(
                 "screen.control",
                 %{"seat" => "cua_a", "control" => "pause"},
                 nil,
                 context
               )

      assert_received {:screen_helper_control, :pause}
    end
  end

  defp request(action, more \\ %{}),
    do: %{"seat" => "cua_a", "request" => Map.put(more, "action", action)}

  defp context(origin, mode) do
    %{
      id: "inv-1",
      origin: origin,
      epoch: 3,
      turn: %{session_id: "main-31", tool_call_id: "call-1"},
      home: "/nonexistent",
      switches: Switches.only([:computer_use]),
      sandbox: SandboxConfig.normalize(mode: mode),
      clock: &DateTime.utc_now/0,
      deadline_ms: 30_000
    }
  end

  # The watch is a call the seat holds: wait until it is held, never for time.
  defp await_watch(name, attempts \\ 1_000) do
    cond do
      match?(%{held: %{watchers: [_ | _]}}, :sys.get_state(name)) ->
        :ok

      attempts == 0 ->
        flunk("the watch never reached the seat")

      true ->
        # sleep: the seat tells nobody when a watch arrives
        Process.sleep(5)
        await_watch(name, attempts - 1)
    end
  end
end
