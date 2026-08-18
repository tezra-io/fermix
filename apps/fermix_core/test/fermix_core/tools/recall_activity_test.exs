defmodule FermixCore.Tools.RecallActivityTest do
  @moduledoc """
  MILESTONE_32 §11.2 — the recall_activity tool. Asserts the fail-closed cases
  (guest / worker / disabled / ungranted-remote chain), which hold regardless of
  host OS; the permitted path is proven by the Gate + Recall unit tests (which
  inject macos?).
  """
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.Tools.RecallActivity

  defp local_route, do: {%{provider: :ollama, base_url: "http://localhost:11434/v1"}, []}
  defp remote_route(p), do: {%{provider: p, base_url: "https://api.#{p}.example/v1"}, []}

  defp ctx(overrides) do
    Map.merge(
      %{
        agent_name: "main",
        conversation_key: {"cli", "owner", "root"},
        source_trust: :operator,
        computer_use_origin: :interactive,
        ordered_routes: [local_route()]
      },
      overrides
    )
  end

  setup do
    original = Application.get_env(:fermix_core, :computer_history)
    Application.put_env(:fermix_core, :computer_history, enabled: true, summarizer: :local)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:fermix_core, :computer_history)
        value -> Application.put_env(:fermix_core, :computer_history, value)
      end
    end)

    :ok
  end

  test "is a registered, classified, owner-only built-in" do
    assert RecallActivity.name() == "recall_activity"
    assert RecallActivity in BuiltinSeeder.builtin_tool_modules()
    assert Builtin.owner_only_declared?("recall_activity")

    capability = Builtin.from_tool_module(RecallActivity)
    assert capability.owner_only? == true
  end

  describe "advertise?/1 fails closed" do
    test "a guest sender never sees the tool" do
      refute RecallActivity.advertise?(ctx(%{source_trust: :guest}))
    end

    test "a subagent worker never sees the tool" do
      refute RecallActivity.advertise?(ctx(%{subagent_depth: 1}))
    end

    test "disabled config hides the tool" do
      Application.put_env(:fermix_core, :computer_history, enabled: false)
      refute RecallActivity.advertise?(ctx(%{}))
    end

    test "an ungranted-remote chain hides the tool" do
      refute RecallActivity.advertise?(ctx(%{ordered_routes: [remote_route(:openai)]}))
    end
  end

  describe "execute/2 re-checks the Gate" do
    test "a guest execution is refused" do
      assert {:ok, result} =
               RecallActivity.execute(%{"window" => "today"}, ctx(%{source_trust: :guest}))

      refute result.success
      assert result.error =~ "not available"
    end

    test "an ungranted-remote chain refuses at execute" do
      assert {:ok, result} =
               RecallActivity.execute(%{}, ctx(%{ordered_routes: [remote_route(:openai)]}))

      refute result.success
    end
  end
end
