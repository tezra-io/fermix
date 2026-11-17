defmodule FermixCore.Tools.PhoneCallControlsTest do
  # The in-call controls (M94 §07): offered and run only inside a phone call's
  # backend turn, on the call and the handle the turn's context carries, never
  # on a model's argument; one exec event per model call, refusals included.
  use ExUnit.Case, async: true

  alias FermixCore.PhoneCalls.Limits
  alias FermixCore.Tools.PhoneCallEnd
  alias FermixCore.Tools.PhoneCallPressKeys
  alias FermixTestSupport.TelemetryCapture

  # The call's worker: it accepts only the handle it minted for the running
  # turn, and tells the calling process what it was asked.
  defmodule Worker do
    def press_keys(call_id, handle, keys) do
      send(self(), {:press_keys, call_id, handle, keys})

      if handle == "h-current",
        do: {:ok, %{confirmed: keys, unconfirmed: ""}},
        else: {:error, :stale_handle}
    end

    def finish(call_id, handle, reason, note) do
      send(self(), {:finish, call_id, handle, reason, note})
      if handle == "h-current", do: :ok, else: {:error, :stale_handle}
    end
  end

  # A worker whose last key was sent but never acknowledged.
  defmodule UnackedWorker do
    def press_keys(_call_id, _handle, "12"),
      do: {:ok, %{confirmed: "1", unconfirmed: "2", stopped: :ack_timeout}}
  end

  defp in_call(session, overrides \\ %{}) do
    Map.merge(
      %{
        agent_name: "phone_call",
        conversation_key: {"phone_call", "pc_1", :root},
        session_id: session,
        source_trust: :phone_call,
        computer_use_origin: :unattended,
        phone_call: %{call_id: "pc_1", handle: "h-current", delegation_id: "d1", revision: 1},
        phone_call_controls: Worker
      },
      overrides
    )
  end

  # An owner's own turn: even one that carries a call-shaped map is no call.
  defp owner_turn(session) do
    %{
      agent_name: "main",
      conversation_key: {"telegram", "40017", :root},
      session_id: session,
      source_trust: :operator,
      computer_use_origin: :interactive,
      phone_call: %{call_id: "pc_1", handle: "h-current"},
      phone_call_controls: Worker
    }
  end

  setup do
    session = "phone_call_pc_#{System.unique_integer([:positive])}"
    TelemetryCapture.attach([[:fermix, :tool, :exec]], session_id: session)
    %{session: session}
  end

  describe "phone_call_press_keys" do
    test "presses on the turn's call with its handle, never one the model names", ctx do
      args = %{"keys" => "1#", "handle" => "h-forged", "call_id" => "pc_other"}

      assert {:ok, %{success: true, output: output}} =
               PhoneCallPressKeys.execute(args, in_call(ctx.session))

      assert_received {:press_keys, "pc_1", "h-current", "1#"}
      assert %{"confirmed" => "1#", "unconfirmed" => ""} = Jason.decode!(output)

      assert_received {:telemetry, [:fermix, :tool, :exec], _m,
                       %{tool: "phone_call_press_keys", success: true} = meta}

      assert meta.key_count == 2
      refute inspect(meta) =~ "1#"
    end

    test "says which keys were never acknowledged", ctx do
      context = in_call(ctx.session, %{phone_call_controls: UnackedWorker})

      assert {:ok, %{success: true, output: output}} =
               PhoneCallPressKeys.execute(%{"keys" => "12"}, context)

      assert %{
               "confirmed" => "1",
               "unconfirmed" => "2",
               "stopped" => "ack_timeout",
               "detail" => detail
             } =
               Jason.decode!(output)

      assert detail =~ "Do not press them again"
    end

    # No registry holds it (`PhoneCallToolsTrustInvariantTest`); called anyway
    # from another turn, it refuses.
    test "is not run outside a phone call's backend turn", ctx do
      assert {:ok, %{success: false, error: error}} =
               PhoneCallPressKeys.execute(%{"keys" => "1"}, owner_turn(ctx.session))

      assert error =~ "only on a phone call's backend turn"
      refute_received {:press_keys, _call, _handle, _keys}

      assert_received {:telemetry, [:fermix, :tool, :exec], _m,
                       %{tool: "phone_call_press_keys", success: false}}
    end

    test "a stale turn's handle presses nothing", ctx do
      context = in_call(ctx.session, %{phone_call: %{call_id: "pc_1", handle: "h-old"}})

      assert {:ok, %{success: false, error: error}} =
               PhoneCallPressKeys.execute(%{"keys" => "1"}, context)

      assert error =~ "stale_handle"
    end

    test "only digits, * and #, within the call's key cap", ctx do
      for keys <- ["", "1a", "4111 1111", String.duplicate("1", 33), nil] do
        assert {:ok, %{success: false}} =
                 PhoneCallPressKeys.execute(%{"keys" => keys}, in_call(ctx.session))
      end

      refute_received {:press_keys, _call, _handle, _keys}
    end
  end

  describe "phone_call_end" do
    test "ends the turn's call with each of the worker's four reasons", ctx do
      for {word, reason} <- [
            {"done", :done},
            {"needs_owner", :needs_owner},
            {"cannot_proceed", :cannot_proceed},
            {"voicemail", :voicemail}
          ] do
        args = %{"reason" => word, "note" => "  left a note  ", "handle" => "h-forged"}
        assert {:ok, %{success: true}} = PhoneCallEnd.execute(args, in_call(ctx.session))
        assert_received {:finish, "pc_1", "h-current", ^reason, "left a note"}
      end

      assert Enum.sort(PhoneCallEnd.reasons()) == [
               "cannot_proceed",
               "done",
               "needs_owner",
               "voicemail"
             ]
    end

    test "refuses another reason or a note past its bound", ctx do
      for args <- [
            %{"reason" => "hung_up", "note" => ""},
            %{
              "reason" => "done",
              "note" => String.duplicate("x", Limits.max_finish_note_bytes() + 1)
            },
            %{"reason" => "done"}
          ] do
        assert {:ok, %{success: false}} = PhoneCallEnd.execute(args, in_call(ctx.session))
      end

      refute_received {:finish, _call, _handle, _reason, _note}
    end

    test "is not run outside a phone call's backend turn", ctx do
      args = %{"reason" => "done", "note" => ""}
      assert {:ok, %{success: false}} = PhoneCallEnd.execute(args, owner_turn(ctx.session))
      refute_received {:finish, _call, _handle, _reason, _note}

      assert_received {:telemetry, [:fermix, :tool, :exec], _m,
                       %{tool: "phone_call_end", success: false, reason: "done"}}
    end

    test "a stale turn's handle ends nothing", ctx do
      context = in_call(ctx.session, %{phone_call: %{call_id: "pc_1", handle: "h-old"}})
      args = %{"reason" => "done", "note" => ""}
      assert {:ok, %{success: false, error: error}} = PhoneCallEnd.execute(args, context)
      assert error =~ "stale_handle"
    end
  end
end
