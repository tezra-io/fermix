defmodule FermixCore.ComputerUse.ElementActionsTest do
  @moduledoc """
  Controls the model can NAME (M42 slice 4): `press` and `set_value` reach a
  control through accessibility instead of the pointer, and a pointer action may
  address one too.

  What is under test here is the half that is Fermix's: which outcome the receipt
  earns, what the model is told next, and that nothing is ever quietly switched
  from one mechanism to another. The helper's own revalidation is proved against
  the wire in `port_driver_test.exs`.
  """

  use ExUnit.Case, async: false

  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Session
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Tools.ComputerUse
  alias FermixTestSupport.ComputerUseObservations
  alias FermixTestSupport.ComputerUseReceipts

  @obs ComputerUseObservations.id()

  # A driver whose receipt is chosen by the test, so every rung of the effect
  # ladder can be walked without a real accessibility call.
  defmodule ReceiptDriver do
    @behaviour Compux.Driver

    @impl true
    def start(opts) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         receipt: Keyword.get(opts, :receipt),
         elements: Keyword.get(opts, :elements, []),
         marks: Keyword.get(opts, :marks)
       }}
    end

    @impl true
    def execute(%{test_pid: pid} = state, request) do
      send(pid, {:driver_execute, request})
      {:ok, response(state, request)}
    end

    @impl true
    def stop(_state), do: :ok

    defp response(_state, %{"action" => "idle_ms"}), do: %{"ok" => true, "idle_ms" => 10_000}

    defp response(state, %{"action" => "elements"} = request) do
      %{"ok" => true, "elements" => state.elements}
      |> ComputerUseObservations.stamp(request)
    end

    defp response(state, request) do
      %{
        "ok" => true,
        "data" => Base.encode64("png"),
        "mime" => "image/png",
        "width" => 80,
        "height" => 60
      }
      |> put_marks(state, request)
      |> ComputerUseObservations.stamp(request)
      |> put_receipt(state, request)
    end

    defp put_marks(response, %{marks: marks}, %{"marks" => true}) when is_list(marks),
      do: Map.put(response, "marks", marks)

    defp put_marks(response, _state, _request), do: response

    defp put_receipt(response, %{receipt: nil}, request),
      do: ComputerUseReceipts.stamp(response, request)

    defp put_receipt(response, %{receipt: receipt}, _request),
      do: Map.put(response, "receipt", receipt)
  end

  # A driver that refuses every action with one helper code and one receipt, so
  # both halves of the sentence the model reads — what went wrong, and whether the
  # input went anywhere at all — are what is under test.
  defmodule RefusingDriver do
    @behaviour Compux.Driver

    @impl true
    def start(opts) do
      {:ok,
       %{
         code: Keyword.fetch!(opts, :code),
         dispatch: Keyword.get(opts, :dispatch, :not_sent),
         detail: Keyword.get(opts, :detail, "the helper refused it")
       }}
    end

    @impl true
    def execute(state, _request) do
      {:error,
       {:action_failed,
        %{
          "error" => state.code,
          "detail" => state.detail,
          "receipt" => ComputerUseReceipts.receipt(state.dispatch, input_method: "ax")
        }}}
    end

    @impl true
    def stop(_state), do: :ok
  end

  setup do
    handler = "cu-elements-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:fermix, :tool, :exec],
      fn _event, _measure, metadata, _config -> send(test_pid, {:tool_exec, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    # The tool reads the live posture, and the suite's default sandbox mode is what
    # decides whether a mutating action runs at all.
    previous = Application.get_env(:fermix_core, :sandbox)
    Application.put_env(:fermix_core, :sandbox, mode: "standard")
    on_exit(fn -> restore(:sandbox, previous) end)

    assert SandboxConfig.current().mode == :standard

    %{config: Config.normalize(enabled: true)}
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)

  defp start_session(config, driver_opts) do
    start_supervised!(
      {Session,
       [
         config: config,
         driver: {ReceiptDriver, [test_pid: self()] ++ driver_opts},
         origin: :interactive,
         session_id: "cua_elements_#{System.unique_integer([:positive])}"
       ]},
      id: {:elements_session, System.unique_integer([:positive])}
    )
  end

  defp context(session, config) do
    %{
      computer_use_session: session,
      computer_use_config: config,
      conversation_key: "test",
      session_id: "main-1"
    }
  end

  defp run(session, config, params), do: ComputerUse.execute(params, context(session, config))

  defp press(ref \\ "e1"),
    do: %{"action" => "press", "observation_id" => @obs, "element_ref" => ref}

  describe "outcomes from the receipt" do
    # A successful AX return says the call was made, not that the control acted,
    # so the honest verdict is performed-and-unverified.
    test "a press is performed and unverified, over the ax method", %{config: config} do
      session = start_session(config, receipt: ComputerUseReceipts.ax(:not_observed))

      assert {:ok, %{success: true}} = run(session, config, press())

      assert_receive {:tool_exec,
                      %{outcome: :performed_unverified, input_method: "ax", effect: :not_observed}}
    end

    # `set_value` is the one action that reads its own result back, so a matching
    # read-back is the only thing in this family that earns plain `performed`.
    test "a set_value whose read-back matched is performed", %{config: config} do
      session = start_session(config, receipt: ComputerUseReceipts.ax(:verified))

      assert {:ok, result} =
               run(session, config, %{
                 "action" => "set_value",
                 "observation_id" => @obs,
                 "element_ref" => "e2",
                 "value" => "chess"
               })

      assert result.success == true
      refute result.output =~ "Read the field"
      assert_receive {:tool_exec, %{outcome: :performed, input_method: "ax", effect: :verified}}
    end

    test "a set_value that could not be read back says to read the field first", %{config: config} do
      session = start_session(config, receipt: ComputerUseReceipts.ax(:not_observed))

      assert {:ok, result} =
               run(session, config, %{
                 "action" => "set_value",
                 "observation_id" => @obs,
                 "element_ref" => "e3",
                 "value" => "hunter2"
               })

      text = result.output
      assert text =~ "reading the field back did not return it"
      assert text =~ "secure field always reads back masked"
      assert text =~ "Read the field before you rely on it"

      assert_receive {:tool_exec,
                      %{outcome: :performed_unverified, input_method: "ax", effect: :not_observed}}
    end

    # A call the helper cannot account for is `unknown` wherever that receipt
    # arrives. The helper only ever ships it as a REFUSAL (`ax_timed_out`), where
    # the sentence lives; this pins the derivation itself, so a receipt that did
    # reach a success reply could never read as "it happened".
    test "an accessibility receipt that accounts for nothing is an unknown outcome", %{
      config: config
    } do
      session = start_session(config, receipt: ComputerUseReceipts.ax(:unknown))

      assert {:ok, %{success: true}} = run(session, config, press())

      assert_receive {:tool_exec, %{outcome: :unknown, input_method: "ax", effect: :unknown}}
    end

    # A click is still a click: its `effect` is a field its method cannot fill in,
    # so the dispatch verdict stands alone and slice 2's rule is untouched.
    test "a pointer action keeps its own method and its own verdict", %{config: config} do
      session = start_session(config, [])

      assert {:ok, %{success: true}} =
               run(session, config, %{
                 "action" => "left_click",
                 "observation_id" => @obs,
                 "x" => 1,
                 "y" => 2
               })

      assert_receive {:tool_exec, %{outcome: :performed, input_method: "foreground_hid"}}
    end

    # The value is CONTENT. It reaches the helper and it never reaches a row.
    test "the value a set_value carried never reaches the exec row", %{config: config} do
      session = start_session(config, receipt: ComputerUseReceipts.ax(:verified))

      assert {:ok, %{success: true}} =
               run(session, config, %{
                 "action" => "set_value",
                 "observation_id" => @obs,
                 "element_ref" => "e2",
                 "value" => "a-secret-passphrase"
               })

      assert_receive {:driver_execute,
                      %{"action" => "set_value", "value" => "a-secret-passphrase"}}

      assert_receive {:tool_exec, metadata}

      refute metadata |> Map.drop([:input]) |> inspect() =~ "a-secret-passphrase",
             "the value must never ride always-on metadata"
    end
  end

  describe "the foreground" do
    test "a press that took the front says so, and what it means for the next keystroke", %{
      config: config
    } do
      session =
        start_session(config,
          receipt: ComputerUseReceipts.ax(:not_observed, foreground_changed: true)
        )

      assert {:ok, result} = run(session, config, press())

      text = result.output
      assert text =~ "brought its application to the FRONT"
      assert text =~ "anything typed now goes elsewhere"
    end

    test "a press that left the front alone says nothing about it", %{config: config} do
      session = start_session(config, receipt: ComputerUseReceipts.ax(:not_observed))

      assert {:ok, result} = run(session, config, press())

      refute result.output =~ "FRONT"
    end

    # ABSENT is unknown, not false. The helper leaves the field off when the
    # platform would not say, and a reply that then claimed the front window was
    # left alone would get the next keystroke typed into the wrong application.
    test "a press whose receipt does not answer the question claims nothing", %{config: config} do
      receipt =
        :not_observed |> ComputerUseReceipts.ax() |> Map.delete("foreground_changed")

      session = start_session(config, receipt: receipt)

      assert {:ok, result} = run(session, config, press())

      refute result.output =~ "FRONT"
      refute result.output =~ "front", "silence, never a claim either way"
    end
  end

  # The helper ships an accessibility failure ONLY as a refusal, so this is the
  # ONE path where its sentence can reach the model. Left to the catch-all it read
  # "action failed: ax_timed_out (AXError -25204)", which tells a model nothing
  # except to try again — a second press on a control that may already have acted.
  describe "an accessibility call that failed" do
    for {code, dispatch, outcome, anchor} <- [
          {"ax_timed_out", :sent, :unknown, "was made and never came back"},
          {"ax_timed_out", :not_sent, :refused, "timed out before its message went anywhere"},
          {"ax_action_failed", :sent, :unknown, "failed after its message had already gone out"},
          {"ax_action_failed", :not_sent, :refused,
           "was refused by the accessibility system before it went anywhere"}
        ] do
      test "#{code} with a #{dispatch} receipt says so and records #{outcome}", %{config: config} do
        session =
          start_supervised!(
            {Session,
             [
               config: config,
               driver:
                 {RefusingDriver,
                  [
                    code: unquote(code),
                    dispatch: unquote(dispatch),
                    detail: "AXError -25204"
                  ]},
               origin: :interactive,
               session_id: "cua_ax_#{System.unique_integer([:positive])}"
             ]},
            id: {:ax_session, System.unique_integer([:positive])}
          )

        assert {:ok, result} = run(session, config, press())

        assert result.success == false
        assert result.error =~ unquote(anchor)

        refute result.error =~ "action failed:",
               "a named failure must never render as a raw code"

        assert result.error =~ "(AXError -25204)",
               "the platform's own words belong beside the sentence, never as it"

        assert_receive {:tool_exec, %{outcome: unquote(outcome)}}
      end
    end

    # The two halves that must never disagree: a receipt that says the message went
    # out gets "do not repeat", and one that says it did not gets "not sent".
    test "the claim about dispatch follows the receipt, not the code", %{config: config} do
      sent = ax_session(config, "ax_action_failed", :sent)
      assert {:ok, %{error: sent_error}} = run(sent, config, press())
      assert sent_error =~ "outcome unknown"
      assert sent_error =~ "Do NOT repeat it"
      refute sent_error =~ "was not sent"

      not_sent = ax_session(config, "ax_action_failed", :not_sent)
      assert {:ok, %{error: refused_error}} = run(not_sent, config, press())
      assert refused_error =~ "this action was not sent"
      assert refused_error =~ "Accessibility permission"
      refute refused_error =~ "outcome unknown"
    end
  end

  defp ax_session(config, code, dispatch) do
    start_supervised!(
      {Session,
       [
         config: config,
         driver: {RefusingDriver, [code: code, dispatch: dispatch]},
         origin: :interactive,
         session_id: "cua_ax_#{System.unique_integer([:positive])}"
       ]},
      id: {:ax_session, System.unique_integer([:positive])}
    )
  end

  describe "refusals, each naming the next move" do
    # Nothing is switched for the model: a refused press stays a refused press.
    for {code, anchor} <- [
          {"stale_element", "Take `elements` again and use the reference from THAT reply"},
          {"element_disabled", "Work out what enables it"},
          {"ax_action_unsupported", "click it by `element_ref`, or by its point"},
          {"addressing_conflict", "it names its target twice"},
          {"element_required", "it names no control"}
        ] do
      test "the helper's #{code} names the next move", %{config: config} do
        session =
          start_supervised!(
            {Session,
             [
               config: config,
               driver: {RefusingDriver, [code: unquote(code)]},
               origin: :interactive,
               session_id: "cua_refuse_#{System.unique_integer([:positive])}"
             ]},
            id: {:refuse_session, System.unique_integer([:positive])}
          )

        assert {:ok, result} = run(session, config, press())

        assert result.success == false
        assert result.error =~ unquote(anchor)
        refute result.error =~ "action failed:", "a named refusal never renders as a raw term"
      end
    end

    test "a disabled control is never told to try again", %{config: config} do
      session =
        start_supervised!(
          {Session,
           [
             config: config,
             driver: {RefusingDriver, [code: "element_disabled"]},
             origin: :interactive,
             session_id: "cua_disabled"
           ]}
        )

      assert {:ok, result} = run(session, config, press())
      assert result.error =~ "Do not retry it"
      assert result.error =~ "clicking its pixels included"
    end

    # This side's own gate: two answers to "where" never reach the driver, and the
    # row carries the countable code beside the helper's own.
    test "naming a target twice is refused before any driver call", %{config: config} do
      session = start_session(config, [])

      assert {:ok, result} =
               run(session, config, %{
                 "action" => "left_click",
                 "observation_id" => @obs,
                 "element_ref" => "e1",
                 "x" => 1,
                 "y" => 2
               })

      assert result.success == false
      assert result.error =~ "it names its target twice"
      refute_received {:driver_execute, %{"action" => "left_click"}}

      assert_receive {:tool_exec, %{outcome: :refused, geometry_refusal: "addressing_conflict"}}
    end

    test "a reference with no image named is refused for want of the image", %{config: config} do
      session = start_session(config, [])

      assert {:ok, result} =
               run(session, config, %{"action" => "press", "element_ref" => "e1"})

      assert result.error =~ "it names no `observation_id`"
      assert result.error =~ "an `element_ref` alike"
      refute_received {:driver_execute, %{"action" => "press"}}
    end
  end

  describe "a mark is a control too" do
    setup %{config: config} do
      marks = [
        %{
          "id" => 1,
          "role" => "AXButton",
          "label" => "Save",
          "x" => 10,
          "y" => 20,
          "element_ref" => "e1"
        },
        %{"id" => 2, "role" => "AXImage", "label" => "Board", "x" => 30, "y" => 40}
      ]

      session =
        start_session(config, marks: marks, receipt: ComputerUseReceipts.ax(:not_observed))

      # The badges reach the table the only way they can: on a screenshot reply.
      assert {:ok, %{success: true}} =
               run(session, config, %{"action" => "screenshot", "marks" => true})

      %{session: session}
    end

    test "press by mark resolves to the badged control's reference", %{
      config: config,
      session: session
    } do
      assert {:ok, %{success: true}} =
               run(session, config, %{
                 "action" => "press",
                 "observation_id" => @obs,
                 "mark" => 1
               })

      assert_receive {:driver_execute, %{"action" => "press", "element_ref" => "e1"} = request}
      refute Map.has_key?(request, "mark"), "the helper never sees a mark id"
    end

    test "a badge with no reference is refused rather than clicked", %{
      config: config,
      session: session
    } do
      assert {:ok, result} =
               run(session, config, %{
                 "action" => "press",
                 "observation_id" => @obs,
                 "mark" => 2
               })

      assert result.success == false
      assert result.error =~ "mark 2 carries no `element_ref`"
      assert result.error =~ "your choice, not one made for you"
      refute_received {:driver_execute, %{"action" => "press"}}
    end

    test "that same badge still clicks by mark", %{config: config, session: session} do
      assert {:ok, %{success: true}} =
               run(session, config, %{
                 "action" => "left_click",
                 "observation_id" => @obs,
                 "mark" => 2
               })

      assert_receive {:driver_execute, %{"action" => "left_click", "x" => 30, "y" => 40}}
    end
  end
end
