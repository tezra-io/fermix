defmodule FermixCore.ComputerHistory.RecentActivityTest do
  @moduledoc """
  MILESTONE_32 §11.1 — the Recent Activity section note. Asserts the gated-off
  cases (host-OS-independent); the rendered-digest path is covered by the Gate
  + Recall unit tests.
  """
  use ExUnit.Case, async: false

  alias FermixCore.ComputerHistory.RecentActivity

  defp local_route, do: {%{provider: :ollama, base_url: "http://localhost:11434/v1"}, []}

  defp operator_ctx,
    do: %{
      source_trust: :operator,
      computer_use_origin: :interactive,
      ordered_routes: [local_route()]
    }

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

  test "note is nil when the feature is disabled" do
    Application.put_env(:fermix_core, :computer_history, enabled: false)
    assert RecentActivity.note(operator_ctx()) == nil
  end

  test "note is nil for a guest turn even when enabled" do
    Application.put_env(:fermix_core, :computer_history, enabled: true, summarizer: :local)

    guest = %{
      source_trust: :guest,
      computer_use_origin: :interactive,
      ordered_routes: [local_route()]
    }

    assert RecentActivity.note(guest) == nil
  end

  test "note is nil on an ungranted-remote chain" do
    Application.put_env(:fermix_core, :computer_history, enabled: true, summarizer: :local)
    remote = {%{provider: :openai, base_url: "https://api.openai.com/v1"}, []}
    assert RecentActivity.note(%{operator_ctx() | ordered_routes: [remote]}) == nil
  end
end
