defmodule FermixCore.Realtime.LivePromptTest do
  use ExUnit.Case, async: false

  alias FermixCore.Agents.VoiceCall
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Prompt.BootstrapPaths
  alias FermixCore.Prompt.Defaults
  alias FermixCore.Realtime.LivePrompt

  @title "# LIVE.md — Live Voice Companion"

  setup do
    bootstrap_dir =
      FermixTestSupport.SafeRm.make_tmp_dir!(
        "live-prompt-#{System.unique_integer([:positive, :monotonic])}"
      )

    previous_bootstrap = Application.get_env(:fermix_core, :prompt_bootstrap, [])
    Application.put_env(:fermix_core, :prompt_bootstrap, bootstrap_dir: bootstrap_dir)

    on_exit(fn ->
      Application.put_env(:fermix_core, :prompt_bootstrap, previous_bootstrap)
      FermixTestSupport.SafeRm.rm_rf!(bootstrap_dir)
    end)

    %{agent_id: "main", bootstrap_dir: bootstrap_dir}
  end

  describe "compose/2" do
    test "renders LIVE.md, the backend tools heading, and one line per category" do
      prompt =
        LivePrompt.compose(Defaults.live_md(), [
          capability("read_file", :file),
          capability("write_file", :file),
          capability("web_search", :web)
        ])

      assert prompt =~ @title
      assert prompt =~ "\n\nBackend tools:\n"
      assert prompt =~ "- File & Code: read_file, write_file"
      assert prompt =~ "- Web: web_search"
    end

    test "carries no schemas, no realtime wire vocabulary, no screen share, and no JSON" do
      prompt =
        LivePrompt.compose(Defaults.live_md(), [
          capability("read_file", :file),
          capability("computer_use", :computer),
          capability("screen_share", :computer)
        ])

      refute prompt =~ "parameters"
      refute prompt =~ "server_vad"
      refute prompt =~ "screen_share"
      refute prompt =~ "{"
      assert byte_size(prompt) < 12_000
    end

    test "orders categories the way the built-in capability catalog does" do
      prompt =
        LivePrompt.compose(@title, [
          capability("recall", :memory),
          capability("web_search", :web),
          capability("read_file", :file)
        ])

      assert prompt ==
               @title <>
                 "\n\nBackend tools:\n- File & Code: read_file\n- Web: web_search\n- Memory: recall"
    end
  end

  describe "capability_lines/1" do
    test "drops plugin capabilities and never names screen_share" do
      lines =
        LivePrompt.capability_lines([
          capability("github_list_issues", :plugin),
          capability("screen_share", :computer),
          capability("read_file", :file)
        ])

      assert lines == "- File & Code: read_file"
    end

    test "drops trailing categories past the byte cap and never truncates a line" do
      capabilities =
        Enum.map(1..60, &capability(numbered("file_tool_alpha_beta_gamma", &1), :file)) ++
          Enum.map(1..60, &capability(numbered("web_tool_alpha_beta_gamma", &1), :web))

      lines = LivePrompt.capability_lines(capabilities)

      assert byte_size(lines) <= 3_200
      assert String.starts_with?(lines, "- File & Code: ")
      refute lines =~ "- Web:"
      assert String.ends_with?(lines, numbered("file_tool_alpha_beta_gamma", 60))

      # The cap is what keeps the whole prompt under the API's instruction
      # ceiling no matter how large the capability surface grows.
      assert byte_size(LivePrompt.compose(Defaults.live_md(), capabilities)) < 12_000
    end

    test "labels an unknown category the way the runtime catalog does" do
      assert LivePrompt.capability_lines([capability("odd_tool", :system)]) ==
               "- System: odd_tool"
    end
  end

  describe "backend_addendum/0" do
    test "is a stable non-empty string naming the voice conversation" do
      addendum = LivePrompt.backend_addendum()

      assert is_binary(addendum)
      assert addendum =~ "voice conversation"
      assert byte_size(addendum) > 200
      assert addendum == LivePrompt.backend_addendum()
    end
  end

  describe "eligible_capabilities/1" do
    test "keeps operator tools and drops channel, media, delegation and harness" do
      registry = :"live_prompt_capabilities_#{System.unique_integer([:positive, :monotonic])}"
      start_supervised!({CapabilityRegistry, [name: registry]})

      for {name, category} <- [
            {"read_file", :file},
            {"send_message", :channel},
            {"generate_image", :media},
            {"subagents", :delegation},
            # A coding run launched by a call outlives it, and its completion
            # notice re-enters on the voice channel with no delegation left to
            # answer — so the voice model must never be offered one (M41 §5.1).
            {"codex_run", :harness}
          ] do
        :ok = CapabilityRegistry.register(registry, capability(name, category))
      end

      names = registry |> LivePrompt.eligible_capabilities() |> Enum.map(& &1.name)

      assert names == ["read_file"]
    end

    test "the exclusion list is the shared one the delegation turn also reads" do
      # One list, two surfaces (`TurnRunner` builds the delegation's profile
      # from it): a disagreement between them would advertise a capability the
      # delegation would not be given, and nothing would report it.
      assert VoiceCall.excluded_categories() == [:channel, :media, :delegation, :harness]
    end
  end

  describe "load/2" do
    test "returns the installed LIVE.md content", %{agent_id: agent_id} do
      File.mkdir_p!(BootstrapPaths.agent_dir(agent_id))
      File.write!(BootstrapPaths.live_path(agent_id), "#{@title}\n\noperator edited\n")

      assert {:ok, content} = LivePrompt.load(agent_id, [])
      assert content == "#{@title}\n\noperator edited\n"
    end

    test "falls back to the shipped template when LIVE.md is absent", %{agent_id: agent_id} do
      assert {:ok, content} = LivePrompt.load(agent_id, [])
      assert content == Defaults.live_md()
    end

    test "rejects an agent id that can escape the bootstrap directory" do
      assert {:error, {:invalid_agent_id, "../../etc"}} = LivePrompt.load("../../etc", [])
    end
  end

  defp capability(name, category) do
    Capability.new(%{
      name: name,
      description: "Test tool.",
      parameters: %{"type" => "object"},
      kind: :builtin,
      executor: {__MODULE__, :execute, []},
      policy_class: :read_only,
      metadata: %{category: category, when_to_use: "Never, this is a fixture."}
    })
  end

  defp numbered(prefix, index) do
    "#{prefix}_#{String.pad_leading(Integer.to_string(index), 3, "0")}"
  end
end
