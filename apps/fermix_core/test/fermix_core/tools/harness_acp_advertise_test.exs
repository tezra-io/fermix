defmodule FermixCore.Tools.HarnessAcpAdvertiseTest do
  # async: false — the gate reads the global `:harness` app env and the vendor
  # detector seam; both are forced here and restored on exit.
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.BuiltinSeeder

  # MILESTONE_29_ACP_AGENT_SURFACE §4 ("Detached work"): an ACP session is owned
  # by the client and ends with it, so no coding-harness tool is advertised on
  # that surface — a finished run would have nowhere to report back.
  #
  # The tool list is READ FROM THE SEEDER (`BuiltinSeeder.harness_modules/1`,
  # the same source that decides which harness tools get registered), never
  # spelled out here: the M28 lesson is that a feature-level gate asserted over a
  # hand-written list drifts the moment an eighth tool is added. With every seam
  # forced on, `harness_modules/1` returns the whole family.
  defp seeded_harness_tools do
    BuiltinSeeder.harness_modules(
      harness_enabled: true,
      cloud_enabled: true,
      vendor_available_fn: fn _vendor -> true end
    )
  end

  setup do
    prior_harness = Application.get_env(:fermix_core, :harness)
    prior_detector = Application.get_env(:fermix_core, :harness_vendor_detector)

    Application.put_env(:fermix_core, :harness, enabled: true, approved: true)
    # Both CLIs present and no configured default ⇒ `advertise_vendor?` is true
    # for both run tools, so the channel is the only variable under test.
    Application.put_env(:fermix_core, :harness_vendor_detector, fn ->
      %{
        "codex" => %{vendor: "codex", available?: true},
        "claude" => %{vendor: "claude", available?: true}
      }
    end)

    on_exit(fn ->
      restore(:harness, prior_harness)
      restore(:harness_vendor_detector, prior_detector)
    end)

    %{tools: seeded_harness_tools()}
  end

  test "the seeder still registers a harness family to gate", %{tools: tools} do
    assert length(tools) >= 7
  end

  test "no harness tool is advertised on the acp channel", %{tools: tools} do
    context = attended_context("acp")

    for tool <- tools do
      refute tool.advertise?(context), "#{inspect(tool)} advertised on an ACP turn"
    end
  end

  test "every harness tool still advertises on an ordinary operator channel", %{tools: tools} do
    context = attended_context("telegram")

    for tool <- tools do
      assert tool.advertise?(context), "#{inspect(tool)} stayed hidden on a telegram turn"
    end
  end

  test "a turn with no channel key keeps advertising", %{tools: tools} do
    context = Map.delete(attended_context("telegram"), :channel)

    for tool <- tools do
      assert tool.advertise?(context), "#{inspect(tool)} stayed hidden on a channel-less turn"
    end
  end

  defp attended_context(channel) do
    %{
      agent_name: "main",
      channel: channel,
      source_trust: :operator,
      subagent_depth: 0,
      reply_fn: fn _text -> :ok end,
      conversation_key: {channel, "session-1", :root},
      session_id: "main-1"
    }
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, prior), do: Application.put_env(:fermix_core, key, prior)
end
