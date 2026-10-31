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

  alias Compux.Protocol
  alias FermixCore.ComputerUse.Background
  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.HelperActions
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
         marks: Keyword.get(opts, :marks),
         extra: Keyword.get(opts, :extra, %{}),
         actions: Keyword.get(opts, :actions, Protocol.actions()),
         input_methods: Keyword.get(opts, :input_methods, ~w(foreground_hid ax))
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

    # The handshake of the macOS helper unless a case names another one.
    defp response(state, %{"action" => "hello"}) do
      %{
        "ok" => true,
        "protocol_version" => Protocol.protocol_version(),
        "actions" => state.actions,
        "capabilities" => %{"input_methods" => state.input_methods}
      }
    end

    defp response(state, %{"action" => "elements"} = request) do
      %{"ok" => true, "elements" => state.elements}
      |> ComputerUseObservations.stamp(request)
      |> Map.merge(state.extra)
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
      |> Map.merge(state.extra)
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

  # The reading the tool's words and its row follow (`HelperActions`).
  defp read_helper(actions, input_methods) do
    start_supervised!({HelperActions, read_at_boot?: false})
    :ok = HelperActions.record(%{actions: actions, input_methods: input_methods})
  end

  defp press(ref \\ "e1"),
    do: %{"action" => "press", "observation_id" => @obs, "element_ref" => ref}

  defp ax_receipt(effect, extra) do
    :sent
    |> ComputerUseReceipts.receipt(
      effect: effect,
      input_method: "ax",
      check: %{"kind" => "semantic"}
    )
    |> Map.merge(extra)
  end

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
          {"ax_action_unsupported", "another verb it lists, or a click by its `element_ref`"},
          {"addressing_conflict", "it names its target twice"},
          {"element_required", "it names no control"},
          {"observation_required", "it names no `observation_id`"},
          {"state_unreadable", "nothing was sent rather than guessed"},
          {"focus_refused", "`focus` never brings a window forward"},
          {"scope_not_found", "that scope has nothing in it right now"},
          {"accessibility_unavailable", "Work by pixels"},
          {"pixels_unavailable", "Work by control"},
          {"ambiguous_element", "could not be told apart"},
          {"identity_unknown", "reliably enough to be sure"},
          {"toolkit_accessibility_off", "is not publishing its controls"},
          {"check_unsupported", "its check could not be taken"},
          {"invalid_argument", "Fix that argument and send it again"},
          {"text_outside_layout", "Send it with `paste` instead"},
          {"consent_refused", "Ask them whether they want to allow it"},
          {"consent_timeout", "watch for that prompt"},
          {"unknown_action", "does not offer"},
          {"malformed_frame", "different versions"},
          {"untagged_frame", "different versions"},
          {"unknown_frame_type", "different versions"},
          {"display_asleep", "no capturable display"},
          {"display_disconnected", "no capturable display"},
          {"capture_stalled", "restarts itself after this"}
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

    # Every code protocol 12 answers reaches the model as a sentence of its own,
    # never as the raw code (M86 P2), so a code the library adds fails here until
    # it has one. Left out on purpose: the bound-window family speaks only with its
    # flag on (`Background`, tested there), and `request_too_large` is never
    # correlated to a request, so no action reply carries it.
    test "every refusal the protocol names renders as a sentence", %{config: config} do
      for code <- Protocol.refusals() -- ["request_too_large" | Background.codes()] do
        session =
          start_supervised!(
            {Session,
             [
               config: config,
               driver: {RefusingDriver, [code: code]},
               origin: :interactive,
               session_id: "cua_every_#{code}"
             ]},
            id: {:every_refusal, code}
          )

        assert {:ok, result} = run(session, config, press())
        assert result.success == false, code
        refute result.error =~ "action failed:", "#{code} renders as a raw term"
        :ok = stop_supervised!({:every_refusal, code})
      end
    end

    # The argument and check refusals name an argument only where the reading
    # offers the action it belongs to.
    test "the argument and check refusals name only what the reading offers", %{config: config} do
      pixel =
        for code <- ~w(invalid_argument check_unsupported), into: %{} do
          session =
            start_supervised!(
              {Session,
               [
                 config: config,
                 driver: {RefusingDriver, [code: code]},
                 origin: :interactive,
                 session_id: "cua_reading_#{code}"
               ]},
              id: {:reading_refusal, code}
            )

          {:ok, result} = run(session, config, press())
          :ok = stop_supervised!({:reading_refusal, code})
          {code, result.error}
        end

      assert pixel["check_unsupported"] =~ "its check could not be taken"
      assert pixel["invalid_argument"] =~ "Fix that argument and send it again"

      # Two examples are joined by "or" alone.
      assert pixel["invalid_argument"] =~
               "a combination that cannot go together or a `type` without `text`."

      for {code, error} <- pixel, word <- ~w(`scope` `query` `until` `on` `wait_for`) do
        refute error =~ word, "#{code} names #{word} to a pixel helper"
      end

      read_helper(Protocol.actions(), ~w(foreground_hid ax))

      session =
        start_supervised!(
          {Session,
           [
             config: config,
             driver: {RefusingDriver, [code: "invalid_argument"]},
             origin: :interactive,
             session_id: "cua_reading_full"
           ]},
          id: :reading_full
        )

      {:ok, result} = run(session, config, press())

      for word <- ~w(`scope` `query` `until` `on`), do: assert(result.error =~ word)
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

    # References exist only where the helper lists controls, so only there does
    # the sentence name one, whichever side refused: this side's gate or the
    # helper's own code. A mark and a point clash on any helper that badges marks.
    test "naming a target twice names a reference only where controls are listed", %{
      config: config
    } do
      twice = %{
        "action" => "left_click",
        "observation_id" => @obs,
        "mark" => 3,
        "x" => 1,
        "y" => 2
      }

      pixel_gate = start_session(config, [])
      assert {:ok, gate} = run(pixel_gate, config, twice)
      refute_received {:driver_execute, %{"action" => "left_click"}}

      pixel_helper =
        start_supervised!(
          {Session,
           [
             config: config,
             driver: {RefusingDriver, [code: "addressing_conflict"]},
             origin: :interactive,
             session_id: "cua_twice_helper"
           ]},
          id: :twice_helper
        )

      assert {:ok, helper} = run(pixel_helper, config, press())

      for error <- [gate.error, helper.error] do
        assert error =~ "it names its target twice — a `mark` together with coordinates"
        refute error =~ "element_ref"
      end

      read_helper(Protocol.actions(), ~w(foreground_hid ax))
      controls = start_session(config, [])
      assert {:ok, result} = run(controls, config, twice)
      assert result.error =~ "an `element_ref` together with coordinates or a `mark`"
    end

    test "a reference with no image named is refused for want of the image", %{config: config} do
      session = start_session(config, [])

      assert {:ok, result} =
               run(session, config, %{"action" => "press", "element_ref" => "e1"})

      assert result.error =~ "it names no `observation_id`"
      assert result.error =~ "the listing the target came from"
      refute_received {:driver_execute, %{"action" => "press"}}
    end
  end

  # Protocol 12 (M86 P2): what a receipt adds once the helper reads states and
  # looks for what an action left open. Built by hand from the contract's own
  # examples (compux `PROTOCOL.md` §3–§5).
  describe "protocol 12 receipts" do
    test "the dialogs and menus an action left open are named, and counted on the row", %{
      config: config
    } do
      receipt =
        ax_receipt("not_observed", %{
          "surfaces" => [
            %{"kind" => "dialog", "native_kind" => "AXSheet", "label" => "Clear all items?"}
          ]
        })

      session = start_session(config, receipt: receipt)

      assert {:ok, result} = run(session, config, press())

      assert result.output =~ ~s(Open after this action: dialog "Clear all items?".)
      assert result.output =~ ~s(`scope` "dialog")
      assert_receive {:tool_exec, %{cu_surfaces_count: 1, cu_verb: "press"} = metadata}
      refute inspect(metadata) =~ "Clear all items", "a surface's name is content"
    end

    test "nothing open is counted as zero and says nothing", %{config: config} do
      session = start_session(config, receipt: ax_receipt("not_observed", %{"surfaces" => []}))

      assert {:ok, result} = run(session, config, press())

      refute result.output =~ "Open after this action"
      assert_receive {:tool_exec, %{cu_surfaces_count: 0}}
    end

    test "a receipt that did not look carries no count", %{config: config} do
      session = start_session(config, receipt: ax_receipt("not_observed", %{}))

      assert {:ok, _result} = run(session, config, press())

      assert_receive {:tool_exec, metadata}
      refute Map.has_key?(metadata, :cu_surfaces_count), "absent is not looked, never zero"
    end

    test "the control read back carries its normalised role and states", %{config: config} do
      session =
        start_session(config,
          receipt: ax_receipt("changed", %{}),
          extra: %{
            "element_after" => %{
              "present" => true,
              "role" => "checkbox",
              "native_role" => "AXCheckBox",
              "label" => "Bold",
              "enabled" => true,
              "checked" => true
            }
          }
        )

      assert {:ok, result} = run(session, config, press())

      assert result.output =~ ~s(The control now reads: checkbox "Bold", enabled, on.)

      assert_receive {:tool_exec,
                      %{outcome: :performed, effect: :changed, check_kind: "semantic"}}
    end

    test "a condition the action waited on says what it found", %{config: config} do
      receipt =
        ComputerUseReceipts.receipt(:sent,
          effect: "not_observed",
          input_method: "ax",
          check: %{"kind" => "semantic", "until" => "not_met", "looks" => 51, "waited_ms" => 5004}
        )

      session = start_session(config, receipt: receipt)

      assert {:ok, result} = run(session, config, press())

      assert result.output =~ "What you waited for did not hold within its timeout"
      assert result.output =~ "do not repeat it for that"
    end

    # A secure field's value is never read back (PROTOCOL.md §4.7). A reply that
    # carries one anyway must not reach the model, the row or anything else.
    test "typing into a secure field never repeats a value, even one the reply carried", %{
      config: config
    } do
      secret = "correct horse battery"

      session =
        start_session(config,
          receipt: ax_receipt("not_observed", %{}),
          extra: %{
            "value" => secret,
            "element_after" => %{
              "present" => true,
              "role" => "textfield",
              "label" => "Password",
              "secure" => true,
              "enabled" => true
            }
          }
        )

      assert {:ok, result} =
               run(session, config, %{
                 "action" => "type",
                 "observation_id" => @obs,
                 "element_ref" => "e3",
                 "text" => secret
               })

      assert result.output =~ "The field is secure; its value is not read back."
      refute inspect(result) =~ secret
    end

    # Typing into a control rides the contract's own signal, the helper's
    # `input_methods` (PROTOCOL.md §1), not whether it lists controls.
    test "typing into a control is a verb on it only where the helper types by accessibility",
         %{config: config} do
      read_helper(Protocol.actions(), ~w(foreground_hid))
      keyboard = start_session(config, input_methods: ~w(foreground_hid))
      type = %{"action" => "type", "observation_id" => @obs, "element_ref" => "e2", "text" => "x"}

      assert {:ok, _result} = run(keyboard, config, type)
      assert_receive {:driver_execute, %{"action" => "type"} = sent}
      refute sent["check"] == "semantic"
      assert_receive {:tool_exec, plain}
      refute Map.has_key?(plain, :cu_verb)

      :ok =
        HelperActions.record(%{actions: Protocol.actions(), input_methods: ~w(foreground_hid ax)})

      accessibility = start_session(config, [])

      assert {:ok, _result} = run(accessibility, config, type)
      assert_receive {:driver_execute, %{"action" => "type", "check" => "semantic"}}
      assert_receive {:tool_exec, %{cu_verb: "type"}}
    end

    # The way to read a field back names `inspect` only where this helper has it.
    test "a set_value that did not read back names `inspect` only where the helper has it", %{
      config: config
    } do
      set = %{
        "action" => "set_value",
        "observation_id" => @obs,
        "element_ref" => "e2",
        "value" => "a"
      }

      receipt = ax_receipt("not_observed", %{})

      without =
        start_session(config, receipt: receipt, actions: Protocol.actions() -- ["inspect"])

      assert {:ok, result} = run(without, config, set)
      assert result.output =~ "reading the field back did not return it"
      refute result.output =~ "inspect"

      with_inspect = start_session(config, receipt: receipt)
      assert {:ok, result} = run(with_inspect, config, set)
      assert result.output =~ "`inspect` the control"
    end

    test "a walk's cut and its message count reach the row", %{config: config} do
      session =
        start_session(config,
          elements: [%{"element_ref" => "e1", "role" => "button", "label" => "Save"}],
          extra: %{"truncated" => "nodes", "ax_messages" => 412}
        )

      assert {:ok, %{success: true}} = run(session, config, %{"action" => "elements"})
      assert_receive {:tool_exec, %{cu_truncated: "nodes", cu_ax_messages: 412}}
    end

    test "a pointer action names no verb on its row", %{config: config} do
      session = start_session(config, [])

      assert {:ok, %{success: true}} =
               run(session, config, %{
                 "action" => "left_click",
                 "observation_id" => @obs,
                 "x" => 1,
                 "y" => 2
               })

      assert_receive {:tool_exec, metadata}
      refute Map.has_key?(metadata, :cu_verb)
    end

    test "typing at the focus names no verb; typing into a control does", %{config: config} do
      read_helper(Protocol.actions(), ~w(foreground_hid ax))
      session = start_session(config, [])

      assert {:ok, _result} = run(session, config, %{"action" => "type", "text" => "hi"})
      assert_receive {:tool_exec, plain}
      refute Map.has_key?(plain, :cu_verb)

      assert {:ok, _result} =
               run(session, config, %{"action" => "type", "element_ref" => "e2", "text" => "hi"})

      assert_receive {:tool_exec, %{cu_verb: "type"} = named}
      refute named |> Map.drop([:input]) |> inspect() =~ ~s("hi"), "the text is content"
    end
  end

  # Every verb on a control, and `type` into one, names the listing its reference
  # came from — refused HERE, before any driver call, like `press` (M86 P2).
  describe "a verb on a control names its listing" do
    for action <- ~w(focus select toggle expand collapse scroll_to) do
      test "#{action} without an observation_id is refused before the driver", %{config: config} do
        session = start_session(config, [])

        assert {:ok, result} =
                 run(session, config, %{"action" => unquote(action), "element_ref" => "e1"})

        assert result.success == false
        assert result.error =~ "it names no `observation_id`"
        refute_received {:driver_execute, %{"action" => unquote(action)}}
        assert_receive {:tool_exec, %{geometry_refusal: "observation_required"}}
      end
    end

    test "type into a control needs its listing; type at the focus needs none", %{config: config} do
      session = start_session(config, [])

      assert {:ok, refused} =
               run(session, config, %{"action" => "type", "element_ref" => "e2", "text" => "x"})

      assert refused.error =~ "it names no `observation_id`"

      assert {:ok, %{success: true}} = run(session, config, %{"action" => "type", "text" => "x"})
    end

    test "a drill into a control needs the listing that named it", %{config: config} do
      session = start_session(config, [])

      assert {:ok, result} = run(session, config, %{"action" => "elements", "root" => "e12"})

      assert result.error =~ "it names no `observation_id`"
      refute_received {:driver_execute, %{"action" => "elements"}}
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
