defmodule FermixCore.Management.SettingsTest do
  @moduledoc """
  The settings descriptor and its writes (M34 native setup §7.3, §7.7).

  Every case establishes its own home and its own application environment in
  `setup` and restores both in `on_exit`: rows are a projection of global
  configuration, so a case reading what an earlier module left behind would pass
  or fail on test order.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Management.Copy
  alias FermixCore.Management.Secrets
  alias FermixCore.Management.Settings
  alias FermixCore.Management.Settings.AnswerMap
  alias FermixCore.Management.Settings.Row
  alias FermixCore.Management.Settings.Voice
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Readiness
  alias FermixCore.Realtime.Config, as: RealtimeConfig
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState
  alias FermixCore.Setup.SecretWriter
  alias FermixCore.Transcription.Local, as: LocalTranscription
  alias FermixCore.Transcription.Local.SidecarInstaller, as: SttInstaller
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub

  @core_keys [
    :providers,
    :routing,
    :personalization,
    :agent,
    :compaction,
    :memory,
    :skill_curation,
    :realtime,
    :transcription,
    :meetings,
    :computer_use,
    :computer_history,
    :harness,
    :tools,
    :sandbox,
    :secret_writer
  ]
  @channel_keys [:telegram, :whatsapp, :discord, :slack, :signal, :acp]

  @row_fields ~w(
    key kind label footer info value present options min max step restart read_only suggestions
    unit format
  )

  setup do
    home = System.get_env("FERMIX_HOME")
    core = Map.new(@core_keys, fn key -> {key, Application.get_env(:fermix_core, key)} end)

    channels =
      Map.new(@channel_keys, fn key -> {key, Application.get_env(:fermix_channels, key)} end)

    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    SecretWriterStub.reset()

    tmp = SafeRm.make_tmp_dir!("management_settings_home")
    System.put_env("FERMIX_HOME", tmp)
    # The tree already runs one restart state, and it is the one every writer
    # consults. Recording the baseline against this home is what makes each case
    # start from a known `config_state` instead of a cached answer about the
    # home the previous case used.
    :ok = RestartState.record_persisted_baseline()

    on_exit(fn ->
      Enum.each(core, fn {key, value} -> restore(:fermix_core, key, value) end)
      Enum.each(channels, fn {key, value} -> restore(:fermix_channels, key, value) end)
      SecretWriterStub.reset()

      case home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      SafeRm.rm_rf!(tmp)
      :ok = RestartState.record_persisted_baseline()
    end)

    %{home: tmp}
  end

  describe "the section inventory" do
    test "publishes one section per provider descriptor, under the providers pane" do
      ids = Enum.map(Settings.sections(), & &1.id)

      for descriptor <- Descriptor.all() do
        assert "providers.#{descriptor.id}" in ids
      end
    end

    test "publishes one section per channel plus the editors surface" do
      sections = Settings.sections()

      for channel <- Readiness.channels() do
        assert Enum.any?(sections, &(&1.id == "channels.#{channel}"))
      end

      assert Enum.any?(sections, &(&1.id == "editors" and &1.pane == "channels"))
    end

    # The inventory is the one enumerator: a section reachable through `get/2`
    # and absent from it would be a fourth hand-written list for a client to
    # discover by accident.
    test "every published section can be read, and every id is unique" do
      ids = Enum.map(Settings.sections(), & &1.id)

      assert ids == Enum.uniq(ids)

      for %{id: id} <- Settings.sections() do
        assert {:ok, %{"id" => ^id}} = Settings.get(id)
      end
    end

    test "every pane a section names is a pane the app routes to" do
      panes = ~w(providers personality memory channels voice meetings computer coding
                 search images sandbox)

      for section <- Settings.sections() do
        assert section.pane in panes, "#{section.id} names an unroutable pane"
      end
    end

    test "titles are sentence case and carry no wire punctuation" do
      for %{id: id, title: title} <- Settings.sections() do
        assert title != "", "#{id} has no title"
        refute title =~ "—", "#{id} title carries an em dash"
        refute title =~ "!", "#{id} title carries an exclamation mark"
      end
    end
  end

  # `info` is free text a call site hands in rather than a value this module
  # derives, so the builder refuses what no surface can draw: an empty string is
  # an info control with nothing behind it, and anything else is not the shape
  # the wire publishes.
  describe "the row builder" do
    test "a row carries no explanation unless its call site declares one" do
      assert Row.new("k", :text, "Label", restart: false)["info"] == nil
    end

    test "a declared explanation is published verbatim" do
      row = Row.new("k", :text, "Label", restart: false, info: "The longer story.")

      assert row["info"] == "The longer story."
    end

    test "an empty or non-string explanation fails at build time" do
      assert_raise ArgumentError, ~r/row k declared/, fn ->
        Row.new("k", :text, "Label", restart: false, info: "")
      end

      assert_raise ArgumentError, ~r/row k declared/, fn ->
        Row.new("k", :text, "Label", restart: false, info: :venice)
      end
    end

    # A choice greyed out with no reason is one the operator cannot act on.
    test "a disabled option must say why" do
      assert Row.option("v", "Label", disabled: true, hint: "Not here.")["hint"] == "Not here."

      for hint <- [nil, ""] do
        assert_raise ArgumentError, ~r/option v is disabled without a hint/, fn ->
          Row.option("v", "Label", disabled: true, hint: hint)
        end
      end
    end
  end

  describe "one section's rows" do
    test "an unknown section is refused rather than answered empty" do
      assert Settings.get("nonesuch") == {:error, {:unknown_section, "nonesuch"}}
    end

    # The client decodes a fixed record. A field the daemon omits is a decode
    # failure, not a default.
    test "every row of every section carries every published field" do
      for %{id: id} <- Settings.sections(), row <- rows(id) do
        assert Enum.sort(Map.keys(row)) == Enum.sort(@row_fields),
               "#{id}/#{row["key"]} does not carry the published row shape"

        assert row["kind"] in Enum.map(Row.kinds(), &Atom.to_string/1)
        assert is_boolean(row["restart"]) and is_boolean(row["read_only"])
      end
    end

    test "a secret row reports presence and never a value" do
      for %{id: id} <- Settings.sections(), row <- rows(id), row["kind"] == "secret" do
        assert row["value"] == nil, "#{id}/#{row["key"]} carries a secret value"
        assert is_boolean(row["present"]), "#{id}/#{row["key"]} does not report presence"
      end
    end

    # The key behind this row is the NAMES of the environment variables a
    # sandboxed command may read. A label that says "variable" alone reads as a
    # setting of the sandbox rather than as the process environment, and the
    # footer is the only place the names-not-values distinction is made.
    test "the sandbox allow row names environment variables and says values are hidden" do
      row = row("sandbox", "sandbox_env_allow")

      assert row["label"] == "Allowed environment variables"
      assert row["footer"] == "These are names only. Values are never shown here."
    end

    test "only a number row carries a unit or a format" do
      for %{id: id} <- Settings.sections(), row <- rows(id), row["kind"] != "number" do
        assert row["unit"] == nil, "#{id}/#{row["key"]} carries a unit"
        assert row["format"] == nil, "#{id}/#{row["key"]} carries a number format"
      end
    end

    test "a choice row publishes options and no other kind does" do
      for %{id: id} <- Settings.sections(), row <- rows(id), row["kind"] != "choice" do
        assert row["options"] == [], "#{id}/#{row["key"]} publishes options"
      end
    end

    # The restart flag is derived from the same list that decides what
    # `restart.required` reports, so a row can never deny a restart the very
    # next `overview.get` asks for.
    test "a row is flagged exactly when its own section is boot-bound" do
      assert Enum.all?(rows("channels.telegram"), & &1["restart"])
      assert Enum.all?(rows("realtime"), & &1["restart"])
      assert %{"restart" => true} = row("sandbox", "sandbox_mode")
      assert %{"restart" => true} = row("sandbox", "sandbox_profile")
      # The environment policy is read on every command (M45 §4.5).
      assert %{"restart" => false} = row("sandbox", "sandbox_env_allow")

      refute Enum.any?(rows("memory"), & &1["restart"])
      refute Enum.any?(rows("transcription"), & &1["restart"])
      assert %{"restart" => false} = row("personalization", "user_name")
      assert %{"restart" => true} = row("personalization", "skill_curation_enabled")
    end

    test "every channel section carries its credentials and a real enable toggle" do
      for channel <- Readiness.channels() do
        rows = rows("channels.#{channel}")
        keys = Enum.map(rows, & &1["key"])

        assert "#{channel}_enabled" in keys, "#{channel} has no enable toggle"
        assert "#{channel}_owner_user_id" in keys, "#{channel} has no owner id"
      end

      whatsapp = Enum.map(rows("channels.whatsapp"), & &1["key"])

      for key <- ~w(whatsapp_access_token whatsapp_verify_token whatsapp_app_secret) do
        assert key in whatsapp, "WhatsApp cannot be completed without #{key}"
      end
    end

    test "the telegram toggle shows the shipped default before anything is configured" do
      Application.put_env(:fermix_channels, :telegram, [])
      Application.put_env(:fermix_channels, :discord, [])

      assert %{"value" => true} = row("channels.telegram", "telegram_enabled")
      assert %{"value" => false} = row("channels.discord", "discord_enabled")
    end

    test "meeting help distinguishes Google Meet setup from Zoom credentials" do
      footer = row("meetings", "meetings_enabled")["footer"]

      assert footer =~ "Google Meet"
      assert footer =~ "Zoom"
      assert footer =~ "RTMS credentials"
      refute footer =~ "first enable"
    end

    test "a provider section reads its own block" do
      Application.put_env(:fermix_core, :providers,
        anthropic: [default_model: "claude-opus-5", auth_mode: :oauth]
      )

      assert %{"value" => "claude-opus-5"} = row("providers.anthropic", "default_model")
      assert %{"value" => "oauth", "kind" => "choice"} = row("providers.anthropic", "auth_mode")
    end

    # The macOS app draws its model picker from these options, so a catalog
    # model reaches the app only if it is published here.
    test "a model row offers the newest catalog models to the app" do
      published = fn section ->
        section |> row("default_model") |> Map.fetch!("options") |> Enum.map(& &1["value"])
      end

      assert "claude-opus-5-5" in published.("providers.anthropic")
      assert "grok-4.7" in published.("providers.xai")

      for section <- ["providers.openai", "providers.openai_codex"] do
        assert ["gpt-6-sol", "gpt-6-luna"] -- published.(section) == []
      end
    end

    # The explanation behind the model row's info control is the descriptor's,
    # so the one provider that declares it publishes it and every other one
    # publishes null. A branch on the provider id here would be a second place
    # the sentence lives, and the two would drift.
    test "a model row publishes exactly the explanation its descriptor declares" do
      for descriptor <- Descriptor.all() do
        section = "providers.#{descriptor.id}"

        assert row(section, "default_model")["info"] == descriptor.model_info,
               "#{section} publishes an explanation its descriptor does not declare"
      end

      assert row("providers.venice", "default_model")["info"] =~ "Private models"
      assert row("providers.openai", "default_model")["info"] == nil
    end

    test "a single-mode provider publishes no auth-mode row" do
      keys = Enum.map(rows("providers.openai"), & &1["key"])

      refute "auth_mode" in keys
      assert "openai_api_key" in keys
    end

    test "a number row publishes its own bounds, so no front-end invents them" do
      assert %{"min" => 0.1, "max" => 1.0, "step" => 0.01, "format" => "percent"} =
               row("memory", "compaction_threshold")

      assert %{"min" => 0, "step" => 1, "unit" => "hours"} =
               row("memory", "review_interval_hours")
    end
  end

  # The voice section is the one section whose row list depends on a value inside
  # itself: the model decides which engine is in force, and the engine decides
  # which voices exist, whether reasoning effort is a setting at all, and whether
  # the backend that answers is worth naming. A client renders whichever list it
  # is handed, so the engine-scoped half is pinned here rather than trusted.
  # On-device speech runs only where this build pins a sidecar for the machine.
  # It is offered and disabled rather than hidden, so a pane says why, and the
  # write refuses the disabled choice instead of trusting every client to grey
  # it out.
  describe "the on-device transcription option" do
    @backend_rows [
      {"transcription", "transcription_backend"},
      {"meetings", "meetings_transcription_backend"}
    ]

    # The shipped posture: picking on-device downloads a speech model on the
    # spot, a flow that has not been proven, so no pane lists the choice.
    test "is not published at all while this build does not offer it" do
      put_transcription(backend: "openai")

      for {section, key} <- @backend_rows do
        refute local_option(section, key, pinned()),
               "#{section}/#{key} publishes a choice setup does not offer"
      end
    end

    # A configuration that already names it keeps transcribing on-device, so the
    # pane shows what is in force rather than a picker with nothing selected.
    test "is shown, disabled, where a configuration already names it" do
      put_transcription(backend: "local")
      put_meetings(transcription_backend: "local")

      for {section, key} <- @backend_rows do
        option = local_option(section, key, pinned())

        assert option["label"] == "On this device"
        assert option["disabled"] == true
        assert option["hint"] == LocalTranscription.unoffered_message()
        assert Copy.violations(option["hint"], :prose) == []
      end
    end

    test "is offered by name once the build offers it, on a machine with a sidecar" do
      put_transcription(backend: "openai", local_offered: true)

      for {section, key} <- @backend_rows do
        option = local_option(section, key, pinned())

        assert option["label"] == "On this device"
        assert option["disabled"] == false
        assert option["hint"] == nil
      end
    end

    test "is disabled, with the machine's own reason, where it is offered but has no sidecar" do
      put_transcription(backend: "openai", local_offered: true)

      for {section, key} <- @backend_rows do
        option = local_option(section, key, releases: %{})

        assert option["disabled"] == true
        assert option["hint"] == SttInstaller.error_message(:no_release_pinned)
        assert Copy.violations(option["hint"], :prose) == []
      end
    end

    test "the write refuses a disabled option in the reason's own words" do
      put_transcription(backend: "local")
      row = backend_row("transcription", "transcription_backend", pinned())

      assert AnswerMap.answer("transcription", row, "local") ==
               {:error, LocalTranscription.unoffered_message()}

      assert AnswerMap.answer("transcription", row, "deepgram") ==
               {:ok, {:transcription_backend, "deepgram"}}
    end

    # Nothing published, nothing writable: the generic refusal is what a client
    # asking for an unlisted value gets.
    test "the write refuses it outright where it is not published" do
      put_transcription(backend: "openai")
      row = backend_row("transcription", "transcription_backend", pinned())

      assert AnswerMap.answer("transcription", row, "local") ==
               {:error, "This setting takes one of its published values."}
    end
  end

  describe "the voice section under each engine" do
    test "the default engine publishes the effort row and no engine row" do
      Application.put_env(:fermix_core, :realtime, enabled: true)

      keys = Enum.map(rows("realtime"), & &1["key"])

      assert keys == [
               "realtime_enabled",
               "realtime_model",
               "realtime_voice",
               "realtime_reasoning_effort",
               "openai_api_key",
               "realtime_max_session_minutes",
               "realtime_max_cost_cents",
               "realtime_persist_transcripts"
             ]

      assert %{"value" => "gpt-realtime-2"} = row("realtime", "realtime_model")
      assert option_values("realtime", "realtime_voice") == RealtimeConfig.valid_voices()
    end

    # One combined menu, both catalogs, under either engine: the model IS the
    # engine choice, so a client that published only the engine in force would
    # leave an operator with no way to reach the other one.
    test "the model row is one list of both catalogs, each option naming its engine" do
      Application.put_env(:fermix_core, :realtime, enabled: true)

      assert option_values("realtime", "realtime_model") == RealtimeConfig.all_models()

      labels =
        "realtime" |> row("realtime_model") |> Map.fetch!("options") |> Enum.map(& &1["label"])

      assert labels == [
               "gpt-realtime-2.1-mini · Realtime, integrated tools",
               "gpt-realtime-2.1 · Realtime, integrated tools",
               "gpt-realtime-2 · Realtime, integrated tools",
               "gpt-live-1 · Live, with your Fermix agent"
             ]
    end

    test "the Live engine publishes Live's voices and no reasoning effort row" do
      Application.put_env(:fermix_core, :realtime,
        enabled: true,
        engine: "openai_live",
        model: "gpt-live-1"
      )

      keys = Enum.map(rows("realtime"), & &1["key"])

      assert keys == [
               "realtime_enabled",
               "realtime_model",
               "realtime_voice",
               "realtime_backend",
               "openai_api_key",
               "realtime_max_session_minutes",
               "realtime_max_cost_cents",
               "realtime_persist_transcripts"
             ]

      assert option_values("realtime", "realtime_model") == RealtimeConfig.all_models()

      assert option_values("realtime", "realtime_voice") ==
               RealtimeConfig.valid_voices("openai_live")

      assert "beacon" in option_values("realtime", "realtime_voice")
    end

    # Live speaks and the operator's own primary provider answers. The row is
    # read-only because it is a statement about the Providers pane, and
    # `settings.apply` refuses it rather than offering a control that cannot save.
    test "the Live engine names the primary route in a read-only backend row" do
      Application.put_env(:fermix_core, :providers,
        openai: [primary: true, default_model: "gpt-5.4"]
      )

      Application.put_env(:fermix_core, :realtime,
        enabled: true,
        engine: "openai_live",
        model: "gpt-live-1"
      )

      assert %{"kind" => "text", "read_only" => true, "label" => "Backend", "value" => value} =
               row("realtime", "realtime_backend")

      assert value == "OpenAI · gpt-5.4"

      assert {:error, {:invalid_params, "realtime_backend", _sentence}} =
               Settings.apply("realtime", %{"realtime_backend" => "anything"})
    end

    test "a host that has never chosen a primary provider says so rather than guessing" do
      Application.put_env(:fermix_core, :providers, [])
      Application.put_env(:fermix_core, :agent, [])

      Application.put_env(:fermix_core, :realtime,
        enabled: true,
        engine: "openai_live",
        model: "gpt-live-1"
      )

      assert %{"value" => "Not configured"} = row("realtime", "realtime_backend")
    end
  end

  # Choosing a model of the other engine is the one write in this pane that
  # carries other keys with it: Live refuses the Realtime-only settings at the
  # configuration boundary, and a Realtime engine left on a Live model refuses
  # too. Answering the operator's choice with a validation error is the defect
  # these cases exist for.
  describe "switching the voice engine through the model" do
    test "choosing a Live model moves the engine and drops the Realtime-only settings" do
      Application.put_env(:fermix_core, :realtime,
        enabled: true,
        engine: "openai_realtime",
        model: "gpt-realtime-2",
        reasoning_effort: "high",
        voice: "marin"
      )

      assert {:ok, result} =
               Settings.apply("realtime", %{"realtime_model" => "gpt-live-1"})

      realtime = Application.get_env(:fermix_core, :realtime)

      assert Keyword.get(realtime, :engine) == "openai_live"
      assert Keyword.get(realtime, :model) == "gpt-live-1"
      refute Keyword.has_key?(realtime, :reasoning_effort)

      assert Enum.sort(result["applied"]) ==
               ["realtime_engine", "realtime_model", "realtime_reasoning_effort"]

      assert "The engine changed to Live, with your Fermix agent." in result["side_effects"]

      assert "Reasoning effort was removed because this engine does not use it." in result[
               "side_effects"
             ]
    end

    test "choosing a Realtime model moves back and restores a reasoning effort" do
      Application.put_env(:fermix_core, :realtime,
        enabled: true,
        engine: "openai_live",
        model: "gpt-live-1",
        voice: "marin"
      )

      assert {:ok, result} =
               Settings.apply("realtime", %{"realtime_model" => "gpt-realtime-2.1"})

      realtime = Application.get_env(:fermix_core, :realtime)

      assert Keyword.get(realtime, :engine) == "openai_realtime"
      assert Keyword.get(realtime, :model) == "gpt-realtime-2.1"
      assert Keyword.get(realtime, :reasoning_effort) == "low"

      assert "realtime_engine" in result["applied"]
      assert "realtime_reasoning_effort" in result["applied"]
      assert "The engine changed to Realtime, integrated tools." in result["side_effects"]

      assert "Reasoning effort was restored because this engine uses it." in result[
               "side_effects"
             ]
    end

    # The engine stopped being a row when it became a consequence of the model,
    # and a key this section does not publish is refused by its own name rather
    # than written from a vocabulary no pane renders.
    test "an engine sent explicitly is refused by name as a setting this section has not got" do
      Application.put_env(:fermix_core, :realtime, enabled: true, engine: "openai_realtime")

      assert {:error, {:invalid_params, "realtime_engine", sentence}} =
               Settings.apply("realtime", %{"realtime_engine" => "openai_live"})

      assert sentence == "This section has no setting by that name."
      assert Keyword.get(Application.get_env(:fermix_core, :realtime), :engine) != "openai_live"
    end

    # A voice is a voice under both engines, so nothing is derived and the
    # operator is told nothing they did not do.
    test "a change that is not an engine switch derives nothing" do
      Application.put_env(:fermix_core, :realtime,
        enabled: true,
        engine: "openai_realtime",
        model: "gpt-realtime-2",
        reasoning_effort: "low",
        voice: "marin"
      )

      assert {:ok, result} = Settings.apply("realtime", %{"realtime_voice" => "cedar"})

      assert result["applied"] == ["realtime_voice"]
      assert result["side_effects"] == []
    end

    # Live ships every Realtime voice plus twelve of its own, so the return
    # journey is the one that can strand a voice. The snap is a change the
    # operator did not type, so it is named exactly as the model is.
    test "returning to Realtime snaps a Live-only voice and names the row it moved" do
      Application.put_env(:fermix_core, :realtime,
        enabled: true,
        engine: "openai_live",
        model: "gpt-live-1",
        voice: "beacon"
      )

      assert {:ok, result} =
               Settings.apply("realtime", %{"realtime_model" => "gpt-realtime-2"})

      realtime = Application.get_env(:fermix_core, :realtime)

      assert Keyword.get(realtime, :voice) == "marin"
      assert "realtime_voice" in result["applied"]
      assert "The voice changed to marin." in result["side_effects"]
      assert %{"value" => "marin"} = row("realtime", "realtime_voice")
    end

    test "a voice both engines ship survives the switch and is never named" do
      Application.put_env(:fermix_core, :realtime,
        enabled: true,
        engine: "openai_realtime",
        model: "gpt-realtime-2",
        reasoning_effort: "low",
        voice: "cedar"
      )

      assert {:ok, result} = Settings.apply("realtime", %{"realtime_model" => "gpt-live-1"})

      assert Keyword.get(Application.get_env(:fermix_core, :realtime), :voice) == "cedar"
      refute "realtime_voice" in result["applied"]
      refute Enum.any?(result["side_effects"], &(&1 =~ "The voice changed"))
    end

    # The combined menu is the whole value space, so a slug no engine ships is
    # still refused against the published options rather than reaching the
    # configuration boundary.
    test "a model no engine ships is refused against the published options" do
      Application.put_env(:fermix_core, :realtime, enabled: true, engine: "openai_realtime")

      assert {:error, {:invalid_params, "realtime_model", sentence}} =
               Settings.apply("realtime", %{"realtime_model" => "gpt-realtime-9"})

      assert sentence =~ "published values"
    end
  end

  describe "applying a change" do
    test "writes the value and answers with the restart and readiness state" do
      assert {:ok, result} = Settings.apply("memory", %{"review_interval_hours" => 6})

      assert result["applied"] == ["review_interval_hours"]
      assert %{"required" => _required, "reasons" => _reasons} = result["restart"]
      assert %{"status" => _status, "failure_count" => _count} = result["readiness"]
      assert result["side_effects"] == []

      assert Application.get_env(:fermix_core, :memory)[:review_interval_hours] == 6
    end

    test "a boot-bound change is reported with the daemon's own reason sentence" do
      assert {:ok, result} = Settings.apply("realtime", %{"realtime_enabled" => true})

      assert result["restart"]["required"]
      assert Enum.any?(result["restart"]["reasons"], &(&1["section"] == "realtime"))
      assert Enum.all?(result["restart"]["reasons"], &String.ends_with?(&1["sentence"], "."))
    end

    test "a channel enable answer is the last word, so pausing is not deleting" do
      assert {:ok, _result} = Settings.apply("channels.telegram", %{"telegram_enabled" => false})

      refute Readiness.channel_enabled?(:telegram)
      assert %{"value" => false} = row("channels.telegram", "telegram_enabled")
    end

    test "a provider model persists and reads back without changing the primary's model" do
      Application.put_env(:fermix_core, :providers,
        openai: [primary: true, default_model: "gpt-5.4"],
        anthropic: []
      )

      assert {:ok, _result} =
               Settings.apply("providers.anthropic", %{"default_model" => "claude-sonnet-5"})

      providers = Application.get_env(:fermix_core, :providers)
      assert providers[:anthropic][:default_model] == "claude-sonnet-5"
      assert providers[:openai][:default_model] == "gpt-5.4"
      assert %{"value" => "claude-sonnet-5"} = row("providers.anthropic", "default_model")

      assert {:ok, persisted} = ConfigStore.load_runtime_config()
      assert persisted[:fermix_core][:providers][:anthropic][:default_model] == "claude-sonnet-5"
      assert persisted[:fermix_core][:providers][:openai][:default_model] == "gpt-5.4"

      assert {:ok, _result} = Settings.reload()
      assert %{"value" => "claude-sonnet-5"} = row("providers.anthropic", "default_model")
    end

    test "auth-mode changes persist and read back while preserving an existing API key" do
      Application.put_env(:fermix_core, :providers, anthropic: [auth_mode: :api_key])
      Application.put_env(:fermix_core, :personalization, [])
      assert {:ok, _result} = Secrets.set("anthropic_api_key", "kept-test-key")

      assert {:ok, _result} = Settings.apply("providers.anthropic", %{"auth_mode" => "oauth"})
      assert %{"value" => "oauth"} = row("providers.anthropic", "auth_mode")
      assert {:ok, persisted} = ConfigStore.load_runtime_config()
      assert persisted[:fermix_core][:providers][:anthropic][:auth_mode] == :oauth
      assert {:ok, "kept-test-key"} = SecretWriter.get(:anthropic_api_key)

      assert {:ok, _result} = Settings.reload()
      assert %{"value" => "oauth"} = row("providers.anthropic", "auth_mode")
      assert {:ok, _result} = Settings.apply("providers.anthropic", %{"auth_mode" => "api_key"})
      assert %{"value" => "api_key"} = row("providers.anthropic", "auth_mode")
      assert %{"present" => true} = row("providers.anthropic", "anthropic_api_key")
      assert {:ok, "kept-test-key"} = SecretWriter.get(:anthropic_api_key)
    end

    test "the sandbox section writes through the sandbox override entry" do
      assert {:ok, _result} =
               Settings.apply("sandbox", %{
                 "sandbox_mode" => "strict",
                 "sandbox_profile" => "bare"
               })

      sandbox = Application.get_env(:fermix_core, :sandbox)
      assert sandbox.mode == :strict
      assert sandbox.commands.profile == :bare
    end

    test "the meetings section writes through the meetings writer" do
      assert {:ok, _result} =
               Settings.apply("meetings", %{"meetings_bot_name" => "Scribe"})

      assert Application.get_env(:fermix_core, :meetings)[:bot_name] == "Scribe"
    end

    # A backend switch snaps the shared model key, and the operator did not type
    # that, so the daemon says it happened in its own words.
    test "a change the operator did not type is named as a side effect" do
      Application.put_env(:fermix_core, :transcription, backend: "openai", model: "whisper-1")

      assert {:ok, result} =
               Settings.apply("transcription", %{"transcription_backend" => "deepgram"})

      assert result["side_effects"] == ["The voice notes model changed to nova-3."]
    end

    test "an unknown key is refused by name rather than ignored" do
      assert {:error, {:invalid_params, "wake_word", sentence}} =
               Settings.apply("realtime", %{"wake_word" => "hey"})

      assert sentence =~ "no setting by that name"
    end

    # Secrets cross the socket in exactly one method. A pane that could write one
    # through a typed value would put it in every params log.
    test "a secret row is refused, and named as a secret" do
      assert {:error, {:invalid_params, "telegram_bot_token", sentence}} =
               Settings.apply("channels.telegram", %{"telegram_bot_token" => "1:abc"})

      assert sentence =~ "secret.set"
    end

    test "a read-only row is refused rather than silently dropped" do
      assert {:error, {:invalid_params, "computer_history_summarizer", _sentence}} =
               Settings.apply("computer_history", %{"computer_history_summarizer" => "local"})
    end

    test "a value of the wrong shape is refused with what the row takes" do
      assert {:error, {:invalid_params, "realtime_enabled", sentence}} =
               Settings.apply("realtime", %{"realtime_enabled" => "yes"})

      assert sentence =~ "true or false"
    end

    # Refused above the bound rather than truncated: a wide selection on a large
    # Applications folder would otherwise approach the parameter ceiling and land
    # as a bare "parameters are invalid" with nothing naming the field.
    test "a list above the published bound is refused by name" do
      apps = Enum.map(1..201, &"com.example.app#{&1}")

      assert {:error, {:invalid_params, "computer_history_apps", sentence}} =
               Settings.apply("computer_history", %{"computer_history_apps" => apps})

      assert sentence =~ "200"
    end

    test "null is refused, because no row this daemon publishes can be cleared" do
      assert {:error, {:invalid_params, "user_name", sentence}} =
               Settings.apply("personalization", %{"user_name" => nil})

      assert sentence =~ "cannot be cleared"
    end

    # The exact sentence, not "non-empty": an off-list word used to reach
    # `String.to_existing_atom/1` in the sandbox writer and come back to the
    # operator as "errors were found at the given arguments: * 1st argument: not
    # an already existing atom", which this assertion passed on happily.
    test "an off-list choice value is refused in the daemon's own words" do
      assert {:error, {:invalid_params, "sandbox_mode", sentence}} =
               Settings.apply("sandbox", %{"sandbox_mode" => "paranoid"})

      assert sentence == "This setting takes one of its published values."
    end

    # `"ok"` is an already-existing atom, so it got past
    # `String.to_existing_atom/1` and reached a function-clause guard instead,
    # which is not rescued and surfaced as `internal_error` — a different
    # failure mode for the same mistake.
    test "an off-list value that happens to be an existing atom is refused the same way" do
      assert {:error, {:invalid_params, "sandbox_mode", sentence}} =
               Settings.apply("sandbox", %{"sandbox_mode" => "ok"})

      assert sentence == "This setting takes one of its published values."
    end

    # No published refusal may carry an Elixir error message, a term or a path.
    test "no choice refusal carries Elixir error text" do
      for value <- ["paranoid", "ok", "Strict", ""] do
        assert {:error, {:invalid_params, "sandbox_mode", sentence}} =
                 Settings.apply("sandbox", %{"sandbox_mode" => value})

        refute sentence =~ "argument"
        refute sentence =~ "{:"
        refute sentence =~ "%{"
      end
    end

    # The two rows whose options are suggestions still take any value, or a
    # native time zone picker could offer only the twenty-one zones the daemon
    # lists inline.
    test "a suggestion row still takes a value that is not among its options" do
      assert {:ok, _result} =
               Settings.apply("personalization", %{"timezone" => "Antarctica/Troll"})

      assert {:ok, _style} =
               Settings.apply("personalization", %{"communication_style" => "Terse, no preamble."})
    end

    test "an unknown section is refused" do
      assert Settings.apply("nonesuch", %{}) == {:error, {:unknown_section, "nonesuch"}}
    end
  end

  describe "the external-change refusal" do
    # The outside write lands before the first read of this case on purpose: the
    # state is cached for a second by design, so a case that read it, wrote the
    # file and read again would be asserting on the cache window rather than on
    # the refusal.
    test "a write refuses while an outside edit stands, and lands after a reload", %{home: home} do
      File.write!(Path.join(home, "config.toml"), """
      [fermix_core.memory]
      review_interval_hours = 12
      """)

      assert {:error, {:external_change, ["memory"]}} =
               Settings.apply("memory", %{"review_interval_hours" => 8})

      assert {:ok, reload} = Settings.reload()
      assert reload["reloaded"]
      assert reload["config_state"] == "clear"
      assert Application.get_env(:fermix_core, :memory)[:review_interval_hours] == 12

      assert {:ok, _applied} = Settings.apply("memory", %{"review_interval_hours" => 8})
      assert Application.get_env(:fermix_core, :memory)[:review_interval_hours] == 8
    end

    # A fresh install and a home this daemon wrote are both clear, so the very
    # first write of a new install is never refused.
    test "a home with no settings file lets the first write through" do
      assert {:ok, _applied} = Settings.apply("memory", %{"review_interval_hours" => 6})
      assert Application.get_env(:fermix_core, :memory)[:review_interval_hours] == 6
    end

    test "a file that cannot be read refuses with the parser's own sentence", %{home: home} do
      File.write!(Path.join(home, "config.toml"), "[fermix_core.providers]\nopenai = 5\n")

      assert {:error, {:config_unreadable, sentence}} =
               Settings.apply("memory", %{"review_interval_hours" => 8})

      assert is_binary(sentence) and sentence != ""
      assert {:error, {:config_unreadable, _same}} = Settings.reload()
    end
  end

  # The pitfall this exists for: a section that normalizes strings into atoms
  # must render them back in the spelling the parser accepts, or the very next
  # load raises and the daemon cannot boot on the file it just wrote. Seeded
  # with the NORMALIZED application-env shapes, because the live snapshot is
  # what a save actually persists.
  describe "the save then load round trip" do
    test "every section a write touches survives being written and read back", %{home: home} do
      seed_normalized_app_env()

      assert {:ok, _result} = Settings.apply("memory", %{"review_interval_hours" => 6})
      assert File.exists?(Path.join(home, "config.toml"))

      assert {:ok, reloaded} = ConfigStore.load_runtime_config()
      core = Map.get(reloaded, :fermix_core, [])

      assert core[:computer_history][:summarizer] == :default_provider
      assert core[:providers][:anthropic][:auth_mode] == :oauth
      assert core[:providers][:anthropic][:reasoning_effort] == :high
      assert core[:transcription][:backend] == "deepgram"
      assert Map.get(reloaded, :sandbox).mode == :strict
      assert core[:realtime][:voice] == "cedar"
    end

    test "a second save on top of a loaded file is stable" do
      seed_normalized_app_env()
      assert {:ok, _first} = Settings.apply("memory", %{"review_interval_hours" => 6})
      assert {:ok, loaded} = ConfigStore.load_runtime_config()
      :ok = ConfigStore.apply_snapshot(loaded)
      :ok = RestartState.record_persisted_baseline()

      assert {:ok, _second} = Settings.apply("memory", %{"review_interval_hours" => 7})
      assert {:ok, again} = ConfigStore.load_runtime_config()

      assert Map.get(again, :fermix_core)[:memory][:review_interval_hours] == 7
      assert Map.get(again, :fermix_core)[:computer_history][:summarizer] == :default_provider
    end
  end

  # Live application environment in the shape the normalizers leave it: atoms
  # where a section normalizes to atoms, which is exactly the shape a save reads
  # and the shape a TOML-string fixture would never exercise.
  defp seed_normalized_app_env do
    Application.put_env(:fermix_core, :computer_history,
      enabled: true,
      apps: ["com.apple.Safari"],
      summarizer: :default_provider
    )

    Application.put_env(:fermix_core, :providers,
      anthropic: [auth_mode: :oauth, reasoning_effort: :high, default_model: "claude-opus-5"]
    )

    Application.put_env(:fermix_core, :transcription, backend: "deepgram", model: "nova-3")
    Application.put_env(:fermix_core, :realtime, enabled: true, voice: "cedar")

    Application.put_env(:fermix_core, :sandbox, SandboxConfig.normalize(%{mode: :strict}))
  end

  # M45 §4.4: one row per allowed or stored name, after the allow list. The
  # snapshot is passed in, so each shape is seeded rather than inherited.
  describe "the sandbox environment rows" do
    setup do
      profile = Application.get_env(:fermix_core, :profile)
      Application.delete_env(:fermix_core, :profile)
      on_exit(fn -> restore(:fermix_core, :profile, profile) end)
      :ok
    end

    test "every name state has its own row, in allow-list order then stored names" do
      rows = env_rows(sandbox_with_every_shape())

      assert Enum.map(rows, & &1["key"]) ==
               ~w(env:STORED_KEY env:UNSTORED_KEY env:HELPER_KEY env:ALIAS_KEY env:A_PARKED env:Z_PARKED)

      assert Enum.map(rows, & &1["label"]) ==
               ~w(STORED_KEY UNSTORED_KEY HELPER_KEY ALIAS_KEY A_PARKED Z_PARKED)
    end

    test "a stored and allowed name is a present secret row" do
      row = env_row(sandbox_with_every_shape(), "STORED_KEY")

      assert %{"kind" => "secret", "present" => true, "value" => nil, "footer" => nil} = row
      assert row["read_only"] == false
    end

    test "a stored name that is no longer allowed says it is parked" do
      row = env_row(sandbox_with_every_shape(), "A_PARKED")

      assert %{"kind" => "secret", "present" => true, "value" => nil} = row

      assert row["footer"] ==
               "Stored, but commands do not get it until the name is allowed again."
    end

    test "an allowed name with no source is a secret row that is not stored" do
      row = env_row(sandbox_with_every_shape(), "UNSTORED_KEY")

      assert %{"kind" => "secret", "present" => false, "value" => nil} = row
      assert row["footer"] == "Not stored. Commands get it only if Fermix was started with it."
    end

    test "a helper or an alias is a read-only text row saying where the value comes from" do
      helper = env_row(sandbox_with_every_shape(), "HELPER_KEY")
      alias_row = env_row(sandbox_with_every_shape(), "ALIAS_KEY")

      assert %{"kind" => "text", "read_only" => true, "present" => nil, "value" => nil} = helper
      assert helper["footer"] == "Read by a command set in the settings file."

      assert %{"kind" => "text", "read_only" => true, "value" => "ALPACA_OLD_NAME"} = alias_row

      assert alias_row["footer"] ==
               "Read from another variable in the environment Fermix was started with."
    end

    # Offering Add on a name every store refuses is a control whose save always
    # fails; the row says what is in force instead.
    test "an allowed name Fermix cannot store is read-only" do
      rows = env_rows(sandbox_from(env: [allow: ["HOME", "MY-VAR"]]))

      assert Enum.map(rows, & &1["key"]) == ["env:HOME", "env:MY-VAR"]

      for row <- rows do
        assert %{"kind" => "text", "read_only" => true, "value" => nil} = row

        assert row["footer"] ==
                 "Fermix cannot store a value under this name. " <>
                   "Commands get it from the environment Fermix was started with."
      end
    end

    test "presence comes from the settings file alone, never a keychain read" do
      Application.put_env(:fermix_core, :secret_writer, FermixTestSupport.CountingSecretWriter)
      :ok = FermixTestSupport.CountingSecretWriter.watch()
      on_exit(fn -> FermixTestSupport.CountingSecretWriter.unwatch() end)

      rows = env_rows(sandbox_with_every_shape())

      assert Enum.any?(rows, &(&1["present"] == true))
      refute_received {:secret_writer_get, _key}
    end

    test "the allow-list and name rows derive their restart flag from the env rule" do
      {:ok, %{"rows" => rows}} =
        Settings.get("sandbox", snapshot: snapshot_with(sandbox_with_every_shape()))

      live = Row.restart?([:sandbox, :env])

      refute live
      assert live == RestartState.boot_bound?([:sandbox, :env])

      for row <- rows, row["key"] == "sandbox_env_allow" or env_key?(row) do
        assert row["restart"] == live, row["key"]
      end

      for row <- rows, row["key"] in ["sandbox_mode", "sandbox_profile"] do
        assert row["restart"] == Row.restart?(:sandbox)
      end
    end

    test "settings.apply refuses every name row: values cross in secret.set alone" do
      Application.put_env(:fermix_core, :sandbox, sandbox_with_every_shape())

      assert {:error, {:invalid_params, "env:UNSTORED_KEY", sentence}} =
               Settings.apply("sandbox", %{"env:UNSTORED_KEY" => "a-value"})

      assert sentence == "This is a secret. Store it with secret.set instead."

      assert {:error, {:invalid_params, "env:HELPER_KEY", _read_only}} =
               Settings.apply("sandbox", %{"env:HELPER_KEY" => "a-value"})
    end
  end

  # The golden envelopes are hand-written, and a responder round trip proves only
  # that a map survives being encoded. These drive the real writers and compare
  # key shapes, so renaming a field here fails the export rather than shipping a
  # client that validates against a shape the daemon no longer produces.
  describe "the published contract" do
    # A boot-bound change first, so the restart reason list is populated by this
    # case rather than by whichever case ran before it: an empty list is its own
    # shape, so a fixture illustrating a reason would pass or fail on order.
    test "the apply fixture carries the shape the writer returns" do
      assert {:ok, result} = Settings.apply("realtime", %{"realtime_enabled" => true})

      assert result["restart"]["reasons"] != []
      assert shape(result) == shape(fixture_result("settings.apply"))
    end

    test "the reload fixture carries the shape the reloader returns" do
      assert {:ok, _applied} = Settings.apply("realtime", %{"realtime_enabled" => true})

      assert {:ok, result} = Settings.reload()

      assert result["restart"]["reasons"] != []
      assert shape(result) == shape(fixture_result("settings.reload"))
    end
  end

  defp fixture_result(method) do
    :fermix_core
    |> Application.app_dir("priv/management/fixtures/success.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.find(&(&1["method"] == method))
    |> get_in(["response", "result"])
  end

  # Keys and container kinds only: values differ between a fixture and a live
  # run by construction, and an empty list is its own shape so a fixture
  # illustrating an element the daemon never returns still fails.
  defp shape(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, shape(v)} end)
  defp shape([]), do: []
  defp shape([head | _rest]), do: [shape(head)]
  defp shape(_value), do: :scalar

  defp rows(id) do
    {:ok, %{"rows" => rows}} = Settings.get(id)
    rows
  end

  defp backend_row(section, key, opts) do
    section
    |> Voice.rows(ConfigStore.current_snapshot(), opts)
    |> Enum.find(&(&1["key"] == key))
  end

  defp local_option(section, key, opts) do
    section
    |> backend_row(key, opts)
    |> Map.fetch!("options")
    |> Enum.find(&(&1["value"] == "local"))
  end

  # A machine this build pins a sidecar for, whichever one the suite runs on.
  defp pinned, do: [releases: FermixTestSupport.SttPins.for_this_host()]

  defp put_transcription(config), do: Application.put_env(:fermix_core, :transcription, config)

  defp put_meetings(config), do: Application.put_env(:fermix_core, :meetings, config)

  # Every §4.4 name state at once: stored and allowed, allowed with no source,
  # allowed through a helper, allowed through an alias, and two stored names no
  # longer allowed (published sorted, after the allow list).
  defp sandbox_with_every_shape do
    sandbox_from(
      env: [
        allow: ~w(STORED_KEY UNSTORED_KEY HELPER_KEY ALIAS_KEY),
        sources: %{
          "STORED_KEY" => managed("STORED_KEY"),
          "HELPER_KEY" => %{source: :command, command: "/usr/local/bin/op", args: ["read"]},
          "ALIAS_KEY" => %{source: :env, name: "ALPACA_OLD_NAME"},
          "Z_PARKED" => managed("Z_PARKED"),
          "A_PARKED" => managed("A_PARKED")
        }
      ]
    )
  end

  defp managed(name), do: SecretWriter.command_source({:external_env, name})

  defp sandbox_from(config), do: SandboxConfig.normalize(config)

  defp snapshot_with(sandbox), do: Map.put(ConfigStore.current_snapshot(), :sandbox, sandbox)

  defp env_rows(sandbox) do
    {:ok, %{"rows" => rows}} = Settings.get("sandbox", snapshot: snapshot_with(sandbox))
    Enum.filter(rows, &env_key?/1)
  end

  defp env_row(sandbox, name),
    do: Enum.find(env_rows(sandbox), &(&1["label"] == name)) || flunk("no env row for #{name}")

  defp env_key?(row), do: String.starts_with?(row["key"], "env:")

  defp row(id, key), do: Enum.find(rows(id), &(&1["key"] == key)) || flunk("no #{id}/#{key} row")

  defp option_values(id, key),
    do: id |> row(key) |> Map.fetch!("options") |> Enum.map(& &1["value"])

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
