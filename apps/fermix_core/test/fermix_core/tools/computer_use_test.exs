defmodule FermixCore.Tools.ComputerUseTest do
  use ExUnit.Case, async: false

  alias Compux.Protocol
  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Session
  alias FermixCore.ComputerUse.Supervisor, as: CuSupervisor
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Tools.ComputerUse
  alias FermixTestSupport.ComputerUseObservations

  # The image a pointer action names. Addressing is checked before any driver
  # call, so every click in this file carries one.
  @obs ComputerUseObservations.id()

  defmodule StubDriver do
    @behaviour Compux.Driver

    @png <<137, 80, 78, 71>>
    def png, do: @png

    @impl true
    def start(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def execute(%{test_pid: pid}, request) do
      send(pid, {:driver_execute, request})

      # A mutating reply carries the wire's `receipt` (M42 slice 2 §3), as a real
      # sidecar's does: the session derives the tool's `outcome` from its dispatch
      # and treats an absent one as a protocol fault rather than inferring it.
      {:ok,
       %{
         "ok" => true,
         "data" => Base.encode64(@png),
         "mime" => "image/png",
         "width" => 800,
         "height" => 600,
         "region" => ComputerUseObservations.resolved_region(request)
       }
       |> ComputerUseObservations.stamp(request)
       |> FermixTestSupport.ComputerUseReceipts.stamp(request)}
    end

    @impl true
    def stop(_state), do: :ok
  end

  # Returns a configurable REFUSAL from every action — exercises the tool's
  # action-failure messaging path. The real driver decodes an `ok: false` response
  # into exactly this shape: the error code, an optional detail, and the receipt
  # that says what became of the input, which is what the outcome is read from.
  defmodule ErrorDriver do
    @behaviour Compux.Driver

    @impl true
    def start(opts) do
      {:ok,
       %{
         error: Keyword.fetch!(opts, :error),
         dispatch: Keyword.get(opts, :dispatch, "not_sent"),
         detail: Keyword.get(opts, :detail)
       }}
    end

    @impl true
    def execute(state, _request), do: {:error, {:action_failed, payload(state)}}

    @impl true
    def stop(_state), do: :ok

    defp payload(state) do
      %{"error" => state.error, "receipt" => %{"dispatch" => state.dispatch}}
      |> then(&if state.detail, do: Map.put(&1, "detail", state.detail), else: &1)
    end
  end

  # Answers the session's one-time input-control probe normally and fails a NAMED
  # driver call: the courtesy probe (`on: :idle`, before any input reaches the
  # screen) or the action itself. One module, because the difference under test is
  # exactly which call failed. `error:` is a TRANSPORT fault term — a helper that
  # stopped answering or died — which is a different thing from a helper that
  # answered "no" (that is `ErrorDriver`, above).
  defmodule FailingActionDriver do
    @behaviour Compux.Driver

    @impl true
    def start(opts),
      do: {:ok, %{error: Keyword.fetch!(opts, :error), on: Keyword.get(opts, :on, :action)}}

    @impl true
    def execute(_state, %{"action" => "probe"}), do: {:ok, %{"input_control" => true}}

    def execute(%{error: error, on: :idle}, %{"action" => "idle_ms"}), do: {:error, error}
    def execute(_state, %{"action" => "idle_ms"}), do: {:ok, %{"ok" => true, "idle_ms" => 10_000}}
    def execute(%{error: error}, _request), do: {:error, error}

    @impl true
    def stop(_state), do: :ok
  end

  # A stand-in Session with a scripted `execute` reply. The two shapes it serves here
  # cannot be produced from a driver: one needs a `/pause` cast to land in the window
  # between classify and execute, the other is the outer 40 s `GenServer.call`
  # deadline. Both are documented `Session.execute/2` returns (the second is what
  # `Timeouts.expired/3` normalizes that call exit into), and it is the TOOL's
  # rendering of them that is under test.
  defmodule ScriptedSession do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :reply),
        name: Keyword.get(opts, :name)
      )
    end

    @impl true
    def init(reply), do: {:ok, reply}

    @impl true
    def handle_call({:classify, params}, _from, reply), do: {:reply, {:ok, :auto, params}, reply}
    def handle_call({:execute, _request}, _from, reply), do: {:reply, reply, reply}
  end

  @context %{agent_name: "main", conversation_key: {"cli", "chat-cu", :root}}

  defp action_desc(params), do: params["properties"]["action"]["description"]

  # access is derived from the sandbox mode, so dynamic_parameters tests steer it
  # via [sandbox] mode rather than the computer_use config.
  defp put_access(mode) do
    Application.put_env(:fermix_core, :sandbox, %{SandboxConfig.default() | mode: mode})
  end

  defp strict_session do
    start_supervised!(
      {Session,
       [
         config: %{Config.normalize(enabled: true) | access: :strict},
         driver: {StubDriver, [test_pid: self()]},
         origin: :interactive,
         session_id: "cua_strict_#{System.unique_integer([:positive])}"
       ]}
    )
  end

  defp failing_action_session(opts) do
    start_supervised!(
      {Session,
       [
         config: Config.normalize(enabled: true),
         driver: {FailingActionDriver, opts},
         origin: :interactive,
         session_id: "cua_fail_#{System.unique_integer([:positive])}"
       ]}
    )
  end

  defp scripted_session(opts) do
    start_supervised!(%{
      id: {ScriptedSession, System.unique_integer([:positive])},
      start: {ScriptedSession, :start_link, [opts]}
    })
  end

  defp tool_context(session, config, turn) do
    Map.merge(@context, %{
      computer_use_session: session,
      computer_use_config: config,
      session_id: turn
    })
  end

  # Capture this tool's own exec events, pinned to the correlation id the calling
  # test put on its context: a GLOBAL handler filtered by tool name alone can be
  # satisfied by a neighbouring emitter's event, which is how an assertion passes
  # while the thing under test emitted nothing.
  defp capture_tool_exec(turn) do
    test_pid = self()
    handler = "cu-tool-exec-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:fermix, :tool, :exec],
      fn _event, _measurements, metadata, _config ->
        if metadata[:tool] == "computer_use" and metadata[:session_id] == turn,
          do: send(test_pid, {:tool_exec, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # A unique child id, so one test may hold two sessions at once (which is how the
  # same refusal code is shown meaning two different things).
  defp error_session(error, opts \\ []) do
    tag = System.unique_integer([:positive])

    start_supervised!(
      {Session,
       [
         config: Config.normalize(enabled: true),
         driver: {ErrorDriver, [error: error] ++ opts},
         origin: :interactive,
         session_id: "cua_err_#{tag}"
       ]},
      id: {Session, tag}
    )
  end

  describe "static surface" do
    test "name and category" do
      assert ComputerUse.name() == "computer_use"
      assert ComputerUse.category() == :computer
    end

    test "parameters is a discriminated union on action with the full action enum" do
      params = ComputerUse.parameters()
      assert params["type"] == "object"
      assert params["required"] == ["action"]
      assert params["properties"]["action"]["enum"] == Protocol.actions()
    end

    test "static guidance treats accessibility metadata as optional pixel targeting help" do
      params = ComputerUse.parameters()
      action = params["properties"]["action"]["description"]
      region = params["properties"]["region"]["description"]
      x = params["properties"]["x"]["description"]

      assert ComputerUse.description() =~ "best-effort accessibility"
      assert ComputerUse.description() =~ "pixel"
      assert action =~ "empty"
      assert action =~ "pixel"
      assert region =~ "full-screen"
      assert region =~ "elements"
      # One rule, and the schema says it on every field that carries a coordinate.
      assert x =~ "in the image named by observation_id"
      assert params["properties"]["y"]["description"] =~ "in the image named by observation_id"
      assert params["properties"]["observation_id"]["type"] == "string"
      assert params["properties"]["observation_id"]["description"] =~ "REQUIRED"
    end

    # A control the model can NAME needs the schema to say so, and to say when
    # naming beats aiming — otherwise the accessibility half ships invisible.
    test "the schema offers a control reference and says when to prefer it" do
      params = ComputerUse.parameters()
      action = params["properties"]["action"]["description"]
      ref = params["properties"]["element_ref"]

      assert "press" in params["properties"]["action"]["enum"]
      assert "set_value" in params["properties"]["action"]["enum"]
      assert ref["type"] == "string"
      assert ref["description"] =~ "REQUIRED by `press`/`set_value`"
      assert ref["description"] =~ "Never send both a reference and coordinates"
      assert params["properties"]["value"]["description"] =~ "set_value"
      assert action =~ "cannot miss"
      assert action =~ "`type` and `paste` remain"
      assert action =~ "never a quiet click"
    end

    test "failure_modes are tagged maps" do
      assert Enum.all?(ComputerUse.failure_modes(), &match?(%{tag: _, description: _}, &1))
    end

    # Every refusal the model can meet needs a failure mode it can read beforehand.
    test "the reference refusals are all declared failure modes" do
      tags = Enum.map(ComputerUse.failure_modes(), & &1.tag)

      for tag <- ~w(addressing_conflict stale_element element_disabled ax_action_unsupported) do
        assert tag in tags, "#{tag} can be returned and is not a declared failure mode"
      end
    end
  end

  describe "dynamic_parameters/1 — live access mode folded into the action schema" do
    setup do
      prev = Application.get_env(:fermix_core, :sandbox)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:fermix_core, :sandbox)
          value -> Application.put_env(:fermix_core, :sandbox, value)
        end
      end)

      :ok
    end

    test "strict access surfaces the look-only guidance" do
      put_access(:strict)
      desc = action_desc(ComputerUse.dynamic_parameters(%{}))
      assert desc =~ "ACCESS=strict"
      assert desc =~ "look only"
    end

    test "standard access surfaces the confirm-irreversible guidance" do
      put_access(:standard)
      desc = action_desc(ComputerUse.dynamic_parameters(%{}))
      assert desc =~ "ACCESS=standard"
      assert desc =~ ~r/(confirm|ask the owner)/i
    end

    test "open access surfaces autonomous + the truly-dangerous higher bar" do
      put_access(:open)
      desc = action_desc(ComputerUse.dynamic_parameters(%{}))
      assert desc =~ "ACCESS=open"
      assert desc =~ ~r/(autonomous|without asking)/i
      assert desc =~ ~r/truly dangerous|catastrophic/i
    end

    test "the dynamic schema differs from the static parameters (mode is injected)" do
      put_access(:strict)

      refute action_desc(ComputerUse.dynamic_parameters(%{})) ==
               action_desc(ComputerUse.parameters())

      # action enum is unchanged either way
      assert ComputerUse.dynamic_parameters(%{})["properties"]["action"]["enum"] ==
               Protocol.actions()
    end
  end

  describe "execute/2 wiring" do
    setup do
      config = Config.normalize(enabled: true)

      session =
        start_supervised!(
          {Session,
           [
             config: config,
             driver: {StubDriver, [test_pid: self()]},
             origin: :interactive,
             session_id: "cua_tool_test"
           ]}
        )

      %{session: session, config: config}
    end

    test "disabled feature → inert with a clear message (no silent no-op)" do
      context = Map.put(@context, :computer_use_config, Config.normalize([]))

      assert {:ok, result} = ComputerUse.execute(%{"action" => "screenshot"}, context)
      assert result.success == false
      assert result.error =~ "not active"
    end

    test "a read-only action auto-runs and returns the screenshot as an image", %{
      session: session,
      config: config
    } do
      context = Map.merge(@context, %{computer_use_session: session, computer_use_config: config})

      assert {:ok, result} = ComputerUse.execute(%{"action" => "screenshot"}, context)
      assert result.success == true
      assert [%{type: :image, mime_type: "image/png", data: data}] = result.images
      assert data == StubDriver.png()
    end

    # Addressing (M42 slice 3): coordinates that name no image are refused before
    # any input is dispatched, and the sentence names the one next move.
    test "a click that names no image is refused with the recovery named", %{
      session: session,
      config: config
    } do
      region = %{"x" => 10, "y" => 20, "w" => 300, "h" => 200}
      context = Map.merge(@context, %{computer_use_session: session, computer_use_config: config})

      assert {:ok, screenshot} =
               ComputerUse.execute(%{"action" => "screenshot", "region" => region}, context)

      assert screenshot.success == true

      assert {:ok, result} =
               ComputerUse.execute(%{"action" => "left_click", "x" => 10, "y" => 20}, context)

      assert result.success == false
      assert result.error =~ "it names no `observation_id`"
      assert result.error =~ "send this action again with the `observation_id` that reply names"
      refute_received {:driver_execute, %{"action" => "left_click"}}
    end

    test "standard access: a mutating action auto-runs without confirmation", %{
      session: session,
      config: config
    } do
      context = Map.merge(@context, %{computer_use_session: session, computer_use_config: config})

      assert {:ok, result} =
               ComputerUse.execute(
                 %{"action" => "left_click", "observation_id" => @obs, "x" => 10, "y" => 20},
                 context
               )

      assert result.success == true
      assert [%{type: :image}] = result.images
      assert_received {:driver_execute, %{"action" => "left_click"}}
    end

    test "an invalid action is rejected before any driver call", %{
      session: session,
      config: config
    } do
      context = Map.merge(@context, %{computer_use_session: session, computer_use_config: config})

      assert {:ok, result} = ComputerUse.execute(%{"action" => "teleport"}, context)
      assert result.success == false
      assert result.error =~ "invalid action"
      # The session's one-time input-control probe is setup, not the action.
      assert_received {:driver_execute, %{"action" => "probe"}}
      refute_received {:driver_execute, _}
    end
  end

  describe "strict access (look-only floor)" do
    test "a mutating action is refused before any driver call" do
      session = strict_session()
      context = Map.merge(@context, %{computer_use_session: session})

      assert {:ok, result} =
               ComputerUse.execute(
                 %{"action" => "left_click", "observation_id" => @obs, "x" => 1, "y" => 1},
                 context
               )

      assert result.success == false
      assert result.error =~ "strict"
      # The session's one-time input-control probe is setup, not the action.
      assert_received {:driver_execute, %{"action" => "probe"}}
      refute_received {:driver_execute, _}
    end

    test "a read-only action still runs in strict" do
      session = strict_session()
      context = Map.merge(@context, %{computer_use_session: session})

      assert {:ok, result} = ComputerUse.execute(%{"action" => "screenshot"}, context)
      assert result.success == true
      assert [%{type: :image}] = result.images
    end
  end

  # No pre-placed `:computer_use_session` — the tool must acquire it itself through
  # SessionManager (keyed by `conversation_key`), which is the read-only `ask` path.
  describe "lazy session acquisition (read-only ask path)" do
    setup do
      start_supervised!(CuSupervisor)
      :ok
    end

    test "acquires the conversation's session and runs a read-only screenshot" do
      key = {"cli", "chat-ensure", :root}
      config = Config.normalize(enabled: true)

      # Pre-register the session under the conversation key; SessionManager.ensure
      # finds it via the registry and the tool drives a screenshot through it.
      start_supervised!(
        {Session,
         [
           name: {:via, Registry, {CuSupervisor.registry(), key}},
           config: config,
           driver: {StubDriver, [test_pid: self()]},
           origin: :interactive,
           session_id: "cua_ensure_test"
         ]}
      )

      context = %{agent_name: "main", conversation_key: key, computer_use_config: config}

      assert {:ok, result} = ComputerUse.execute(%{"action" => "screenshot"}, context)
      assert result.success == true
      assert [%{type: :image, mime_type: "image/png", data: data}] = result.images
      assert data == StubDriver.png()
      assert_received {:driver_execute, %{"action" => "screenshot"}}
    end

    test "host mode + unattended origin fails closed with a clear message (no crash)" do
      # Enabled host config, no attended origin on the context → SessionManager refuses
      # to start a host session; the tool relays a clean error rather than raising.
      config = Config.normalize(enabled: true, mode: :host)

      context = %{
        agent_name: "main",
        conversation_key: {"cli", "host-x", :root},
        computer_use_config: config
      }

      assert {:ok, result} = ComputerUse.execute(%{"action" => "screenshot"}, context)
      assert result.success == false
      assert result.error =~ "attended session"
    end
  end

  # M42 slice 1 §3/§4.1: every computer_use exec records what happened to the INPUT
  # (`outcome`, a closed five-value enum) and which lifecycle session it happened in
  # (`cu_session`, an opaque id). Both are safe ungated — nothing read off the screen
  # goes into always-on metadata.
  describe "exec telemetry — outcome and cu_session" do
    setup do
      turn = "turn-cu-#{System.unique_integer([:positive])}"
      capture_tool_exec(turn)
      %{config: Config.normalize(enabled: true), turn: turn}
    end

    test "a read records outcome :read and the session's lifecycle id", %{
      config: config,
      turn: turn
    } do
      start_supervised!(CuSupervisor)
      key = {"cli", "chat-outcome", :root}

      start_supervised!(
        {Session,
         [
           name: {:via, Registry, {CuSupervisor.registry(), key}},
           config: config,
           driver: {StubDriver, [test_pid: self()]},
           origin: :interactive,
           session_id: "cua_outcome_test"
         ]}
      )

      context = %{
        agent_name: "main",
        conversation_key: key,
        computer_use_config: config,
        session_id: turn
      }

      assert {:ok, %{success: true}} = ComputerUse.execute(%{"action" => "screenshot"}, context)

      assert_receive {:tool_exec, meta}
      assert meta.outcome == :read
      assert meta.cu_session == "cua_outcome_test"
      assert meta.action == "screenshot"
    end

    test "a dispatched mutating action records outcome :performed", %{
      config: config,
      turn: turn
    } do
      session =
        start_supervised!(
          {Session,
           [
             config: config,
             driver: {StubDriver, [test_pid: self()]},
             origin: :interactive,
             session_id: "cua_performed_test"
           ]}
        )

      assert {:ok, %{success: true}} =
               ComputerUse.execute(
                 %{"action" => "left_click", "observation_id" => @obs, "x" => 3, "y" => 4},
                 tool_context(session, config, turn)
               )

      assert_receive {:tool_exec, meta}
      assert meta.outcome == :performed
    end

    test "a refusal before any input records outcome :refused", %{config: config, turn: turn} do
      assert {:ok, %{success: false}} =
               ComputerUse.execute(
                 %{"action" => "left_click", "observation_id" => @obs, "x" => 1, "y" => 1},
                 tool_context(strict_session(), config, turn)
               )

      assert_receive {:tool_exec, meta}
      assert meta.outcome == :refused
    end

    # A `/pause` cast can land between classify and execute, so the refusal arrives
    # from execute rather than classify. It must read as the SAME sentence: the model
    # was told `action failed: {:refused, :paused}` for an action never attempted.
    test "a pause that lands between classify and execute reads as the pause refusal", %{
      config: config,
      turn: turn
    } do
      session = scripted_session(reply: {:error, {:refused, :paused}})

      assert {:ok, result} =
               ComputerUse.execute(
                 %{"action" => "left_click", "observation_id" => @obs, "x" => 1, "y" => 2},
                 tool_context(session, config, turn)
               )

      assert result.success == false
      assert result.error =~ "computer use is paused"
      assert result.error =~ "/resume"
      refute result.error =~ "action failed"
      refute result.error =~ "refused"

      assert_receive {:tool_exec, meta}
      assert meta.outcome == :refused
      assert meta.courtesy == :paused
    end

    # The OUTER call deadline. An execute makes up to four driver calls inside one
    # 40 s budget, so it can fire with the action already dispatched — and the
    # session is still working, so nothing was reset.
    test "the outer session deadline is unknown dispatch and never claims a reset", %{
      config: config,
      turn: turn
    } do
      session = scripted_session(reply: {:error, {:timeout, :cu_session_call, 40_000}})

      assert {:ok, result} =
               ComputerUse.execute(
                 %{"action" => "left_click", "observation_id" => @obs, "x" => 1, "y" => 2},
                 tool_context(session, config, turn)
               )

      assert result.success == false
      assert result.error =~ "outcome unknown"
      assert result.error =~ "NOT reset"
      assert result.error =~ "still busy"
      # The session no longer queues a second action behind the first, so telling
      # the model its next call "waits for it" would be a promise the tool breaks.
      assert result.error =~ "refused as busy"
      refute result.error =~ "waits for it"
      refute result.error =~ "cu_session_call"
      refute result.error =~ "action failed"

      assert_receive {:tool_exec, meta}
      assert meta.outcome == :unknown
    end

    # One action at a time per conversation: the previous one is still inside the
    # helper. Nothing was sent, so the answer is a wait, never a re-send.
    test "a second action while one is running is a refusal that says to wait", %{
      config: config,
      turn: turn
    } do
      session = scripted_session(reply: {:error, :busy})

      assert {:ok, result} =
               ComputerUse.execute(
                 %{"action" => "left_click", "observation_id" => @obs, "x" => 1, "y" => 2},
                 tool_context(session, config, turn)
               )

      assert result.success == false
      assert result.error =~ "was not sent"
      assert result.error =~ "still running"
      assert result.error =~ "do not re-send"
      refute result.error =~ "action failed"

      assert_receive {:tool_exec, meta}
      assert meta.outcome == :refused
    end

    # There is one cursor on the machine and another conversation has it. Nothing
    # was sent, looking still works, and re-sending would only fight for the seat.
    test "another conversation holding the cursor names the next move", %{
      config: config,
      turn: turn
    } do
      session = scripted_session(reply: {:error, {:refused, :input_busy}})

      assert {:ok, result} =
               ComputerUse.execute(
                 %{"action" => "left_click", "observation_id" => @obs, "x" => 1, "y" => 2},
                 tool_context(session, config, turn)
               )

      assert result.success == false
      assert result.error =~ "another conversation"
      assert result.error =~ "was not sent"
      assert result.error =~ "Read-only actions"
      refute result.error =~ "action failed"

      assert_receive {:tool_exec, meta}
      assert meta.outcome == :refused
    end

    # A helper that will not say what it did with the input has broken the contract
    # the verdict rests on. That is unknown dispatch, not a failure to retry.
    test "a helper that reports no receipt is unknown, and never a raw term", %{
      config: config,
      turn: turn
    } do
      session = scripted_session(reply: {:error, {:protocol_error, :missing_receipt}})

      assert {:ok, result} =
               ComputerUse.execute(
                 %{"action" => "left_click", "observation_id" => @obs, "x" => 1, "y" => 2},
                 tool_context(session, config, turn)
               )

      assert result.success == false
      assert result.error =~ "outcome unknown"
      assert result.error =~ "did not report whether it sent this input"
      assert result.error =~ "session was reset"
      refute result.error =~ "protocol_error"

      assert_receive {:tool_exec, meta}
      assert meta.outcome == :unknown
    end

    test "the process running the actions dying mid-action is unknown dispatch", %{
      config: config,
      turn: turn
    } do
      session = scripted_session(reply: {:error, {:helper_fault, :killed}})

      assert {:ok, result} =
               ComputerUse.execute(
                 %{"action" => "left_click", "observation_id" => @obs, "x" => 1, "y" => 2},
                 tool_context(session, config, turn)
               )

      assert result.success == false
      assert result.error =~ "outcome unknown"
      assert result.error =~ "stopped during this action"
      refute result.error =~ "helper_fault"

      assert_receive {:tool_exec, meta}
      assert meta.outcome == :unknown
    end

    # Some of the input was posted and some was not — and the RECEIPT says so,
    # rather than the tool inferring it from the code. Reporting it as a plain
    # failure would buy a second real drag.
    test "a sequence the helper stopped part way through is unknown, not failed", %{
      config: config,
      turn: turn
    } do
      session = error_session("cancelled", dispatch: "partial")

      assert {:ok, result} =
               ComputerUse.execute(
                 %{"action" => "left_click", "observation_id" => @obs, "x" => 1, "y" => 2},
                 tool_context(session, config, turn)
               )

      assert result.success == false
      assert result.error =~ "outcome unknown"
      assert result.error =~ "stopped part way through"
      refute result.error =~ "action failed"

      assert_receive {:tool_exec, meta}
      assert meta.outcome == :unknown
    end

    # The whole point of the receipt: the SAME refusal code means different things
    # for the input depending on what the helper says it dispatched, and the tool
    # reads that rather than deciding from the code. Before this the code alone
    # decided, which is how a half-sent drag was recorded as a clean refusal.
    test "a refusal's outcome comes from its receipt, not from its code", %{
      config: config,
      turn: turn
    } do
      not_sent = error_session("no_active_display", dispatch: "not_sent")
      partial = error_session("no_active_display", dispatch: "partial")
      click = %{"action" => "left_click", "observation_id" => @obs, "x" => 1, "y" => 2}

      assert {:ok, _} = ComputerUse.execute(click, tool_context(not_sent, config, turn))
      assert_receive {:tool_exec, %{outcome: :refused}}

      assert {:ok, _} = ComputerUse.execute(click, tool_context(partial, config, turn))
      assert_receive {:tool_exec, %{outcome: :unknown}}
    end

    # The helper's own words about a code that has no sentence here, so an operator
    # is never left with a bare token. A code that HAS a sentence already says more
    # than the detail would, and appending it would make that sentence ramble.
    test "a detail reaches the model only where the code has no sentence of its own", %{
      config: config,
      turn: turn
    } do
      named = error_session("no_active_display", detail: "CGDisplayCreateImage returned null")
      unnamed = error_session("ax_timeout", detail: "the element tree took 1500 ms")
      click = %{"action" => "left_click", "observation_id" => @obs, "x" => 1, "y" => 2}

      assert {:ok, named_result} = ComputerUse.execute(click, tool_context(named, config, turn))
      assert named_result.error =~ "no capturable display"
      refute named_result.error =~ "CGDisplayCreateImage"

      assert {:ok, other} = ComputerUse.execute(click, tool_context(unnamed, config, turn))
      assert other.error =~ "ax_timeout"
      assert other.error =~ "the element tree took 1500 ms"
    end

    # Every code the helper's gate can answer with has a sentence naming the next
    # move. A bare token — "action failed: stale_mutation" — is a dead end for a
    # model and a mystery for whoever reads the trace.
    test "every gate refusal names its next move rather than echoing a token", %{
      config: config,
      turn: turn
    } do
      click = %{"action" => "left_click", "observation_id" => @obs, "x" => 1, "y" => 2}

      for {code, expected} <- [
            {"busy", "already running another action"},
            {"stale_generation", "out of step with the session"},
            {"stale_mutation", "out of step with the session"},
            {"unknown_field", "needs reinstalling to match"}
          ] do
        session = error_session(code)
        assert {:ok, result} = ComputerUse.execute(click, tool_context(session, config, turn))

        assert result.error =~ expected, "#{code} rendered as: #{result.error}"
        refute result.error =~ "action failed", "#{code} fell to the catch-all"
        refute result.error =~ code, "#{code} echoed its own token at the model"

        assert_receive {:tool_exec, %{outcome: :refused}}
      end
    end

    # Addressing (M42 slice 3): each of the helper's own refusals gets a sentence
    # naming the next move, and a countable code on the exec row — never the bare
    # token, and never the catch-all's raw term.
    test "the addressing and geometry refusals each get a sentence and a countable code", %{
      config: config,
      turn: turn
    } do
      click = %{"action" => "left_click", "observation_id" => @obs, "x" => 1, "y" => 2}

      for {code, expected} <- [
            {"unknown_observation", "no longer one the computer-use helper holds"},
            {"expired_observation", "no longer one the computer-use helper holds"},
            {"stale_observation", "no longer one the computer-use helper holds"},
            {"point_outside_observation", "outside the image its `observation_id` names"},
            {"capture_geometry_mismatch", "do not match the picture it captured"}
          ] do
        session = error_session(code)
        assert {:ok, result} = ComputerUse.execute(click, tool_context(session, config, turn))

        assert result.error =~ expected, "#{code} rendered as: #{result.error}"
        refute result.error =~ "action failed", "#{code} fell to the catch-all"
        refute result.error =~ code, "#{code} echoed its own token at the model"

        assert_receive {:tool_exec, %{outcome: :refused, geometry_refusal: ^code}}
      end
    end

    # A geometry mismatch arrives on BOTH sides of dispatch: on the action, where
    # nothing was sent, and on the CHECK that follows a click the helper already
    # dispatched. Neither reading may claim the wrong thing about dispatch — the
    # RECEIPT decides, never the code — so the two are told apart here. Before the
    # action and its check became one frame (M42 slice 6) the check was a separate
    # capture, and a refused one answered exactly as the second half does.
    test "a geometry mismatch before dispatch is an operator fault, told plainly", %{
      config: config,
      turn: turn
    } do
      session = error_session("capture_geometry_mismatch", dispatch: "not_sent")

      assert {:ok, result} =
               ComputerUse.execute(mismatch_click(), tool_context(session, config, turn))

      assert result.error =~ "do not match the picture it captured"
      assert result.error =~ "Do not retry."
      assert result.error =~ "give them both sizes below"
      refute result.error =~ "action failed"

      assert_receive {:tool_exec,
                      %{outcome: :refused, geometry_refusal: "capture_geometry_mismatch"}}
    end

    test "the same code after dispatch is a check that failed, not a click that did", %{
      config: config,
      turn: turn
    } do
      session =
        error_session("capture_geometry_mismatch",
          dispatch: "sent",
          detail: "geometry 1512x982, captured 3024x1964"
        )

      assert {:ok, result} =
               ComputerUse.execute(mismatch_click(), tool_context(session, config, turn))

      assert result.output =~ "action performed, but its check capture failed"
      assert result.output =~ "the action itself was sent"
      # The code's OWN operator sentence follows, with the helper's numbers where
      # that sentence promises them, and the row stays countable by the code: an
      # operator fault must not degrade into "take a fresh screenshot" just
      # because it landed after dispatch rather than before it.
      assert result.output =~ "do not match the picture it captured"
      assert result.output =~ "Do not retry."
      assert result.output =~ "(geometry 1512x982, captured 3024x1964)"
      refute result.output =~ "was not sent"
      refute result.output =~ "action failed"

      assert_receive {:tool_exec,
                      %{
                        outcome: :performed_unverified,
                        geometry_refusal: "capture_geometry_mismatch"
                      }}
    end

    defp mismatch_click,
      do: %{"action" => "left_click", "observation_id" => @obs, "x" => 1, "y" => 2}

    # `capture_geometry_mismatch` is an operator fault, so the helper's own numbers
    # reach the person who has to act on them rather than being re-derived here.
    test "a geometry mismatch carries the helper's own measurements", %{
      config: config,
      turn: turn
    } do
      session =
        error_session("capture_geometry_mismatch",
          detail: "geometry 1512x982, captured 3024x1964"
        )

      assert {:ok, result} =
               ComputerUse.execute(
                 %{"action" => "left_click", "observation_id" => @obs, "x" => 1, "y" => 2},
                 tool_context(session, config, turn)
               )

      assert result.error =~ "Do not retry."
      assert result.error =~ "(geometry 1512x982, captured 3024x1964)"
    end

    # Fermix stamped the observation when it recorded it, so it knows exactly how
    # stale the image an action aimed at was. A millisecond count and nothing else.
    test "a click's exec row carries how stale the image it aimed at was", %{
      config: config,
      turn: turn
    } do
      session =
        start_supervised!(
          {Session,
           [
             config: config,
             driver: {StubDriver, [test_pid: self()]},
             origin: :interactive,
             session_id: "cua_observation_age"
           ]}
        )

      context = tool_context(session, config, turn)

      assert {:ok, %{success: true}} = ComputerUse.execute(%{"action" => "screenshot"}, context)
      assert_receive {:tool_exec, %{outcome: :read} = read}
      refute Map.has_key?(read, :observation_age_ms), "a look aims at nothing"

      assert {:ok, %{success: true}} =
               ComputerUse.execute(
                 %{"action" => "left_click", "observation_id" => @obs, "x" => 1, "y" => 2},
                 context
               )

      assert_receive {:tool_exec, %{outcome: :performed, observation_age_ms: age}}
      assert is_integer(age) and age >= 0
    end

    # This side's own addressing gate: nothing was sent, so nothing reaches the
    # driver, and the row carries the same countable code as the helper's five.
    test "a click that names no image records the refusal without a driver call", %{
      config: config,
      turn: turn
    } do
      session = error_session("paused")

      assert {:ok, result} =
               ComputerUse.execute(
                 %{"action" => "left_click", "x" => 1, "y" => 2},
                 tool_context(session, config, turn)
               )

      assert result.success == false
      assert result.error =~ "it names no `observation_id`"

      assert_receive {:tool_exec, %{outcome: :refused, geometry_refusal: "observation_required"}}
    end

    # The blocker this fix pass exists for, from the tool's side. `Session.execute/2`
    # catches only its OWN deadline, so a session that dies without answering kills
    # the tool process — and `Tools.Telemetry.exec/5` never runs, so the turn that
    # drove the machine leaves no row at all. Exactly one exec, and it says unknown.
    test "a session that dies under an action still records exactly one exec", %{
      config: config,
      turn: turn
    } do
      session = scripted_session(reply: {:error, {:helper_fault, :control_unconfirmed}})

      assert {:ok, result} =
               ComputerUse.execute(
                 %{"action" => "left_click", "observation_id" => @obs, "x" => 1, "y" => 2},
                 tool_context(session, config, turn)
               )

      assert result.success == false
      assert result.error =~ "outcome unknown"
      refute result.error =~ "control_unconfirmed"

      assert_receive {:tool_exec, meta}
      assert meta.outcome == :unknown
      refute_receive {:tool_exec, _second}, 50
    end

    # One hold, one sentence. The helper's barrier and Fermix's own flag are two
    # halves of the same pause, so which half an action met first must not change
    # what the model is told.
    test "the helper's own pause reads exactly like Fermix's pause refusal", %{
      config: config,
      turn: turn
    } do
      session = error_session("paused")

      assert {:ok, result} =
               ComputerUse.execute(
                 %{"action" => "left_click", "observation_id" => @obs, "x" => 1, "y" => 2},
                 tool_context(session, config, turn)
               )

      assert result.error =~ "computer use is paused"
      assert result.error =~ "/resume"
      refute result.error =~ "action failed"
    end

    # A frame this build cannot read is a broken wire, not a failed action: the
    # frame that would have said what happened to the input is the unreadable one.
    test "a wire fault is unknown dispatch, and never a raw term", %{config: config, turn: turn} do
      session = failing_action_session(error: {:malformed_frame, {:invalid_json, "boom"}})

      assert {:ok, result} =
               ComputerUse.execute(
                 %{"action" => "left_click", "observation_id" => @obs, "x" => 1, "y" => 2},
                 tool_context(session, config, turn)
               )

      assert result.error =~ "outcome unknown"
      assert result.error =~ "cannot read"
      refute result.error =~ "malformed_frame"
      refute result.error =~ "action failed"

      assert_receive {:tool_exec, meta}
      assert meta.outcome == :unknown
    end

    # `read` is for a read that RAN. A refusal is a refusal whatever the action, or
    # the same hold traces two different ways depending on where it was caught.
    test "a refused read records :refused, not :read", %{config: config, turn: turn} do
      session = scripted_session(reply: {:error, :action_budget_exhausted})

      assert {:ok, %{success: false}} =
               ComputerUse.execute(
                 %{"action" => "screenshot"},
                 tool_context(session, config, turn)
               )

      assert_receive {:tool_exec, meta}
      assert meta.outcome == :refused
    end

    # A context may carry any `GenServer.server()`. Resolving the lifecycle id must
    # never raise out of the tool — that would lose the exec event for an action
    # that ran, which is the one row a reader has.
    test "a session that is not a pid still records its exec, without an id", %{
      config: config,
      turn: turn
    } do
      scripted_session(reply: {:error, :action_budget_exhausted}, name: :fermix_cu_named_session)

      assert {:ok, %{success: false}} =
               ComputerUse.execute(
                 %{"action" => "screenshot"},
                 tool_context(:fermix_cu_named_session, config, turn)
               )

      assert_receive {:tool_exec, meta}
      assert meta.outcome == :refused
      refute Map.has_key?(meta, :cu_session)
    end

    test "a helper that was not running says nothing was sent", %{config: config, turn: turn} do
      session = failing_action_session(error: :sidecar_unavailable)

      assert {:ok, result} =
               ComputerUse.execute(
                 %{"action" => "left_click", "observation_id" => @obs, "x" => 1, "y" => 1},
                 tool_context(session, config, turn)
               )

      assert result.success == false
      assert result.error =~ "was not sent"
      assert result.error =~ "was not running"
      refute result.error =~ "action failed"

      assert_receive {:tool_exec, meta}
      assert meta.outcome == :refused
    end

    test "a helper that stops answering ON the action records :unknown and says so", %{
      config: config,
      turn: turn
    } do
      session = failing_action_session(error: {:timeout, :cu_sidecar_action, 30_000})
      context = tool_context(session, config, turn)

      assert {:ok, result} =
               ComputerUse.execute(
                 %{"action" => "left_click", "observation_id" => @obs, "x" => 1, "y" => 1},
                 context
               )

      assert result.success == false
      assert result.error =~ "outcome unknown"
      assert result.error =~ "session was reset"
      # The raw term never reaches the model, and nothing claims the click failed.
      refute result.error =~ "cu_sidecar_action"
      refute result.error =~ "action failed"

      assert_receive {:tool_exec, meta}
      assert meta.outcome == :unknown
    end

    test "a helper that fails BEFORE any input records :refused and says nothing was sent", %{
      config: config,
      turn: turn
    } do
      session =
        failing_action_session(error: {:timeout, :cu_sidecar_action, 30_000}, on: :idle)

      assert {:ok, result} =
               ComputerUse.execute(
                 %{"action" => "left_click", "observation_id" => @obs, "x" => 1, "y" => 1},
                 tool_context(session, config, turn)
               )

      assert result.success == false
      assert result.error =~ "was not sent"
      assert result.error =~ "send the action again"
      refute result.error =~ "cu_sidecar_action"

      assert_receive {:tool_exec, meta}
      assert meta.outcome == :refused
    end

    # A read that RAN and failed at the helper is still a read: it dispatches no
    # input, so its dispatch was never in doubt. (A read that was REFUSED is above.)
    test "a read-only action that fails is still a read (it dispatches no input)", %{
      config: config,
      turn: turn
    } do
      session = failing_action_session(error: {:sidecar_exited, 2})

      assert {:ok, result} =
               ComputerUse.execute(
                 %{"action" => "screenshot"},
                 tool_context(session, config, turn)
               )

      assert result.success == false
      assert result.error =~ "outcome unknown"

      assert_receive {:tool_exec, meta}
      assert meta.outcome == :read
    end
  end

  describe "action-failure messaging" do
    test "a no_active_display sidecar error becomes an honest, non-transient diagnosis" do
      session = error_session("no_active_display")

      context =
        Map.merge(@context, %{
          computer_use_session: session,
          computer_use_config: Config.normalize(enabled: true)
        })

      assert {:ok, result} = ComputerUse.execute(%{"action" => "screenshot"}, context)
      assert result.success == false
      # Names the real cause (locked / asleep) and that retrying is futile; carries
      # no app-specific example. The raw machine token never leaks to the model.
      assert result.error =~ ~r/lock(ed)?/i
      assert result.error =~ ~r/asleep|awake/i
      refute result.error =~ "no_active_display"
    end

    test "an unrecognized sidecar error still surfaces verbatim (errors are never swallowed)" do
      session = error_session("scale_factor: backend hiccup")

      context =
        Map.merge(@context, %{
          computer_use_session: session,
          computer_use_config: Config.normalize(enabled: true)
        })

      assert {:ok, result} = ComputerUse.execute(%{"action" => "screenshot"}, context)
      assert result.success == false
      assert result.error =~ "action failed:"
      assert result.error =~ "scale_factor: backend hiccup"
    end
  end
end
