defmodule FermixCore.Management.SettingsTest do
  @moduledoc """
  The settings descriptor and its writes (M34 native setup §7.3, §7.7).

  Every case establishes its own home and its own application environment in
  `setup` and restores both in `on_exit`: rows are a projection of global
  configuration, so a case reading what an earlier module left behind would pass
  or fail on test order.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Management.Secrets
  alias FermixCore.Management.Settings
  alias FermixCore.Management.Settings.Row
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Readiness
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState
  alias FermixCore.Setup.SecretWriter
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
    key kind label footer value present options min max step restart read_only suggestions
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
      assert Enum.all?(rows("sandbox"), & &1["restart"])

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

  defp row(id, key), do: Enum.find(rows(id), &(&1["key"] == key)) || flunk("no #{id}/#{key} row")

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
