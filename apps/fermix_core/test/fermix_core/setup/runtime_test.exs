defmodule FermixCore.Setup.RuntimeTest do
  use ExUnit.Case, async: false

  alias FermixCore.Auth.ChatGPT
  alias FermixCore.Auth.Store, as: AuthStore
  alias FermixCore.Auth.TokenSupervisor
  alias FermixCore.Memory.Repo, as: MemoryRepo
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.Runtime
  alias FermixCore.Setup.SecretWriter

  setup do
    providers = Application.fetch_env(:fermix_core, :providers)
    # A setup run applies its home's config and saves through the wizard, and both
    # write the sandbox to app env: a provider key answer adds a keyring-backed
    # `[sandbox.env]` allow entry under the stub writer.
    sandbox = Application.fetch_env(:fermix_core, :sandbox)
    telegram = Application.fetch_env(:fermix_channels, :telegram)
    personalization = Application.get_env(:fermix_core, :personalization, [])
    agent = Application.get_env(:fermix_core, :agent, [])
    memory = Application.get_env(:fermix_core, :memory, [])
    realtime = Application.get_env(:fermix_core, :realtime, [])
    transcription = Application.get_env(:fermix_core, :transcription, [])
    fermix_home = System.get_env("FERMIX_HOME")
    openai_api_key = System.get_env("OPENAI_API_KEY")
    apns_key = System.get_env("FERMIX_APNS_KEY")
    mobile = Application.fetch_env(:fermix_channels, :mobile)

    on_exit(fn ->
      restore(:fermix_core, :providers, providers)
      restore(:fermix_core, :sandbox, sandbox)
      restore(:fermix_channels, :telegram, telegram)
      restore(:fermix_channels, :mobile, mobile)
      Application.put_env(:fermix_core, :personalization, personalization)
      Application.put_env(:fermix_core, :agent, agent)
      Application.put_env(:fermix_core, :memory, memory)
      Application.put_env(:fermix_core, :realtime, realtime)
      Application.put_env(:fermix_core, :transcription, transcription)
      restart_global_memory_repo!()

      case fermix_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      case openai_api_key do
        nil -> System.delete_env("OPENAI_API_KEY")
        value -> System.put_env("OPENAI_API_KEY", value)
      end

      case apns_key do
        nil -> System.delete_env("FERMIX_APNS_KEY")
        value -> System.put_env("FERMIX_APNS_KEY", value)
      end
    end)

    :ok
  end

  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore(app, key, :error), do: Application.delete_env(app, key)

  defp tmp_home do
    Path.join(System.tmp_dir!(), "fermix-runtime-#{System.unique_integer([:positive])}")
  end

  defp baseline_snapshot do
    %{
      fermix_core: [
        providers: [openai: []],
        personalization: [
          user_name: "Op",
          timezone: "UTC",
          communication_style: "concise and direct"
        ],
        agent: [name: "fermix"]
      ],
      fermix_channels: [telegram: [enabled: true, mode: :webhook, bot_token: "bot-token"]],
      fermix_web: []
    }
  end

  defp prepare(home, opts \\ []) do
    System.put_env("FERMIX_HOME", home)
    File.mkdir_p!(home)

    Application.put_env(:fermix_core, :providers, openai: [])
    # Pin agent.provider so the suite can't be polluted by a host
    # ~/.fermix/config.toml that sets a non-default provider (e.g. dev
    # using openai_codex). Tests that want to assert codex routing must
    # override this explicitly.
    Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai)
    Application.put_env(:fermix_core, :realtime, enabled: false)

    Application.put_env(
      :fermix_core,
      :memory,
      Keyword.merge(Application.get_env(:fermix_core, :memory, []),
        enabled: true,
        database_path: Path.join(home, "memory.db"),
        prompt_base_dir: Path.join(home, "memory"),
        agent_id: "main"
      )
    )

    Application.put_env(
      :fermix_core,
      :prompt_bootstrap,
      bootstrap_dir: Path.join(home, "bootstrap")
    )

    restart_global_memory_repo!()

    if Keyword.get(opts, :persist, true) do
      :ok =
        ConfigStore.save_snapshot(
          baseline_snapshot()
          |> snapshot_with_openai_key(Keyword.get(opts, :openai_api_key))
          |> maybe_drop_personalization(Keyword.get(opts, :personalization, true))
        )
    end

    :ok
  end

  defp maybe_drop_personalization(snapshot, true), do: snapshot

  defp maybe_drop_personalization(snapshot, false) do
    %{snapshot | fermix_core: Keyword.delete(snapshot.fermix_core, :personalization)}
  end

  # Persist the openai api_key as a plaintext config literal. On hosts with an
  # OS secret writer the wizard relocates it to the keychain; CI has none, so
  # without this the probe sees an unconfigured provider and skips it.
  defp snapshot_with_openai_key(snapshot, nil), do: snapshot

  defp snapshot_with_openai_key(snapshot, key) do
    core = Keyword.put(snapshot.fermix_core, :providers, openai: [api_key: key])
    %{snapshot | fermix_core: core}
  end

  defp restart_global_memory_repo! do
    case Process.whereis(MemoryRepo) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        :ok = Supervisor.terminate_child(FermixCore.Supervisor, MemoryRepo)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          1_000 -> Process.demonitor(ref, [:flush])
        end
    end

    {:ok, _pid} = Supervisor.restart_child(FermixCore.Supervisor, MemoryRepo)
    :ok
  end

  # The mobile channel ships feature-flagged: `[fermix_channels.mobile] enabled
  # = true` in config.toml is the only enable path, so a terminal setup run must
  # ask nothing about it and must never turn it on or write APNs credentials —
  # not even when a caller injects the withdrawn answer keys.
  test "terminal setup asks nothing mobile and never enables the channel" do
    home = tmp_home()
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
    FermixTestSupport.SecretWriterStub.reset()
    prepare(home, openai_api_key: "sk-test")
    {:ok, prompt_log} = Agent.start_link(fn -> [] end)

    prompt = fn label ->
      Agent.update(prompt_log, &[label | &1])

      if String.starts_with?(label, "Enable local voice companion"), do: "no", else: ""
    end

    {puts, _collector} = puts_collector()

    assert :ok =
             Runtime.run(
               [
                 mobile_enabled: true,
                 mobile_port: 4_555,
                 mobile_push_enabled: true,
                 mobile_push_team_id: "ABCDE12345",
                 mobile_push_key: "p8-fixture",
                 mobile_push_topic: "io.tezra.fermix.app",
                 skip_probe: true
               ],
               puts: puts,
               prompt: prompt
             )

    labels = Agent.get(prompt_log, &Enum.reverse/1)
    refute Enum.any?(labels, &(String.downcase(&1) =~ "mobile"))
    refute Enum.any?(labels, &(String.downcase(&1) =~ "apns"))

    assert {:ok, snapshot} = ConfigStore.load_runtime_config()
    mobile = snapshot.fermix_channels |> Keyword.fetch!(:mobile)
    assert Keyword.get(mobile, :enabled) == false
    refute Keyword.get(mobile, :port) == 4_555

    contents = File.read!(ConfigStore.path())
    refute contents =~ "ABCDE12345"
    refute contents =~ "p8-fixture"
    refute contents =~ "io.tezra.fermix.app"
  end

  test "runtime config file raises when bootstrap returns an error" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-runtime-file-#{System.unique_integer([:positive])}")

    previous_home = System.get_env("FERMIX_HOME")

    on_exit(fn ->
      case previous_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      FermixTestSupport.SafeRm.rm_rf!(tmp_home)
    end)

    File.write!(tmp_home, "not a directory")
    System.put_env("FERMIX_HOME", tmp_home)

    # runtime.exs lives at the umbrella root, but this test runs with the
    # fermix_core app dir as CWD — anchor to __DIR__ rather than the CWD.
    runtime_exs = Path.expand("../../../../../config/runtime.exs", __DIR__)

    # Evaluate through Config.Reader (not Code.eval_file): runtime.exs uses
    # `config/2`, which only works inside the Config context. The bootstrap
    # block raises before any env-dependent config is read.
    assert_raise RuntimeError, ~r/bootstrap_runtime_config failed.*:enotdir/s, fn ->
      read_runtime_config!(runtime_exs)
    end
  end

  test "runtime config overlays only the nested APNs credential from FERMIX_APNS_KEY" do
    tmp_home = FermixTestSupport.SafeRm.make_tmp_dir!("fermix-runtime-mobile-apns")
    System.put_env("FERMIX_HOME", tmp_home)

    System.put_env(
      "FERMIX_APNS_KEY",
      "-----BEGIN PRIVATE KEY-----\nenv-key\n-----END PRIVATE KEY-----"
    )

    Application.put_env(:fermix_channels, :mobile,
      enabled: true,
      port: 4_444,
      push: [enabled: true, topic: "io.tezra.fermix", key: "hydrated-key"]
    )

    runtime_exs = Path.expand("../../../../../config/runtime.exs", __DIR__)
    config = read_runtime_config!(runtime_exs)
    mobile = config[:fermix_channels][:mobile]

    assert Keyword.get(mobile, :enabled) == true
    assert Keyword.get(mobile, :port) == 4_444
    assert get_in(mobile, [:push, :topic]) == "io.tezra.fermix"

    assert get_in(mobile, [:push, :key]) ==
             "-----BEGIN PRIVATE KEY-----\nenv-key\n-----END PRIVATE KEY-----"

    FermixTestSupport.SafeRm.rm_rf!(tmp_home)
  end

  test "blank APNs credential preserves the ConfigStore-hydrated key" do
    tmp_home = FermixTestSupport.SafeRm.make_tmp_dir!("fermix-runtime-mobile-apns-blank")
    System.put_env("FERMIX_HOME", tmp_home)
    System.put_env("FERMIX_APNS_KEY", "")

    Application.put_env(:fermix_channels, :mobile,
      enabled: true,
      push: [enabled: true, key: "hydrated-key"]
    )

    runtime_exs = Path.expand("../../../../../config/runtime.exs", __DIR__)
    config = read_runtime_config!(runtime_exs)

    assert get_in(config, [:fermix_channels, :mobile, :push, :key]) == "hydrated-key"
    FermixTestSupport.SafeRm.rm_rf!(tmp_home)
  end

  defp read_runtime_config!(path) do
    Config.Reader.read!(path, env: :test)
  end

  defp puts_collector do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    fun = fn line -> Agent.update(agent, fn acc -> [line | acc] end) end
    {fun, agent}
  end

  defp puts_lines(agent), do: agent |> Agent.get(& &1) |> Enum.reverse()

  # The answers that choose `openai_codex` with its model and effort, on this
  # home's auth file, plus the case's seams.
  defp codex_answers(home, seams) do
    Keyword.merge(
      [
        provider: "openai_codex",
        default_model: "gpt-5.5",
        reasoning_effort: "high",
        fermix_auth_path: Path.join(home, "auth.json"),
        read_line: typed([]),
        browser: fn _url -> flunk("no browser opens in a test") end
      ],
      seams
    )
  end

  # Answers `lines` in order, then end of input, as standard input would.
  defp typed(lines) do
    {:ok, agent} = Agent.start_link(fn -> lines end)

    fn ->
      Agent.get_and_update(agent, fn
        [] -> {:eof, []}
        [line | rest] -> {line, rest}
      end)
    end
  end

  # A finished Sign in with ChatGPT with plan usage granted. No refresh token,
  # so nothing in the case can reach OpenAI to renew it.
  defp usable_chatgpt do
    %{
      auth_mode: "oauth_siwc",
      provider: "chatgpt",
      client_id: "oaiapp_setup",
      subject: "user-setup",
      account: %{email: "owner@example.com"},
      granted_scopes: ["openid", "offline_access", "chatgpt.tokens.use.direct"],
      tokens: %{access_token: "setup_at", refresh_token: nil},
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      last_refresh: nil,
      status: "ready"
    }
  end

  describe "personalization defaults" do
    # The default is the machine's own zone (`Setup.MachineFacts`), which the
    # suite pins to New York.
    test "blank timezone answer falls back to the machine's time zone" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home, personalization: false)

      {puts, _collector} = puts_collector()

      assert :ok =
               Runtime.run(
                 [openai_api_key: "sk-test", skip_probe: true],
                 puts: puts,
                 prompt: fn _ -> "" end
               )

      assert {:ok, snapshot} = ConfigStore.load_runtime_config(resolve_secrets: false)
      personalization = snapshot.fermix_core |> Keyword.get(:personalization, [])
      assert Keyword.get(personalization, :timezone) == "America/New_York"
    end
  end

  describe "finalize probe wiring" do
    test "skip_probe: true bypasses the probe entirely" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)

      {puts, collector} = puts_collector()

      assert :ok =
               Runtime.run(
                 [openai_api_key: "sk-test", skip_probe: true],
                 puts: puts,
                 prompt: fn _ -> "" end
               )

      lines = puts_lines(collector)
      refute Enum.any?(lines, &String.contains?(&1, "auth probe"))
    end

    test "probe pass emits an auth-probe line and returns :ok" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      # Persist the key as a config literal so the probe's provider lookup works
      # on CI (no OS secret writer); export it too for the readiness gate.
      prepare(home, openai_api_key: "sk-test")
      System.put_env("OPENAI_API_KEY", "sk-test")

      {puts, collector} = puts_collector()
      probe_plug = fn conn -> Plug.Conn.send_resp(conn, 200, "{}") end

      assert :ok =
               Runtime.run(
                 [openai_api_key: "sk-test", req_options: [plug: probe_plug]],
                 puts: puts,
                 prompt: fn _ -> "" end
               )

      lines = puts_lines(collector)
      assert Enum.any?(lines, &String.contains?(&1, "auth probe: openai/"))
    end

    test "probe auth_scope_mismatch (401) fails the run with a clear error message" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home, openai_api_key: "sk-bad")
      System.put_env("OPENAI_API_KEY", "sk-bad")

      {puts, _collector} = puts_collector()
      probe_plug = fn conn -> Plug.Conn.send_resp(conn, 401, "{}") end

      assert {:error, message} =
               Runtime.run(
                 [openai_api_key: "sk-bad", req_options: [plug: probe_plug]],
                 puts: puts,
                 prompt: fn _ -> "" end
               )

      assert message =~ "auth probe failed"
      assert message =~ "api.openai.com"
    end

    test "probe transient 5xx is inconclusive — run returns :ok with a warning line" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home, openai_api_key: "sk-test")
      System.put_env("OPENAI_API_KEY", "sk-test")

      {puts, collector} = puts_collector()
      probe_plug = fn conn -> Plug.Conn.send_resp(conn, 503, "service unavailable") end

      assert :ok =
               Runtime.run(
                 [openai_api_key: "sk-test", req_options: [plug: probe_plug]],
                 puts: puts,
                 prompt: fn _ -> "" end
               )

      lines = puts_lines(collector)
      assert Enum.any?(lines, &String.contains?(&1, "auth probe inconclusive"))
      assert Enum.any?(lines, &String.contains?(&1, "503"))
    end
  end

  # `openai_codex` signs in with ChatGPT through the terminal sign-in `fermix
  # auth login` runs (`Auth.ChatGPT.TerminalLogin`), so a line typed at its
  # prompt reaches it as a pasted address. Every seam is injected: no browser
  # opens, no standard input is read and nothing reaches OpenAI. The stand-in
  # sign-in stores nothing, so setup is not ready after it and no probe runs.
  describe "the openai_codex sign-in step" do
    test "with no sign-in, setup signs in with a pasted address, then checks the model" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)
      parent = self()
      pasted = "http://127.0.0.1:1455/auth/callback?code=C&state=S"

      login = fn opts ->
        :ok = Keyword.fetch!(opts, :opener).("https://auth.openai.com/api/accounts/authorize")

        receive do
          {:chatgpt_callback, url} -> send(parent, {:pasted, url})
        after
          2_000 -> flunk("no pasted address reached the sign-in")
        end

        {:ok, %{account: "owner@example.com", plan_usage: :on}}
      end

      live_model = fn provider, opts ->
        send(parent, {:live_model, provider, opts})
        {:ok, %{model: "gpt-live", changed?: true}}
      end

      {puts, collector} = puts_collector()

      assert :ok =
               Runtime.run(
                 codex_answers(home,
                   no_browser: true,
                   chatgpt_login: login,
                   read_line: typed(["  #{pasted}\n"]),
                   live_model: live_model
                 ),
                 puts: puts,
                 prompt: fn _ -> "" end
               )

      assert_received {:pasted, ^pasted}
      assert_received {:live_model, :openai_codex, []}

      lines = puts_lines(collector)
      assert "Signing in with ChatGPT for openai_codex." in lines
      assert Enum.any?(lines, &(&1 =~ "Open this address in a browser to sign in to ChatGPT:"))
      assert "Or paste the address your browser ended on:" in lines
      assert "Signed in to ChatGPT as owner@example.com." in lines
      assert "Default model set to gpt-live, the first one your ChatGPT account lists." in lines
    end

    test "a model list that cannot be read is said, and setup goes on" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)
      {puts, collector} = puts_collector()

      assert :ok =
               Runtime.run(
                 codex_answers(home,
                   chatgpt_login: fn _opts -> {:ok, %{account: nil, plan_usage: :on}} end,
                   live_model: fn :openai_codex, [] -> {:error, "No models were listed."} end
                 ),
                 puts: puts,
                 prompt: fn _ -> "" end
               )

      lines = puts_lines(collector)
      assert "Signed in to ChatGPT." in lines

      assert ("The default model was not checked against your ChatGPT account. " <>
                "No models were listed.") in lines
    end

    test "a sign-in without plan usage fails setup with what to turn on" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)
      {puts, _collector} = puts_collector()

      assert {:error, sentence} =
               Runtime.run(
                 codex_answers(home,
                   chatgpt_login: fn _opts -> {:ok, %{account: nil, plan_usage: :off}} end,
                   live_model: fn _provider, _opts ->
                     flunk("no model check without plan usage")
                   end
                 ),
                 puts: puts,
                 prompt: fn _ -> "" end
               )

      assert sentence == ChatGPT.failure_sentence(:plan_usage_off)
    end

    test "a failed sign-in fails setup with the sign-in's own sentence" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)
      {puts, _collector} = puts_collector()

      assert {:error, "Sign-in was cancelled in the browser."} =
               Runtime.run(
                 codex_answers(home, chatgpt_login: fn _opts -> {:error, :access_denied} end),
                 puts: puts,
                 prompt: fn _ -> "" end
               )
    end

    # A registration the route can use needs no sign-in. Setup is then ready,
    # so its probe runs, through the plug; what it answers is the probe's own.
    test "a usable ChatGPT sign-in starts no new one" do
      home = tmp_home()
      profile = AuthStore.profile(:openai_codex)
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      on_exit(fn -> TokenSupervisor.stop_profile(profile) end)
      prepare(home)
      :ok = TokenSupervisor.stop_profile(profile)
      :ok = AuthStore.write(profile, usable_chatgpt(), Path.join(home, "auth.json"))
      {puts, collector} = puts_collector()

      Runtime.run(
        codex_answers(home,
          chatgpt_login: fn _opts -> flunk("a usable sign-in needs no new one") end,
          req_options: [plug: fn conn -> Plug.Conn.send_resp(conn, 503, "{}") end]
        ),
        puts: puts,
        prompt: fn _ -> "" end
      )

      refute "Signing in with ChatGPT for openai_codex." in puts_lines(collector)
    end
  end

  describe "the file store, offered in the terminal when the keyring cannot be used" do
    setup do
      FermixTestSupport.SecretWriterStub.reset()

      on_exit(fn ->
        FermixTestSupport.SecretWriterStub.clear_verdict(:keyring)
        FermixTestSupport.SecretWriterStub.reset()
        Application.delete_env(:fermix_core, :secret_store)
      end)

      :ok
    end

    # The keyring locks after the home is prepared: `prepare/1` itself saves a
    # baseline with a plaintext token, which a locked keyring would refuse.
    defp lock_keyring! do
      FermixTestSupport.SecretWriterStub.set_verdict(%{
        store: :keyring,
        state: :locked,
        sentence: "the login keyring is locked"
      })
    end

    defp locked_run(prompt) do
      lock_keyring!()
      {puts, collector} = puts_collector()

      result =
        Runtime.run(
          [
            telegram_bot_token: "123:abc",
            telegram_owner_user_id: "42",
            openai_api_key: "sk-x",
            skip_probe: true
          ],
          puts: puts,
          prompt: prompt
        )

      {result, collector}
    end

    test "a yes records the file store and saves the same answers into it" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)
      test_pid = self()

      # The wizard's other questions take a blank answer; only the consent
      # question is answered yes.
      {result, collector} =
        locked_run(fn label ->
          send(test_pid, {:prompt, label})
          if label =~ "Store secrets in that folder", do: "y", else: ""
        end)

      assert :ok = result
      assert_received {:prompt, "Store secrets in that folder from now on? [y/N]: "}

      printed = Enum.join(puts_lines(collector), "\n")
      assert printed =~ "could not be saved: the login keyring is locked"
      assert printed =~ Path.join(home, "secrets")

      contents = File.read!(Path.join(home, "config.toml"))
      assert contents =~ ~s(secret_store = "file")
      assert contents =~ ~s(bot_token = "@file")
      assert contents =~ ~s(api_key = "@file")
      assert {:ok, "123:abc"} = SecretWriter.get(:telegram_bot_token, store: :file)
    end

    test "a no leaves the refusal exactly as the save gave it, and nothing is stored" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)

      {result, _collector} =
        locked_run(fn label ->
          if label =~ "Store secrets in that folder", do: "n", else: ""
        end)

      assert {:error, sentence} = result
      assert sentence =~ "could not be saved: the login keyring is locked"
      assert sentence =~ "fermix setup --secret-store file"

      refute File.exists?(Path.join(home, "config.toml")) and
               File.read!(Path.join(home, "config.toml")) =~ "secret_store"

      assert {:error, :missing_secret} = SecretWriter.get(:telegram_bot_token, store: :file)
    end

    test "--secret-store file asks nothing and saves straight into the file store" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)
      lock_keyring!()
      {puts, _collector} = puts_collector()

      assert :ok =
               Runtime.run(
                 [
                   secret_store: "file",
                   telegram_bot_token: "123:abc",
                   telegram_owner_user_id: "42",
                   openai_api_key: "sk-x",
                   skip_probe: true
                 ],
                 puts: puts,
                 prompt: fn label ->
                   refute label =~ "Store secrets in that folder", "the choice was already made"
                   ""
                 end
               )

      assert File.read!(Path.join(home, "config.toml")) =~ ~s(bot_token = "@file")
    end
  end

  # A server has no display, so nothing can unlock or create a keyring for it:
  # the store question comes before any answer the keyring would refuse, and
  # the file store is its default (owner decision 2026-10-02).
  describe "the file store, asked first on a headless host whose keyring cannot be used" do
    setup do
      FermixTestSupport.SecretWriterStub.reset()

      on_exit(fn ->
        FermixTestSupport.SecretWriterStub.clear_verdict(:keyring)
        FermixTestSupport.SecretWriterStub.reset()
        Application.delete_env(:fermix_core, :secret_store)
      end)

      :ok
    end

    defp no_keyring! do
      FermixTestSupport.SecretWriterStub.set_verdict(%{
        store: :keyring,
        state: :tool_absent,
        sentence: "this machine has no keyring client"
      })
    end

    defp channel_answers do
      [telegram_bot_token: "123:abc", telegram_owner_user_id: "42", openai_api_key: "sk-x"]
    end

    defp store_run(opts, store_answer) do
      test_pid = self()
      {puts, collector} = puts_collector()

      prompt = fn label ->
        send(test_pid, {:prompt, label})
        if label =~ "Store secrets in that folder", do: store_answer, else: ""
      end

      result =
        Runtime.run(
          opts ++ [skip_probe: true],
          puts: puts,
          prompt: prompt
        )

      {result, Enum.join(puts_lines(collector), "\n"), received_prompts([])}
    end

    defp received_prompts(acc) do
      receive do
        {:prompt, label} -> received_prompts([label | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "the store question comes first, and a blank answer saves every secret in the file store" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)
      no_keyring!()

      {result, printed, prompts} = store_run([display?: false] ++ channel_answers(), "")

      assert :ok = result
      assert [first | _] = prompts
      assert first == "Store secrets in that folder? [Y/n]"
      refute Enum.any?(prompts, &(&1 =~ "[y/N]")), "the choice was already made"

      assert printed =~ "this machine has no keyring client"
      assert printed =~ Path.join(home, "secrets")

      contents = File.read!(Path.join(home, "config.toml"))
      assert contents =~ ~s(secret_store = "file")
      assert contents =~ ~s(bot_token = "@file")
      assert {:ok, "123:abc"} = SecretWriter.get(:telegram_bot_token, store: :file)
    end

    # Recording the store writes config.toml before any other answer; on a
    # fresh home that must not read as a configured provider. Production has
    # no default agent provider, so this home has none either.
    test "on a fresh home the provider is still asked after the store answer" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home, persist: false)
      Application.put_env(:fermix_core, :agent, name: "fermix")
      no_keyring!()

      {_result, _printed, prompts} = store_run([display?: false], "")

      assert [first | rest] = prompts
      assert first == "Store secrets in that folder? [Y/n]"
      assert Enum.any?(rest, &String.starts_with?(&1, "Provider ("))
      assert File.read!(Path.join(home, "config.toml")) =~ ~s(secret_store = "file")
    end

    test "a no keeps the keyring, and the save refuses without asking a second time" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)
      no_keyring!()

      {result, _printed, prompts} = store_run([display?: false] ++ channel_answers(), "n")

      assert {:error, sentence} = result
      assert sentence =~ "could not be saved: this machine has no keyring client"
      assert sentence =~ "fermix setup --secret-store file"

      assert ["Store secrets in that folder? [Y/n]"] =
               Enum.filter(prompts, &(&1 =~ "Store secrets"))

      refute File.read!(Path.join(home, "config.toml")) =~ "secret_store"
      assert {:error, :missing_secret} = SecretWriter.get(:telegram_bot_token, store: :file)
    end

    test "a desktop keeps the question for the moment a save is refused" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)
      no_keyring!()

      {result, _printed, prompts} = store_run([display?: true] ++ channel_answers(), "")

      assert {:error, _sentence} = result
      assert "Store secrets in that folder from now on? [y/N]: " in prompts
      refute "Store secrets in that folder? [Y/n]" in prompts
    end

    test "a keyring that works asks nothing and keeps the keyring" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)

      {result, _printed, prompts} = store_run([display?: false] ++ channel_answers(), "")

      assert :ok = result
      refute Enum.any?(prompts, &(&1 =~ "Store secrets in that folder"))
      assert File.read!(Path.join(home, "config.toml")) =~ ~s(bot_token = "@keyring")
    end

    test "an explicit --secret-store keyring asks nothing up front" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)
      no_keyring!()

      {result, _printed, prompts} =
        store_run([display?: false, secret_store: "keyring"] ++ channel_answers(), "")

      assert {:error, sentence} = result
      assert sentence =~ "could not be saved"
      refute Enum.any?(prompts, &(&1 =~ "Store secrets in that folder"))
    end
  end

  describe "provided_answers/1 — provider/model/effort flags" do
    test "extracts provider/default_model/reasoning_effort opts as answers" do
      opts = [
        provider: "openai_codex",
        anthropic_api_key: "sk-ant-test",
        default_model: "gpt-5.5",
        reasoning_effort: "high",
        realtime_enabled: true,
        realtime_voice: "marin",
        realtime_max_session_minutes: 20,
        realtime_max_cost_cents: 35,
        realtime_persist_transcripts: true
      ]

      assert answers = Runtime.provided_answers(opts)
      assert Keyword.get(answers, :provider) == "openai_codex"
      assert Keyword.get(answers, :anthropic_api_key) == "sk-ant-test"
      assert Keyword.get(answers, :default_model) == "gpt-5.5"
      assert Keyword.get(answers, :reasoning_effort) == "high"
      assert Keyword.get(answers, :realtime_enabled) == true
      assert Keyword.get(answers, :realtime_voice) == "marin"
      assert Keyword.get(answers, :realtime_max_session_minutes) == 20
      assert Keyword.get(answers, :realtime_max_cost_cents) == 35
      assert Keyword.get(answers, :realtime_persist_transcripts) == true
    end

    # The model flag reaches the same answer vocabulary the setup panes write
    # through, so a headless install picks the voice engine by naming a model.
    # There is no engine flag any more: the engine is derived from the model, so
    # an engine answer cannot arrive from the command line at all.
    test "extracts the voice model flag as an answer and has no engine flag" do
      answers = Runtime.provided_answers(realtime_model: "gpt-live-1")

      assert Keyword.get(answers, :realtime_model) == "gpt-live-1"

      refute Keyword.has_key?(
               Runtime.provided_answers(realtime_engine: "openai_live"),
               :realtime_engine
             )
    end

    test "keeps the xai_api_key flag as an answer" do
      answers = Runtime.provided_answers(provider: "xai", xai_api_key: "xai-key")

      assert Keyword.get(answers, :provider) == "xai"
      assert Keyword.get(answers, :xai_api_key) == "xai-key"
    end

    test "extracts the M54 iMessage flags as answers, and no account choice" do
      answers =
        Runtime.provided_answers(
          imessage_posture: "dedicated_account",
          imessage_owner_user_id: "+15551234567",
          imessage_allowed_sender_ids: "friend@example.com"
        )

      refute Keyword.has_key?(answers, :imessage_posture)
      assert Keyword.get(answers, :imessage_owner_user_id) == "+15551234567"
      assert Keyword.get(answers, :imessage_allowed_sender_ids) == "friend@example.com"
    end

    test "extracts the M15 image flags as answers" do
      answers =
        Runtime.provided_answers(
          image_backend: "google",
          image_model: "gemini-2.5-flash-image",
          google_api_key: "gm-key"
        )

      assert Keyword.get(answers, :image_backend) == "google"
      assert Keyword.get(answers, :image_model) == "gemini-2.5-flash-image"
      assert Keyword.get(answers, :google_api_key) == "gm-key"
    end

    test "non-interactive run persists the generate_image backend, model, and google key" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)

      {puts, _collector} = puts_collector()

      assert :ok =
               Runtime.run(
                 [
                   image_backend: "google",
                   image_model: "gemini-2.5-flash-image",
                   google_api_key: "gm-key",
                   skip_probe: true
                 ],
                 puts: puts,
                 prompt: fn _ -> "" end
               )

      assert {:ok, snapshot} = ConfigStore.load_runtime_config()
      tools = Keyword.get(snapshot.fermix_core, :tools, [])
      generate_image = Keyword.get(tools, :generate_image, [])

      assert Keyword.get(generate_image, :backend) == "google"
      assert Keyword.get(generate_image, :model) == "gemini-2.5-flash-image"
      assert Keyword.get(generate_image, :google_api_key) == "gm-key"
    end

    test "extracts the M21 transcription flags as answers" do
      answers =
        Runtime.provided_answers(
          transcription_backend: "deepgram",
          transcription_model: "nova-2"
        )

      assert Keyword.get(answers, :transcription_backend) == "deepgram"
      assert Keyword.get(answers, :transcription_model) == "nova-2"
    end

    test "non-interactive run persists the transcription backend and explicit model" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)

      {puts, _collector} = puts_collector()

      assert :ok =
               Runtime.run(
                 [
                   openai_api_key: "sk-test",
                   transcription_backend: "deepgram",
                   transcription_model: "nova-2",
                   skip_probe: true
                 ],
                 puts: puts,
                 prompt: fn _ -> "" end
               )

      assert {:ok, snapshot} = ConfigStore.load_runtime_config()
      transcription = Keyword.get(snapshot.fermix_core, :transcription, [])

      assert Keyword.get(transcription, :backend) == "deepgram"
      assert Keyword.get(transcription, :model) == "nova-2"
    end

    test "switching backend without a model snaps the model to the backend default (coherence)" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)

      {puts, _collector} = puts_collector()

      assert :ok =
               Runtime.run(
                 [openai_api_key: "sk-test", transcription_backend: "deepgram", skip_probe: true],
                 puts: puts,
                 prompt: fn _ -> "" end
               )

      assert {:ok, snapshot} = ConfigStore.load_runtime_config()
      transcription = Keyword.get(snapshot.fermix_core, :transcription, [])

      # No OpenAI-shaped default model bleeds onto Deepgram — it gets its default.
      assert Keyword.get(transcription, :backend) == "deepgram"
      assert Keyword.get(transcription, :model) == "nova-3"
    end

    test "switching to the modelless xai backend drops the model entirely (coherence)" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)

      {puts, _collector} = puts_collector()

      assert :ok =
               Runtime.run(
                 [openai_api_key: "sk-test", transcription_backend: "xai", skip_probe: true],
                 puts: puts,
                 prompt: fn _ -> "" end
               )

      assert {:ok, snapshot} = ConfigStore.load_runtime_config()
      transcription = Keyword.get(snapshot.fermix_core, :transcription, [])

      # xai is modelless: no OpenAI-shaped model survives the switch and none is
      # written — the backend sends no model to the API.
      assert Keyword.get(transcription, :backend) == "xai"
      refute Keyword.has_key?(transcription, :model)
    end

    test "re-running the SAME backend without a model keeps the operator-pinned model" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)

      # Pin openai + whisper-1 first.
      {puts, _collector} = puts_collector()

      assert :ok =
               Runtime.run(
                 [
                   openai_api_key: "sk-test",
                   transcription_backend: "openai",
                   transcription_model: "whisper-1",
                   skip_probe: true
                 ],
                 puts: puts,
                 prompt: fn _ -> "" end
               )

      # Re-run with the SAME backend and NO model flag — the pinned model must
      # survive (the coherence snap only fires on an actual backend change).
      {puts2, _collector2} = puts_collector()

      assert :ok =
               Runtime.run(
                 [openai_api_key: "sk-test", transcription_backend: "openai", skip_probe: true],
                 puts: puts2,
                 prompt: fn _ -> "" end
               )

      assert {:ok, snapshot} = ConfigStore.load_runtime_config()
      transcription = Keyword.get(snapshot.fermix_core, :transcription, [])

      assert Keyword.get(transcription, :backend) == "openai"
      assert Keyword.get(transcription, :model) == "whisper-1"
    end

    test "the generic --transcription-api-key stores under the selected backend's slot" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)

      {puts, _collector} = puts_collector()

      assert :ok =
               Runtime.run(
                 [
                   openai_api_key: "sk-test",
                   transcription_backend: "deepgram",
                   transcription_api_key: "dg-generic-flag",
                   skip_probe: true
                 ],
                 puts: puts,
                 prompt: fn _ -> "" end
               )

      assert {:ok, snapshot} = ConfigStore.load_runtime_config(resolve_secrets: false)
      transcription = Keyword.get(snapshot.fermix_core, :transcription, [])

      # The key rode to deepgram_api_key (the selected backend's slot), keychained.
      assert Keyword.get(transcription, :backend) == "deepgram"
      assert Keyword.get(transcription, :deepgram_api_key) == "@keyring"
      refute Keyword.has_key?(transcription, :openai_api_key)
      assert {:ok, "dg-generic-flag"} = FermixTestSupport.SecretWriterStub.get(:deepgram_api_key)
    end

    test "non-interactive run with provider/model/effort writes them through ConfigStore" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)

      {puts, _collector} = puts_collector()

      assert :ok =
               Runtime.run(
                 [
                   openai_api_key: "sk-test",
                   provider: "openai_codex",
                   default_model: "gpt-5.5",
                   reasoning_effort: "high",
                   skip_probe: true
                 ],
                 puts: puts,
                 prompt: fn _ -> "" end
               )

      assert {:ok, snapshot} = ConfigStore.load_runtime_config()
      agent = snapshot.fermix_core |> Keyword.get(:agent, [])
      providers = snapshot.fermix_core |> Keyword.get(:providers, [])
      codex_block = Keyword.get(providers, :openai_codex, [])

      refute Keyword.has_key?(agent, :provider)
      assert Keyword.get(codex_block, :primary) == true
      assert Keyword.get(codex_block, :default_model) == "gpt-5.5"
      assert Keyword.get(codex_block, :reasoning_effort) == :high
      refute Keyword.has_key?(codex_block, :fast)
    end

    test "non-interactive xai run persists the api key, provider, model, and effort" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)

      {puts, _collector} = puts_collector()

      assert :ok =
               Runtime.run(
                 [
                   provider: "xai",
                   xai_api_key: "xai-key",
                   default_model: "grok-4.3",
                   reasoning_effort: "high",
                   skip_probe: true
                 ],
                 puts: puts,
                 prompt: fn _ -> "" end
               )

      assert {:ok, snapshot} = ConfigStore.load_runtime_config()
      agent = snapshot.fermix_core |> Keyword.get(:agent, [])
      xai_block = snapshot.fermix_core |> Keyword.get(:providers, []) |> Keyword.get(:xai, [])

      refute Keyword.has_key?(agent, :provider)
      assert Keyword.get(xai_block, :primary) == true
      assert Keyword.get(xai_block, :api_key) == "xai-key"
      assert Keyword.get(xai_block, :default_model) == "grok-4.3"
      assert Keyword.get(xai_block, :reasoning_effort) == :high
    end

    test "provided channel flags do not suppress missing provider/model prompts" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)

      :ok =
        ConfigStore.save_snapshot(%{
          fermix_core: [
            providers: [openai: [api_key: "sk-test"]],
            personalization: [
              user_name: "Op",
              timezone: "UTC",
              communication_style: "concise and direct"
            ],
            agent: [name: "fermix"]
          ],
          fermix_channels: [telegram: [enabled: true, mode: :webhook]],
          fermix_web: []
        })

      Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-test"])
      Application.put_env(:fermix_core, :agent, name: "fermix")
      Application.put_env(:fermix_channels, :telegram, enabled: true, mode: :webhook)

      {:ok, prompt_log} = Agent.start_link(fn -> [] end)

      prompt = fn label ->
        Agent.update(prompt_log, &[label | &1])

        cond do
          String.starts_with?(label, "Provider") -> "openai_codex"
          String.starts_with?(label, "Default model") -> "gpt-5.5"
          String.starts_with?(label, "Reasoning effort") -> "high"
          true -> ""
        end
      end

      {puts, _collector} = puts_collector()

      assert :ok =
               Runtime.run(
                 [telegram_bot_token: "bot-token", skip_probe: true],
                 puts: puts,
                 prompt: prompt
               )

      labels = Agent.get(prompt_log, &Enum.reverse/1)

      assert Enum.any?(labels, &String.starts_with?(&1, "Provider"))
      assert Enum.any?(labels, &String.starts_with?(&1, "Default model"))
      assert Enum.any?(labels, &String.starts_with?(&1, "Reasoning effort"))
      refute Enum.any?(labels, &String.starts_with?(&1, "Codex fast mode"))

      assert {:ok, snapshot} = ConfigStore.load_runtime_config()
      agent = snapshot.fermix_core |> Keyword.get(:agent, [])
      providers = snapshot.fermix_core |> Keyword.get(:providers, [])
      codex_block = Keyword.get(providers, :openai_codex, [])

      refute Keyword.has_key?(agent, :provider)
      assert Keyword.get(codex_block, :primary) == true
      assert Keyword.get(codex_block, :default_model) == "gpt-5.5"
      assert Keyword.get(codex_block, :reasoning_effort) == :high
      refute Keyword.has_key?(codex_block, :fast)
    end

    # `openai_codex` ships no catalog model: the one it runs comes from the
    # account's own list once it signs in with ChatGPT (`Setup.LiveModel`), so
    # a blank model answer stores none.
    test "blank model and effort answers use the selected provider defaults" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)

      :ok =
        ConfigStore.save_snapshot(%{
          fermix_core: [
            providers: [openai: [api_key: "sk-test"]],
            personalization: [
              user_name: "Op",
              timezone: "UTC",
              communication_style: "concise and direct"
            ],
            agent: [name: "fermix"]
          ],
          fermix_channels: [telegram: [enabled: true, mode: :webhook, bot_token: "bot-token"]],
          fermix_web: []
        })

      Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-test"])
      Application.put_env(:fermix_core, :agent, name: "fermix")

      Application.put_env(:fermix_channels, :telegram,
        enabled: true,
        mode: :webhook,
        bot_token: "bot-token"
      )

      prompt = fn label ->
        if String.starts_with?(label, "Provider"), do: "openai_codex", else: ""
      end

      {puts, _collector} = puts_collector()

      assert :ok =
               Runtime.run([skip_probe: true], puts: puts, prompt: prompt)

      assert {:ok, snapshot} = ConfigStore.load_runtime_config()
      providers = snapshot.fermix_core |> Keyword.get(:providers, [])
      codex_block = Keyword.get(providers, :openai_codex, [])

      assert Keyword.get(codex_block, :primary) == true
      assert Keyword.get(codex_block, :default_model) == nil
      assert Keyword.get(codex_block, :reasoning_effort) == :high
    end

    test "does not ask for reasoning_effort on providers without effort support" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)

      :ok =
        ConfigStore.save_snapshot(%{
          fermix_core: [
            providers: [
              openai: [api_key: "sk-test"],
              openrouter: []
            ],
            personalization: [
              user_name: "Op",
              timezone: "UTC",
              communication_style: "concise and direct"
            ],
            agent: [name: "fermix"]
          ],
          fermix_channels: [telegram: [enabled: true, mode: :webhook, bot_token: "bot-token"]],
          fermix_web: []
        })

      Application.put_env(:fermix_core, :providers,
        openai: [api_key: "sk-test"],
        openrouter: []
      )

      Application.put_env(:fermix_core, :agent, name: "fermix")

      {:ok, prompt_log} = Agent.start_link(fn -> [] end)

      prompt = fn label ->
        Agent.update(prompt_log, &[label | &1])

        if String.starts_with?(label, "Default model") do
          "qwen-2.5-7b-instruct"
        else
          ""
        end
      end

      {puts, _collector} = puts_collector()

      assert :ok =
               Runtime.run(
                 [
                   provider: "openrouter",
                   openrouter_api_key: "or-key",
                   skip_probe: true
                 ],
                 puts: puts,
                 prompt: prompt
               )

      labels = Agent.get(prompt_log, &Enum.reverse/1)

      refute Enum.any?(labels, &String.starts_with?(&1, "Reasoning effort"))
      assert Enum.any?(labels, &String.starts_with?(&1, "Default model"))
    end

    test "--reconfigure prompts provider model and effort even when setup is ready" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)

      :ok =
        ConfigStore.save_snapshot(%{
          fermix_core: [
            providers: [
              openai: [
                api_key: "sk-test",
                default_model: "gpt-5.4",
                reasoning_effort: :medium
              ],
              openai_codex: [default_model: "gpt-5.5", reasoning_effort: :high]
            ],
            personalization: [
              user_name: "Op",
              timezone: "UTC",
              communication_style: "concise and direct"
            ],
            agent: [name: "fermix", provider: :openai]
          ],
          fermix_channels: [telegram: [enabled: true, mode: :webhook, bot_token: "bot-token"]],
          fermix_web: []
        })

      Application.put_env(:fermix_core, :providers,
        openai: [api_key: "sk-test", default_model: "gpt-5.4", reasoning_effort: :medium],
        openai_codex: [default_model: "gpt-5.5", reasoning_effort: :high]
      )

      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai)

      {:ok, prompt_log} = Agent.start_link(fn -> [] end)

      prompt = fn label ->
        Agent.update(prompt_log, &[label | &1])

        cond do
          String.starts_with?(label, "Provider") -> "openai_codex"
          String.starts_with?(label, "Default model") -> "gpt-5.5"
          String.starts_with?(label, "Reasoning effort") -> "high"
          true -> ""
        end
      end

      {puts, _collector} = puts_collector()

      assert :ok =
               Runtime.run([reconfigure: true, skip_probe: true], puts: puts, prompt: prompt)

      labels = Agent.get(prompt_log, &Enum.reverse/1)

      assert Enum.any?(labels, &String.starts_with?(&1, "Provider"))
      assert Enum.any?(labels, &String.starts_with?(&1, "Default model"))
      assert Enum.any?(labels, &String.starts_with?(&1, "Reasoning effort"))

      assert {:ok, snapshot} = ConfigStore.load_runtime_config()
      agent = snapshot.fermix_core |> Keyword.get(:agent, [])
      providers = snapshot.fermix_core |> Keyword.get(:providers, [])
      codex_block = Keyword.get(providers, :openai_codex, [])

      refute Keyword.has_key?(agent, :provider)
      assert Keyword.get(codex_block, :primary) == true
      assert Keyword.get(codex_block, :default_model) == "gpt-5.5"
      assert Keyword.get(codex_block, :reasoning_effort) == :high
    end

    test "--reconfigure skips detailed realtime prompts when voice companion stays disabled" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)

      :ok =
        ConfigStore.save_snapshot(%{
          fermix_core: [
            providers: [
              openai: [
                api_key: "sk-test",
                default_model: "gpt-5.4",
                reasoning_effort: :medium
              ]
            ],
            personalization: [
              user_name: "Op",
              timezone: "UTC",
              communication_style: "concise and direct"
            ],
            agent: [name: "fermix", provider: :openai],
            realtime: [enabled: false]
          ],
          fermix_channels: [telegram: [enabled: true, mode: :webhook, bot_token: "bot-token"]],
          fermix_web: []
        })

      Application.put_env(:fermix_core, :providers,
        openai: [api_key: "sk-test", default_model: "gpt-5.4", reasoning_effort: :medium]
      )

      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai)
      Application.put_env(:fermix_core, :realtime, enabled: false)

      {:ok, prompt_log} = Agent.start_link(fn -> [] end)

      prompt = fn label ->
        Agent.update(prompt_log, &[label | &1])

        cond do
          String.starts_with?(label, "Enable local voice companion") -> "no"
          String.starts_with?(label, "Provider") -> "openai"
          String.starts_with?(label, "Default model") -> "gpt-5.4"
          String.starts_with?(label, "Reasoning effort") -> "medium"
          true -> ""
        end
      end

      {puts, _collector} = puts_collector()

      assert :ok =
               Runtime.run([reconfigure: true, skip_probe: true], puts: puts, prompt: prompt)

      labels = Agent.get(prompt_log, &Enum.reverse/1)

      assert Enum.any?(labels, &String.starts_with?(&1, "Enable local voice companion"))
      refute Enum.any?(labels, &String.starts_with?(&1, "Realtime model"))
      refute Enum.any?(labels, &String.starts_with?(&1, "Realtime voice"))
    end

    test "--reconfigure asks basic realtime prompts after voice companion is enabled" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)

      :ok =
        ConfigStore.save_snapshot(%{
          fermix_core: [
            providers: [
              openai: [
                api_key: "sk-test",
                default_model: "gpt-5.4",
                reasoning_effort: :medium
              ]
            ],
            personalization: [
              user_name: "Op",
              timezone: "UTC",
              communication_style: "concise and direct"
            ],
            agent: [name: "fermix", provider: :openai],
            realtime: [enabled: false]
          ],
          fermix_channels: [telegram: [enabled: true, mode: :webhook, bot_token: "bot-token"]],
          fermix_web: []
        })

      Application.put_env(:fermix_core, :providers,
        openai: [api_key: "sk-test", default_model: "gpt-5.4", reasoning_effort: :medium]
      )

      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai)
      Application.put_env(:fermix_core, :realtime, enabled: false)

      {:ok, prompt_log} = Agent.start_link(fn -> [] end)

      prompt = fn label ->
        Agent.update(prompt_log, &[label | &1])

        cond do
          String.starts_with?(label, "Enable local voice companion") -> "yes"
          String.starts_with?(label, "Provider") -> "openai"
          String.starts_with?(label, "Default model") -> "gpt-5.4"
          String.starts_with?(label, "Reasoning effort") -> "medium"
          true -> ""
        end
      end

      {puts, _collector} = puts_collector()

      assert :ok =
               Runtime.run([reconfigure: true, skip_probe: true], puts: puts, prompt: prompt)

      labels = Agent.get(prompt_log, &Enum.reverse/1)

      assert Enum.any?(labels, &String.starts_with?(&1, "Enable local voice companion"))
      assert Enum.any?(labels, &String.starts_with?(&1, "Realtime voice"))
      assert Enum.any?(labels, &String.starts_with?(&1, "Realtime max session minutes"))
      assert Enum.any?(labels, &String.starts_with?(&1, "Realtime max estimated cost cents"))
      refute Enum.any?(labels, &String.starts_with?(&1, "Realtime tool policy"))

      assert {:ok, snapshot} = ConfigStore.load_runtime_config()
      realtime = snapshot.fermix_core |> Keyword.get(:realtime, [])
      assert Keyword.get(realtime, :enabled) == true
      assert Keyword.get(realtime, :voice) == "marin"
    end
  end
end
