defmodule FermixCore.Setup.RuntimeTest do
  use ExUnit.Case, async: false

  alias FermixCore.Auth.CodexToken
  alias FermixCore.Auth.TokenManager
  alias FermixCore.Memory.Repo, as: MemoryRepo
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.Runtime

  setup do
    providers = Application.fetch_env(:fermix_core, :providers)
    telegram = Application.fetch_env(:fermix_channels, :telegram)
    personalization = Application.get_env(:fermix_core, :personalization, [])
    agent = Application.get_env(:fermix_core, :agent, [])
    memory = Application.get_env(:fermix_core, :memory, [])
    realtime = Application.get_env(:fermix_core, :realtime, [])
    fermix_home = System.get_env("FERMIX_HOME")
    openai_api_key = System.get_env("OPENAI_API_KEY")

    on_exit(fn ->
      restore(:fermix_core, :providers, providers)
      restore(:fermix_channels, :telegram, telegram)
      Application.put_env(:fermix_core, :personalization, personalization)
      Application.put_env(:fermix_core, :agent, agent)
      Application.put_env(:fermix_core, :memory, memory)
      Application.put_env(:fermix_core, :realtime, realtime)
      restart_global_memory_repo!()

      case fermix_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      case openai_api_key do
        nil -> System.delete_env("OPENAI_API_KEY")
        value -> System.put_env("OPENAI_API_KEY", value)
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

    :ok =
      ConfigStore.save_snapshot(
        snapshot_with_openai_key(baseline_snapshot(), Keyword.get(opts, :openai_api_key))
      )
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

  defp write_codex_auth(home, refresh_token \\ "codex_rt") do
    path = Path.join(home, "codex_auth.json")

    File.write!(
      path,
      Jason.encode!(%{
        "auth_mode" => "chatgpt",
        "tokens" => %{"access_token" => "codex_at", "refresh_token" => refresh_token}
      })
    )

    path
  end

  defp write_fermix_codex_auth(home, access_token) do
    path = Path.join(home, "auth.json")

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "providers" => %{
          "openai_codex" => %{
            "auth_mode" => "chatgpt",
            "tokens" => %{
              "access_token" => access_token,
              "refresh_token" => "fermix_rt"
            },
            "expires_at" =>
              DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
          }
        }
      })
    )

    path
  end

  defp pick_free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp oauth_opener(port, test_pid) do
    fn url ->
      send(test_pid, {:oauth_opened, url})

      Task.start(fn ->
        state =
          url
          |> URI.parse()
          |> Map.fetch!(:query)
          |> URI.decode_query()
          |> Map.fetch!("state")

        deliver_callback(port, "/auth/callback?code=AUTHCODE&state=#{state}")
      end)

      :ok
    end
  end

  defp deliver_callback(port, path) do
    {:ok, conn} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    request = "GET #{path} HTTP/1.1\r\nHost: localhost:#{port}\r\nConnection: close\r\n\r\n"
    :ok = :gen_tcp.send(conn, request)
    {:ok, _resp} = :gen_tcp.recv(conn, 0, 5_000)
    :gen_tcp.close(conn)
  end

  def success_plug(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      200,
      Jason.encode!(%{
        "access_token" => "imported_at",
        "refresh_token" => "imported_rt",
        "expires_in" => 3600
      })
    )
  end

  def failure_plug(conn) do
    Plug.Conn.send_resp(conn, 500, "boom")
  end

  def oauth_exchange_plug(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      200,
      Jason.encode!(%{
        "access_token" => "oauth_at",
        "refresh_token" => "oauth_rt",
        "expires_in" => 3600
      })
    )
  end

  defp puts_collector do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    fun = fn line -> Agent.update(agent, fn acc -> [line | acc] end) end
    {fun, agent}
  end

  defp puts_lines(agent), do: agent |> Agent.get(& &1) |> Enum.reverse()

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

    test "openai_codex probe uses Fermix auth store without TokenManager" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)

      auth_path = write_fermix_codex_auth(home, "runtime_store_at")
      {puts, collector} = puts_collector()

      probe_plug = fn conn ->
        assert ["Bearer runtime_store_at"] = Plug.Conn.get_req_header(conn, "authorization")
        Plug.Conn.send_resp(conn, 200, "{}")
      end

      assert :ok =
               Runtime.run(
                 [
                   provider: "openai_codex",
                   default_model: "gpt-5.5",
                   reasoning_effort: "high",
                   codex_auth_path: Path.join(home, "missing_codex_auth.json"),
                   fermix_auth_path: auth_path,
                   req_options: [plug: probe_plug]
                 ],
                 puts: puts,
                 prompt: fn _ -> "" end
               )

      lines = puts_lines(collector)
      assert Enum.any?(lines, &String.contains?(&1, "auth probe: openai_codex/gpt-5.5"))
      refute Enum.any?(lines, &String.contains?(&1, "auth probe skipped"))
    end

    test "selecting openai_codex starts native OAuth when Fermix has no token" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)

      auth_path = Path.join(home, "auth.json")
      port = pick_free_port()
      {puts, collector} = puts_collector()

      probe_plug = fn conn ->
        assert ["Bearer oauth_at"] = Plug.Conn.get_req_header(conn, "authorization")
        Plug.Conn.send_resp(conn, 200, "{}")
      end

      assert :ok =
               Runtime.run(
                 [
                   provider: "openai_codex",
                   default_model: "gpt-5.5",
                   reasoning_effort: "high",
                   codex_auth_path: Path.join(home, "missing_codex_auth.json"),
                   fermix_auth_path: auth_path,
                   oauth_port: port,
                   oauth_opener: oauth_opener(port, self()),
                   oauth_timeout_ms: 5_000,
                   oauth_req_options: [plug: &__MODULE__.oauth_exchange_plug/1],
                   req_options: [plug: probe_plug]
                 ],
                 puts: puts,
                 prompt: fn _ -> "" end
               )

      assert_received {:oauth_opened, url}
      assert url =~ "https://auth.openai.com/oauth/authorize?"

      data = auth_path |> File.read!() |> Jason.decode!()
      assert data["providers"]["openai_codex"]["tokens"]["access_token"] == "oauth_at"

      lines = puts_lines(collector)
      assert Enum.any?(lines, &String.contains?(&1, "Opening ChatGPT OAuth login"))
      assert Enum.any?(lines, &String.contains?(&1, "auth probe: openai_codex/gpt-5.5"))
    end

    test "openai_codex refresh errors do not auto-launch OAuth" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)

      auth_path = Path.join(home, "auth.json")

      File.write!(
        auth_path,
        Jason.encode!(%{
          "version" => 1,
          "providers" => %{
            "openai_codex" => %{
              "auth_mode" => "chatgpt",
              "tokens" => %{"access_token" => "expired_at", "refresh_token" => nil},
              "expires_at" =>
                DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
            }
          }
        })
      )

      {puts, _collector} = puts_collector()

      assert {:error, :no_refresh_token} = CodexToken.get_token(fermix_auth_path: auth_path)

      result =
        Runtime.run(
          [
            provider: "openai_codex",
            default_model: "gpt-5.5",
            reasoning_effort: "high",
            codex_auth_path: Path.join(home, "missing_codex_auth.json"),
            fermix_auth_path: auth_path,
            oauth_opener: fn url ->
              send(self(), {:oauth_opened, url})
              :ok
            end,
            oauth_timeout_ms: 10
          ],
          puts: puts,
          prompt: fn _ -> "" end
        )

      assert Keyword.get(Application.get_env(:fermix_core, :agent, []), :provider) ==
               :openai_codex

      assert {:error, message} = result

      assert message =~ "codex token unavailable"
      assert message =~ ":no_refresh_token"
      refute_received {:oauth_opened, _url}
    end

    test "rejected openai_codex token triggers native OAuth and retries the probe" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)

      auth_path = write_fermix_codex_auth(home, "stale_at")
      port = pick_free_port()
      {puts, collector} = puts_collector()
      {:ok, seen_tokens} = Agent.start_link(fn -> [] end)

      probe_plug = fn conn ->
        [authorization] = Plug.Conn.get_req_header(conn, "authorization")
        Agent.update(seen_tokens, &[authorization | &1])

        case authorization do
          "Bearer stale_at" -> Plug.Conn.send_resp(conn, 401, "unauthorized")
          "Bearer oauth_at" -> Plug.Conn.send_resp(conn, 200, "{}")
        end
      end

      assert :ok =
               Runtime.run(
                 [
                   provider: "openai_codex",
                   default_model: "gpt-5.5",
                   reasoning_effort: "high",
                   codex_auth_path: Path.join(home, "missing_codex_auth.json"),
                   fermix_auth_path: auth_path,
                   oauth_port: port,
                   oauth_opener: oauth_opener(port, self()),
                   oauth_timeout_ms: 5_000,
                   oauth_req_options: [plug: &__MODULE__.oauth_exchange_plug/1],
                   req_options: [plug: probe_plug]
                 ],
                 puts: puts,
                 prompt: fn _ -> "" end
               )

      assert_received {:oauth_opened, _url}
      assert Agent.get(seen_tokens, &Enum.reverse/1) == ["Bearer stale_at", "Bearer oauth_at"]

      lines = puts_lines(collector)
      assert Enum.any?(lines, &String.contains?(&1, "Codex OAuth token rejected"))
      assert Enum.any?(lines, &String.contains?(&1, "auth probe: openai_codex/gpt-5.5"))
    end

    test "OAuth recovery reloads a running TokenManager so the retry probe sees fresh tokens" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)

      auth_path = write_fermix_codex_auth(home, "stale_at")
      port = pick_free_port()
      {puts, collector} = puts_collector()
      {:ok, seen_tokens} = Agent.start_link(fn -> [] end)

      probe_plug = fn conn ->
        [authorization] = Plug.Conn.get_req_header(conn, "authorization")
        Agent.update(seen_tokens, &[authorization | &1])

        case authorization do
          "Bearer stale_at" -> Plug.Conn.send_resp(conn, 401, "unauthorized")
          "Bearer oauth_at" -> Plug.Conn.send_resp(conn, 200, "{}")
        end
      end

      # Start TokenManager pointing at the same auth file the wizard writes.
      # In production the daemon supervises TokenManager when provider is
      # :openai_codex, and the wizard's recovery flow must keep its
      # in-memory cache in sync with the post-OAuth on-disk tokens.
      start_supervised!({TokenManager, fermix_auth_path: auth_path})

      assert :ok =
               Runtime.run(
                 [
                   provider: "openai_codex",
                   default_model: "gpt-5.5",
                   reasoning_effort: "high",
                   codex_auth_path: Path.join(home, "missing_codex_auth.json"),
                   fermix_auth_path: auth_path,
                   oauth_port: port,
                   oauth_opener: oauth_opener(port, self()),
                   oauth_timeout_ms: 5_000,
                   oauth_req_options: [plug: &__MODULE__.oauth_exchange_plug/1],
                   req_options: [plug: probe_plug]
                 ],
                 puts: puts,
                 prompt: fn _ -> "" end
               )

      assert_received {:oauth_opened, _url}
      assert Agent.get(seen_tokens, &Enum.reverse/1) == ["Bearer stale_at", "Bearer oauth_at"]
      assert {:ok, "oauth_at"} = TokenManager.get_token(TokenManager)

      lines = puts_lines(collector)
      assert Enum.any?(lines, &String.contains?(&1, "auth probe: openai_codex/gpt-5.5"))
    end

    test "rejected openai_codex token asks before starting OAuth recovery" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)

      auth_path = write_fermix_codex_auth(home, "stale_at")
      {puts, _collector} = puts_collector()

      probe_plug = fn conn -> Plug.Conn.send_resp(conn, 401, "unauthorized") end

      assert {:error, message} =
               Runtime.run(
                 [
                   provider: "openai_codex",
                   default_model: "gpt-5.5",
                   reasoning_effort: "high",
                   fermix_auth_path: auth_path,
                   # Isolate the codex-import probe so it never stats the host's
                   # real ~/.codex/auth.json (provider:openai is unconfigured here,
                   # so maybe_import_codex would otherwise reach the host fallback).
                   # The prompt "n" already declines the import, so the outcome is
                   # unchanged — this just keeps the test strictly host-independent.
                   codex_auth_path: Path.join(home, "missing_codex_auth.json"),
                   oauth_opener: fn url ->
                     send(self(), {:oauth_opened, url})
                     :ok
                   end,
                   oauth_timeout_ms: 10,
                   req_options: [plug: probe_plug]
                 ],
                 puts: puts,
                 prompt: fn _ -> "n" end
               )

      assert message =~ "auth probe failed"
      assert message =~ "Codex"
      refute_received {:oauth_opened, _url}
    end
  end

  describe "--import-codex" do
    test "imports tokens, persists to fermix store, and selects openai_codex" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)

      prepare(home)
      codex_path = write_codex_auth(home)
      fermix_auth = Path.join(home, "auth.json")

      {puts, collector} = puts_collector()

      assert :ok =
               Runtime.run(
                 [
                   import_codex: true,
                   codex_auth_path: codex_path,
                   fermix_auth_path: fermix_auth,
                   req_options: [plug: &__MODULE__.success_plug/1]
                 ],
                 puts: puts,
                 prompt: fn _ -> "" end
               )

      assert {:ok, raw} = File.read(fermix_auth)
      data = Jason.decode!(raw)
      assert data["providers"]["openai_codex"]["tokens"]["access_token"] == "imported_at"

      providers = Application.get_env(:fermix_core, :providers, [])
      refute Keyword.has_key?(providers[:openai], :auth_mode)

      agent = Application.get_env(:fermix_core, :agent, [])
      assert Keyword.get(agent, :provider) == :openai_codex

      lines = puts_lines(collector)
      assert Enum.any?(lines, &String.contains?(&1, "Imported OpenAI tokens"))
    end

    test "explicit --import-codex re-runs when openai_codex is already selected" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)

      prepare(home)

      Application.put_env(:fermix_core, :providers,
        openai: [],
        openai_codex: [default_model: "gpt-5.5", reasoning_effort: :medium]
      )

      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai_codex)

      codex_path = write_codex_auth(home, "fresh_codex_rt")
      fermix_auth = Path.join(home, "auth.json")

      {puts, collector} = puts_collector()

      assert :ok =
               Runtime.run(
                 [
                   import_codex: true,
                   codex_auth_path: codex_path,
                   fermix_auth_path: fermix_auth,
                   req_options: [plug: &__MODULE__.success_plug/1],
                   skip_probe: true
                 ],
                 puts: puts,
                 prompt: fn _ -> "" end
               )

      assert {:ok, raw} = File.read(fermix_auth)
      data = Jason.decode!(raw)
      assert data["providers"]["openai_codex"]["tokens"]["access_token"] == "imported_at"
      assert data["providers"]["openai_codex"]["tokens"]["refresh_token"] == "imported_rt"

      lines = puts_lines(collector)
      assert Enum.any?(lines, &String.contains?(&1, "Imported OpenAI tokens"))
    end

    test "surfaces an error when refresh fails" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)

      prepare(home)
      codex_path = write_codex_auth(home)
      fermix_auth = Path.join(home, "auth.json")

      {puts, _collector} = puts_collector()

      assert {:error, message} =
               Runtime.run(
                 [
                   import_codex: true,
                   codex_auth_path: codex_path,
                   fermix_auth_path: fermix_auth,
                   req_options: [plug: &__MODULE__.failure_plug/1]
                 ],
                 puts: puts,
                 prompt: fn _ -> "" end
               )

      assert message =~ "codex import failed"
      refute File.exists?(fermix_auth)
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

    test "keeps the xai_api_key flag as an answer" do
      answers = Runtime.provided_answers(provider: "xai", xai_api_key: "xai-key")

      assert Keyword.get(answers, :provider) == "xai"
      assert Keyword.get(answers, :xai_api_key) == "xai-key"
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

      assert Keyword.get(agent, :provider) == :openai_codex
      assert Keyword.get(codex_block, :default_model) == "gpt-5.5"
      assert Keyword.get(codex_block, :reasoning_effort) == :high
      assert Keyword.get(codex_block, :fast) == false
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

      assert Keyword.get(agent, :provider) == :xai
      assert Keyword.get(xai_block, :api_key) == "xai-key"
      assert Keyword.get(xai_block, :default_model) == "grok-4.3"
      assert Keyword.get(xai_block, :reasoning_effort) == :high
    end

    test "explicitly selecting a non-codex provider suppresses the Codex import even with a Codex auth file present" do
      home = tmp_home()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
      prepare(home)

      # A real, importable Codex auth file: codex_available?/1 returns true, so the
      # only thing standing between this xai run and a live token import is the
      # selected-provider guard under test.
      codex_path = write_codex_auth(home)
      test_pid = self()

      # If the import ever fires, run_codex_import -> RefreshClient.refresh hits
      # this plug. An xai run must never reach it: a non-codex provider selection
      # suppresses the import outright.
      refresh_spy = fn conn ->
        send(test_pid, :codex_refresh_called)
        __MODULE__.success_plug(conn)
      end

      {puts, _collector} = puts_collector()

      assert :ok =
               Runtime.run(
                 [
                   provider: "xai",
                   xai_api_key: "xai-key",
                   default_model: "grok-4.3",
                   reasoning_effort: "high",
                   skip_probe: true,
                   codex_auth_path: codex_path,
                   req_options: [plug: refresh_spy]
                 ],
                 puts: puts,
                 # Blank answers: the import prompt would default to YES pre-fix.
                 prompt: fn _ -> "" end
               )

      refute_received :codex_refresh_called

      assert {:ok, snapshot} = ConfigStore.load_runtime_config()
      assert snapshot.fermix_core |> Keyword.get(:agent, []) |> Keyword.get(:provider) == :xai
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
      assert Enum.any?(labels, &String.starts_with?(&1, "Codex fast mode"))

      assert {:ok, snapshot} = ConfigStore.load_runtime_config()
      agent = snapshot.fermix_core |> Keyword.get(:agent, [])
      providers = snapshot.fermix_core |> Keyword.get(:providers, [])
      codex_block = Keyword.get(providers, :openai_codex, [])

      assert Keyword.get(agent, :provider) == :openai_codex
      assert Keyword.get(codex_block, :default_model) == "gpt-5.5"
      assert Keyword.get(codex_block, :reasoning_effort) == :high
      assert Keyword.get(codex_block, :fast) == false
    end

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

      assert Keyword.get(snapshot.fermix_core |> Keyword.get(:agent, []), :provider) ==
               :openai_codex

      assert Keyword.get(codex_block, :default_model) == "gpt-5.5"
      assert Keyword.get(codex_block, :reasoning_effort) == :high
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

      assert Keyword.get(agent, :provider) == :openai_codex
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
