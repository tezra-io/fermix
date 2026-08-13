defmodule FermixCore.Agents.SelfKnowledgeSkillTest do
  use ExUnit.Case, async: true

  alias FermixCore.Agents.SkillRegistry

  test "bundled self-knowledge skill loads as a core skill with no tools" do
    local =
      Path.join(
        System.tmp_dir!(),
        "fermix-self-knowledge-local-#{System.unique_integer([:positive])}"
      )

    core = Path.expand("../../../priv/skills", __DIR__)
    File.mkdir_p!(local)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(local) end)

    registry =
      start_supervised!(
        {SkillRegistry,
         name: :"self_knowledge_#{System.unique_integer([:positive])}",
         skills_dir: local,
         core_dir: core,
         seed_defaults: false},
        id: :"self_knowledge_child_#{System.unique_integer([:positive])}"
      )

    assert {:ok, definition} = SkillRegistry.load(registry, "self-knowledge")
    assert definition.trust == :operator
    assert definition.allowed_tools == []
    assert definition.system_prompt =~ "Fermix is"
    assert definition.system_prompt =~ "Built-in capabilities"
  end

  test "documents the ACP agent surface: how to add it and what is absent on it" do
    acp_text = acp_paragraph()

    assert acp_text != "", "self-knowledge never mentions the ACP surface"
    assert acp_text =~ "[fermix_channels.acp]"
    assert acp_text =~ "fermix acp"

    # The absences ARE the surface's posture (M29 §11), so each is named in the
    # same place rather than left to be inferred from the rest of the doc.
    # Coding-harness delegation left this list when identities became durable
    # (§17.6) — it is asserted as PRESENT by the test below instead.
    for absent <- ["slash-command", "approval", "origin-mode"] do
      assert acp_text =~ absent, "self-knowledge does not say #{absent} is absent on ACP"
    end
  end

  test "documents durable client identities and the harness delegation they unlock" do
    acp_text = acp_paragraph()

    # Custody and its one disconnect verb (M29 §17.3): an operator reading this
    # must learn that credentials outlive the connection and how to sever them.
    assert acp_text =~ "fermix acp forget"
    assert acp_text =~ "npub"

    # The harness half, which the absence list above used to claim was missing.
    for present <- ["codex_run", "claude_code_run"] do
      assert acp_text =~ present, "self-knowledge does not offer #{present} on ACP"
    end
  end

  test "documents the mobile companion setup and its v1 boundaries" do
    body = File.read!(self_knowledge_path())
    reference = File.read!(mobile_reference_path())

    assert body =~ ~s(file: "mobile")

    for required <- [
          "fermix pair",
          "fermix devices list",
          "fermix devices revoke",
          "FERMIX_APNS_KEY",
          "media_store_max_bytes",
          "2 GiB",
          "Noise",
          "voice notes",
          "realtime voice",
          "fermix doctor"
        ] do
      assert reference =~ required, "mobile self-knowledge does not mention #{required}"
    end
  end

  defp acp_paragraph do
    self_knowledge_path()
    |> File.read!()
    |> String.split("\n\n")
    |> Enum.filter(&String.contains?(&1, "ACP"))
    |> Enum.join("\n\n")
  end

  defp self_knowledge_path,
    do: Path.expand("../../../priv/skills/self_knowledge/SKILL.md", __DIR__)

  defp mobile_reference_path do
    Path.expand("../../../priv/skills/self_knowledge/references/mobile.md", __DIR__)
  end

  test "stays decomposed: main body has headroom, references are bounded, pointers resolve" do
    core = Path.expand("../../../priv/skills", __DIR__)
    refs_dir = Path.join([core, "self_knowledge", "references"])

    local =
      Path.join(
        System.tmp_dir!(),
        "fermix-self-knowledge-shape-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(local)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(local) end)

    registry =
      start_supervised!(
        {SkillRegistry,
         name: :"self_knowledge_shape_#{System.unique_integer([:positive])}",
         skills_dir: local,
         core_dir: core,
         plugin_skill_dirs: [],
         seed_defaults: false},
        id: :"self_knowledge_shape_child_#{System.unique_integer([:positive])}"
      )

    assert {:ok, definition} = SkillRegistry.load(registry, "self-knowledge")
    body = definition.system_prompt

    # The on-demand skill_view ceiling is 65_536; keep real headroom so the next
    # edit has room instead of squeaking under the limit.
    assert byte_size(body) < 60_000

    # Every reference is itself individually under the same on-demand ceiling.
    ref_files = refs_dir |> Path.join("*.md") |> Path.wildcard()
    assert ref_files != []

    for ref <- ref_files do
      assert byte_size(File.read!(ref)) < 65_536, "reference too large: #{ref}"
    end

    # Every `file:` pointer named in the main body resolves to a real reference.
    pointers =
      ~r/file:\s*"([a-z0-9_]+)"/
      |> Regex.scan(body)
      |> Enum.map(fn [_, name] -> name end)
      |> Enum.uniq()

    assert pointers != []

    for name <- pointers do
      assert File.exists?(Path.join(refs_dir, name <> ".md")),
             "dangling reference pointer in main body: #{name}"
    end

    # Each externalized feature keeps a stub + loader in the main body.
    for name <- ~w(coding_harness computer_use mobile plugins voice) do
      assert body =~ ~s(file: "#{name}"), "missing stub loader for #{name}"
    end
  end
end
