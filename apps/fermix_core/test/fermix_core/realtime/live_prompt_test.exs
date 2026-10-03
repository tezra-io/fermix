defmodule FermixCore.Realtime.LivePromptTest do
  use ExUnit.Case, async: false

  alias FermixCore.Agents.VoiceCall
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Prompt.BootstrapPaths
  alias FermixCore.Prompt.CurrentDate
  alias FermixCore.Prompt.Defaults
  alias FermixCore.Prompt.VoicePresence
  alias FermixCore.Realtime.LivePrompt
  alias FermixCore.Realtime.LiveText

  @title "# LIVE.md — Live Voice Companion"
  @voice_in_chat_suite Path.expand("../../../../../benchmark/suites/voice_in_chat.yaml", __DIR__)

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

  # What a call is told about the owner when nothing is known: the date only.
  # A private call, so nothing about the chat is added either.
  @bare %{
    agent_id: "main",
    assistant_name: nil,
    personalization: [],
    date_note: "Current date: Friday, 2026-10-02 (UTC).",
    prompt_memory: %{user: nil, memory: nil},
    conversation: "private"
  }

  describe "compose/2" do
    # The owner talks to the pet on their Mac, and the model denied being it
    # when the prompt never said so (owner, 2026-09-29).
    test "tells the voice model the pet on the owner's Mac is itself" do
      prompt = LivePrompt.compose(Defaults.live_md(), [capability("web_search", :web)], @bare)

      assert prompt =~ "That pet is you"
      assert prompt =~ "never deny it"
    end

    test "renders LIVE.md, the backend tools heading, and one line per category" do
      prompt =
        LivePrompt.compose(
          Defaults.live_md(),
          [
            capability("read_file", :file),
            capability("write_file", :file),
            capability("web_search", :web)
          ],
          @bare
        )

      assert prompt =~ @title
      assert prompt =~ "\n\nBackend tools:\n"
      assert prompt =~ "- File & Code: read_file, write_file"
      assert prompt =~ "- Web: web_search"
    end

    test "carries no schemas, no realtime wire vocabulary, no screen share, and no JSON" do
      prompt =
        LivePrompt.compose(
          Defaults.live_md(),
          [
            capability("read_file", :file),
            capability("computer_use", :computer),
            capability("screen_share", :computer)
          ],
          @bare
        )

      refute prompt =~ "parameters"
      refute prompt =~ "server_vad"
      refute prompt =~ "screen_share"
      refute prompt =~ "{"
      assert byte_size(prompt) < 12_000
    end

    test "orders categories the way the built-in capability catalog does" do
      prompt =
        LivePrompt.compose(
          @title,
          [
            capability("recall", :memory),
            capability("web_search", :web),
            capability("read_file", :file)
          ],
          @bare
        )

      assert prompt ==
               @title <>
                 "\n\n" <>
                 VoicePresence.text() <>
                 "\n\n" <>
                 @bare.date_note <>
                 "\n\nBackend tools:\n- File & Code: read_file\n- Web: web_search\n- Memory: recall"
    end

    # M56 §4.3 (D5): who the owner is, what day it is and the memory files,
    # generated after LIVE.md and the presence text and before the tools, in
    # this order. SOUL.md is not among them: LIVE.md is the voice's persona.
    test "names the assistant, the owner, the date and the memory, in that order" do
      context = %{
        @bare
        | assistant_name: "Nova",
          personalization: [
            user_name: "Sujeeth",
            timezone: "Europe/London",
            communication_style: "Balanced"
          ],
          prompt_memory: %{user: "- Likes short answers", memory: "- Car is a Model 3"}
      }

      prompt = LivePrompt.compose(@title, [capability("web_search", :web)], context)

      sections = [
        @title,
        VoicePresence.text(),
        "Your name is Nova.",
        "## The owner\n\n- Name: Sujeeth\n- Time zone: Europe/London\n" <>
          "- Communication style: Balanced",
        @bare.date_note,
        "<memory-context>",
        "- Likes short answers",
        "- Car is a Model 3",
        "</memory-context>",
        "Backend tools:"
      ]

      positions = Enum.map(sections, &position(prompt, &1))
      assert positions == Enum.sort(positions)
      assert prompt =~ "NOT new user input"
    end

    test "the owner block holds only the fields that are set" do
      context = %{@bare | personalization: [user_name: "Sujeeth", timezone: "  ", other: "x"]}

      prompt = LivePrompt.compose(@title, [], context)

      assert prompt =~ "## The owner\n\n- Name: Sujeeth\n\n"
      refute prompt =~ "Time zone:"
      refute prompt =~ "Communication style:"
      refute prompt =~ ": x"
    end

    # M56 §4.5: the voice learns from the generated capability section, not
    # from LIVE.md, that a result it cannot say is put in the chat, and only
    # in a call whose results can be.
    test "a call in the chat is told after the tools that results it cannot say go to the chat" do
      prompt =
        LivePrompt.compose(@title, [capability("web_search", :web)], %{
          @bare
          | conversation: "chat"
        })

      assert prompt =~ "Backend tools:\n- Web: web_search\n\n"
      [_before, after_tools] = String.split(prompt, "- Web: web_search", parts: 2)
      assert after_tools =~ "in the owner's chat"
      assert after_tools =~ "never say a result is there otherwise"
      # M56 §4.6: a task still running when the call ends finishes into the chat.
      assert after_tools =~ "goes on after the call ends"
    end

    test "a private call is told nothing about the chat" do
      prompt = LivePrompt.compose(@title, [capability("web_search", :web)], @bare)

      refute prompt =~ "chat"
    end

    test "with nothing set there is no name line, no owner block and no memory frame" do
      prompt = LivePrompt.compose(@title, [], @bare)

      refute prompt =~ "Your name is"
      refute prompt =~ "## The owner"
      refute prompt =~ "<memory-context>"
    end

    # The engine has no tokenizer for the provider's 16,384 token ceiling, so
    # the instructions are bounded in bytes, counted at 4 bytes a token.
    test "past the byte bound MEMORY.md is left out first, then USER.md", %{} do
      max = LivePrompt.instructions_max_bytes()
      assert max <= 16_384 * 4

      user = "- " <> String.duplicate("u", 1_000)
      memory = "- " <> String.duplicate("m", 6_000)
      context = %{@bare | prompt_memory: %{user: user, memory: memory}}
      base = byte_size(LivePrompt.compose(@title, [], @bare))

      # Everything fits: both files.
      fits = LivePrompt.compose(@title, [], context)
      assert fits =~ user and fits =~ memory

      # Room for USER.md but not for MEMORY.md as well.
      padded = @title <> "\n" <> String.duplicate("p", max - base - 4_000)
      user_only = LivePrompt.compose(padded, [], context)
      assert user_only =~ user
      refute user_only =~ memory
      assert byte_size(user_only) <= max

      # Room for neither: the frame goes, LIVE.md and the presence text stay.
      tight = @title <> "\n" <> String.duplicate("p", max - base - 200)
      neither = LivePrompt.compose(tight, [], context)
      refute neither =~ "<memory-context>"
      assert neither =~ tight
      assert neither =~ VoicePresence.text()
      assert byte_size(neither) <= max
    end

    test "LIVE.md and the presence text are never cut, however long" do
      huge = @title <> "\n" <> String.duplicate("p", LivePrompt.instructions_max_bytes())

      prompt = LivePrompt.compose(huge, [], %{@bare | prompt_memory: %{user: "- u", memory: nil}})

      assert prompt =~ huge
      assert prompt =~ VoicePresence.text()
      refute prompt =~ "<memory-context>"
    end
  end

  describe "context/1" do
    setup do
      memory_dir =
        FermixTestSupport.SafeRm.make_tmp_dir!(
          "live-prompt-memory-#{System.unique_integer([:positive, :monotonic])}"
        )

      saved =
        Map.new(
          [:agent, :personalization, :memory],
          &{&1, Application.fetch_env(:fermix_core, &1)}
        )

      previous_memory = Application.get_env(:fermix_core, :memory, [])

      Application.put_env(
        :fermix_core,
        :memory,
        Keyword.merge(previous_memory, prompt_base_dir: memory_dir, agent_id: "main")
      )

      on_exit(fn ->
        Enum.each(saved, &restore_env/1)
        FermixTestSupport.SafeRm.rm_rf!(memory_dir)
      end)

      %{memory_dir: memory_dir}
    end

    test "reads the assistant's name, the owner, today's date and both memory files", %{
      agent_id: agent_id,
      memory_dir: memory_dir
    } do
      Application.put_env(:fermix_core, :agent, name: "Nova")
      Application.put_env(:fermix_core, :personalization, user_name: "Sujeeth", timezone: "UTC")
      File.mkdir_p!(Path.join(memory_dir, agent_id))
      File.write!(Path.join([memory_dir, agent_id, "USER.md"]), "- Likes short answers\n")
      File.write!(Path.join([memory_dir, agent_id, "MEMORY.md"]), "- Car is a Model 3\n")

      assert {:ok, context} = LivePrompt.context(agent_id, "chat")

      assert context.agent_id == agent_id
      assert context.conversation == "chat"
      assert context.assistant_name == "Nova"
      assert context.personalization == [user_name: "Sujeeth", timezone: "UTC"]
      assert context.date_note == CurrentDate.note()

      assert context.prompt_memory == %{
               user: "- Likes short answers",
               memory: "- Car is a Model 3"
             }
    end

    test "a home with no name and no memory files gives none", %{agent_id: agent_id} do
      Application.delete_env(:fermix_core, :agent)
      Application.delete_env(:fermix_core, :personalization)

      assert {:ok, %{assistant_name: nil, personalization: [], prompt_memory: memory}} =
               LivePrompt.context(agent_id, "private")

      assert memory == %{user: nil, memory: nil}
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
      assert byte_size(LivePrompt.compose(Defaults.live_md(), capabilities, @bare)) < 12_000
    end

    test "labels an unknown category the way the runtime catalog does" do
      assert LivePrompt.capability_lines([capability("odd_tool", :system)]) ==
               "- System: odd_tool"
    end
  end

  describe "backend_addendum/1" do
    test "is a stable non-empty string naming the voice conversation, for either call" do
      for conversation <- ~w(chat private) do
        addendum = LivePrompt.backend_addendum(conversation)

        assert addendum =~ "voice conversation"
        assert addendum =~ "Do not treat partial speech"
        assert byte_size(addendum) > 200
        assert addendum == LivePrompt.backend_addendum(conversation)
      end
    end

    # M56 §4.5: the reply is spoken, so it opens with a line to say, and what
    # cannot be said follows the one delimiter line, for Fermix to show in the
    # chat and tell the voice about.
    test "a call in the chat asks for a line to say and the rest after the delimiter" do
      addendum = LivePrompt.backend_addendum("chat")

      assert addendum =~ "one short line to say"
      assert addendum =~ "a line that is exactly #{LiveText.shown_delimiter()}"
      assert addendum =~ "owner's chat"
      refute addendum =~ "result view"
      # M56 §4.6: a reply that comes after the call ended is shown, not said.
      assert one_spaced(addendum) =~
               "If the call has ended by the time you reply, your reply is shown in the " <>
                 "owner's chat instead of said."
    end

    # M56 §4.7: "send it to my Telegram" asked aloud is sent with the tool,
    # and the line the voice says names where it went.
    test "a call in the chat sends a result the owner asks to send, and says where" do
      addendum = one_spaced(LivePrompt.backend_addendum("chat"))

      assert addendum =~
               "When the owner asks for something to be sent to one of their own channels, " <>
                 "send it with send_to_channel and say in the short line where it went."
    end

    # M56 §5: a private call is today's behaviour in full, its addendum included.
    test "a private call keeps its wording, with no delimiter and nothing shown" do
      addendum = LivePrompt.backend_addendum("private")

      assert addendum =~ "Keep the portion sent to\nthe voice model concise"
      refute addendum =~ LiveText.shown_delimiter()
      refute addendum =~ "chat"
      refute addendum =~ "send_to_channel"
    end

    test "no other conversation has an addendum" do
      assert_raise FunctionClauseError, fn -> LivePrompt.backend_addendum("shared") end
    end

    # The eval drives a hand-off's turn with the addendum in front of the
    # spoken exchange, since no driver can mint a trusted voice turn: its copy
    # must be the one a call in the chat sends, or the eval grades a prompt the
    # product no longer has.
    test "every addendum the voice_in_chat eval carries is the one a call in the chat sends" do
      suite = one_spaced(File.read!(@voice_in_chat_suite))
      addendum = one_spaced(LivePrompt.backend_addendum("chat"))
      opening = "This task comes from an ongoing voice conversation."

      copies = length(String.split(suite, opening)) - 1

      assert copies > 0
      assert length(String.split(suite, addendum)) - 1 == copies
    end
  end

  describe "eligible_capabilities/2" do
    # M56 §4.7: a call in the chat launches a coding run in the chat's own
    # conversation, so its outcome re-enters the chat and is answered there.
    test "a call in the chat keeps operator tools, sends and coding runs" do
      registry = eligible_registry()

      assert names(registry, "chat") == ["codex_run", "read_file", "send_to_channel"]
    end

    # A private call's conversation ends with the call, and a run launched
    # there would report back into a conversation nobody reads (M41 §5.1).
    test "a private call drops coding runs too, and keeps sends" do
      registry = eligible_registry()

      assert names(registry, "private") == ["read_file", "send_to_channel"]
    end

    test "the voice model is told the categories its call keeps, delivery among them" do
      registry = eligible_registry()
      chat = registry |> LivePrompt.eligible_capabilities("chat") |> LivePrompt.capability_lines()

      assert chat ==
               "- File & Code: read_file\n- Coding Harness: codex_run\n" <>
                 "- Delivery: send_to_channel"

      private =
        registry |> LivePrompt.eligible_capabilities("private") |> LivePrompt.capability_lines()

      assert private == "- File & Code: read_file\n- Delivery: send_to_channel"
    end

    test "the exclusion list is the shared one the delegation turn also reads" do
      # One list per mode, two surfaces (`TurnRunner` builds the delegation's
      # profile from it): a disagreement between them would advertise a
      # capability the delegation would not be given, and nothing would report
      # it.
      assert VoiceCall.excluded_categories("chat") == [:channel, :media, :delegation]

      assert VoiceCall.excluded_categories("private") == [
               :channel,
               :media,
               :delegation,
               :harness
             ]
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

  # One capability per category a voice call may or may not keep.
  defp eligible_registry do
    registry = :"live_prompt_capabilities_#{System.unique_integer([:positive, :monotonic])}"
    start_supervised!({CapabilityRegistry, [name: registry]})

    for {name, category} <- [
          {"read_file", :file},
          {"send_message", :channel},
          {"generate_image", :media},
          {"subagents", :delegation},
          {"codex_run", :harness},
          {"send_to_channel", :delivery}
        ] do
      :ok = CapabilityRegistry.register(registry, capability(name, category))
    end

    registry
  end

  defp names(registry, conversation) do
    registry |> LivePrompt.eligible_capabilities(conversation) |> Enum.map(& &1.name)
  end

  defp position(text, part) do
    case :binary.match(text, part) do
      {index, _length} -> index
      :nomatch -> flunk("missing from the prompt: #{inspect(part)}")
    end
  end

  defp one_spaced(text), do: text |> String.split() |> Enum.join(" ")

  defp restore_env({key, {:ok, value}}), do: Application.put_env(:fermix_core, key, value)
  defp restore_env({key, :error}), do: Application.delete_env(:fermix_core, key)

  defp numbered(prefix, index) do
    "#{prefix}_#{String.pad_leading(Integer.to_string(index), 3, "0")}"
  end
end
