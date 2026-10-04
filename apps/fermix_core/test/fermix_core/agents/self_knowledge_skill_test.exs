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

  # The proxy has no pane and no setup flag, so the skill is the only place an
  # operator's question about it can be answered, and it must not promise a
  # surface that does not exist or an environment variable Fermix ignores.
  test "documents the outbound proxy, where it is set and what it does not cover" do
    body = File.read!(self_knowledge_path())
    reference = File.read!(config_reference_path())

    assert body =~ "[fermix_core.network]"
    assert body =~ "does not read `HTTPS_PROXY`"

    for required <- [
          "[fermix_core.network]",
          "proxy_bypass",
          "HTTPS_PROXY",
          "never prints the value",
          "Nothing falls back to a direct connection",
          "no Mac Settings pane",
          "fermix doctor"
        ] do
      assert reference =~ required, "config self-knowledge does not mention #{required}"
    end

    assert reference =~ "fermix setup --proxy"
  end

  # On a server reached over SSH the terminal verb is the settings surface, and
  # a secret enters it only through `secret set`, prompted or piped, so the
  # reference must name both or the agent answers with an argument.
  test "documents fermix settings and how a secret enters it" do
    reference = File.read!(config_reference_path())

    for required <- ["fermix settings", "secret set", "--stdin"] do
      assert reference =~ required, "config self-knowledge does not mention #{required}"
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

  # The channel's surface is the management protocol: a settings section and
  # the `mobile.*` methods a desktop Phone pane would be built on, with the
  # config flag the route on a host with no pane. The self-reference must
  # name both, must say pairing on an app-managed Mac is the app's, and must not
  # point an owner at surfaces that do not exist. The refutations name concrete
  # withdrawn artifacts rather than a phrasing allowlist, so a true sentence
  # that happens to mention setup (e.g. `--migrate-secrets`) stays legal while a
  # re-added mobile setup step or flag, or the withdrawn "no setup surface"
  # claim, fails here.
  test "documents mobile's management surface and the config route, never a setup step" do
    reference = File.read!(mobile_reference_path())
    paragraph = mobile_paragraph()

    for text <- [reference, paragraph] do
      assert text =~ "[fermix_channels.mobile]"
      assert text =~ "enabled = true"
      assert text =~ "channels.mobile"
      assert text =~ "mobile.*"
      assert text =~ "fermix pair"
      assert text =~ "never the CLI"
      refute text =~ "Channels page"
      refute text =~ "Channels tab"
      refute text =~ "--mobile-enabled"
      refute text =~ "--mobile-push"
      refute text =~ "no setup surface"
    end

    assert reference =~ "config.toml"
    assert reference =~ "restart"

    for word <- ~w(awaiting_scan awaiting_decision cancelled device_disconnected) do
      assert reference =~ word, "the mobile reference does not describe #{word}"
    end
  end

  # The companion socket has no setting, so the runtime self-reference must not
  # invent one, and it must say the app half has not shipped: an owner is never
  # walked to a chat window that is not there.
  test "documents the companion chat socket, its boundaries and its reads" do
    paragraph = companion_paragraph()
    # The reference is hard-wrapped; a phrase may span a line break.
    reference = companion_reference_path() |> File.read!() |> String.replace(~r/\s+/, " ")

    assert paragraph =~ ~s(file: "companion")

    for text <- [paragraph, reference] do
      assert text =~ "companion.sock"
      assert text =~ "0600"
      assert text =~ "client message id"
      assert text =~ ~s(delivery_mode: "origin")
      assert text =~ "No released Fermix.app" or text =~ "no released Fermix.app"
      refute text =~ "[fermix_channels.companion]"
    end

    for required <- [
          "still waiting behind another turn, or not yet queued",
          "/stop",
          "forward",
          "backward",
          "Full-text search",
          "whether or not the app is connected",
          "Attachments do not travel",
          "companion:main"
        ] do
      assert reference =~ required, "companion self-knowledge does not mention #{required}"
    end
  end

  # M34 §4 changes what a whole family of CLI verbs does on an app-managed
  # engine, so the always-loaded body — not only the reference — has to name the
  # mode, the surface the app drives it over, each hand-off, and the migration
  # verb. A body that only says "several verbs behave differently" cannot answer
  # "why did `fermix upgrade` open a window".
  test "documents app-managed macOS mode, its management surface, and migrate-to-app" do
    body = File.read!(self_knowledge_path())
    paragraph = app_managed_paragraph()

    assert paragraph != "", "self-knowledge never mentions the app-managed macOS engine"
    assert body =~ ~s(file: "macos_app")

    for required <- [
          "management protocol",
          "daemon.sock",
          "fermix://",
          "fermix migrate-to-app",
          "not-applicable",
          "Enable/Disable background service",
          "service install|uninstall",
          "exit non-zero"
        ] do
      assert paragraph =~ required, "app-managed self-knowledge does not mention #{required}"
    end
  end

  # The reference carries the per-verb detail. Assert the three verb families
  # M34 §4 splits the CLI into are each named there, plus the one promise every
  # path in that section makes.
  test "the macos_app reference names every app-managed verb family and the home promise" do
    reference = File.read!(macos_app_reference_path())

    for required <- [
          "fermix start",
          "fermix stop",
          "fermix service install",
          "fermix setup",
          "fermix upgrade",
          "fermix uninstall",
          "fermix status",
          "fermix doctor",
          "fermix logs",
          "fermix migrate-to-app",
          "brew install --cask"
        ] do
      assert reference =~ required, "macos_app reference does not mention #{required}"
    end

    assert reference =~ "never deletes a Fermix home" or
             reference =~ "ever deletes a Fermix home"
  end

  # Production Fermix on a Mac is the app, which ships no `fermix` command, so
  # an owner asking "how do I set up / update you?" must get the app's own
  # labels. Each label below is a control a correct answer cannot do without.
  # The refutation names a withdrawn artifact: no desktop package ships.
  test "answers a Mac app owner with the app's own controls" do
    body = File.read!(self_knowledge_path())
    reference = File.read!(macos_app_reference_path())

    assert body =~ "Check for Updates…"

    for label <- [
          "Set up Fermix",
          "Open Login Items settings",
          "Connect your AI",
          "Verify and save",
          "Use as primary",
          "Restart Fermix…",
          "Check for Updates…",
          "Reload settings from disk"
        ] do
      assert reference =~ label, "macos_app reference does not name #{label}"
    end

    for text <- [body, reference, File.read!(service_unit_reference_path())] do
      refute text =~ "fermix-desktop"
    end
  end

  # Voice, computer use, the notetaker and the sandbox are settings panes on a
  # Mac, so "how do I turn it on?" needs the pane. The refutation names a
  # withdrawn artifact: the voice companion ships inside the Fermix app, not
  # as a separate FermixPet app.
  test "sends a Mac app owner to the pane for each desktop feature" do
    body = File.read!(self_knowledge_path())

    for pane <- [
          "Settings > Voice",
          "Settings > Computer",
          "Settings > Meetings",
          "Settings > Sandbox"
        ] do
      assert body =~ pane, "self-knowledge body does not name #{pane}"
    end

    for text <- [
          body,
          File.read!(reference_path("voice")),
          File.read!(reference_path("computer_use"))
        ] do
      refute text =~ "FermixPet"
    end
  end

  # GPT-Live has no noise or echo settings, so "why does it hear my keyboard or
  # its own voice?" is answered by the Mac's voice processing and the daemon's
  # echo window, and a Linux client has to bring its own.
  test "documents where a call's noise and echo are handled" do
    reference = File.read!(reference_path("voice"))

    for required <- [
          "GPT-Live takes no noise, echo or voice-detection settings",
          "echo cancellation, noise suppression",
          "in the 2 s after it",
          "Headphones avoid echo",
          "A Linux client must cancel echo"
        ] do
      assert reference =~ required, "the voice reference does not say #{required}"
    end
  end

  # After the first provider, the primary moves only by an explicit action; a
  # self-reference that says saving a provider promotes it sends an owner to
  # the wrong control.
  test "names the explicit action that changes the primary provider" do
    body = File.read!(self_knowledge_path())
    reference = File.read!(providers_reference_path())

    for text <- [body, reference] do
      assert text =~ "Use as primary"
      assert text =~ "Set primary"
    end
  end

  # No repository serves the packages, so the family commands `fermix upgrade`
  # prints find nothing. An agent asked "how do I update you?" on a packaged
  # host must not stop at `apt upgrade`.
  test "documents the Linux package installer, and that running it again is the update" do
    paragraph = service_paragraph()
    reference = File.read!(service_unit_reference_path())

    assert paragraph =~ "curl -fsSL https://fermix.ai/install | sh"
    assert paragraph =~ "fermix restart"
    assert paragraph =~ "until a repository is published"

    for required <- [
          "curl -fsSL https://fermix.ai/install | sh",
          "sha256",
          "cosign",
          "`apt`, `dnf` or `zypper`",
          "--standalone",
          "not a repository",
          "Until a repository is published, those lines find nothing",
          "fermix restart"
        ] do
      assert reference =~ required, "service_unit reference does not mention #{required}"
    end
  end

  # "How do I connect Telegram?" needs the values, where each comes from, where
  # it is entered and what to send first; the always-loaded body keeps the
  # roster, the owner rule and one loader, and the reference carries the rest.
  # Each required string is a vendor step or a Fermix key a correct answer
  # cannot do without, not a phrasing.
  test "documents how to connect each chat channel, from its values to the first message" do
    paragraph = channels_paragraph()
    reference = channel_setup_reference_path() |> File.read!() |> String.replace(~r/\s+/, " ")

    assert paragraph != "", "self-knowledge never lists the chat channels"
    assert paragraph =~ ~s(file: "channel_setup")
    assert paragraph =~ "owner_user_id"

    for required <- [
          # Telegram
          "@BotFather",
          "/newbot",
          "@userinfobot",
          "/start",
          # Discord
          "Message Content Intent",
          "Interactions Endpoint URL",
          "Copy User ID",
          # Slack
          "xoxb-",
          "Signing Secret",
          "/webhook/slack",
          "app_mention",
          "message.im",
          # WhatsApp
          "/webhook/whatsapp",
          "Verify and save",
          "Phone number ID",
          # Signal
          "signal-cli",
          # Where the values go and who may talk
          "Settings > Channels",
          "Restart to apply",
          "Apply & restart",
          "--telegram-owner-user-id",
          "owner_user_id",
          "allowed_user_ids",
          "allowed_sender_ids",
          "command_allowlist",
          "/whoami"
        ] do
      assert reference =~ required, "channel_setup reference does not mention #{required}"
    end
  end

  # iMessage is the one channel whose setup is macOS permissions rather than
  # platform credentials, and the one that refuses Linux outright, so "how do I
  # connect iMessage?" and "why is it silent?" are answered only if the grants,
  # the recipient confirmation and the probe fields are named. Each string is a
  # pane, a key, a probe field or a doctor row, not a phrasing.
  test "documents iMessage: its permissions, the recipient confirmation and the Mac-only rule" do
    paragraph = channels_paragraph()
    reference = channel_setup_reference_path() |> File.read!() |> String.replace(~r/\s+/, " ")
    presentation = "channel_presentation" |> reference_path() |> File.read!()

    for required <- ["iMessage", "Fermix Messages", "Full Disk Access", "Automation"] do
      assert paragraph =~ required, "the Channels paragraph does not mention #{required}"
    end

    for required <- [
          "## iMessage",
          "Fermix Messages",
          "Full Disk Access",
          "Messages data",
          "Messages automation",
          "Awaiting confirmation",
          "Confirm…",
          "dedicated_account",
          "own_account",
          "[fermix_channels.imessage]",
          "allowed_sender_ids",
          "full_disk_access",
          "user_session",
          "signed_in",
          "policy_matches_config",
          "imessage_helper",
          "imessage_permissions",
          "Linux"
        ] do
      assert reference =~ required, "channel_setup reference does not mention #{required}"
    end

    assert presentation =~ "iMessage"
  end

  defp channels_paragraph do
    self_knowledge_path()
    |> File.read!()
    |> String.split("\n\n")
    |> Enum.filter(&String.starts_with?(&1, "Channels:"))
    |> Enum.join("\n\n")
  end

  defp channel_setup_reference_path do
    Path.expand("../../../priv/skills/self_knowledge/references/channel_setup.md", __DIR__)
  end

  defp service_paragraph do
    self_knowledge_path()
    |> File.read!()
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "- Service:"))
    |> Enum.join("\n")
  end

  defp config_reference_path do
    Path.expand("../../../priv/skills/self_knowledge/references/config.md", __DIR__)
  end

  defp providers_reference_path do
    Path.expand("../../../priv/skills/self_knowledge/references/providers.md", __DIR__)
  end

  defp service_unit_reference_path do
    Path.expand("../../../priv/skills/self_knowledge/references/service_unit.md", __DIR__)
  end

  defp app_managed_paragraph do
    self_knowledge_path()
    |> File.read!()
    |> String.split("\n\n")
    |> Enum.flat_map(&String.split(&1, "\n"))
    |> Enum.filter(&String.contains?(&1, "Fermix.app-managed"))
    |> Enum.join("\n")
  end

  defp macos_app_reference_path do
    Path.expand("../../../priv/skills/self_knowledge/references/macos_app.md", __DIR__)
  end

  defp mobile_paragraph do
    self_knowledge_path()
    |> File.read!()
    |> String.split("\n\n")
    |> Enum.filter(&String.contains?(&1, "Mobile companion"))
    |> Enum.join("\n\n")
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

  defp companion_paragraph do
    self_knowledge_path()
    |> File.read!()
    |> String.split("\n\n")
    |> Enum.filter(&String.contains?(&1, "Companion chat socket"))
    |> Enum.join("\n\n")
  end

  defp companion_reference_path do
    Path.expand("../../../priv/skills/self_knowledge/references/companion.md", __DIR__)
  end

  defp mobile_reference_path do
    Path.expand("../../../priv/skills/self_knowledge/references/mobile.md", __DIR__)
  end

  defp reference_path(name) do
    Path.expand("../../../priv/skills/self_knowledge/references/#{name}.md", __DIR__)
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
    # The lookbehind is load-bearing: `profile: "selected_tab"` ends in `file:`
    # and is an ordinary thing to write in the body, so without it an argument
    # name reads as a dangling pointer.
    pointers =
      ~r/(?<![a-z_])file:\s*"([a-z0-9_]+)"/
      |> Regex.scan(body)
      |> Enum.map(fn [_, name] -> name end)
      |> Enum.uniq()

    assert pointers != []

    for name <- pointers do
      assert File.exists?(Path.join(refs_dir, name <> ".md")),
             "dangling reference pointer in main body: #{name}"
    end

    # Each externalized feature keeps a stub + loader in the main body.
    for name <- ~w(coding_harness companion computer_use mobile plugins voice) do
      assert body =~ ~s(file: "#{name}"), "missing stub loader for #{name}"
    end

    # The other half of that invariant, derived from the live reference
    # directory rather than a hand-maintained list: a reference the body never
    # offers is unreachable detail, and decomposing a section without leaving a
    # loader behind is exactly how it goes missing.
    for ref <- ref_files do
      name = Path.basename(ref, ".md")
      assert name in pointers, "reference with no loader in the main body: #{name}"
    end
  end
end
