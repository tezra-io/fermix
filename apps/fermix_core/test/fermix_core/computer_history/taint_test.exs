defmodule FermixCore.ComputerHistory.TaintTest do
  @moduledoc "MILESTONE_32 §13.6 — the strict compaction/replay taint (inv. 20, 2nd clause)."
  use ExUnit.Case, async: false

  alias FermixCore.ComputerHistory.Gate
  alias FermixCore.ComputerHistory.Taint

  defp local_route, do: {%{provider: :ollama, base_url: "http://localhost:11434/v1"}, []}

  defp remote_route(provider),
    do: {%{provider: provider, base_url: "https://api.#{provider}.example/v1"}, []}

  defp operator_ctx(chain),
    do: %{source_trust: :operator, computer_use_origin: :interactive, ordered_routes: chain}

  setup do
    original = Application.get_env(:fermix_core, :computer_history)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:fermix_core, :computer_history)
        value -> Application.put_env(:fermix_core, :computer_history, value)
      end
    end)

    :ok
  end

  # Pin summarizer :local unless overridden, so the default (`:default_provider`,
  # §22.1) doesn't auto-grant the primary and change which chains are tainted.
  defp enable(kw) do
    kw = Keyword.put_new(kw, :summarizer, :local)
    Application.put_env(:fermix_core, :computer_history, [enabled: true] ++ kw)
  end

  defp tainted_msg,
    do: %{role: "assistant", content: "You were reading the Q3 report.", history_tainted: true}

  defp clean_msg, do: %{role: "user", content: "what was I doing?"}

  describe "mask_for_chain/2" do
    test "an all-local chain leaves tainted and clean messages untouched" do
      enable([])
      msgs = [clean_msg(), tainted_msg()]
      assert Taint.mask_for_chain(msgs, [local_route()]) == msgs
    end

    test "an ungranted-remote chain masks the tainted message, keeps the clean one" do
      enable([])

      [clean, tainted] =
        Taint.mask_for_chain([clean_msg(), tainted_msg()], [remote_route(:openai)])

      assert clean == clean_msg()
      assert tainted.role == "assistant"
      # The masked copy DROPS the marker: its content is the neutral
      # placeholder, so downstream consumers (a compaction summarizing the
      # masked tail, a replace persisting it) treat it as clean instead of
      # tainting a checkpoint summary that contains no activity content.
      refute Map.has_key?(tainted, :history_tainted)
      refute tainted.content =~ "Q3 report"
      assert tainted.content =~ "omitted"
    end

    test "a granted-remote chain (Tier 2) leaves the tainted message intact" do
      enable(remote_summaries: [:anthropic])
      msgs = [tainted_msg()]
      assert Taint.mask_for_chain(msgs, [remote_route(:anthropic)]) == msgs
    end

    test "masking is independent of enabled? (a disabled posture still masks on remote)" do
      # The taint is a property of the message's origin, not the current config.
      Application.put_env(:fermix_core, :computer_history, enabled: false)
      [tainted] = Taint.mask_for_chain([tainted_msg()], [remote_route(:openai)])
      assert tainted.content =~ "omitted"
    end

    test "a nil chain fails closed (masks)" do
      enable([])
      [tainted] = Taint.mask_for_chain([tainted_msg()], nil)
      assert tainted.content =~ "omitted"
    end
  end

  describe "mask_for_chain/3 — the turn's frozen grant set" do
    test "the frozen snapshot masks a chain the live config would now permit" do
      # A mid-turn grant edit must not retroactively un-mask the replay the
      # turn already built: every mask in one turn reads one grant set.
      enable([])
      snapshot = Gate.snapshot(operator_ctx([local_route()]), macos?: true)

      enable(remote_summaries: [:anthropic])

      [masked] =
        Taint.mask_for_chain([tainted_msg()], [remote_route(:anthropic)], snapshot: snapshot)

      assert masked.content =~ "omitted"
      assert Taint.mask_for_chain([tainted_msg()], [remote_route(:anthropic)]) == [tainted_msg()]
    end

    test "the frozen snapshot permits a chain the live config would now mask" do
      enable(remote_summaries: [:anthropic])
      snapshot = Gate.snapshot(operator_ctx([local_route()]), macos?: true)

      Application.put_env(:fermix_core, :computer_history, enabled: false)

      msgs = [tainted_msg()]
      assert Taint.mask_for_chain(msgs, [remote_route(:anthropic)], snapshot: snapshot) == msgs
      [live] = Taint.mask_for_chain(msgs, [remote_route(:anthropic)])
      assert live.content =~ "omitted"
    end

    test "an empty opts list is byte-identical to the 2-arity call" do
      enable([])
      msgs = [clean_msg(), tainted_msg()]

      for chain <- [[local_route()], [remote_route(:openai)], nil] do
        assert Taint.mask_for_chain(msgs, chain, []) == Taint.mask_for_chain(msgs, chain)
      end
    end
  end

  describe "carries_unmasked_taint?/3" do
    test "true when a permitted chain carries a tainted message unmasked" do
      enable([])
      assert Taint.carries_unmasked_taint?([clean_msg(), tainted_msg()], [local_route()])
    end

    test "false on an ungranted-remote chain (the message was masked)" do
      enable([])
      refute Taint.carries_unmasked_taint?([tainted_msg()], [remote_route(:openai)])
    end

    test "false when no message carries the marker" do
      enable([])
      refute Taint.carries_unmasked_taint?([clean_msg()], [local_route()])
      refute Taint.carries_unmasked_taint?([], [local_route()])
    end

    test "a nil chain fails closed" do
      enable([])
      refute Taint.carries_unmasked_taint?([tainted_msg()], nil)
    end

    test "a disabled feature still sees the taint on a local chain" do
      # The marker outlives `/history off`, so a reply paraphrasing it must
      # still inherit the stamp.
      Application.put_env(:fermix_core, :computer_history, enabled: false)
      assert Taint.carries_unmasked_taint?([tainted_msg()], [local_route()])
    end

    test "reads the turn's frozen grant set when given a snapshot" do
      enable(remote_summaries: [:anthropic])
      snapshot = Gate.snapshot(operator_ctx([local_route()]), macos?: true)

      Application.put_env(:fermix_core, :computer_history, enabled: false)

      assert Taint.carries_unmasked_taint?([tainted_msg()], [remote_route(:anthropic)],
               snapshot: snapshot
             )

      refute Taint.carries_unmasked_taint?([tainted_msg()], [remote_route(:anthropic)])
    end

    test "a string-keyed marker (a row straight off the Repo) counts" do
      enable([])
      row = %{"role" => "assistant", "content" => "…", "history_tainted" => true}
      assert Taint.carries_unmasked_taint?([row], [local_route()])
    end
  end

  describe "tainted?/1" do
    test "recognises both marker spellings and nothing else" do
      assert Taint.tainted?(tainted_msg())
      assert Taint.tainted?(%{"history_tainted" => true})
      refute Taint.tainted?(clean_msg())
      refute Taint.tainted?(%{history_tainted: false})
      refute Taint.tainted?(%{})
    end
  end

  describe "tainted_turn?/2" do
    test "an operator turn on an all-local permitted chain is tainted" do
      enable([])
      assert Taint.tainted_turn?(operator_ctx([local_route()]), macos?: true)
    end

    test "a guest turn is not tainted" do
      enable([])

      ctx = %{
        source_trust: :guest,
        computer_use_origin: :interactive,
        ordered_routes: [local_route()]
      }

      refute Taint.tainted_turn?(ctx, macos?: true)
    end

    test "an ungranted-remote chain is not tainted (no section this turn)" do
      enable([])
      refute Taint.tainted_turn?(operator_ctx([remote_route(:openai)]), macos?: true)
    end

    test "a disabled feature is never tainted" do
      Application.put_env(:fermix_core, :computer_history, enabled: false)
      refute Taint.tainted_turn?(operator_ctx([local_route()]), macos?: true)
    end

    test "the turn's frozen snapshot wins over a mid-turn config flip" do
      # The stamp must read the SAME decision the section injection read: a
      # `/history off` landing while the turn is running tools must not
      # un-stamp a reply whose prompt already carried the section.
      enable([])
      ctx = operator_ctx([local_route()])
      snapshot = Gate.snapshot(ctx, macos?: true)

      Application.put_env(:fermix_core, :computer_history, enabled: false)

      assert Taint.tainted_turn?(ctx, snapshot: snapshot)
      refute Taint.tainted_turn?(ctx, macos?: true)
    end
  end
end
