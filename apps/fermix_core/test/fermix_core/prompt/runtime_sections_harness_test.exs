defmodule FermixCore.Prompt.RuntimeSectionsHarnessTest do
  # async: false — reads the global [fermix_core :harness] keys (`enabled`,
  # `approved`, `default_vendor`), which decide whether the harness section renders
  # at all (design §23.4) and which vendor it steers toward (§7.4). Each test
  # establishes the whole keyword list itself, never inheriting global state.
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Prompt.RuntimeSections

  setup do
    previous = Application.get_env(:fermix_core, :harness)
    put_harness(enabled: true, approved: true)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:fermix_core, :harness)
        value -> Application.put_env(:fermix_core, :harness, value)
      end
    end)

    :ok
  end

  test "renders the coding-harness section with the owner-authored preamble when tools present" do
    content = RuntimeSections.build([], capabilities: [codex_run(), claude_code_run()])

    assert content =~ "### Coding Harness"
    assert content =~ "Delegating repository work."
    assert content =~ "a real fix needs root-cause analysis"
    assert content =~ "your own hands are for the small, non-repo touches."
    assert content =~ "`codex_run`"
    assert content =~ "`claude_code_run`"
  end

  test "omits the coding-harness section when no harness tools are registered" do
    content = RuntimeSections.build([], capabilities: [non_harness_cap()])

    refute content =~ "### Coding Harness"
    refute content =~ "Delegating repository work."
  end

  # §23.4: the run tools are seeded on CLI detection alone but advertise only when
  # the harness is usable, so an unapproved (or disabled) host must render NO
  # steering — otherwise the model is told to route repo work to tools it cannot see.
  test "omits the section entirely when the owner has not approved coding agents" do
    put_harness(enabled: true, approved: false)

    content = RuntimeSections.build([], capabilities: [codex_run(), claude_code_run()])

    refute content =~ "### Coding Harness"
    refute content =~ "Delegating repository work."
    refute content =~ "`codex_run`"
  end

  test "omits the section entirely when the harness is disabled" do
    put_harness(enabled: false, approved: true)

    content = RuntimeSections.build([], capabilities: [codex_run(), claude_code_run()])

    refute content =~ "### Coding Harness"
    refute content =~ "Delegating repository work."
  end

  test "an unusable harness leaves the rest of the catalog untouched" do
    put_harness(enabled: true, approved: false)

    content = RuntimeSections.build([], capabilities: [codex_run(), non_harness_cap()])

    refute content =~ "### Coding Harness"
    assert content =~ "`content_search`"
  end

  test "vendor steer names both tools when default_vendor is set and both CLIs registered" do
    put_harness(default_vendor: "codex", enabled: true, approved: true)

    content = RuntimeSections.build([], capabilities: [codex_run(), claude_code_run()])

    assert content =~ "prefer `codex`"
    assert content =~ "`codex_run` and `claude_code_run` remain available"
    assert content =~ "run the other on an explicit request"
  end

  test "omits the vendor steer when default_vendor is set but only one CLI is registered" do
    put_harness(default_vendor: "codex", enabled: true, approved: true)

    content = RuntimeSections.build([], capabilities: [codex_run()])

    assert content =~ "### Coding Harness"
    assert content =~ "Delegating repository work."
    refute content =~ "run the other on an explicit request"
  end

  test "omits the vendor steer when default_vendor is unset even with both CLIs registered" do
    put_harness(enabled: true, approved: true)

    content = RuntimeSections.build([], capabilities: [codex_run(), claude_code_run()])

    assert content =~ "### Coding Harness"
    refute content =~ "run the other on an explicit request"
  end

  defp put_harness(config), do: Application.put_env(:fermix_core, :harness, config)

  defp codex_run, do: harness_cap("codex_run", "Run a Codex coding task inside a repository.")

  defp claude_code_run,
    do: harness_cap("claude_code_run", "Run a Claude Code coding task inside a repository.")

  defp harness_cap(name, when_to_use) do
    Capability.new(%{
      name: name,
      description: when_to_use,
      parameters: %{"type" => "object"},
      kind: :builtin,
      executor: {__MODULE__, :unused, []},
      policy_class: :exec,
      metadata: %{category: :harness, when_to_use: when_to_use}
    })
  end

  defp non_harness_cap do
    Capability.new(%{
      name: "content_search",
      description: "Search file contents.",
      parameters: %{"type" => "object"},
      kind: :builtin,
      executor: {__MODULE__, :unused, []},
      policy_class: :read_only,
      metadata: %{category: :file, when_to_use: "Search file contents."}
    })
  end
end
