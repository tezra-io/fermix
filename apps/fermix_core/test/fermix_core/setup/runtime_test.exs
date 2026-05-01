defmodule FermixCore.Setup.RuntimeTest do
  use ExUnit.Case, async: false

  alias FermixCore.Memory.Repo, as: MemoryRepo
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.Runtime

  setup do
    providers = Application.fetch_env(:fermix_core, :providers)
    telegram = Application.fetch_env(:fermix_channels, :telegram)
    personalization = Application.get_env(:fermix_core, :personalization, [])
    agent = Application.get_env(:fermix_core, :agent, [])
    memory = Application.get_env(:fermix_core, :memory, [])
    fermix_home = System.get_env("FERMIX_HOME")

    on_exit(fn ->
      restore(:fermix_core, :providers, providers)
      restore(:fermix_channels, :telegram, telegram)
      Application.put_env(:fermix_core, :personalization, personalization)
      Application.put_env(:fermix_core, :agent, agent)
      Application.put_env(:fermix_core, :memory, memory)
      restart_global_memory_repo!()

      case fermix_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
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

  defp prepare(home) do
    System.put_env("FERMIX_HOME", home)
    File.mkdir_p!(home)

    Application.put_env(:fermix_core, :providers, openai: [])

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
    :ok = ConfigStore.save_snapshot(baseline_snapshot())
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

  defp puts_collector do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    fun = fn line -> Agent.update(agent, fn acc -> [line | acc] end) end
    {fun, agent}
  end

  defp puts_lines(agent), do: agent |> Agent.get(& &1) |> Enum.reverse()

  describe "finalize probe wiring" do
    test "skip_probe: true bypasses the probe entirely" do
      home = tmp_home()
      on_exit(fn -> File.rm_rf!(home) end)
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
      on_exit(fn -> File.rm_rf!(home) end)
      prepare(home)

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
      on_exit(fn -> File.rm_rf!(home) end)
      prepare(home)

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
      on_exit(fn -> File.rm_rf!(home) end)
      prepare(home)

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

  describe "--import-codex" do
    test "imports tokens, persists to fermix store, and marks openai oauth-configured" do
      home = tmp_home()
      on_exit(fn -> File.rm_rf!(home) end)

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
      assert data["providers"]["openai"]["tokens"]["access_token"] == "imported_at"

      providers = Application.get_env(:fermix_core, :providers, [])
      assert Keyword.get(providers[:openai], :auth_mode) == :oauth

      lines = puts_lines(collector)
      assert Enum.any?(lines, &String.contains?(&1, "Imported OpenAI tokens"))
    end

    test "surfaces an error when refresh fails" do
      home = tmp_home()
      on_exit(fn -> File.rm_rf!(home) end)

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
end
