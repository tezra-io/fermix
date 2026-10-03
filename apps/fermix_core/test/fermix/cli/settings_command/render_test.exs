defmodule Fermix.CLI.SettingsCommand.RenderTest do
  use ExUnit.Case, async: true

  alias Fermix.CLI.SettingsCommand.Render

  @read %{subject: :read, timeout_ms: 10_000, section: nil, check: nil}

  defp text({:ok, iodata}), do: IO.iodata_to_binary(iodata)

  defp row(fields) do
    Map.merge(
      %{
        "footer" => nil,
        "info" => nil,
        "format" => nil,
        "kind" => "text",
        "label" => "Label",
        "max" => nil,
        "min" => nil,
        "options" => [],
        "present" => nil,
        "read_only" => false,
        "suggestions" => false,
        "restart" => false,
        "step" => nil,
        "unit" => nil,
        "value" => ""
      },
      fields
    )
  end

  defp option(value, label, fields \\ %{}) do
    Map.merge(%{"value" => value, "label" => label, "hint" => nil, "disabled" => false}, fields)
  end

  defp view(rows), do: %{"id" => "demo", "title" => "Demo", "rows" => rows}

  defp mgmt(code, details), do: {:management_error, code, "message for #{code}", details}

  describe "sections/1" do
    test "prints a tab-separated table under a header" do
      result = %{
        "sections" => [
          %{"id" => "providers.openai", "pane" => "providers", "title" => "OpenAI"},
          %{"id" => "memory", "pane" => "memory", "title" => "Memory"}
        ]
      }

      assert text(Render.sections(result)) ==
               "PANE\tSECTION\tTITLE\n" <>
                 "providers\tproviders.openai\tOpenAI\n" <>
                 "memory\tmemory\tMemory\n"
    end

    test "a section missing its pane is an invalid reply" do
      result = %{"sections" => [%{"id" => "memory", "title" => "Memory"}]}

      assert Render.sections(result) == {:error, :invalid_reply}
      assert Render.sections(%{"sections" => "nope"}) == {:error, :invalid_reply}
      assert Render.sections(%{}) == {:error, :invalid_reply}
    end
  end

  describe "section/2" do
    test "a number row shows its value, range, footer and percent format" do
      memory = %{
        "id" => "memory",
        "title" => "Memory",
        "rows" => [
          row(%{
            "key" => "compaction_threshold",
            "kind" => "number",
            "label" => "Compact a conversation at",
            "format" => "percent",
            "min" => 0.1,
            "max" => 1.0,
            "value" => 0.85,
            "footer" => "How full the context window gets."
          }),
          row(%{
            "key" => "review_interval_hours",
            "kind" => "number",
            "label" => "Review memory every",
            "format" => "hours",
            "unit" => "hours",
            "min" => 0,
            "value" => 24
          })
        ]
      }

      assert text(Render.section(memory, false)) ==
               "Memory  (memory)\n" <>
                 "\n" <>
                 "  compaction_threshold   Compact a conversation at: 0.85 (85%)  [number 0.1 to 1.0]\n" <>
                 "                         How full the context window gets.\n" <>
                 "  review_interval_hours  Review memory every: 24 hours  [number >= 0]\n"
    end

    test "a number row in cents says so" do
      realtime = %{
        "id" => "realtime",
        "title" => "Voice",
        "rows" => [
          row(%{
            "key" => "realtime_max_cost_cents",
            "kind" => "number",
            "label" => "Stop a conversation at",
            "format" => "currency_cents",
            "min" => 1,
            "value" => 50
          })
        ]
      }

      assert text(Render.section(realtime, false)) =~
               "realtime_max_cost_cents  Stop a conversation at: 50 cents  [number >= 1]\n"
    end

    test "a secret row shows only its presence and the command that changes it" do
      rows = [
        row(%{
          "key" => "openai_api_key",
          "kind" => "secret",
          "label" => "OpenAI key",
          "present" => true,
          "restart" => true,
          "value" => "sk-leaked-by-a-bad-daemon"
        }),
        row(%{"key" => "tavily_api_key", "kind" => "secret", "label" => "Tavily key"})
      ]

      output = text(Render.section(view(rows), false))

      assert output =~
               "  openai_api_key  OpenAI key: stored  [secret, needs restart]\n" <>
                 "                  change: fermix settings secret set openai_api_key\n"

      assert output =~
               "  tavily_api_key  Tavily key: not set  [secret]\n" <>
                 "                  change: fermix settings secret set tavily_api_key\n"

      refute output =~ "sk-leaked"
    end

    test "a read-only row says it is changed elsewhere" do
      rows = [
        row(%{
          "key" => "browser_executable",
          "label" => "Browser",
          "read_only" => true,
          "value" => "/usr/bin/chromium"
        })
      ]

      assert text(Render.section(view(rows), false)) =~
               "  browser_executable  Browser: /usr/bin/chromium  [text, shown here, changed elsewhere]\n"
    end

    test "a closed choice lists its values with labels and a disabled option with its hint" do
      rows = [
        row(%{
          "key" => "transcription_backend",
          "kind" => "choice",
          "label" => "Backend",
          "value" => "openai",
          "options" => [
            option("openai", "OpenAI"),
            option("local", "On this machine", %{
              "disabled" => true,
              "hint" => "No on-device speech engine here."
            })
          ]
        })
      ]

      assert text(Render.section(view(rows), false)) ==
               "Demo  (demo)\n\n" <>
                 "  transcription_backend  Backend: openai  [choice]\n" <>
                 "                         one of:\n" <>
                 "                           - openai (OpenAI)\n" <>
                 "                           - local (On this machine; unavailable: No on-device speech engine here.)\n"
    end

    test "a choice with suggestions says any value is accepted" do
      rows = [
        row(%{
          "key" => "default_model",
          "kind" => "choice",
          "label" => "Model",
          "value" => "gpt-6-astra",
          "suggestions" => true,
          "restart" => true,
          "options" => [option("gpt-6-astra", "GPT-6 Astra"), option("gpt-6-luna", "gpt-6-luna")]
        })
      ]

      assert text(Render.section(view(rows), false)) ==
               "Demo  (demo)\n\n" <>
                 "  default_model  Model: gpt-6-astra  [choice (any value), needs restart]\n" <>
                 "                 suggested:\n" <>
                 "                   - gpt-6-astra (GPT-6 Astra)\n" <>
                 "                   - gpt-6-luna\n"
    end

    test "toggles, lists and empty values render as typed" do
      rows = [
        row(%{"key" => "a", "kind" => "toggle", "label" => "On", "value" => true}),
        row(%{"key" => "b", "kind" => "list", "label" => "Hosts", "value" => ["x.lan", "y.lan"]}),
        row(%{"key" => "c", "kind" => "list", "label" => "None", "value" => []}),
        row(%{"key" => "d", "label" => "Name", "value" => ""}),
        row(%{"key" => "e", "label" => "Null", "value" => nil})
      ]

      assert text(Render.section(view(rows), false)) ==
               "Demo  (demo)\n\n" <>
                 "  a  On: true  [toggle]\n" <>
                 "  b  Hosts: x.lan, y.lan  [list]\n" <>
                 "  c  None: (none)  [list]\n" <>
                 "  d  Name: (not set)  [text]\n" <>
                 "  e  Null: (not set)  [text]\n"
    end

    test "info is hidden without --info and shown with it" do
      rows = [row(%{"key" => "secret_store", "label" => "Keep secrets in", "info" => "Longer."})]

      refute text(Render.section(view(rows), false)) =~ "Longer."
      assert text(Render.section(view(rows), true)) =~ "               Longer.\n"
    end

    test "control characters are scrubbed from every daemon string" do
      rows = [
        row(%{
          "key" => "communication_style",
          "label" => "St\e[2Jyle",
          "value" => "line one\nline\u009Btwo\u007F",
          "footer" => "foot\rer",
          "kind" => "choice",
          "options" => [option("a\u0007", "b\u0085")]
        })
      ]

      output = text(Render.section(%{"id" => "x\e", "title" => "T\u009B", "rows" => rows}, false))

      for bad <- ["\e", "\u009B", "\u007F", "\u0007", "\u0085", "\r"] do
        refute output =~ bad
      end

      assert output =~ ": line one line two "
      # A newline survives only as the renderer's own line breaks.
      refute output =~ "line one\n"
    end

    test "a daemon string longer than 200 graphemes is truncated with an ellipsis" do
      rows = [row(%{"key" => "k", "label" => "L", "value" => String.duplicate("v", 300)})]

      output = text(Render.section(view(rows), false))

      assert output =~ String.duplicate("v", 200) <> "…"
      refute output =~ String.duplicate("v", 201)
    end

    test "a row missing its key, kind or label is an invalid reply" do
      for missing <- ["key", "kind", "label"] do
        bad = Map.delete(row(%{"key" => "k"}), missing)
        assert Render.section(view([bad]), false) == {:error, :invalid_reply}
      end

      assert Render.section(%{"id" => "x", "rows" => []}, false) == {:error, :invalid_reply}
    end
  end

  # The validators are pinned to the published wire: every golden reply this
  # verb reads must render, or a real daemon's answer would read as invalid.
  describe "the published success goldens" do
    test "every settings, secret and provider reply this verb reads renders" do
      goldens =
        :fermix_core
        |> Application.app_dir("priv/management/fixtures/success.jsonl")
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Map.new(&{&1["name"], &1["response"]["result"]})

      section_views = for {"settings_get" <> _rest, view} <- goldens, do: view

      assert length(section_views) >= 29
      for view <- section_views, do: assert({:ok, _text} = Render.section(view, true))

      assert {:ok, _text} = Render.sections(goldens["settings_sections"])
      assert {:ok, _text} = Render.providers(goldens["setup_state_get"])
      assert {:ok, _text} = Render.applied(goldens["settings_apply"], "realtime", [])
      assert {:ok, _text} = Render.applied(goldens["settings_apply_browser"], "browser", [])
      assert {:ok, _text} = Render.reload(goldens["settings_reload"])
      assert {:ok, _text} = Render.primary(goldens["providers_set_primary"], "openai")

      for name <- ~w(secret_set secret_set_anthropic_setup_token secret_set_external_env) do
        assert {:ok, _text} = Render.secret(goldens[name], :set)
      end

      for name <- ~w(secret_clear secret_clear_external_env) do
        assert {:ok, _text} = Render.secret(goldens[name], :clear)
      end
    end
  end

  describe "applied/3" do
    test "prints the saved keys, the side effects, the restart reasons and the derived-key hint" do
      result = %{
        "applied" => ["realtime_model", "realtime_engine"],
        "restart" => %{
          "required" => true,
          "reasons" => [
            %{
              "section" => "realtime",
              "sentence" => "Voice settings changed since Fermix started."
            }
          ]
        },
        "readiness" => %{"status" => "ready", "failure_count" => 0},
        "side_effects" => ["The engine changed to GPT-Live."]
      }

      assert text(Render.applied(result, "realtime", ["realtime_model"])) ==
               "Saved realtime: realtime_model, realtime_engine\n" <>
                 "The engine changed to GPT-Live.\n" <>
                 "Restart to apply (fermix restart):\n" <>
                 "  - Voice settings changed since Fermix started.\n" <>
                 "(rows in this section changed; run `fermix settings show realtime` to see them)\n"
    end

    test "says nothing about restart or readiness when neither applies" do
      result = %{
        "applied" => ["browser_allowed_hosts"],
        "restart" => %{"required" => false, "reasons" => []},
        "readiness" => %{"status" => "ready", "failure_count" => 0},
        "side_effects" => []
      }

      assert text(Render.applied(result, "browser", ["browser_allowed_hosts"])) ==
               "Saved browser: browser_allowed_hosts\n"
    end

    test "names readiness only when it is not ready" do
      result = %{
        "applied" => ["bot_name"],
        "restart" => %{"required" => false, "reasons" => []},
        "readiness" => %{"status" => "setup_required", "failure_count" => 2},
        "side_effects" => []
      }

      assert text(Render.applied(result, "personalization", ["bot_name"])) =~
               "Readiness is setup_required (2 failing); `fermix doctor` says why.\n"
    end

    test "a reply missing a key the renderer reads is invalid" do
      assert Render.applied(%{"applied" => []}, "memory", []) == {:error, :invalid_reply}
    end
  end

  describe "secret, primary, providers and reload" do
    @restart %{
      "required" => true,
      "reasons" => [
        %{
          "section" => "providers",
          "sentence" => "Provider settings changed since Fermix started."
        }
      ]
    }

    test "secret set and clear name the id and the restart reasons" do
      result = %{"id" => "openai_api_key", "present" => true, "restart" => @restart}

      assert text(Render.secret(result, :set)) ==
               "Stored openai_api_key.\n" <>
                 "Restart to apply (fermix restart):\n" <>
                 "  - Provider settings changed since Fermix started.\n"

      cleared = %{
        "id" => "brave_api_key",
        "present" => false,
        "restart" => %{"required" => false, "reasons" => []}
      }

      assert text(Render.secret(cleared, :clear)) == "Cleared brave_api_key.\n"
      assert Render.secret(%{"id" => "x"}, :set) == {:error, :invalid_reply}
    end

    test "providers prints the configured and primary columns" do
      result = %{
        "providers" => [
          %{
            "id" => "openai_codex",
            "label" => "OpenAI Codex",
            "configured" => true,
            "primary" => true
          },
          %{
            "id" => "anthropic",
            "label" => "Anthropic",
            "configured" => false,
            "primary" => false
          }
        ]
      }

      assert text(Render.providers(result)) ==
               "PROVIDER\tNAME\tCONFIGURED\tPRIMARY\n" <>
                 "openai_codex\tOpenAI Codex\tyes\tyes\n" <>
                 "anthropic\tAnthropic\tno\tno\n"

      assert Render.providers(%{"providers" => [%{"id" => "x"}]}) == {:error, :invalid_reply}
    end

    test "primary names the new primary and the restart reasons" do
      result = %{"restart" => @restart, "side_effects" => []}

      assert text(Render.primary(result, "openai")) ==
               "Primary provider is now openai.\n" <>
                 "Restart to apply (fermix restart):\n" <>
                 "  - Provider settings changed since Fermix started.\n"
    end

    test "reload says so and names a config state that is not clear" do
      result = %{
        "reloaded" => true,
        "restart" => @restart,
        "readiness" => %{"status" => "ready", "failure_count" => 0},
        "config_state" => "clear"
      }

      assert text(Render.reload(result)) ==
               "Reloaded settings from disk.\n" <>
                 "Restart to apply (fermix restart):\n" <>
                 "  - Provider settings changed since Fermix started.\n"

      assert text(Render.reload(%{result | "config_state" => "external_change"})) =~
               "config.toml state: external_change\n"
    end
  end

  describe "error/2" do
    test "invalid_params with a sentence prints the field and the daemon's sentence" do
      ctx = %{@read | section: "memory"}

      assert Render.error(
               mgmt("invalid_params", %{
                 "field" => "compaction_threshold",
                 "sentence" => "This setting takes a number."
               }),
               ctx
             ) == {1, "compaction_threshold: This setting takes a number."}

      assert Render.error(
               mgmt("invalid_params", %{
                 "field" => "memory",
                 "sentence" => "The change could not be saved. See the daemon log."
               }),
               ctx
             ) == {1, "The change could not be saved. See the daemon log."}
    end

    test "an unknown section names the section and the listing command" do
      ctx = %{@read | section: "providers.gemini"}

      assert Render.error(mgmt("invalid_params", %{"field" => "section"}), ctx) ==
               {1,
                ~s(this daemon has no settings section "providers.gemini"; `fermix settings` lists them.)}
    end

    test "outside set, a field that names a request parameter is not printed" do
      assert Render.error(
               mgmt("invalid_params", %{
                 "field" => "provider",
                 "sentence" => "This provider has no credentials yet."
               }),
               @read
             ) == {1, "This provider has no credentials yet."}
    end

    test "invalid_params with no sentence on another field is a refusal naming the field" do
      assert Render.error(mgmt("invalid_params", %{"field" => "values"}), @read) ==
               {1, "the daemon refused the request (field values)."}
    end

    test "external_change points at reload" do
      assert Render.error(mgmt("external_change", %{"section" => "personalization"}), @read) ==
               {1,
                "config.toml changed outside Fermix, so nothing was saved.\n" <>
                  "Load it with `fermix settings reload`, then retry."}
    end

    test "config_unreadable carries the daemon's sentence" do
      details = %{"sentence" => "config.toml [fermix_core.providers] openai must be a table."}

      assert Render.error(mgmt("config_unreadable", details), @read) ==
               {1,
                "config.toml could not be read: config.toml [fermix_core.providers] openai " <>
                  "must be a table. Fix it, then run `fermix settings reload`."}
    end

    test "a refused secret store names the file store and never switches it" do
      remedy =
        "On a machine with no desktop session to unlock it, store secrets in the file store instead:\n" <>
          "  fermix settings set secrets secret_store=file"

      assert Render.error(
               mgmt("secret_store_failed", %{"id" => "x", "reason" => "locked"}),
               @read
             ) ==
               {1,
                "the keyring is locked or refused the write, so nothing was stored.\n" <> remedy}

      assert Render.error(
               mgmt("secret_store_failed", %{"id" => "x", "reason" => "unavailable"}),
               @read
             ) ==
               {1,
                "no keyring is available to the Fermix service, so nothing was stored.\n" <>
                  remedy}

      assert Render.error(
               mgmt("secret_store_failed", %{"id" => "x", "reason" => "timeout"}),
               @read
             ) ==
               {1,
                "the keyring did not answer within its unlock wait; nothing was stored.\n" <>
                  remedy}
    end

    test "a daemon that predates the method or protocol is told to restart" do
      assert Render.error(
               mgmt("method_not_found", %{"method" => "settings.apply", "requires" => 2}),
               @read
             ) ==
               {1,
                "the running daemon is older than this fermix and has no settings.apply.\n" <>
                  "Restart it with `fermix restart`."}

      assert Render.error(mgmt("client_too_old", %{"minimum_version" => 3}), @read) ==
               {1,
                "the running daemon does not speak this fermix's management protocol.\n" <>
                  "Restart it with `fermix restart` so both run the same version."}

      assert Render.error(mgmt("daemon_too_old", %{}), @read) ==
               {1,
                "the running daemon is older than this fermix's management protocol.\n" <>
                  "Restart it with `fermix restart`."}
    end

    test "busy and unavailable use the daemon's protocol message" do
      assert Render.error({:management_error, "busy", "Already running.", %{}}, @read) ==
               {1, "Already running. (busy)"}
    end

    test "no daemon is exit 3 with the start and setup remedy" do
      assert Render.error(:not_running, @read) ==
               {3,
                "the Fermix daemon is not running, and settings change only through it.\n" <>
                  "Start it with `fermix start`. If setup never finished, run `fermix setup` first."}
    end

    test "a receive timeout on a write says the change may still be applied" do
      write = %{
        subject: :change,
        timeout_ms: 30_000,
        section: "memory",
        check: "fermix settings show memory"
      }

      assert Render.error(:timeout, write) ==
               {1,
                "the daemon did not answer within 30 s; the change may still be applied. " <>
                  "Check with `fermix settings show memory`."}

      assert Render.error(:timeout, @read) == {1, "the daemon did not answer within 10 s."}

      secret = %{subject: :secret_set, timeout_ms: 130_000, section: nil, check: nil}
      {1, sentence} = Render.error(:timeout, secret)
      assert sentence =~ "may still be stored"
      assert sentence =~ "Check"
      refute sentence =~ "not stored"
    end

    test "an invalid management response and an invalid reply exit 1" do
      assert Render.error(:invalid_management_response, @read) ==
               {1,
                "the daemon did not answer management protocol v1; restart it with `fermix restart`"}

      assert Render.error(:invalid_reply, @read) == {1, "invalid daemon reply"}
    end

    test "any other reason is inspected and scrubbed" do
      assert Render.error({:weird, "a\eb"}, @read) == {1, ~s({:weird, "a\\eb"})}
      assert Render.error(:closed, @read) == {1, ":closed"}
    end

    test "secret input failures say nothing was stored" do
      assert {1, not_a_terminal} = Render.error(:not_a_terminal, @read)
      assert not_a_terminal =~ "--stdin"
      assert {1, stdin_tty} = Render.error(:stdin_is_a_terminal, @read)
      assert stdin_tty =~ "drop --stdin"
      assert Render.error(:no_input, @read) == {1, "no secret was read, so nothing was stored."}
    end

    test "an app-managed home points at the app's Settings window" do
      assert {1, sentence} = Render.error(:app_managed, @read)
      assert sentence =~ "Fermix.app"
      assert sentence =~ "Settings window"
    end
  end

  describe "error_json/1" do
    test "a management error is decoded whole" do
      assert Render.error_json(
               {:management_error, "external_change", "The settings file changed outside Fermix.",
                %{"section" => "personalization"}}
             ) == %{
               "error" => %{
                 "code" => "external_change",
                 "message" => "The settings file changed outside Fermix.",
                 "details" => %{"section" => "personalization"}
               }
             }
    end

    test "transport and local failures carry only a code" do
      assert Render.error_json(:not_running) == %{"error" => %{"code" => "not_running"}}
      assert Render.error_json(:timeout) == %{"error" => %{"code" => "timeout"}}
      assert Render.error_json(:invalid_reply) == %{"error" => %{"code" => "invalid_reply"}}

      assert Render.error_json(:invalid_management_response) ==
               %{"error" => %{"code" => "invalid_reply"}}

      assert Render.error_json(:app_managed) == %{"error" => %{"code" => "app_managed"}}
      assert Render.error_json(:no_input) == %{"error" => %{"code" => "no_input"}}
      assert Render.error_json(:closed) == %{"error" => %{"code" => "transport_error"}}
    end
  end

  describe "secret_in_argv/2" do
    test "the set form names the key, says to rotate it and gives both safe forms" do
      message = Render.secret_in_argv(:set, "openai_api_key")

      assert message =~ "fermix settings set: openai_api_key is a secret"
      assert message =~ "rotate it"
      assert message =~ "fermix settings secret set openai_api_key "
      assert message =~ "fermix settings secret set openai_api_key --stdin"
    end

    test "the secret set form names secret set" do
      message = Render.secret_in_argv(:secret_set, "tavily_api_key")

      assert message =~ "fermix settings secret set: a secret is never taken as an argument"
      assert message =~ "rotate it"
      assert message =~ "fermix settings secret set tavily_api_key --stdin"
    end
  end
end
