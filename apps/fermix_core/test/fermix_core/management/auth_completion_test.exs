defmodule FermixCore.Management.AuthCompletionTest do
  use ExUnit.Case, async: false

  alias FermixCore.Auth.Store
  alias FermixCore.Auth.TokenManager
  alias FermixCore.Management.Auth
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.Secrets
  alias FermixCore.Management.SetupState
  alias FermixCore.Providers.PrimaryConfig
  alias FermixCore.Setup.RestartState
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub

  @env_keys [:providers, :agent, :personalization, :routing, :secret_writer]

  setup context do
    previous_home = System.get_env("FERMIX_HOME")
    previous_env = Map.new(@env_keys, &{&1, Application.get_env(:fermix_core, &1)})
    home = SafeRm.make_tmp_dir!("auth_completion_home")
    System.put_env("FERMIX_HOME", home)
    Enum.each(@env_keys, &Application.put_env(:fermix_core, &1, []))
    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    SecretWriterStub.reset()
    :ok = RestartState.record_persisted_baseline()

    tasks = :"completion_tasks_#{:erlang.phash2(context.test)}"
    start_supervised!({Task.Supervisor, name: tasks}, id: tasks)

    jobs =
      start_supervised!(
        {Jobs, name: :"completion_jobs_#{:erlang.phash2(context.test)}", task_supervisor: tasks}
      )

    on_exit(fn ->
      Enum.each(previous_env, fn {key, value} -> restore_env(key, value) end)
      restore_home(previous_home)
      SecretWriterStub.reset()
      SafeRm.rm_rf!(home)
      :ok = RestartState.record_persisted_baseline()
    end)

    %{home: home, jobs: [server: jobs]}
  end

  test "a fresh Claude import selects OAuth, clears readiness and loads its empty manager", %{
    jobs: jobs
  } do
    manager = start_manager(:anthropic)
    assert {:error, :no_token} = TokenManager.get_token(manager)

    assert {:ok, view} =
             Auth.import_start("claude_code", jobs: jobs, importer: importer(:anthropic, "new"))

    assert terminal(view, jobs)["status"] == "completed"
    assert Application.get_env(:fermix_core, :providers)[:anthropic][:auth_mode] == :oauth
    assert PrimaryConfig.primary() == {:ok, :anthropic}
    assert {:ok, "new"} = TokenManager.get_token(manager)

    refute Enum.any?(SetupState.report()["readiness"]["failures"], fn failure ->
             String.starts_with?(failure["component"], "provider")
           end)
  end

  test "a refused Claude route write fails the import before promotion or reload", %{
    home: home,
    jobs: jobs
  } do
    manager = start_manager(:anthropic)

    File.write!(
      Path.join(home, "config.toml"),
      "[fermix_core.memory]\nreview_interval_hours = 12\n"
    )

    assert {:ok, view} =
             Auth.import_start("claude_code", jobs: jobs, importer: importer(:anthropic, "new"))

    done = terminal(view, jobs)
    assert done["status"] == "failed"
    assert done["failure"]["sentence"] =~ "sign-in route could not be changed"
    assert PrimaryConfig.primary() == {:ok, :openai}
    assert {:error, :no_token} = TokenManager.get_token(manager)
  end

  test "a Codex import loads an empty manager and reconnects after logout", %{jobs: jobs} do
    manager = start_manager(:openai_codex)
    assert {:error, :no_token} = TokenManager.get_token(manager)

    assert {:ok, first} =
             Auth.import_start("codex_cli",
               jobs: jobs,
               importer: importer(:openai_codex, "first")
             )

    assert terminal(first, jobs)["status"] == "completed"
    assert {:ok, "first"} = TokenManager.get_token(manager)
    assert {:ok, _view} = Auth.logout("openai_codex")
    assert {:error, _reason} = TokenManager.get_token(manager)

    assert {:ok, second} =
             Auth.import_start("codex_cli",
               jobs: jobs,
               importer: importer(:openai_codex, "second")
             )

    assert terminal(second, jobs)["status"] == "completed"
    assert {:ok, "second"} = TokenManager.get_token(manager)
  end

  test "xAI browser completion loads its empty manager and reconnects after logout", %{jobs: jobs} do
    manager = start_manager(:xai)
    assert {:error, :no_token} = TokenManager.get_token(manager)

    assert {:ok, first} = Auth.start("xai", jobs: jobs, login: login(:xai, "first"))
    assert first["status"] == "completed"
    assert {:ok, "first"} = TokenManager.get_token(manager)
    assert {:ok, _view} = Auth.logout("xai")
    assert {:error, _reason} = TokenManager.get_token(manager)

    assert {:ok, second} = Auth.start("xai", jobs: jobs, login: login(:xai, "second"))
    assert second["status"] == "completed"
    assert {:ok, "second"} = TokenManager.get_token(manager)
  end

  test "a Claude setup token loads an empty manager and replaces a forgotten token" do
    manager = start_manager(:anthropic)
    assert {:error, :no_token} = TokenManager.get_token(manager)

    assert {:ok, _view} = Secrets.set("anthropic_setup_token", "first")
    assert {:ok, "first"} = TokenManager.get_token(manager)
    assert {:ok, _view} = Secrets.clear("anthropic_setup_token")
    assert {:error, _reason} = TokenManager.get_token(manager)

    assert {:ok, _view} = Secrets.set("anthropic_setup_token", "second")
    assert {:ok, "second"} = TokenManager.get_token(manager)
  end

  test "a refused import reload fails the job before promotion", %{jobs: jobs} do
    assert {:ok, view} =
             Auth.import_start("codex_cli",
               jobs: jobs,
               importer: importer(:openai_codex, "new"),
               reload: fn -> {:error, :eacces} end
             )

    done = terminal(view, jobs)
    assert done["status"] == "failed"
    assert done["failure"]["sentence"] =~ "credentials were stored but could not be loaded"
    assert PrimaryConfig.primary() == {:ok, :openai}
  end

  test "a refused xAI reload fails the job before promotion", %{jobs: jobs} do
    assert {:ok, view} =
             Auth.start("xai",
               jobs: jobs,
               login: login(:xai, "new"),
               reload: fn -> {:error, :eacces} end
             )

    assert view["status"] == "failed"
    assert view["failure"]["sentence"] =~ "credentials were stored but could not be loaded"
    assert PrimaryConfig.primary() == {:ok, :openai}
  end

  defp start_manager(:openai_codex) do
    assert Process.whereis(TokenManager) == nil
    start_supervised!({TokenManager, name: TokenManager, fermix_auth_path: Store.path()})
  end

  defp start_manager(provider) do
    profile = Store.profile(provider)
    assert Registry.lookup(FermixCore.Auth.TokenRegistry, profile) == []

    start_supervised!(
      {TokenManager,
       name: {:via, Registry, {FermixCore.Auth.TokenRegistry, profile}},
       auth_profile: profile,
       fermix_auth_path: Store.path()}
    )
  end

  defp importer(provider, token) do
    fn ->
      entry = %{
        provider: Atom.to_string(provider),
        auth_mode: "oauth",
        tokens: %{access_token: token, refresh_token: "refresh"},
        expires_at: nil,
        last_refresh: nil
      }

      with :ok <- Store.write(Store.profile(provider), entry), do: {:ok, entry}
    end
  end

  defp login(provider, token), do: fn _opts -> importer(provider, token).() end

  defp terminal(view, jobs, attempts \\ 100)
  defp terminal(%{"status" => status} = view, _jobs, _left) when status != "running", do: view
  defp terminal(_view, _jobs, 0), do: flunk("authentication job did not finish")

  defp terminal(view, jobs, attempts) do
    Process.sleep(10)
    {:ok, next} = Jobs.get(view["job_id"], jobs)
    terminal(next, jobs, attempts - 1)
  end

  defp restore_env(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore_env(key, value), do: Application.put_env(:fermix_core, key, value)
  defp restore_home(nil), do: System.delete_env("FERMIX_HOME")
  defp restore_home(value), do: System.put_env("FERMIX_HOME", value)
end
