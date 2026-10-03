defmodule Fermix.CLI.SettingsCommandTest do
  # async: false — the masked-read cases capture `:standard_error`, where
  # SecretInput writes its prompt. That device is one global name, so a
  # concurrent async writer would land in a capture this module asserts the
  # secret is absent from.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.SettingsCommand
  alias FermixTestSupport.PipedTerminal
  alias FermixTestSupport.TtyTerminal

  @not_running "the Fermix daemon is not running, and settings change only through it.\n" <>
                 "Start it with `fermix start`. If setup never finished, run `fermix setup` first.\n"

  @sections %{
    "sections" => [
      %{"id" => "memory", "pane" => "memory", "title" => "Memory"},
      %{"id" => "browser", "pane" => "browser", "title" => "Browser"}
    ]
  }

  @restart %{
    "required" => true,
    "reasons" => [
      %{"section" => "memory", "sentence" => "Memory settings changed since Fermix started."}
    ]
  }

  @ready %{"status" => "ready", "failure_count" => 0}

  @memory %{
    "id" => "memory",
    "title" => "Memory",
    "rows" => [
      %{
        "key" => "compaction_threshold",
        "kind" => "number",
        "label" => "Compact a conversation at",
        "format" => "percent",
        "value" => 0.85,
        "options" => [],
        "restart" => false,
        "read_only" => false
      },
      %{
        "key" => "review_interval_hours",
        "kind" => "number",
        "label" => "Review memory every",
        "unit" => "hours",
        "value" => 24,
        "options" => [],
        "restart" => false,
        "read_only" => false
      },
      %{
        "key" => "future_token",
        "kind" => "secret",
        "label" => "A future secret",
        "present" => false,
        "value" => nil,
        "options" => []
      }
    ]
  }

  # Every call is reported to the test process, so a test pins the exact
  # sequence (and the absence of a call) rather than only the final output.
  defp client(replies) do
    test_pid = self()

    fn method, params, opts ->
      send(test_pid, {:call, method, params, opts})

      case Map.fetch(replies, method) do
        {:ok, reply} when is_function(reply, 1) -> reply.(params)
        {:ok, reply} -> reply
        :error -> flunk("unexpected daemon call #{method}")
      end
    end
  end

  defp refusing_client do
    fn method, _params, _opts -> flunk("no daemon call was expected, got #{method}") end
  end

  defp run(argv, client, extra \\ []) do
    {:ok, stdout} = StringIO.open("")
    {:ok, stderr} = StringIO.open("")

    opts =
      Keyword.merge(
        [client: client, stdout: stdout, stderr: stderr, app_managed?: fn -> false end],
        extra
      )

    status = SettingsCommand.run(argv, opts)
    {status, contents(stdout), contents(stderr)}
  end

  defp contents(device) do
    {:ok, {_input, output}} = StringIO.close(device)
    output
  end

  defp calls do
    receive do
      {:call, method, params, opts} -> [{method, params, opts} | calls()]
    after
      0 -> []
    end
  end

  defp methods, do: Enum.map(calls(), &elem(&1, 0))

  defp mgmt(code, details),
    do: {:error, {:management_error, code, "message for #{code}", details}}

  describe "list" do
    test "asks settings.sections with no params and the read timeout, then prints the table" do
      {status, stdout, stderr} = run([], client(%{"settings.sections" => {:ok, @sections}}))

      assert status == 0

      assert stdout ==
               "PANE\tSECTION\tTITLE\nmemory\tmemory\tMemory\nbrowser\tbrowser\tBrowser\n"

      assert stderr == ""
      assert [{"settings.sections", %{}, opts}] = calls()
      assert opts[:timeout] == 10_000
    end

    test "--json prints the daemon's result on one stdout line and nothing else" do
      {0, stdout, stderr} = run(["--json"], client(%{"settings.sections" => {:ok, @sections}}))

      assert [line] = String.split(stdout, "\n", trim: true)
      assert Jason.decode!(line) == @sections
      assert stderr == ""
    end

    test "a section missing its pane is an invalid reply" do
      bad = %{"sections" => [%{"id" => "memory", "title" => "Memory"}]}

      assert run(["list"], client(%{"settings.sections" => {:ok, bad}})) ==
               {1, "", "fermix settings: invalid daemon reply\n"}

      assert {1, ~s({"error":{"code":"invalid_reply"}}\n), _stderr} =
               run(["list", "--json"], client(%{"settings.sections" => {:ok, bad}}))
    end
  end

  describe "show" do
    test "asks settings.get for the section and renders its rows" do
      {status, stdout, _stderr} =
        run(["show", "memory"], client(%{"settings.get" => {:ok, @memory}}))

      assert status == 0
      assert stdout =~ "Memory  (memory)\n"
      assert stdout =~ "Compact a conversation at: 0.85 (85%)"
      assert stdout =~ "Review memory every: 24 hours"
      assert [{"settings.get", %{"section" => "memory"}, opts}] = calls()
      assert opts[:timeout] == 10_000
    end

    test "an unknown section prints the CLI's own sentence" do
      reply = mgmt("invalid_params", %{"field" => "section"})

      assert run(["show", "providers.gemini"], client(%{"settings.get" => reply})) ==
               {1, "",
                ~s(fermix settings: this daemon has no settings section "providers.gemini"; ) <>
                  "`fermix settings` lists them.\n"}
    end
  end

  describe "set" do
    test "reads the rows, then applies the values coerced by each row's kind" do
      apply_reply =
        {:ok,
         %{
           "applied" => ["compaction_threshold", "review_interval_hours"],
           "restart" => @restart,
           "readiness" => @ready,
           "side_effects" => []
         }}

      replies = %{"settings.get" => {:ok, @memory}, "settings.apply" => apply_reply}

      {status, stdout, stderr} =
        run(
          ["set", "memory", "compaction_threshold=0.75", "review_interval_hours=12"],
          client(replies)
        )

      assert status == 0
      assert stderr == ""

      assert stdout ==
               "Saved memory: compaction_threshold, review_interval_hours\n" <>
                 "Restart to apply (fermix restart):\n" <>
                 "  - Memory settings changed since Fermix started.\n"

      assert [
               {"settings.get", %{"section" => "memory"}, get_opts},
               {"settings.apply", apply_params, apply_opts}
             ] = calls()

      assert apply_params == %{
               "section" => "memory",
               "values" => %{"compaction_threshold" => 0.75, "review_interval_hours" => 12}
             }

      assert get_opts[:timeout] == 10_000
      assert apply_opts[:timeout] == 30_000
    end

    test "derived keys and side effects are printed with the hint to show the section again" do
      realtime = %{
        "id" => "realtime",
        "title" => "Voice",
        "rows" => [%{"key" => "realtime_model", "kind" => "choice", "label" => "Model"}]
      }

      apply_reply =
        {:ok,
         %{
           "applied" => ["realtime_model", "realtime_engine"],
           "restart" => %{"required" => false, "reasons" => []},
           "readiness" => @ready,
           "side_effects" => ["The engine changed to GPT-Live."]
         }}

      {0, stdout, _stderr} =
        run(
          ["set", "realtime", "realtime_model=gpt-live-orbit"],
          client(%{"settings.get" => {:ok, realtime}, "settings.apply" => apply_reply})
        )

      assert stdout =~ "Saved realtime: realtime_model, realtime_engine\n"
      assert stdout =~ "The engine changed to GPT-Live.\n"
      assert stdout =~ "run `fermix settings show realtime` to see them"
    end

    test "the daemon's refusal is printed as key: sentence" do
      replies = %{
        "settings.get" => {:ok, @memory},
        "settings.apply" =>
          mgmt("invalid_params", %{
            "field" => "compaction_threshold",
            "sentence" => "This setting takes a number."
          })
      }

      assert run(["set", "memory", "compaction_threshold=lots"], client(replies)) ==
               {1, "", "fermix settings: compaction_threshold: This setting takes a number.\n"}

      assert [_get, {"settings.apply", %{"values" => %{"compaction_threshold" => "lots"}}, _}] =
               calls()
    end

    test "a key with no row is sent raw for the daemon to refuse" do
      replies = %{
        "settings.get" => {:ok, @memory},
        "settings.apply" =>
          mgmt("invalid_params", %{
            "field" => "nope",
            "sentence" => "This section has no setting by that name."
          })
      }

      {1, _stdout, stderr} = run(["set", "memory", "nope=12"], client(replies))

      assert stderr =~ "nope: This section has no setting by that name."
      assert [_get, {"settings.apply", %{"values" => %{"nope" => "12"}}, _}] = calls()
    end

    test "a secret row typed as an argument is refused after the rows are read, never sent" do
      {status, stdout, stderr} =
        run(
          ["set", "memory", "future_token=sk-test-abc123"],
          client(%{"settings.get" => {:ok, @memory}})
        )

      assert status == 2
      assert stdout == ""
      assert stderr =~ "future_token is a secret"
      assert stderr =~ "rotate it"
      assert stderr =~ "fermix settings secret set future_token"
      refute stderr =~ "sk-test-abc123"
      assert methods() == ["settings.get"]
    end

    test "a published secret id is refused before any daemon call" do
      for key <- [
            "openai_api_key",
            "env:ACME_TOKEN",
            "plugin:acme",
            "oauth_client:github",
            "anthropic_setup_token"
          ] do
        {status, stdout, stderr} =
          run(["set", "providers.openai", "#{key}=sk-test-abc123"], refusing_client())

        assert status == 2
        assert stdout == ""
        assert stderr =~ "#{key} is a secret"
        refute stderr =~ "sk-test-abc123"
      end
    end

    test "under --json a secret in argv prints only its code on stdout" do
      {2, stdout, stderr} =
        run(
          ["set", "providers.openai", "openai_api_key=sk-test-abc123", "--json"],
          refusing_client()
        )

      assert stdout == ~s({"error":{"code":"secret_in_argv"}}\n)
      assert stderr =~ "rotate it"
      refute stdout <> stderr =~ "sk-test-abc123"
    end

    test "an outside edit is answered with the reload remedy" do
      replies = %{
        "settings.get" => {:ok, @memory},
        "settings.apply" => mgmt("external_change", %{"section" => "memory"})
      }

      assert run(["set", "memory", "review_interval_hours=12"], client(replies)) ==
               {1, "",
                "fermix settings: config.toml changed outside Fermix, so nothing was saved.\n" <>
                  "Load it with `fermix settings reload`, then retry.\n"}
    end

    test "a receive timeout on apply says the change may still be applied" do
      replies = %{"settings.get" => {:ok, @memory}, "settings.apply" => {:error, :timeout}}

      {1, "", stderr} = run(["set", "memory", "review_interval_hours=12"], client(replies))

      assert stderr ==
               "fermix settings: the daemon did not answer within 30 s; the change may still " <>
                 "be applied. Check with `fermix settings show memory`.\n"
    end
  end

  describe "reload" do
    test "reloads with no params and prints the restart reasons and a config state that is not clear" do
      reply =
        {:ok,
         %{
           "reloaded" => true,
           "restart" => @restart,
           "readiness" => @ready,
           "config_state" => "external_change"
         }}

      {0, stdout, ""} = run(["reload"], client(%{"settings.reload" => reply}))

      assert stdout =~ "Reloaded settings from disk.\n"
      assert stdout =~ "  - Memory settings changed since Fermix started.\n"
      assert stdout =~ "config.toml state: external_change\n"
      assert [{"settings.reload", %{}, opts}] = calls()
      assert opts[:timeout] == 30_000
    end

    test "an unreadable config prints the daemon's sentence" do
      reply = mgmt("config_unreadable", %{"sentence" => "config.toml line 3 is not TOML."})

      assert run(["reload"], client(%{"settings.reload" => reply})) ==
               {1, "",
                "fermix settings: config.toml could not be read: config.toml line 3 is not TOML. " <>
                  "Fix it, then run `fermix settings reload`.\n"}
    end
  end

  describe "secret set" do
    test "a value glued to the id is refused before any prompt or daemon call" do
      for argv <- [
            ["secret", "set", "openai_api_key=sk-test-abc123"],
            ["secret", "set", "openai_api_key", "--sk-test-abc123"]
          ] do
        {status, stdout, stderr} = run(argv, refusing_client())

        assert status == 2
        assert stdout == ""
        assert stderr =~ "rotate it"
        assert stderr =~ "fermix settings secret set openai_api_key"
        refute stderr =~ "sk-test-abc123"
      end
    end

    @stored {:ok,
             %{
               "id" => "openai_api_key",
               "present" => true,
               "restart" => %{"required" => false, "reasons" => []}
             }}

    test "prompts masked on stderr, then stores the value with the long secret timeout" do
      {:ok, device} = StringIO.open("sk-test-xyz\n")
      replies = %{"settings.sections" => {:ok, @sections}, "secret.set" => @stored}
      test_pid = self()

      prompt =
        capture_io(:stderr, fn ->
          result =
            run(["secret", "set", "openai_api_key"], client(replies),
              secret_input: [device: device, terminal: TtyTerminal]
            )

          send(test_pid, {:result, result})
        end)

      assert_received {:result, {0, stdout, stderr}}
      assert stdout == "Stored openai_api_key.\n"
      assert prompt =~ "openai_api_key: "

      for captured <- [stdout, stderr, prompt] do
        refute captured =~ "sk-test-xyz"
      end

      assert [
               {"settings.sections", %{}, _},
               {"secret.set", %{"id" => "openai_api_key", "value" => "sk-test-xyz"}, opts}
             ] = calls()

      assert opts[:timeout] >= 121_000
      assert_received {:secret_input_echo, false}
      assert_received {:secret_input_echo, true}
    end

    test "--stdin reads a piped value with one trailing newline stripped" do
      {:ok, device} = StringIO.open("sk-piped\n")
      replies = %{"settings.sections" => {:ok, @sections}, "secret.set" => @stored}

      {0, stdout, ""} =
        run(["secret", "set", "openai_api_key", "--stdin", "--json"], client(replies),
          secret_input: [device: device, terminal: PipedTerminal]
        )

      assert Jason.decode!(stdout) == elem(@stored, 1)

      assert [_preflight, {"secret.set", %{"value" => "sk-piped"}, _opts}] = calls()
    end

    test "--stdin on a terminal is refused and nothing is sent" do
      {:ok, device} = StringIO.open("")

      {1, "", stderr} =
        run(
          ["secret", "set", "openai_api_key", "--stdin"],
          client(%{"settings.sections" => {:ok, @sections}}),
          secret_input: [device: device, terminal: TtyTerminal]
        )

      assert stderr =~ "fermix settings secret set: --stdin was passed but stdin is a terminal"
      assert methods() == ["settings.sections"]
    end

    test "an empty pipe stores nothing" do
      {:ok, device} = StringIO.open("")

      {1, "", stderr} =
        run(
          ["secret", "set", "openai_api_key", "--stdin"],
          client(%{"settings.sections" => {:ok, @sections}}),
          secret_input: [device: device, terminal: PipedTerminal]
        )

      assert stderr == "fermix settings secret set: no secret was read, so nothing was stored.\n"
      assert methods() == ["settings.sections"]
    end

    test "a masked read with no terminal points at --stdin" do
      {:ok, device} = StringIO.open("sk-test-xyz\n")

      {1, "", stderr} =
        run(
          ["secret", "set", "openai_api_key"],
          client(%{"settings.sections" => {:ok, @sections}}),
          secret_input: [device: device, terminal: PipedTerminal]
        )

      assert stderr =~ "--stdin"
      refute stderr =~ "sk-test-xyz"
      assert methods() == ["settings.sections"]
    end

    test "with no daemon it exits 3 before the operator is asked for anything" do
      {:ok, device} = StringIO.open("sk-test-xyz\n")

      result =
        run(
          ["secret", "set", "openai_api_key"],
          client(%{"settings.sections" => {:error, :not_running}}),
          secret_input: [device: device, terminal: TtyTerminal]
        )

      assert result == {3, "", "fermix settings secret set: " <> @not_running}
      # The input is still unread, and the terminal was never touched.
      assert StringIO.contents(device) == {"sk-test-xyz\n", ""}
      refute_received {:secret_input_echo, _echo}
    end

    test "a locked keyring names the file store and stores nothing" do
      {:ok, device} = StringIO.open("sk-piped\n")

      replies = %{
        "settings.sections" => {:ok, @sections},
        "secret.set" =>
          mgmt("secret_store_failed", %{"id" => "telegram_bot_token", "reason" => "locked"})
      }

      {1, "", stderr} =
        run(["secret", "set", "telegram_bot_token", "--stdin"], client(replies),
          secret_input: [device: device, terminal: PipedTerminal]
        )

      assert stderr =~ "nothing was stored"
      assert stderr =~ "fermix settings set secrets secret_store=file"
      refute stderr =~ "sk-piped"
    end

    test "a receive timeout says the secret may still be stored, never that it was not" do
      {:ok, device} = StringIO.open("sk-piped\n")

      replies = %{"settings.sections" => {:ok, @sections}, "secret.set" => {:error, :timeout}}

      {1, "", stderr} =
        run(["secret", "set", "openai_api_key", "--stdin"], client(replies),
          secret_input: [device: device, terminal: PipedTerminal]
        )

      assert stderr =~ "may still be stored"
      assert stderr =~ "Check"
      refute stderr =~ "not stored"
      refute stderr =~ "sk-piped"
    end

    test "a value typed as an argument is refused before any daemon call" do
      {status, stdout, stderr} =
        run(["secret", "set", "openai_api_key", "sk-test-abc123"], refusing_client())

      assert status == 2
      assert stdout == ""
      assert stderr =~ "fermix settings secret set: a secret is never taken as an argument"
      assert stderr =~ "rotate it"
      refute stderr =~ "sk-test-abc123"
    end
  end

  describe "secret clear" do
    test "clears the id with the long secret timeout" do
      reply =
        {:ok,
         %{
           "id" => "brave_api_key",
           "present" => false,
           "restart" => %{"required" => false, "reasons" => []}
         }}

      assert run(["secret", "clear", "brave_api_key"], client(%{"secret.clear" => reply})) ==
               {0, "Cleared brave_api_key.\n", ""}

      assert [{"secret.clear", %{"id" => "brave_api_key"}, opts}] = calls()
      assert opts[:timeout] >= 121_000
    end
  end

  describe "primary" do
    test "with no provider it lists providers from setup.state.get" do
      state = %{
        "providers" => [
          %{
            "id" => "openai_codex",
            "label" => "OpenAI Codex",
            "configured" => true,
            "primary" => true
          },
          %{"id" => "openai", "label" => "OpenAI", "configured" => true, "primary" => false}
        ]
      }

      {0, stdout, ""} = run(["primary"], client(%{"setup.state.get" => {:ok, state}}))

      assert stdout ==
               "PROVIDER\tNAME\tCONFIGURED\tPRIMARY\n" <>
                 "openai_codex\tOpenAI Codex\tyes\tyes\n" <>
                 "openai\tOpenAI\tyes\tno\n"

      assert [{"setup.state.get", %{}, opts}] = calls()
      assert opts[:timeout] == 10_000
    end

    test "with a provider it makes it primary and prints the restart reasons" do
      reply = {:ok, %{"restart" => @restart, "side_effects" => []}}

      {0, stdout, ""} = run(["primary", "openai"], client(%{"providers.set_primary" => reply}))

      assert stdout ==
               "Primary provider is now openai.\n" <>
                 "Restart to apply (fermix restart):\n" <>
                 "  - Memory settings changed since Fermix started.\n"

      assert [{"providers.set_primary", %{"provider" => "openai"}, opts}] = calls()
      assert opts[:timeout] == 30_000
    end

    test "the daemon's refusal is its own sentence" do
      reply =
        mgmt("invalid_params", %{
          "field" => "provider",
          "sentence" => "This provider has no credentials yet."
        })

      assert run(["primary", "mistral"], client(%{"providers.set_primary" => reply})) ==
               {1, "", "fermix settings primary: This provider has no credentials yet.\n"}
    end
  end

  describe "failures every subcommand shares" do
    @argvs [
      {["list"], "fermix settings"},
      {["show", "memory"], "fermix settings"},
      {["set", "memory", "review_interval_hours=12"], "fermix settings"},
      {["secret", "clear", "brave_api_key"], "fermix settings secret clear"},
      {["primary"], "fermix settings primary"},
      {["primary", "openai"], "fermix settings primary"},
      {["reload"], "fermix settings"}
    ]

    defp down, do: fn _method, _params, _opts -> {:error, :not_running} end

    test "no daemon is exit 3 with the not-running sentence" do
      for {argv, prefix} <- @argvs do
        assert run(argv, down()) == {3, "", prefix <> ": " <> @not_running}
      end
    end

    test "no daemon under --json prints exactly the not_running code on stdout" do
      for {argv, _prefix} <- @argvs do
        {3, stdout, stderr} = run(argv ++ ["--json"], down())

        assert stdout == ~s({"error":{"code":"not_running"}}\n)
        assert stderr =~ "not running"
      end
    end

    test "a daemon that predates the method is told to restart" do
      old = fn method, _params, _opts ->
        {:error,
         {:management_error, "method_not_found",
          "The requested management method is not available.",
          %{"method" => method, "requires" => 2}}}
      end

      {1, "", stderr} = run(["list"], old)

      assert stderr ==
               "fermix settings: the running daemon is older than this fermix and has no " <>
                 "settings.sections.\nRestart it with `fermix restart`.\n"

      too_old = fn _method, _params, _opts -> mgmt("client_too_old", %{}) end
      {1, "", stderr} = run(["reload"], too_old)
      assert stderr =~ "`fermix restart`"
    end

    test "under --json every failure leaves at most one JSON object on stdout" do
      failures = [
        {:error, :not_running},
        {:error, :timeout},
        {:error, :closed},
        {:error, :invalid_management_response},
        mgmt("external_change", %{"section" => "memory"}),
        mgmt("invalid_params", %{"field" => "section"}),
        {:ok, %{"unexpected" => true}}
      ]

      for reply <- failures, {argv, _prefix} <- @argvs do
        always = fn _method, _params, _opts -> reply end
        {status, stdout, stderr} = run(argv ++ ["--json"], always)

        assert status in [1, 3]
        assert [line] = String.split(stdout, "\n", trim: true)
        assert %{"error" => %{"code" => code}} = Jason.decode!(line)
        assert is_binary(code)
        assert stderr != ""
        refute stderr =~ "{\"error\""
      end
    end

    test "a usage error exits 2 with the usage on stderr and calls nothing" do
      {2, "", stderr} = run(["frobnicate"], refusing_client())

      assert stderr =~ "usage: fermix settings [list] [--json]"
      assert stderr =~ "fermix settings secret set ID [--stdin] [--json]"

      assert {2, ~s({"error":{"code":"usage"}}\n), _stderr} =
               run(["show", "--json"], refusing_client())
    end
  end
end
