defmodule FermixCore.Management.CopyTest do
  @moduledoc """
  The daemon-side copy gate (M34 native setup §7.7, §7.8 step 4).

  Every sentence in this file's case set is one a front-end renders verbatim:
  the app cannot correct it and the browser door does not try. The case set is
  walked out of the live producers rather than listed here, so a row, a
  remediation, a restart reason or a readiness action added in Elixir joins the
  gate on the day it lands instead of on the day someone remembers.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Auth.AnthropicLogin
  alias FermixCore.Auth.ClientRejection
  alias FermixCore.Auth.OAuthProviders
  alias FermixCore.Auth.Redaction
  alias FermixCore.Capabilities.MCP.Config, as: McpConfig
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Cues.Config, as: CuesConfig
  alias FermixCore.Cues.FollowUpReadiness
  alias FermixCore.Cues.FollowUps
  alias FermixCore.Cues.Mandates
  alias FermixCore.Cues.ProposalView
  alias FermixCore.Home.Candidate, as: HomeCandidate
  alias FermixCore.Home.Move, as: HomeMove
  alias FermixCore.Home.MoveReadiness
  alias FermixCore.Home.Provision
  alias FermixCore.Home.Provision.Hetzner
  alias FermixCore.Home.Provision.Registry, as: ProvisionRegistry
  alias FermixCore.Home.Snapshot.Recipient, as: SnapshotRecipient
  alias FermixCore.Home.Snapshot.Recovery
  alias FermixCore.Home.Snapshot.Run, as: SnapshotRun
  alias FermixCore.Home.Snapshot.S3, as: SnapshotS3
  alias FermixCore.Home.Snapshot.Status, as: SnapshotStatus
  alias FermixCore.Management.Copy
  alias FermixCore.Management.Cues, as: ManagementCues
  alias FermixCore.Management.Cues.MandateRow, as: CueMandateRow
  alias FermixCore.Management.Cues.SourceForm, as: CueSourceForm
  alias FermixCore.Management.Cues.SourceRow, as: CueSourceRow
  alias FermixCore.Management.Cues.WatcherRow, as: CueWatcherRow
  alias FermixCore.Management.Doctor.Remediation
  alias FermixCore.Management.HomeMove, as: ManagementHomeMove
  alias FermixCore.Management.HomeSummary
  alias FermixCore.Management.McpServers.Row, as: McpRow
  alias FermixCore.Management.Mobile
  alias FermixCore.Management.Placement
  alias FermixCore.Management.Plugins
  alias FermixCore.Management.Plugins.Row, as: PluginRow
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Settings
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Readiness
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Sandbox.PathPolicy
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState
  alias FermixCore.Setup.SecretWriter

  # What the two renderers really answer for a reason the plugin installer
  # produces: a tuple, a map, and the operator's own home directory.
  @internal_term Redaction.format({:tree_missing, %{root: "/Users/example/.fermix/plugins"}})
  @placeholder "Value"
  # Hetzner's own messages a refusal carries: its words, not the daemon's.
  @vendor_messages ["invalid input in field 'server_type'", "server placement failed"]

  # A backticked span is a literal the operator types, which is the one place a
  # path belongs; the rest of the sentence is prose and may carry none.
  @backticked ~r/`[^`]*`/
  @term_shapes [map: ~r/%\{/, tuple: ~r/\{:/, absolute_path: ~r{(?<![\w~])/[A-Za-z0-9._-]+/}]
  # A `fermix` verb, quoted or bare: what the CLI's user types, never what an
  # app or the setup page asks of its owner.
  @fermix_command ~r/\bfermix\s+[a-z]/
  @recovery_refusals [
    :passphrase_too_short,
    :passphrase_not_text,
    :wrong_passphrase,
    :key_unreadable,
    {:not_saved, :eacces}
  ]

  describe "the rules themselves" do
    # A rule the module publishes and nothing here provokes is a rule nobody has
    # ever seen fire, so the offenders are asserted against `rules/0` rather
    # than listed loosely beside it.
    test "each rule names its own offender" do
      offenders = [
        {:em_dash, "A sentence — with a dash."},
        {:exclamation, "Welcome!"},
        {:mix_task, "Run mix fermix.setup now."},
        {:version_number, "Needs Fermix 0.9.0."},
        {:wire_token, "Set bot_token here."},
        {:sentence_case, "Set the Token here."}
      ]

      assert Enum.map(offenders, &elem(&1, 0)) == Copy.rules()

      for {rule, text} <- offenders do
        assert rule in Enum.map(Copy.violations(text, :prose), &elem(&1, 0)),
               "#{rule} did not fire on #{inspect(text)}"
      end
    end

    test "a backticked literal is what the operator types, not prose" do
      assert Copy.violations("Set `bot_token` in the settings file.", :prose) == []
      assert Copy.violations("Run `fermix setup`.", :prose) == []
    end

    test "a name is held to the four rules that apply to a name" do
      assert Copy.violations("GPT-5.6 Sol (default, latest)", :name) == []
      assert Copy.violations("New York", :name) == []
      assert {:em_dash, "—"} in Copy.violations("Grok — fast", :name)
    end

    test "an initialism and a proper noun are not capitalisation defects" do
      assert Copy.violations("Your Telegram user ID is needed.", :prose) == []

      assert Copy.violations("Runs as Fermix Computer Use, a separate signed helper.", :prose) ==
               []
    end

    # The four sentences this slice rewrote, kept as the proof the gate is not
    # vacuous: each one shipped, each one is what the rule exists to catch.
    test "the sentences this gate was written for are still caught" do
      assert [{:mix_task, _} | _] =
               Copy.violations(
                 "Run mix fermix.setup to provide your name, timezone, and communication style.",
                 :prose
               )

      assert {:em_dash, "—"} in Copy.violations(
               ~s(Invalid auth_mode "x" — set it to "api_key" or "oauth".),
               :prose
             )

      assert {:wire_token, "bot_token"} in Copy.violations(
               "Set the Telegram bot token: run `fermix setup` or set bot_token in config.toml.",
               :prose
             )

      assert {:wire_token, "base_url"} in Copy.violations(
               "Set [fermix_core.providers.ollama] base_url.",
               :prose
             )
    end

    test "an interpolated name is data the call site declares" do
      sentence = "Your prompt reaches Acme."

      assert {:sentence_case, "Acme"} in Copy.violations(sentence, :prose)
      assert Copy.violations(sentence, :prose, ["Acme"]) == []
    end

    # A variable name an operator allowed is data under every rule, not only
    # the capitalisation one: the label of its row IS the name, and a name is
    # `UPPER_SNAKE` by convention. Undeclared, it is still a wire token.
    test "a declared name is exempt from the wire-token rule too" do
      assert {:wire_token, "ALPACA_API_KEY"} in Copy.violations("ALPACA_API_KEY", :prose)
      assert Copy.violations("ALPACA_API_KEY", :prose, ["ALPACA_API_KEY"]) == []
      assert Copy.violations("Set ALPACA_API_KEY.", :prose, ["OTHER_KEY"]) != []
    end
  end

  describe "the copy the management wire publishes" do
    test "every published error sentence obeys the rules" do
      for {code, message} <- Protocol.error_messages() do
        assert_clean(message, :prose, [], "error #{code}")
      end
    end

    test "every section title obeys the rules" do
      for section <- Settings.sections() do
        assert_clean(section.title, :prose, [], "section title #{section.id}")
      end
    end

    test "every row label, footer, info, unit and option obeys the rules" do
      for section <- Settings.sections(), row <- rows(section.id) do
        where = "#{section.id}.#{row["key"]}"

        assert_clean(row["label"], :prose, row_names(row), "row label #{where}")
        assert_clean(row["footer"], :prose, [], "row footer #{where}")
        assert_clean(row["info"], :prose, [], "row info #{where}")
        assert_clean(row["unit"], :name, [], "row unit #{where}")

        for option <- row["options"] do
          assert_clean(option["label"], :name, [], "option label #{where}")
          assert_clean(option["hint"], :prose, [], "option hint #{where}")
        end
      end
    end

    # The live snapshot of an async case allows whatever the suite configured,
    # which is usually nothing, so the sandbox name rows are walked here from a
    # snapshot that carries every shape M45 §4.4 publishes.
    test "every sandbox name row obeys the rules, with the name declared as data" do
      rows = sandbox_name_rows()

      assert length(rows) == 6

      for row <- rows do
        where = "sandbox.#{row["key"]}"

        assert_clean(row["label"], :prose, row_names(row), "row label #{where}")
        assert_clean(row["footer"], :prose, [], "row footer #{where}")
        assert_clean(row["info"], :prose, [], "row info #{where}")
        assert internal_terms(row["footer"] || "") == []
      end
    end

    # The suite's snapshot runs the default engine, so the rows only the Live
    # engine publishes (its backend and whether calls join the chat) are walked
    # here from a Live snapshot.
    test "every row only the Live voice engine publishes obeys the rules" do
      realtime = [enabled: true, engine: "openai_live", model: "gpt-live-1"]

      snapshot =
        Map.update(ConfigStore.current_snapshot(), :fermix_core, [realtime: realtime], fn core ->
          Keyword.put(core, :realtime, realtime)
        end)

      {:ok, view} = Settings.get("realtime", snapshot: snapshot)
      keys = Enum.map(view["rows"], & &1["key"])

      assert "realtime_backend" in keys and "realtime_conversation" in keys

      for row <- view["rows"] do
        where = "realtime.#{row["key"]}"

        assert_clean(row["label"], :prose, [], "row label #{where}")
        assert_clean(row["footer"], :prose, [], "row footer #{where}")

        for option <- row["options"] do
          assert_clean(option["label"], :name, [], "option label #{where}")
        end
      end
    end

    # Grok publishes the task-engine rows under its own words and the SpaceXAI
    # key row in place of OpenAI's (M70 §06), so they are walked from a Grok
    # snapshot too.
    test "every row only the Grok voice engine publishes obeys the rules" do
      realtime = [enabled: true, engine: "xai_realtime", model: "grok-voice-3.0"]

      snapshot =
        Map.update(ConfigStore.current_snapshot(), :fermix_core, [realtime: realtime], fn core ->
          Keyword.put(core, :realtime, realtime)
        end)

      {:ok, view} = Settings.get("realtime", snapshot: snapshot)
      keys = Enum.map(view["rows"], & &1["key"])

      assert "realtime_backend" in keys and "xai_api_key" in keys

      for row <- view["rows"] do
        where = "realtime.#{row["key"]}"

        assert_clean(row["label"], :prose, [], "row label #{where}")
        assert_clean(row["footer"], :prose, [], "row footer #{where}")

        for option <- row["options"] do
          assert_clean(option["label"], :name, [], "option label #{where}")
        end
      end
    end

    test "every remediation title and body obeys the rules" do
      for key <- Remediation.keys() do
        [id, status] = String.split(key, ".")
        entry = Remediation.fetch(id, status)

        assert_clean(entry["title"], :prose, [], "remediation title #{key}")
        assert_clean(entry["body"], :prose, [], "remediation body #{key}")
      end
    end

    test "every restart reason obeys the rules" do
      for {section, sentence} <- RestartState.boot_bound_sections() do
        assert_clean(sentence, :prose, [], "restart reason #{section}")
      end

      assert_clean(
        RestartState.waiting_transports_sentence(),
        :prose,
        [],
        "restart reason waiting"
      )
    end

    test "every readiness action obeys the rules" do
      for {detail_key, action} <- Readiness.published_actions() do
        assert_clean(action, :prose, [], "readiness action #{detail_key}")
      end
    end

    # A pairing refusal is only produced by the failure it names, so the adapter
    # publishes the whole set rather than leaving it to a live call to reach.
    test "every phone pairing sentence obeys the rules" do
      for sentence <- Mobile.sentences() do
        assert_clean(sentence, :prose, [], "mobile sentence")
        assert internal_terms(sentence) == []
      end
    end

    test "every plugin verb obeys the rules" do
      for verb <- PluginRow.verbs(), do: assert_clean(verb, :name, [], "plugin verb")
    end

    test "every plugin row sentence obeys the rules" do
      for row <- plugin_rows() do
        where = row["name"]
        names = [row["title"], row["account_label"]] |> Enum.reject(&is_nil/1)

        assert_clean(row["status_sentence"], :prose, names, "plugin status #{where}")
        assert_clean(row["consent_sentence"], :prose, names, "plugin consent #{where}")
        assert_clean(row["remote_disclosure"], :prose, names, "plugin disclosure #{where}")

        for setting <- row["settings"] do
          assert_clean(setting["label"], :prose, names, "plugin setting #{where}")
        end
      end
    end

    # An MCP server row names what the owner typed and what its program said:
    # a command, a host, a folder, a variable, a stderr line. Those are data the
    # row reflects, declared at the call site; the words around them are copy.
    test "every MCP server row sentence obeys the rules, with what it names declared" do
      rows = mcp_rows()

      assert length(rows) >= 20

      for {row, names} <- rows do
        where = "mcp row #{row["name"]} #{row["status"]}"

        assert_clean(row["status_sentence"], :prose, names, "#{where} status")
        assert_clean(row["consent_sentence"], :prose, names, "#{where} consent")
        assert_clean(row["last_error"], :prose, names, "#{where} last error")
      end
    end

    test "every plugin status has a sentence, and it obeys the rules" do
      for status <- PluginRow.statuses() do
        assert_clean(PluginRow.check_sentence(status), :prose, [], "check sentence #{status}")
      end
    end

    # A wrong-region row names the account's own region, and a region label is a
    # proper noun the daemon interpolates rather than writes: it is declared as
    # data at the call site, exactly like a plugin's display name, rather than
    # widening the hand-listed set with words no fixed sentence uses.
    test "every region label a row can name obeys the rules as the data it is" do
      labels =
        Enum.flat_map(OAuthProviders.providers(), fn id ->
          Enum.map(OAuthProviders.regions(id), & &1.label)
        end)

      assert labels != []

      for label <- labels do
        assert_clean(label, :name, [], "region label #{label}")

        sentence =
          "The account belongs to the #{label} region. " <>
            "Choose it for the sign-in client and sign in again."

        assert_clean(sentence, :prose, [label], "region sentence #{label}")
        assert internal_terms(sentence) == []
      end
    end

    # The refused-client sentences are written once in `Auth.ClientRejection`
    # and rendered verbatim by the app, the browser door and the CLI. The case
    # set is every plugin provider and every refusal code it declares, read
    # from the provider registry rather than listed here.
    test "every refused sign-in client sentence obeys the rules" do
      refusals =
        Enum.flat_map(OAuthProviders.providers(), fn id ->
          {:ok, provider} = OAuthProviders.definition(id, client_config(id))
          Enum.map(provider.client_rejection_errors, &refusal(provider, &1))
        end)

      assert length(refusals) >= length(OAuthProviders.providers())

      for detail <- refusals do
        names = [detail.provider_name]
        where = "#{detail.provider} #{detail.error}"

        assert_clean(ClientRejection.sentence(detail), :prose, names, "refusal #{where}")
        assert_clean(ClientRejection.grant_sentence(detail.provider), :prose, names, where)
        assert internal_terms(ClientRejection.sentence(detail)) == []
      end
    end
  end

  # A Claude Code import that failed answers the Mac app's `auth_import` job
  # with one of these as its `failure.sentence`, verbatim. They are written in
  # `Auth.AnthropicLogin`, outside the management tree the sweep below reads.
  describe "the Claude Code import's failure sentences" do
    test "every one obeys the rules" do
      failures = AnthropicLogin.worded_failures()
      assert failures != []

      for failure <- failures do
        sentence = AnthropicLogin.failure_sentence(failure)
        assert_clean(sentence, :prose, [], "import failure #{inspect(failure)}")
        assert internal_terms(sentence) == []
      end
    end
  end

  # A refusal sentence is only produced by the failure it names, so no live call
  # can enumerate the set. The modules that write them can: every complete
  # sentence literal in the management tree is copy a client renders, and
  # reading them out of the source cannot go stale the way a list beside it
  # would. Docs are skipped; an interpolated fragment is not a whole sentence
  # and does not reach this set.
  # The cue surface (M60 app surface §3): every sentence a row, the form, a gap
  # or a refusal answers, walked out of the producers with what each one names
  # (a source's ref, a host, a tool) declared as data.
  describe "the cue copy" do
    test "every source row sentence and label obeys the rules" do
      rows = cue_source_rows()

      assert length(rows) >= 30

      for {row, names} <- rows do
        where = "cue source #{row["ref"]} #{row["state"]}"

        assert_clean(row["status_sentence"], :prose, names, "#{where} status")
        assert_clean(row["label"], :name, names, "#{where} label")

        for secret <- row["secrets"],
            do: assert_clean(secret["label"], :name, [], "#{where} secret")
      end
    end

    test "every watcher and mandate row sentence obeys the rules" do
      # The tools a held follow-up names are data, like a plugin's name.
      tools = ~w(github_create_issue linear_create deploy_check)

      for row <- cue_watcher_rows() do
        assert_clean(row["status_sentence"], :prose, [], "cue watcher #{row["state"]}")

        if follow_up = row["follow_up"] do
          where = "cue follow-up #{follow_up["state"]}"
          assert_clean(follow_up["status_sentence"], :prose, ["GitHub", "Linear" | tools], where)
        end
      end

      assert length(follow_up_held_sentences()) >= 15

      for row <- cue_mandate_rows() do
        where = "cue mandate #{row["status_sentence"]}"
        assert_clean(row["status_sentence"], :prose, [row["job"]["id"]], where)
        assert_clean(row["consent_sentence"], :prose, [], where)
        assert_clean(row["approval"]["detail"], :prose, [], where)
      end
    end

    test "every form the daemon offers obeys the rules" do
      forms =
        for {kind, preset, verify} <- [
              {nil, nil, nil},
              {"stream", nil, nil},
              {"local_push", nil, nil},
              {"webhook", nil, "hmac"},
              {"webhook", nil, "shared_secret"},
              {"webhook", nil, "standard_webhooks"},
              {nil, "github", nil},
              {nil, "rss", nil},
              {nil, "x_accounts", nil}
            ] do
          {:ok, form} = CueSourceForm.form(kind, preset, verify, x_sign_in: fn -> :ready end)
          form
        end

      for form <- forms do
        assert_clean(form["consent_sentence"], :prose, [], "cue form consent")
        Enum.each(form["notes"], &assert_clean(&1, :prose, [], "cue form note"))

        for kind <- form["kinds"] do
          assert_clean(kind["label"], :name, [], "cue kind label")
          assert_clean(kind["sentence"], :prose, [], "cue kind sentence")
        end

        Enum.each(form["presets"], &assert_clean(&1["label"], :name, [], "cue preset label"))

        for choice <- form["choices"] do
          assert_clean(choice["label"], :name, [], "cue choice label")
          assert_clean(choice["sentence"], :prose, [], "cue choice sentence")
        end

        for row <- form["rows"] do
          assert_clean(row["label"], :name, [], "cue form row #{row["key"]}")
          # A cue row explains itself behind an info control, never in a footer.
          assert row["footer"] == nil, "cue form footer #{row["key"]}"
          assert_clean(row["info"], :prose, [], "cue form info #{row["key"]}")
          Enum.each(row["options"], &assert_clean(&1["label"], :name, [], "cue form option"))
        end

        # Two rows of one form never share a name, so a value is not typed in
        # the row that only reads like its own.
        labels = Enum.map(form["rows"], & &1["label"])
        assert labels == Enum.uniq(labels), "cue form labels repeat: #{inspect(labels)}"
      end

      for sign_in <- [fn -> :ready end, fn -> {:error, :no_token} end] do
        %{"sentence" => sentence} = CueSourceForm.requirement("x_accounts", x_sign_in: sign_in)
        assert_clean(sentence, :prose, [], "cue requirement")
      end
    end

    test "every gap and refused-request sentence obeys the rules" do
      for reason <- ~w(disconnect inbox_full rate_limited budget expired stale identity_conflict
                       watcher_removed read_limit page_limit backfill_limit),
          count <- [1, 12] do
        assert_clean(ManagementCues.gap_sentence(count, reason), :prose, [], "gap #{reason}")
      end

      for reason <- ~w(unauthorized rate_limited busy too_large malformed unsupported_media_type
                       timeout unavailable invalid stale over_budget elsewhere) do
        assert_clean(
          ManagementCues.rejected_sentence(3, reason),
          :prose,
          [],
          "rejected #{reason}"
        )
      end
    end

    # Lane E2's sentences, which reach the app through the proposal methods and
    # the approve-mode load check: written in core, rendered verbatim here.
    test "every proposal and reach sentence obeys the rules" do
      sentences = [
        Mandates.approve_inbox_sentence(),
        "Fermix has no proposal with that id; nothing ran.",
        "Fermix recorded your answer but could not read the proposal back.",
        "Not run: Fermix could not finish checking it.",
        ManagementCues.memory_off_sentence(),
        ManagementCues.owner_only_sentence()
      ]

      for sentence <- sentences, do: assert_clean(sentence, :prose, [], "cue sentence")

      for row <- cue_proposal_rows() do
        record = ProposalView.record(row)
        assert_clean(record.status_sentence, :prose, [row.tool], "proposal #{row.state}")
      end
    end

    # M60_WATCHER_CODING_RUNS.md §6.2: a watcher's follow-up card reaches the
    # Mac's chat as a card, its summary and status sentence drawn verbatim,
    # after Run and after an Always allow that allowed or found a change.
    test "every follow-up card sentence obeys the rules" do
      names = ["codex-limits", "Codex review"]

      for state <- ~w(waiting starting started skipped expired refused),
          always_allow <- [nil, "allowed", "changed"] do
        card = state |> follow_up_card() |> Map.put(:always_allow, always_allow)
        card = ProposalView.follow_up_card(card, [])
        assert_clean(card.summary, :prose, names, "follow-up summary")
        assert_clean(card.status_sentence, :prose, names, "follow-up #{state}")
      end
    end
  end

  # The snapshot sentences `home.status` and `home.snapshots.*` publish are
  # written in `Home.Snapshot`, outside the management tree the sweep below
  # reads, so each producer is walked here with every state it can answer.
  describe "the snapshot copy" do
    test "every status sentence obeys the rules" do
      recipient = SnapshotRecipient.encode(SnapshotRecipient.generate())
      on = [recipient: recipient, s3_bucket: "invented-bucket"]

      verified = %{
        at: ~U[2026-10-27 09:30:00Z],
        result: :verified,
        name: "n",
        epoch: 4,
        size: 1,
        sha256: "s",
        location: "s3://invented-bucket/n",
        error: nil
      }

      failed = %{
        verified
        | result: :failed,
          error: SnapshotS3.sentence({:unreachable, "timeout"})
      }

      stored = SnapshotStatus.record(SnapshotStatus.empty(), "s3", verified)

      for {status, config, running} <- [
            {SnapshotStatus.empty(), [], false},
            {SnapshotStatus.empty(), [recipient: recipient], false},
            {SnapshotStatus.empty(), on, false},
            {%{SnapshotStatus.empty() | next_run_at: ~U[2026-10-27 09:35:00Z]}, on, false},
            {stored, on, false},
            {SnapshotStatus.record(stored, "s3", failed), on, false},
            {stored, on, true}
          ] do
        view =
          SnapshotStatus.view(status, %{
            config: config,
            targets: [SnapshotS3],
            running: running,
            profile: "general"
          })

        assert_clean(view["sentence"], :prose, [], "snapshot status")
        refute_command(view["sentence"], "snapshot status")
      end
    end

    test "every target and capture failure sentence obeys the rules" do
      target_reasons = [
        {:too_large, 6_000_000_000, 5_368_709_120},
        {:refused, 403, "AccessDenied", "Access Denied"},
        {:unreachable, "connection refused"},
        {:checksum_mismatch, "x"},
        {:keys_missing, :snapshot_s3_access_key_id},
        {:secret_unreadable, :snapshot_s3_secret_access_key, :missing_secret}
      ]

      capture_reasons = [
        {:home_moved, %{to: "invented host"}},
        :epoch_absent,
        {:changed_during_capture, "journals/today.md"},
        {:vacuum, "database is locked"},
        {:too_many_files, 100_001, 100_000},
        {:insufficient_space, 21_474_836_480, 1_073_741_824},
        {:free_space_unknown, :df_unavailable}
      ]

      # S3's own code and message are its words, declared as data.
      vendor = ["AccessDenied", "Access Denied"]

      for reason <- target_reasons,
          do: assert_clean(SnapshotS3.sentence(reason), :prose, vendor, "S3 failure")

      for reason <- capture_reasons do
        assert_clean(SnapshotRun.capture_sentence(reason), :prose, [], "capture failure")
        refute_command(SnapshotRun.capture_sentence(reason), "capture failure")
      end
    end
  end

  # The move sentences `home.status` and `home.move.start` publish are written
  # in `Home.Move`, outside the management tree the sweep below reads, so each
  # phase and each refusal that reaches the wire is walked here.
  describe "the move copy" do
    test "every phase sentence and every move refusal obeys the rules" do
      for phase <- HomeMove.phases() do
        assert_clean(HomeMove.sentence(phase, "north-box"), :prose, [], "move #{phase}")
      end

      refusals = [
        {:not_primary, :device},
        {:not_primary, :candidate},
        {:move_pending, "streaming"},
        :epoch_absent,
        {:unknown_candidate, "cand-5e2a9c1f7b3d4086"},
        {:not_ready, ["This home is about 4 GiB; the move needs about 9 GiB free."]}
      ]

      for reason <- refusals,
          do: assert_clean(HomeMove.error_sentence(reason), :prose, [], "move refusal")

      for reason <- @recovery_refusals,
          do: assert_clean(Recovery.error_sentence(reason), :prose, [], "recovery refusal")
    end

    # The readiness report's every item, in each status it can take: an
    # unreadable keychain value, an older server, a full disk, a home over
    # one S3 upload, plugins built for this Mac, and the warnings always said.
    test "every readiness sentence obeys the rules" do
      home = FermixTestSupport.SafeRm.make_tmp_dir!("copy_readiness")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      profile = "copy-#{System.unique_integer([:positive])}"

      File.write!(Path.join(home, "config.toml"), """
      [fermix_core]
      profile = "#{profile}"

      [fermix_core.providers.anthropic]
      api_key = "@keyring"
      """)

      File.mkdir_p!(Path.join(home, "plugins"))
      File.write!(Path.join(home, "plugins/installed.json"), ~s({"invented-notes": {}}))

      candidate = %{
        name: "north-box",
        os: "linux",
        arch: "aarch64",
        version: "0.9.0",
        snapshots: %{"s3_bucket" => "invented-bucket", "s3_region" => "eu-central-1"}
      }

      for {free, version, bytes, restarts?} <- [
            {1_000, "0.16.0", 6_442_450_944, false},
            {1_099_511_627_776, "0.9.0", 10, true}
          ] do
        report =
          MoveReadiness.report(home, candidate,
            free_bytes: fn _dir -> {:ok, free} end,
            version: version,
            host: "macos-aarch64",
            home_bytes: bytes,
            restarts_itself: restarts?
          )

        # The summary shows a block as its sentence and each warning in
        # Details, so each item is a summary word too.
        for item <- report.items do
          assert_clean(item.sentence, :prose, ["invented-notes"], item.id)
          assert Copy.summary_violations(item.sentence) == [], "#{item.id}: #{item.sentence}"
          refute_command(item.sentence, item.id)
        end
      end
    end
  end

  # Production Fermix is managed through the apps and the setup page, so a
  # sentence they can show says what to do there, or names the server, and
  # never prescribes a `fermix` command (AGENTS.md, "App-managed production
  # configuration"). The Always On producers are walked whole: the move's
  # phases and refusals, the readiness items, the snapshot sentences, the
  # snapshots section, the owner decisions, and the refusals a server shows
  # while it enrolls.
  describe "the Always On copy an app shows" do
    test "names no fermix command" do
      {:ok, view} = Settings.get("snapshots")

      section_rows =
        for row <- view["rows"],
            text <- [row["label"], row["footer"], row["info"]],
            is_binary(text),
            do: {"snapshots.#{row["key"]}", text}

      move =
        Enum.map(HomeMove.phases(), &{"move #{&1}", HomeMove.sentence(&1, "north-box")}) ++
          for reason <- [
                {:move_pending, "streaming"},
                {:unknown_candidate, "cand-5e2a9c1f7b3d4086"},
                {:not_primary, :device},
                :epoch_absent
              ],
              do: {"move refusal", HomeMove.error_sentence(reason)}

      enrolling =
        for reason <- [
              {:code_expired, ~U[2026-10-27 12:30:00Z]},
              {:invalid_code, "a bad checksum"},
              :already_candidate,
              :moved
            ],
            do: {"candidate refusal", HomeCandidate.error_sentence(reason)}

      owner = [
        {"home owner decision", ManagementHomeMove.owner_only_sentence()},
        {"setup owner decision", setup_owner_sentence()}
      ]

      recovery =
        for reason <- @recovery_refusals, do: {"recovery", Recovery.error_sentence(reason)}

      service =
        for restarts? <- [true, false],
            item <-
              MoveReadiness.summary_items(
                MoveReadiness.settings(unwritten_home(), unreadable_files: nil),
                false,
                "north-box",
                restarts_itself: restarts?
              ),
            item.id == "service",
            do: {"service", item.sentence}

      # The answer to a move's start whose answer was lost.
      {:error, :unconfirmed, %{"sentence" => unconfirmed}} =
        Placement.unconfirmed("north-box", "home.move.start")

      device = [{"move unconfirmed", unconfirmed}]

      for {where, text} <-
            section_rows ++ move ++ enrolling ++ owner ++ device ++ recovery ++ service,
          do: refute_command(text, where)
    end

    # A home with no settings file, which turns nothing on; nothing is written.
    defp unwritten_home,
      do: Path.join(System.tmp_dir!(), "fermix-copy-#{System.unique_integer([:positive])}")

    # The daemon's refusal of a setup session, as the golden its own test
    # holds the daemon to.
    defp setup_owner_sentence do
      :fermix_core
      |> Application.app_dir("priv/management/fixtures/errors.jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(&1["name"] == "unavailable_setup_owner_decision"))
      |> get_in(["response", "error", "details", "sentence"])
    end

    # A gate nothing provokes is a gate nobody has seen fire.
    test "catches a command, bare or quoted, and nothing else" do
      assert command?("Run fermix home status to see where it stands.")
      assert command?("Get a new code, then run `fermix home enroll-code` on the primary.")
      refute command?("Fermix restarts as a desktop of fermix-vm.")
      refute command?("Get a new code in Always On on the primary.")
    end
  end

  # The provisioner's refusals are written in `Home.Provision` (the shared
  # kinds, in each provider's words) and in the provider's own module (its
  # other refusals), outside the management tree the sweep below reads, so
  # each reason they can answer is rendered here, for every provider in the
  # registry; the type and the city it names are Hetzner's words.
  describe "the Always On provisioner copy" do
    test "every refusal obeys the rules and names no fermix command" do
      for {reason, sentence} <- provision_copy() do
        # Hetzner's own message is its words, not the daemon's.
        assert_clean(sentence, :prose, ["CPX22", "cpx12" | @vendor_messages], inspect(reason))
        refute_command(sentence, inspect(reason))
      end
    end

    test "the owner decision obeys the rules" do
      assert_clean(FermixCore.Management.Provision.owner_only_sentence(), :prose, [], "owner")
      refute_command(FermixCore.Management.Provision.owner_only_sentence(), "owner")
    end
  end

  defp provision_copy do
    unavailable = %{city: "Falkenstein", description: "CPX22", next_city: "Nuremberg"}

    reasons = [
      :token_invalid,
      :token_refused,
      :unauthorized,
      :read_only_token,
      :account_limit,
      {:unavailable, unavailable},
      {:unavailable, %{unavailable | next_city: nil}},
      {:rate_limited, 1_999_999_999},
      {:unreachable, "timeout"},
      {:code_unavailable, "Remote reach is off."},
      :user_data_too_large,
      :invalid_code,
      :interrupted,
      :no_token,
      :no_server,
      :server_exists,
      :nothing_to_delete,
      :not_primary,
      :other_project,
      :live_home,
      :move_under_way,
      {:ledger, :eacces},
      :unreadable,
      # Replace the server, from the linked desktop.
      :replace_only,
      :nothing_to_replace,
      :replacement_exists,
      :replace_moving,
      :old_server_remains,
      :replacement_gone,
      :no_link,
      :code_unreachable,
      :withdraw_unreachable,
      {:code_refused, "unavailable"},
      {:withdraw_refused, "unavailable"},
      {:old_server, :unauthorized},
      {:old_server, Hetzner.error({:refused, 422, "server_error", "Hetzner had a hiccup."})},
      # What the driver answers around a provider's primitives.
      {:ineligible_type, "cpx12"},
      {:action_failed, :create, "server placement failed"},
      {:action_timeout, :start},
      :no_image,
      :no_capacity,
      :not_found,
      :resource_in_use,
      # Hetzner's own refusals, in its words.
      Hetzner.error({:refused, 422, "invalid_input", "invalid input in field 'server_type'"}),
      Hetzner.error(:too_many_types)
    ]

    for provider <- ProvisionRegistry.all(),
        reason <- reasons,
        do: {reason, Provision.error_sentence(reason, provider)}
  end

  # The words of `home.status.summary` (M75 lean v1 §7): every sentence key
  # Copy holds, for a Mac and for a Linux computer, every action's label, the
  # token steps, and the refusal that asks a desktop to update. The apps and
  # the setup page print them as they are, so beside the rules they carry
  # none of the engine's own words for the move and no fermix command.
  describe "the Always On summary copy" do
    test "every sentence, label and step obeys the rules and names nothing internal" do
      for {where, text, kind} <- summary_copy() do
        assert_clean(text, kind, [], where)

        assert Copy.summary_violations(text) == [],
               "#{where}: #{inspect(text)} breaks #{inspect(Copy.summary_violations(text))}"

        refute_command(text, where)
      end
    end

    # A summary word is plain words an owner reads: a backticked span is a
    # literal to type or a code, which `violations/3` lets stand as one, and
    # an internal word is the engine's own.
    test "the summary's own rule catches a backticked code and an internal word" do
      assert Copy.summary_violations("Hetzner refused the request (422 `invalid_input`).") ==
               [{:backtick, "`invalid_input`"}]

      assert Copy.summary_violations("A stray ` mark.") == [{:backtick, "`"}]

      assert Copy.summary_violations("Only the primary opens a code.") == [
               {:internal_word, "primary"}
             ]

      assert Copy.summary_violations("Fermix runs on your server.") == []
    end

    # A secret is named by what the settings call it, never by the id
    # `secret.set` takes, which `violations/3` lets a call site declare.
    test "the summary's own rule catches a secret's id" do
      assert Copy.summary_violations("The keychain did not give Fermix anthropic_api_key.") ==
               [{:secret_id, "anthropic_api_key"}]

      assert Copy.summary_violations("Set cue_source:invented-feed:key again.") ==
               [{:secret_id, "cue_source:invented-feed:key"}]

      assert Copy.summary_violations("The keychain did not give Fermix your Anthropic key.") ==
               []
    end

    # The summary prints a create's or a replace's failure as the provisioner
    # wrote it (`Provision.error_sentence/1`, kept in the ledger), so every
    # refusal it can keep is held to the summary's rule too.
    test "every failure sentence the summary prints is plain words" do
      offenders =
        for {reason, sentence} <- provision_copy(),
            (found = Copy.summary_violations(sentence)) != [],
            do: {reason, sentence, found}

      assert offenders == []

      quoted =
        Provision.error_sentence(
          Hetzner.error({:refused, 422, "invalid_input", "bad `name` field"}),
          Hetzner
        )

      assert Copy.summary_violations(quoted) == [], inspect(quoted)
    end

    # Always On setup §3.1: Details are lines the engine finishes, its times
    # absolute in the owner's zone and its prices from the ledger, so no
    # surface formats a time, a size or money.
    test "each Details line is a label and a value the engine finished" do
      ctx = %{zone: "Europe/Berlin", machine: "Mac"}
      at = ~U[2031-05-04 10:00:00Z]

      assert Copy.summary_line(:waits_until, at, ctx) ==
               %{"label" => "Waits until", "value" => "Sunday, May 4, 2031 at 12:00 PM CEST"}

      assert Copy.summary_line(:backup, {"S3", at}, ctx) ==
               %{
                 "label" => "Last backup to S3",
                 "value" => "Sunday, May 4, 2031 at 12:00 PM CEST"
               }

      assert Copy.summary_line(:checked, at, %{ctx | zone: "Etc/UTC"})["value"] ==
               "Sunday, May 4, 2031 at 10:00 AM UTC"

      assert Copy.summary_line(:copies, 3_221_225_472, ctx) ==
               %{"label" => "Backups on this Mac", "value" => "3 GiB"}

      assert Copy.summary_line(:disk, 0.42, ctx) ==
               %{"label" => "Server disk", "value" => "42% used"}

      assert Copy.summary_line(:costs, {"8.33", "EUR"}, ctx) ==
               %{"label" => "Costs", "value" => "€8.33 a month, billed by the hour until deleted"}

      assert Copy.summary_line(:costs, {"12.00", "USD"}, ctx)["value"] =~ "$12.00 a month"
      assert Copy.summary_line(:costs, {"9.10", "CHF"}, ctx)["value"] =~ "CHF 9.10 a month"
      assert Copy.summary_line(:server, "fermix-general-a3f9", ctx)["label"] == "Server"
      assert Copy.checked_label() == Copy.summary_line(:checked, at, ctx)["label"]

      for key <- Copy.summary_line_keys() do
        assert Copy.violations(Copy.summary_line_label(key), :name) == [], inspect(key)
      end
    end

    # Move now's confirm names what the move costs the owner, in the
    # review's own words, and never a time or a price, so it is stable.
    test "Move now's confirm asks once and names each warning in its words" do
      warnings = [
        "WhatsApp stops after the move: it needs an address on the internet that WhatsApp " <>
          "can send messages to, and north-box has none."
      ]

      assert Copy.move_confirm(warnings) ==
               "Move Fermix to your server now? WhatsApp stops after the move: it needs an " <>
                 "address on the internet that WhatsApp can send messages to, and north-box " <>
                 "has none."

      assert Copy.move_confirm([]) == "Move Fermix to your server now?"
    end

    test "the docs and the own-server command are the engine's to word" do
      assert Copy.always_on_docs_url("hetzner") == "https://fermix.ai/docs/always-on/#hetzner"
      assert Copy.own_server_command() == "curl -fsSL https://fermix.ai/always-on | sudo sh"
      refute Copy.own_server_command() =~ "FERMIX_ENROLL_CODE"
    end

    test "every key and every action answers its words" do
      assert length(Copy.summary_keys()) >= 38
      assert length(HomeSummary.actions()) == length(Enum.uniq(HomeSummary.actions()))
      assert Enum.count(summary_copy()) > 2 * length(Copy.summary_keys())
    end
  end

  defp summary_copy do
    values = %{
      age: 7_200,
      days: 5,
      percent: 90,
      block: "This home is about 4 GiB; the move needs about 9 GiB free.",
      stays_here: [:imessage, :voice, :meetings]
    }

    sentences =
      for provider <- ProvisionRegistry.all(),
          key <- Copy.summary_keys(),
          machine <- ["Mac", "computer"],
          values = Map.merge(values, provider_values(provider)),
          do:
            {"summary #{key}", Copy.summary_sentence(key, Map.put(values, :machine, machine)),
             :prose}

    labels =
      for provider <- ProvisionRegistry.all(),
          id <- HomeSummary.actions(),
          extra <- [%{}, %{first: true, code: true}],
          values = Map.merge(provider_values(provider), extra),
          do: {"action #{id}", Copy.summary_label(String.to_existing_atom(id), values), :name}

    steps =
      for provider <- ProvisionRegistry.all(),
          step <- provider.display().steps,
          do: {"#{provider.id()} token step", step, :prose}

    {:too_old, too_old} =
      Placement.primary_part(
        fn _request, _opts -> {:error, :client_too_old, %{}} end,
        "home.status"
      )

    sentences ++ labels ++ steps ++ [{"too old", too_old, :prose}]
  end

  # What the summary names of a provider: its name, its token's label and a
  # city of its own.
  defp provider_values(provider) do
    display = provider.display()

    %{
      provider: display.name,
      token_label: display.token_label,
      city: List.last(display.locations).city
    }
  end

  # The older copy the apps and the setup page show (readiness actions and
  # every settings row) is held to the same rule: what to do in the app, or
  # on the server, never a `fermix` command.
  # The summary prints sentences written outside `Copy` as they are: a
  # create's failure (`Home.Provision`, kept in the ledger), which keeps a
  # refused code as its own (`{:code_unavailable, _}`: the enrollment
  # window's and the rail's, `Home.Link`, in the channels app), the ledger's
  # unreadable file and the readiness items. They are swept from source with
  # every template rendered, so a fixed word of the engine's own, a code, or
  # a term an interpolation inlines fails here rather than in an owner's pane.
  describe "the sentences the summary takes from elsewhere" do
    test "every one is plain words, with no internal word, code or term" do
      offenders =
        for {file, sentence} <- summary_sources(),
            (found = Copy.summary_violations(sentence) ++ internal_terms(sentence)) != [],
            do: {Path.basename(file), sentence, found}

      assert offenders == []
    end

    test "the sweep reads every producer" do
      files = summary_sources() |> Enum.map(&Path.basename(elem(&1, 0))) |> Enum.uniq()

      # The ledger's own sentences are the contract's now (`Provision`), in
      # its provider's words; it is still read, so one written there is held.
      assert Enum.sort(files) ==
               ~w(enrollment.ex hetzner.ex link.ex move_readiness.ex provision.ex)

      assert Enum.count(summary_sources()) > 60
    end
  end

  describe "the readiness and settings copy an app pane shows" do
    test "names no fermix command" do
      readiness =
        for {key, action} <- Readiness.published_actions(), do: {"readiness #{key}", action}

      rows =
        for section <- Settings.sections(),
            row <- rows(section.id),
            text <- [row["label"], row["footer"], row["info"]],
            is_binary(text),
            do: {"#{section.id}.#{row["key"]}", text}

      for {where, text} <- readiness ++ rows, do: refute_command(text, where)
    end
  end

  describe "the sentences the management modules write" do
    test "every one obeys the rules" do
      for {file, sentence} <- source_sentences() do
        assert_clean(sentence, :prose, [], "sentence in #{Path.basename(file)}")
      end
    end

    test "the sweep reads the whole management tree" do
      files = source_sentences() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      assert length(files) > 10
      assert Enum.count(source_sentences()) > 100
      assert Enum.any?(files, &String.ends_with?(&1, "plugins.ex"))
      assert Enum.any?(files, &String.ends_with?(&1, "readiness.ex"))
    end
  end

  # The one defect the rules above cannot see. `inspect/1` and
  # `Redaction.format/1` answer Elixir term syntax, and the reasons that reach
  # these sentences carry the operator's own paths, so a sentence assembled from
  # one reads as a crash dump in the app, on the browser door, and again in the
  # `management_job` bookend that carries it. The set is the same source sweep,
  # with the templates rendered: a fixed sentence plus a daemon-side log is what
  # passes, and nothing else does.
  describe "the internal terms a published sentence must never carry" do
    test "no published sentence carries a map, a tuple or an absolute path" do
      for {file, sentence} <- published_sentences() do
        assert internal_terms(sentence) == [],
               "sentence in #{Path.basename(file)}: #{inspect(sentence)} " <>
                 "carries #{inspect(internal_terms(sentence))}"
      end
    end

    # A gate nothing provokes is a gate nobody has seen fire, so each shape is
    # asserted against a sentence assembled the way the refused ones were.
    test "each forbidden shape names its own offender" do
      assert :map in internal_terms("The install did not finish: #{@internal_term}.")
      assert :tuple in internal_terms("The install did not finish: #{@internal_term}.")
      assert :absolute_path in internal_terms("The install did not finish: #{@internal_term}.")
      assert internal_terms("The install did not finish. See the daemon log.") == []
    end

    test "the template half of the sweep reads real sentences" do
      templates = source_templates() |> Enum.map(&elem(&1, 1))

      assert length(templates) > 10
      assert Enum.any?(templates, &String.contains?(&1, @placeholder))
    end
  end

  # A producer that answers nothing turns its whole clause above into a loop
  # over an empty list, which passes. The floors are the shapes of the live
  # registries, not round numbers.
  test "every producer the gate walks answers something" do
    assert length(Settings.sections()) >= length(Descriptor.all())
    assert Enum.count(published_copy()) > 200
    assert plugin_rows() != []
    assert Readiness.published_actions() != []
    assert Remediation.keys() != []
    assert Enum.any?(Settings.sections(), &(rows(&1.id) != []))
  end

  # A proper noun nothing publishes any more is a rule that has quietly widened:
  # the list is the only hand-maintained part of the gate, so it is asserted
  # against the copy rather than trusted.
  test "every hand-listed proper noun is still used by published copy" do
    corpus = Enum.join(published_copy(), "\n")
    unused = Enum.reject(hand_listed(), &String.contains?(corpus, &1))

    assert unused == [], "proper nouns no published sentence uses: #{inspect(unused)}"
  end

  # A proper noun an Always On provider declares is held to its own words: a
  # name none of them uses has quietly widened the rule.
  test "every proper noun an Always On provider declares is used by its words" do
    for provider <- ProvisionRegistry.all() do
      display = provider.display()

      corpus =
        Enum.join(
          [display.name, display.token_label, display.write_token] ++
            display.steps ++
            Enum.map(display.locations, & &1.city) ++
            Enum.map(provision_copy(), &elem(&1, 1)),
          "\n"
        )

      unused = Enum.reject(display.proper_nouns, &String.contains?(corpus, &1))
      assert unused == [], "#{provider.id()} declares unused proper nouns: #{inspect(unused)}"
    end
  end

  # The derived half comes from the provider registries and cannot go stale;
  # only what the module writes by hand has to be asserted against the copy.
  defp hand_listed do
    derived =
      Descriptor.all()
      |> Enum.flat_map(&String.split(&1.label, ~r/[\s()]+/, trim: true))
      |> Enum.concat(Enum.flat_map(ProvisionRegistry.all(), & &1.display().proper_nouns))
      |> MapSet.new()

    Enum.reject(Copy.proper_nouns(), &MapSet.member?(derived, &1))
  end

  defp published_copy do
    section_copy() ++
      Enum.map(Settings.sections(), & &1.title) ++
      Enum.flat_map(Remediation.keys(), fn key ->
        [id, status] = String.split(key, ".")
        entry = Remediation.fetch(id, status)
        [entry["title"], entry["body"]]
      end) ++
      Enum.map(RestartState.boot_bound_sections(), fn {_section, sentence} -> sentence end) ++
      [RestartState.waiting_transports_sentence()] ++
      Enum.map(Readiness.published_actions(), fn {_key, action} -> action end) ++
      Map.values(Protocol.error_messages()) ++
      PluginRow.verbs() ++
      Enum.map(PluginRow.statuses(), &PluginRow.check_sentence/1) ++
      plugin_copy() ++
      Enum.map(provision_copy(), &elem(&1, 1)) ++
      Enum.map(summary_copy(), &elem(&1, 1)) ++
      Enum.map(source_sentences(), &elem(&1, 1))
  end

  defp section_copy do
    for section <- Settings.sections(),
        row <- rows(section.id),
        text <- [row["label"], row["footer"], row["info"], row["unit"]] ++ option_copy(row),
        is_binary(text) do
      text
    end
  end

  defp option_copy(row) do
    Enum.flat_map(row["options"], &[&1["label"], &1["hint"]])
  end

  defp plugin_copy do
    for row <- plugin_rows(),
        text <- [row["status_sentence"], row["consent_sentence"], row["remote_disclosure"]],
        is_binary(text) do
      text
    end
  end

  defp rows(section) do
    {:ok, view} = Settings.get(section)
    view["rows"]
  end

  # A sandbox name row is labelled with the variable name the operator allowed,
  # which is data the row reflects rather than copy the daemon wrote.
  defp row_names(%{"key" => "env:" <> name}), do: [name]
  defp row_names(_row), do: []

  defp sandbox_name_rows do
    managed = &SecretWriter.command_source({:external_env, &1})

    sandbox =
      SandboxConfig.normalize(
        env: [
          allow: ~w(STORED_KEY UNSTORED_KEY HELPER_KEY ALIAS_KEY HOME),
          sources: %{
            "STORED_KEY" => managed.("STORED_KEY"),
            "HELPER_KEY" => %{source: :command, command: "/usr/local/bin/op"},
            "ALIAS_KEY" => %{source: :env, name: "OLD_NAME"},
            "PARKED_KEY" => managed.("PARKED_KEY")
          }
        ]
      )

    snapshot = Map.put(ConfigStore.current_snapshot(), :sandbox, sandbox)
    {:ok, view} = Settings.get("sandbox", snapshot: snapshot)
    Enum.filter(view["rows"], &String.starts_with?(&1["key"], "env:"))
  end

  @mcp_servers ~S"""
  [mcp.servers.files]
  command = "npx"
  args = ["-y", "server-filesystem"]
  cwd = "/Users/owner/mcp"
  env_secrets = ["GITHUB_TOKEN"]

  [mcp.servers.linear]
  transport = "http"
  url = "https://mcp.linear.app/mcp"
  auth = "header"
  key_header = "Authorization"
  header_secrets = ["X-Workspace", "Authorization"]
  oauth_client_id = "fermix"

  [mcp.servers.notion]
  transport = "http"
  url = "https://mcp.notion.com/mcp"
  """

  # One row for every status and every class a failed server can end in, for a
  # local and a remote server, each with the names it reflects.
  defp mcp_rows do
    servers = McpConfig.from_toml(@mcp_servers)
    tail = ["the server said: fatal error"]

    entries =
      [nil, {:connecting, nil}, {:ready, nil}, {:reauthorization_required, :sign_in_required}] ++
        [{:insufficient_credential_scope, nil}] ++
        for(
          detail <- ~w(command_not_found cwd_not_found env_unavailable header_unavailable
                       reserved_header invalid_url other)a,
          do: {:invalid_remote_config, detail}
        ) ++
        for(
          detail <- ~w(exited retries_exhausted spawn_failed rate_limited econnrefused)a,
          do: {:remote_unreachable, detail}
        ) ++
        [
          {:reauthorization_required, :key_refused},
          {:reauthorization_required, nil},
          {:remote_protocol_error, :legacy_sse_transport},
          {:remote_protocol_error, :jsonrpc_error},
          {:remote_security_blocked, :link_local},
          {:capability_conflict, nil},
          {:upstream_contract_mismatch, :missing_tool}
        ]

    for server <- servers,
        enabled? <- [true, false],
        stored? <- [true, false],
        entry <- entries,
        alive? <- [true, false],
        grant <- mcp_grants() do
      row =
        McpRow.build(%{server | enabled?: enabled?}, %{
          presence: mcp_presence(server, stored?),
          entry: mcp_entry(entry, tail),
          alive?: alive?,
          resolution: nil,
          grant: grant
        })

      names = ["npx", "mcp.linear.app", "mcp.notion.com", "/Users/owner/mcp", "GITHUB_TOKEN"]
      {row, names ++ ["X-Workspace"] ++ tail}
    end
  end

  # Every state an `auto` server's grant reads as on its row (M74 E5).
  defp mcp_grants do
    grant = %{
      state: :signed_in,
      account_label: "owner@example.com",
      issuer: "https://auth.example.com",
      wanted_scopes: []
    }

    [nil, grant, %{grant | state: :expired}, %{grant | wanted_scopes: ["admin"]}]
  end

  defp cue_source_rows do
    cues =
      CuesConfig.normalize(%{
        "sources" => %{
          "eng-blogs" => %{"preset" => "rss", "url" => "https://example.org/feed.xml"},
          "live-open" => %{
            "kind" => "stream",
            "url" => "wss://stream.example.org/open",
            "id_path" => "id"
          },
          "gh-hooks" => %{"preset" => "github", "secret" => "@keyring"},
          "gh-new" => %{"preset" => "github", "path_secret" => "@keyring"},
          "shared" => %{
            "kind" => "webhook",
            "verify" => "shared_secret",
            "header" => "X-Token",
            "id" => "content_hash"
          },
          "space-posts" => %{"preset" => "x_accounts", "handles" => ["nasa"]},
          "home-alerts" => %{"kind" => "local_push", "token" => "@keyring"},
          "new-alerts" => %{"kind" => "local_push"},
          "live-news" => %{
            "kind" => "stream",
            "url" => "wss://stream.example.org/news",
            "id_path" => "id",
            "key_header" => "X-Feed-Key",
            "auth_message" => ~s({"secret":"{{secret}}"})
          },
          "live-keyed" => %{
            "kind" => "stream",
            "url" => "wss://stream.example.org/news",
            "id_path" => "id",
            "key_header" => "X-Feed-Key",
            "secret_header" => "X-Feed-Secret",
            "key" => "@keyring"
          }
        }
      })

    statuses = ~w(idle polling connected reconnecting auth_failed over_budget stopped unavailable)

    facts =
      [
        %{row: nil, running?: false, cues_on?: false, memory?: false},
        %{row: nil, running?: false, cues_on?: false, memory?: true},
        %{row: nil, running?: false, cues_on?: true, memory?: true},
        %{row: nil, running?: true, cues_on?: true, memory?: true}
        | Enum.map(statuses, fn status ->
            %{
              row: %{status: status, last_accepted_at: ~U[2026-10-17 10:00:00Z]},
              running?: true,
              cues_on?: true,
              memory?: true
            }
          end)
      ] ++
        [
          %{
            row: %{status: "unavailable", stop_reason: "too_large"},
            running?: true,
            cues_on?: true,
            memory?: true
          },
          %{
            row: %{status: "auth_failed", stop_reason: "x_sign_in"},
            running?: true,
            cues_on?: true,
            memory?: true
          }
        ]

    for source <- CuesConfig.sources(cues),
        variant <- [source, %{source | enabled?: false}],
        fact <- facts do
      row = CueSourceRow.build(variant, Map.merge(fact, %{summary: nil, window_s: 86_400}))
      {row, [source.ref, "example.org"]}
    end
  end

  defp cue_watcher_rows do
    base = %{
      id: "cwt_1",
      name: "release-watch",
      enabled?: true,
      filter: "llm",
      held?: false,
      needs_update: nil,
      offered: 56,
      waiting: 12,
      passed: 3,
      dropped: 41,
      acted: 2,
      failed: 0,
      sources: ["eng-blogs"],
      task_job_id: "job_1",
      task_name: "Release watch",
      follow_up: nil,
      task_paused?: false,
      task_notes?: false,
      daily_cap: 0,
      filter_budget: 0,
      instruction_count: 1,
      created_at: nil
    }

    for watcher <-
          [
            base,
            %{base | enabled?: false},
            %{base | held?: true},
            %{base | held?: true, waiting: 1},
            %{base | needs_update: :words},
            %{base | filter: "none", needs_update: :filter},
            %{base | filter: "none"},
            %{base | filter: "none", task_job_id: nil, follow_up: follow_up_view(false)}
          ] ++ Enum.map(follow_up_views(), &%{base | follow_up: &1}) do
      CueWatcherRow.build(watcher, %{window_s: 86_400})
    end
  end

  # A watcher's follow-up asking first and always allowed, and held for each
  # reason the readiness check words (M60_WATCHER_CODING_RUNS.md §3.2).
  defp follow_up_views do
    held = follow_up_held_sentences()

    [follow_up_view(false), follow_up_view(true)] ++
      Enum.map(held, &%{follow_up_view(false) | held: &1})
  end

  defp follow_up_view(always_allowed?),
    do: %{
      job_id: "job_2",
      name: "Codex review",
      always_allowed?: always_allowed?,
      held: nil,
      paused?: false
    }

  # Every sentence `Cues.FollowUpReadiness` and the hold can answer, walked out of
  # the check with every read a seam.
  defp follow_up_held_sentences do
    registry = :"copy_follow_up_caps_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: registry}, id: registry)

    plugin = %{
      name: "github",
      display_name: "GitHub",
      runtime: nil,
      tools: [%{"name" => "github_create_issue"}]
    }

    runtime_plugin = %{
      plugin
      | name: "linear",
        display_name: "Linear",
        runtime: %{"kind" => "node"}
    }

    base = [capability_registry: registry, plugins: fn -> {:ok, [plugin, runtime_plugin]} end]

    harnesses = [
      [enabled: false],
      [enabled: true, approved: false],
      [enabled: true, approved: true],
      [enabled: true, approved: true, cloud_enabled: true]
    ]

    statuses = ~w(not_configured needs_auth needs_secret needs_config not_installed ready error)a

    coding =
      for harness <- harnesses,
          path <- [[], ["codex", "claude"]],
          tools <- [["codex_run"], ["claude_code_run"], ["codex_cloud_run"]] do
        follow_up_check(tools, base,
          harness_config: harness,
          vendor_opts: [
            find_executable: fn name -> if name in path, do: "/stub/#{name}" end,
            codex_home: "/nonexistent/codex",
            claude_config_dir: "/nonexistent/claude"
          ]
        )
      end

    plugins =
      for status <- statuses, tool <- ["github_create_issue", "linear_create", "deploy_check"] do
        follow_up_check([tool], base, plugin_status: fn _plugin -> status end)
      end

    channels =
      for platform <- ~w(telegram slack discord whatsapp) do
        follow_up_check([], base, target: platform, channel_ready?: fn _key -> false end)
      end

    switch_off =
      {_label, _sentence} =
      FollowUps.held(
        %{allowed_tools: []},
        cues_config: [mandates_enabled: false]
      )

    Enum.uniq(coding ++ plugins ++ channels ++ folder_sentences(base) ++ [elem(switch_off, 1)]) --
      [nil]
  end

  # Outside the roots, blocked, protected and past the bound, against a strict
  # sandbox in a folder never made: each path is judged where it would be.
  defp folder_sentences(base) do
    root =
      Path.join(
        PathPolicy.canonical_path(System.tmp_dir!()),
        "fermix-copy-#{System.unique_integer([:positive])}"
      )

    sandbox = %{
      mode: :strict,
      home: Path.join(root, "fermix"),
      os_home: Path.join(root, "home"),
      workspace_root: Path.join(root, "workspace"),
      allowed_roots: [Path.join(root, "src")],
      blocked_roots: [Path.join(root, "src/vault")]
    }

    for instructions <- [
          "Review #{root}/elsewhere.",
          "Back up #{root}/src/vault/keys.",
          "Copy ~/.ssh/config.",
          "Review " <> Enum.map_join(1..11, ", ", &"#{root}/src/p#{&1}") <> "."
        ] do
      follow_up_check([], base, sandbox_config: sandbox, instructions: instructions)
    end
  end

  defp follow_up_check(tools, base, extra) do
    {target, extra} = Keyword.pop(extra, :target, "companion")
    {instructions, extra} = Keyword.pop(extra, :instructions)

    job = %{
      allowed_tools: tools,
      task_prompt: instructions,
      delivery_target: %{"platform" => target, "chat_id" => "1"}
    }

    case FollowUpReadiness.check(job, base ++ extra) do
      :ready -> nil
      {:not_ready, sentence} -> sentence
    end
  end

  defp cue_mandate_rows do
    mandate = %Mandates{
      name: "release-issues",
      job: "job_1",
      mode: :approve,
      tools: ["github_create_issue"],
      read_tools: [],
      approve_within_s: 1_800,
      max_cue_age_s: 900
    }

    status = fn state ->
      {:ok,
       %{
         name: "release-issues",
         state: state,
         approved_at: nil,
         approved_from: nil,
         disabled_at: nil,
         disabled_reason: nil,
         detail: nil
       }}
    end

    approvals =
      Enum.map(~w(unapproved approved changed disabled)a, status) ++
        [{:error, :memory_off}, {:error, :timeout}]

    for variant <- [
          mandate,
          %{mandate | mode: :auto},
          %{mandate | enabled?: false},
          %{mandate | status: {:inactive, "Job job_1 does not exist."}}
        ],
        approval <- approvals do
      CueMandateRow.build(%{mandate: variant, approval: approval}, %{
        counts: %{},
        window_s: 86_400
      })
    end
  end

  defp cue_proposal_rows do
    base = %{
      id: "cpr_1",
      mandate: "release-issues",
      tool: "github_create_issue",
      job_id: "job_1",
      job_name: "Release watch",
      watcher: "release-watch",
      source_ref: "eng-blogs",
      created_at: ~U[2026-10-17 11:50:00Z],
      expires_at: ~U[2026-10-17 12:20:00Z],
      decided_at: nil,
      decided_from: nil,
      result_status: nil
    }

    [
      Map.put(base, :state, "waiting"),
      Map.merge(base, %{state: "confirmed", decided_from: "management"}),
      Map.merge(base, %{state: "confirmed", result_status: "ok"}),
      Map.merge(base, %{state: "confirmed", result_status: "unknown"}),
      Map.merge(base, %{state: "confirmed", result_status: "error"}),
      Map.put(base, :state, "denied"),
      Map.put(base, :state, "expired"),
      Map.put(base, :state, "refused"),
      Map.merge(base, %{state: "refused", decided_from: "companion"})
    ]
  end

  defp follow_up_card(state) do
    %{
      trigger_id: "cft_1",
      state: state,
      mode: "approve",
      reason: if(state == "refused", do: "Not started: it is already running."),
      created_at: ~U[2026-10-30 12:00:00Z],
      expires_at: ~U[2026-10-30 12:30:00Z],
      decided_at: nil,
      decided_from: nil,
      run_id: nil,
      watcher: %{id: "cwt_1", name: "codex-limits"},
      follow_up: %{
        job_id: "job_1",
        name: "Codex review",
        instructions: "Review the last day's commits on dev.",
        tools: ["codex_run"],
        delivery: %{mode: "origin", target: %{"platform" => "telegram", "chat_id" => "1"}}
      },
      outside: %{
        source_ref: "x-feed",
        received_at: ~U[2026-10-30 11:59:00Z],
        occurred_at: nil,
        type: "x.post",
        subject: "limits",
        text: "Limits reset.",
        reason: "a reset"
      }
    }
  end

  defp mcp_presence(server, stored?) do
    %{
      env: Enum.map(Map.get(server, :env_secrets, []), &{&1, stored?}),
      headers: Enum.map(Map.get(server, :header_secrets, []), &{&1, stored?}),
      client_secret: stored?
    }
  end

  defp mcp_entry(nil, _tail), do: nil

  defp mcp_entry({status, detail}, tail) do
    discovery = %{tool_count: 3, server_info: nil, tools: []}
    %{status: status, detail: detail, subject: nil, discovery: discovery, stderr_tail: tail}
  end

  defp plugin_rows do
    {:ok, %{"plugins" => rows}} = Plugins.list()
    rows
  end

  # A regional provider's client is incomplete without a region, so the sweep
  # over every provider carries the first region each one offers.
  defp client_config(id) do
    region =
      case OAuthProviders.regions(id) do
        [] -> []
        [%{id: region} | _rest] -> [region: region]
      end

    [client_id: "id", client_secret: "s"] ++ region
  end

  defp refusal(provider, error) do
    body = %{"error" => error, "error_description" => "The vendor's own words."}
    {:oauth_client_rejected, detail} = ClientRejection.classify(provider, 401, body)
    detail
  end

  @lib Path.expand("../../../lib/fermix_core", __DIR__)
  @channels_lib Path.expand("../../../../fermix_channels/lib/fermix_channels", __DIR__)

  defp published_sentences, do: source_sentences() ++ source_templates()

  defp internal_terms(sentence) do
    prose = Regex.replace(@backticked, sentence, "``")

    for {shape, pattern} <- @term_shapes, Regex.match?(pattern, prose), do: shape
  end

  defp source_files do
    Path.wildcard(Path.join(@lib, "management/**/*.ex")) ++
      [
        Path.join(@lib, "readiness.ex"),
        Path.join(@lib, "setup/restart_state.ex"),
        Path.join(@lib, "setup/coexistence.ex")
      ]
  end

  defp source_sentences, do: collect(&literal/1)

  defp summary_sources do
    files =
      Enum.map(
        [
          "home/provision.ex",
          "home/provision/ledger.ex",
          "home/provision/hetzner.ex",
          "home/move_readiness.ex"
        ],
        &Path.join(@lib, &1)
      ) ++ Enum.map(["home/enrollment.ex", "home/link.ex"], &Path.join(@channels_lib, &1))

    collect(files, &literal/1) ++ collect(files, &template/1) ++ collect(files, &joined/1)
  end

  # A sentence written over several lines is `<>`-joined fragments, none of
  # them a sentence alone: rendered whole, so the sweep reads what is shown.
  defp joined({:<>, _meta, [left, right]}), do: keep(fragment(left) <> fragment(right))
  defp joined(_node), do: :skip

  defp fragment({:<>, _meta, [left, right]}), do: fragment(left) <> fragment(right)
  defp fragment({:<<>>, _meta, parts}), do: Enum.map_join(parts, &part/1)
  defp fragment(text) when is_binary(text), do: text
  defp fragment(_other), do: @placeholder

  # The same sweep, reading the sentences that are assembled rather than
  # written: every interpolation is rendered, so a template that inlines a
  # reason is judged on the text a client would actually be shown.
  defp source_templates, do: collect(&template/1)

  defp collect(render), do: collect(source_files(), render)

  defp collect(files, render) do
    Enum.flat_map(files, fn file ->
      {:ok, ast} = Code.string_to_quoted(File.read!(file))
      {_ast, found} = Macro.prewalk(ast, [], &collect_sentence(&1, &2, render))

      found |> Enum.uniq() |> Enum.map(&{file, &1})
    end)
  end

  defp collect_sentence({:@, meta, [{doc, _, _}]}, acc, _render)
       when doc in [:moduledoc, :doc, :typedoc],
       do: {{:@, meta, []}, acc}

  defp collect_sentence(node, acc, render) do
    case render.(node) do
      {:ok, text} -> {node, [text | acc]}
      :skip -> {node, acc}
    end
  end

  defp literal(node) when is_binary(node), do: keep(node)
  defp literal(_node), do: :skip

  defp template({:<<>>, _meta, parts}), do: parts |> Enum.map_join(&part/1) |> keep()
  defp template(_node), do: :skip

  defp keep(text), do: if(sentence?(text), do: {:ok, text}, else: :skip)

  defp part(text) when is_binary(text), do: text

  defp part({:"::", _meta, [{{:., _dot, [Kernel, :to_string]}, _call, [expr]}, _binary]}),
    do: interpolated(expr)

  defp part(_other), do: @placeholder

  # `inspect/1` and `Redaction.format/1` (and auth's one-line delegate to it)
  # answer an internal term; everything else a sentence interpolates is a
  # bounded scalar the daemon has already chosen. The placeholder is
  # capitalised so a template that opens with an interpolation still reads as a
  # sentence to `sentence?/1`.
  defp interpolated({:inspect, _meta, [_term]}), do: @internal_term
  defp interpolated({:format, _meta, [_term]}), do: @internal_term
  defp interpolated({{:., _meta, [_module, :format]}, _call, [_term]}), do: @internal_term
  defp interpolated(_expr), do: @placeholder

  # A whole sentence: it opens with a capital, closes with a full stop, and has
  # more than one word. A key, a format fragment and a log prefix do not.
  defp sentence?(text) do
    String.contains?(text, " ") and String.ends_with?(text, ".") and
      String.match?(text, ~r/^[A-Z]/)
  end

  defp command?(text), do: Regex.match?(@fermix_command, text)

  defp refute_command(text, where) do
    refute command?(text), "#{where}: #{inspect(text)} prescribes a fermix command"
  end

  defp assert_clean(nil, _kind, _names, _where), do: :ok

  defp assert_clean(text, kind, names, where) when is_binary(text) do
    assert Copy.violations(text, kind, names) == [],
           "#{where}: #{inspect(text)} breaks #{inspect(Copy.violations(text, kind, names))}"
  end
end
