defmodule FermixCore.ComputerUse.ActionGatesTest do
  @moduledoc """
  The gates a click passes, asserted over EVERY action the library offers that is
  not read-only (M42 slice 4 §4).

  `press` and `set_value` reach the same screen a click reaches, by a different
  mechanism, so they must be classified the same way: mutating under the access
  posture, seat-taking, courtesy-waiting, counted against the action budget, and
  refused while the human holds the machine. Writing that per action is how one of
  them ends up outside a gate nobody remembers; writing it over the library's own
  action list means an action added later joins the invariant or fails this file.
  """

  use ExUnit.Case, async: false

  alias Compux.Protocol
  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Courtesy
  alias FermixCore.ComputerUse.InputOwner
  alias FermixCore.ComputerUse.Safety
  alias FermixCore.ComputerUse.Session
  alias FermixTestSupport.ComputerUseObservations
  alias FermixTestSupport.ComputerUseReceipts

  @obs ComputerUseObservations.id()

  # Read at COMPILE time from the library, so this file measures the shipped
  # action list rather than a copy of it.
  @mutating Enum.reject(Protocol.actions(), &Protocol.read_only?/1)

  # What each action IS, pinned here rather than asked of the same predicate the
  # gates ask. Deriving the expectation from `read_only?/1` and then asserting it
  # against `read_only?/1` is a tautology that holds however the library moves;
  # this table fails loudly when an action is reclassified under us — a `press`
  # that became "read-only" would drop out of every gate below AND out of the loop
  # that checks them — and when a new action arrives with no row at all.
  @classification %{
    "screenshot" => :read_only,
    "mouse_move" => :read_only,
    "wait" => :read_only,
    "inspect" => :read_only,
    "wait_for_change" => :read_only,
    "elements" => :read_only,
    "windows" => :read_only,
    "left_click" => :mutating,
    "right_click" => :mutating,
    "double_click" => :mutating,
    "left_click_drag" => :mutating,
    "scroll" => :mutating,
    "type" => :mutating,
    "paste" => :mutating,
    "key" => :mutating,
    "press" => :mutating,
    "set_value" => :mutating,
    # M42 slice 5: binding a window and giving it back change what the helper is
    # POINTED at. Nothing is dispatched, no pointer moves and no key goes down,
    # so they are read-only in every sense the gates below key on — including the
    # pause, which takes the keyboard back and not the bookkeeping.
    "select_target" => :read_only,
    "release_target" => :read_only
  }

  # One well-formed request per mutating action. An action the library gains and
  # this map does not is a failure below — deliberately, because an unfixtured
  # action is one no gate here was ever proved over.
  @requests %{
    "left_click" => %{"observation_id" => @obs, "x" => 1, "y" => 2},
    "right_click" => %{"observation_id" => @obs, "x" => 1, "y" => 2},
    "double_click" => %{"observation_id" => @obs, "x" => 1, "y" => 2},
    "left_click_drag" => %{
      "observation_id" => @obs,
      "from" => %{"x" => 1, "y" => 2},
      "to" => %{"x" => 3, "y" => 4}
    },
    "scroll" => %{
      "observation_id" => @obs,
      "x" => 1,
      "y" => 2,
      "direction" => "down",
      "amount" => 3
    },
    "type" => %{"text" => "hello"},
    "paste" => %{"text" => "hello"},
    "key" => %{"chord" => "cmd+s"},
    "press" => %{"observation_id" => @obs, "element_ref" => "e1"},
    "set_value" => %{"observation_id" => @obs, "element_ref" => "e1", "value" => "hello"}
  }

  # A driver that answers every action, so the gates under test are the only thing
  # that can refuse one.
  defmodule GateDriver do
    @behaviour Compux.Driver

    @impl true
    def start(opts) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         idle_ms: Keyword.get(opts, :idle_ms, 10_000),
         reached_idle: Keyword.get(opts, :reached_idle, true)
       }}
    end

    @impl true
    def execute(%{test_pid: pid} = state, request) do
      send(pid, {:driver_execute, request})
      {:ok, response(state, request)}
    end

    @impl true
    def stop(_state), do: :ok

    defp response(state, %{"action" => "idle_ms"}),
      do: %{"ok" => true, "idle_ms" => state.idle_ms}

    defp response(state, %{"action" => "wait_for_idle"}),
      do: %{"ok" => true, "idle" => state.reached_idle}

    defp response(_state, request) do
      %{
        "ok" => true,
        "data" => Base.encode64("png"),
        "mime" => "image/png",
        "width" => 80,
        "height" => 60
      }
      |> ComputerUseObservations.stamp(request)
      |> ComputerUseReceipts.stamp(request)
    end
  end

  defp start_session(opts) do
    start_supervised!(
      {Session,
       [
         config: Keyword.get(opts, :config, Config.normalize(enabled: true)),
         driver: {GateDriver, [test_pid: self()] ++ Keyword.get(opts, :driver_opts, [])},
         origin: :interactive,
         session_id: "cua_gates_#{System.unique_integer([:positive])}"
       ]},
      id: {:gate_session, System.unique_integer([:positive])}
    )
  end

  defp holder do
    pid = spawn(fn -> receive do: (:done -> :ok) end)
    on_exit(fn -> send(pid, :done) end)
    pid
  end

  defp request_for(action), do: Map.put(Map.fetch!(@requests, action), "action", action)

  test "every action the library offers is classified and covered here" do
    unclassified = Enum.reject(Protocol.actions(), &Map.has_key?(@classification, &1))

    assert unclassified == [],
           "these actions have no expected classification, so no gate below was ever " <>
             "proved over them: #{inspect(unclassified)}."

    missing = Enum.reject(@mutating, &Map.has_key?(@requests, &1))

    assert missing == [],
           "these actions act on the machine and pass no gate this file proves: " <>
             "#{inspect(missing)}. Add a request for each, so it joins the invariants below."
  end

  # The library's own classification, against the table rather than against itself.
  test "the library classifies each action the way this file expects" do
    for {action, expected} <- @classification do
      assert action in Protocol.actions(), "#{action} is no longer an action the library offers"

      assert Protocol.read_only?(action) == (expected == :read_only),
             "the library reclassified #{action}; every gate below keys on that"
    end
  end

  # The coexistence seat, the courtesy wait and the "the agent last disturbed the
  # machine at" stamp all read this one predicate, so an action outside it acts
  # without any of the three. `mouse_move` is the deliberate asymmetry: read-only
  # there, disturbing here, because it warps a cursor the human is holding.
  test "every action this file calls mutating disturbs a present human" do
    for {action, expected} <- @classification do
      disturbing? = Courtesy.disturbing?(action)

      case {expected, action} do
        {:mutating, _} ->
          assert disturbing?, "#{action} acts on the machine without taking the seat"

        {:read_only, "mouse_move"} ->
          assert disturbing?, "mouse_move warps the cursor, so it still yields to a human"

        {:read_only, _} ->
          refute disturbing?, "#{action} looks and nothing more, so it must not take the seat"
      end
    end
  end

  # The one deterministic floor (§14): strict access is look-only.
  test "strict access refuses exactly the actions this file calls mutating" do
    strict = %Config{Config.normalize(enabled: true) | access: :strict}
    standard = %Config{Config.normalize(enabled: true) | access: :standard}

    for {action, expected} <- @classification do
      assert Safety.gate(action, standard) == :auto, "#{action} is refused under standard access"

      if expected == :mutating,
        do: assert(Safety.gate(action, strict) == :refuse, "#{action} runs under look-only"),
        else:
          assert(Safety.gate(action, strict) == :auto, "#{action} only looks; strict allows it")
    end
  end

  test "a paused session refuses every action that is not read-only" do
    session = start_session([])
    assert :paused = Session.pause(session)

    for action <- @mutating do
      assert {:error, {:refused, :paused}} = Session.classify(session, request_for(action)),
             "#{action} slipped past the human's /pause"
    end
  end

  test "an exhausted action budget refuses every action that is not read-only" do
    config = Config.normalize(enabled: true, max_actions: 1)
    session = start_session(config: config)

    {:ok, :auto, first} = Session.classify(session, request_for("left_click"))
    assert {:ok, _result} = Session.execute(session, first)

    for action <- @mutating do
      assert {:error, :action_budget_exhausted} = Session.classify(session, request_for(action)),
             "#{action} runs past the per-session action budget"
    end
  end

  test "every action that is not read-only takes the one native input seat" do
    start_supervised!(InputOwner)
    assert :ok = InputOwner.acquire(holder())

    for action <- @mutating do
      session = start_session([])
      {:ok, :auto, request} = Session.classify(session, request_for(action))

      assert {:error, {:refused, :input_busy}} = Session.execute(session, request),
             "#{action} drove the machine while another conversation held it"

      refute_received {:driver_execute, %{"action" => ^action}}
    end
  end

  # The human is at the machine and stays at it, so every action that would take
  # the cursor or the keyboard from them steps aside instead.
  test "every action that is not read-only waits for a present human" do
    for action <- @mutating do
      session = start_session(driver_opts: [idle_ms: 0, reached_idle: false])
      {:ok, :auto, request} = Session.classify(session, request_for(action))

      assert {:error, :user_active} = Session.execute(session, request),
             "#{action} fought a present human for the machine"
    end
  end

  # A mutating action ends in evidence, so the model reads what its input did
  # rather than assuming; a read-only one is already the look. Which evidence is
  # this side's rule, never the model's: the view for anything that went out over
  # the pointer or the keyboard, the control itself for an accessibility action.
  test "every action that is not read-only is counted and answered with a check" do
    for action <- @mutating do
      session = start_session([])
      {:ok, :auto, request} = Session.classify(session, request_for(action))

      assert request["check"] in ~w(image semantic),
             "#{action} asks for no evidence, so what it did is never seen"

      assert {:ok, _result} = Session.execute(session, request)
      assert Session.action_count(session) == 1, "#{action} costs nothing against the budget"
    end
  end
end
