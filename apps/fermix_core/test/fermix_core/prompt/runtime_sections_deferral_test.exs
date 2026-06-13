defmodule FermixCore.Prompt.RuntimeSectionsDeferralTest do
  # async: false — flips the global [fermix_core :tools] deferral flag, which
  # RuntimeSections.build/1 reads.
  use ExUnit.Case, async: false

  alias FermixCore.Prompt.RuntimeSections

  setup do
    previous = Application.get_env(:fermix_core, :tools)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:fermix_core, :tools)
        value -> Application.put_env(:fermix_core, :tools, value)
      end
    end)

    :ok
  end

  test "off: the deferred-tools contract bullet is absent" do
    Application.put_env(:fermix_core, :tools, tool_search: [enabled: false])
    # Note: the literal "tool_search" can still appear as a seeded bridge
    # builtin in the global registry's catalog; assert on the bullet's unique
    # phrase, which is what the flag actually gates.
    refute RuntimeSections.build([]) =~ "schemas load on demand"
    refute RuntimeSections.build([]) =~ "`tool_describe` when unsure of parameters"
  end

  test "on: the deferred-tools contract bullet is rendered" do
    Application.put_env(:fermix_core, :tools, tool_search: [enabled: true])

    content = RuntimeSections.build([])
    assert content =~ "schemas load on demand"
    assert content =~ "`tool_describe` when unsure of parameters"
    assert content =~ "`tool_search` to discover by capability"
  end
end
