defmodule FermixCore.Management.PrimaryPromotionTest do
  @moduledoc """
  One mechanism for "the first provider you connect is the one Fermix calls",
  shared by both setup doors (M34 native setup §7.3, MULTI_PROVIDER_FAILOVER §2).

  The browser door has promoted the first configured provider since M12, inside
  `save_answers/2`. The management door reached `config.toml` through other
  tails and skipped it, so on a fresh home `agent.provider` stayed on the
  compiled-in `:openai` default: readiness gates on the PRIMARY alone, so an
  operator who signed in with ChatGPT or typed an Anthropic key was told to
  connect a provider they had just connected.

  Every case runs against its own home and its own application environment,
  established here and restored in `on_exit`.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Auth.Store
  alias FermixCore.Management.Auth
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.Secrets
  alias FermixCore.Management.SetupState
  alias FermixCore.Providers.PrimaryConfig
  alias FermixCore.Setup.RestartState
  alias FermixTestSupport.SafeRm

  @env_keys [:providers, :agent, :personalization, :routing]

  @codex_entry %{
    auth_mode: "chatgpt",
    tokens: %{access_token: "at", refresh_token: "rt"},
    expires_at: nil,
    last_refresh: nil,
    account: %{email: "owner@example.com"}
  }

  setup context do
    home = System.get_env("FERMIX_HOME")
    core = Map.new(@env_keys, fn key -> {key, Application.get_env(:fermix_core, key)} end)
    secret_writer = Application.get_env(:fermix_core, :secret_writer)

    Application.put_env(:fermix_core, :secret_writer, FermixTestSupport.SecretWriterStub)
    FermixTestSupport.SecretWriterStub.reset()

    tmp = SafeRm.make_tmp_dir!("primary_promotion_home")
    System.put_env("FERMIX_HOME", tmp)

    # A fresh install: no provider block, no chosen primary, and the daemon has
    # read the (absent) file, which is what the write baseline means.
    Application.put_env(:fermix_core, :providers, [])
    Application.put_env(:fermix_core, :agent, [])

    # Personalization is left unset on purpose: it is the OTHER gating
    # component, and leaving it failing keeps the write tail out of prompt-file
    # seeding, which needs the memory repo. Every assertion here is about the
    # provider gate, which is the one an operator can clear by connecting.
    Application.put_env(:fermix_core, :personalization, [])
    :ok = RestartState.record_persisted_baseline()

    tasks = :"promotion_tasks_#{:erlang.phash2(context.test)}"
    start_supervised!({Task.Supervisor, name: tasks}, id: tasks)

    jobs =
      start_supervised!(
        {Jobs, name: :"promotion_jobs_#{:erlang.phash2(context.test)}", task_supervisor: tasks}
      )

    on_exit(fn ->
      Enum.each(core, fn {key, value} -> restore(:fermix_core, key, value) end)
      restore(:fermix_core, :secret_writer, secret_writer)
      FermixTestSupport.SecretWriterStub.reset()

      case home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      SafeRm.rm_rf!(tmp)
    end)

    %{home: tmp, jobs: [server: jobs]}
  end

  test "a key through secret.set makes its provider primary and clears the gate" do
    assert {:ok, _result} = Secrets.set("anthropic_api_key", "sk-ant-live")

    assert PrimaryConfig.primary() == {:ok, :anthropic}

    report = SetupState.report()
    assert provider_failures(report) == []

    assert %{"id" => "anthropic", "primary" => true, "configured" => true} =
             Enum.find(report["providers"], &(&1["id"] == "anthropic"))
  end

  test "a completed sign-in makes its provider primary", %{home: home, jobs: jobs} do
    :ok = Store.write("openai_codex", @codex_entry, Path.join(home, "auth.json"))

    assert {:ok, view} =
             Auth.start("openai_codex",
               jobs: jobs,
               login: fn _opts -> {:ok, @codex_entry} end,
               reload: fn -> :ok end
             )

    assert view["status"] == "completed"
    assert PrimaryConfig.primary() == {:ok, :openai_codex}
    assert provider_failures(SetupState.report()) == []
  end

  test "an adopted sign-in makes its provider primary", %{home: home, jobs: jobs} do
    :ok = Store.write("openai_codex", @codex_entry, Path.join(home, "auth.json"))

    assert {:ok, view} =
             Auth.import_start("codex_cli",
               jobs: jobs,
               importer: fn -> {:ok, @codex_entry} end
             )

    assert await_completed(view, jobs)["status"] == "completed"
    assert PrimaryConfig.primary() == {:ok, :openai_codex}
  end

  # After the first one, promotion is the explicit "Set primary" action. A
  # second key must not silently move the route the operator is already using.
  test "a second key leaves the established primary alone" do
    assert {:ok, _first} = Secrets.set("anthropic_api_key", "sk-ant-live")
    assert {:ok, _second} = Secrets.set("openai_api_key", "sk-openai-live")

    assert PrimaryConfig.primary() == {:ok, :anthropic}
  end

  # A key that belongs to no provider block is not a provider decision.
  test "a tool key promotes nothing" do
    assert {:ok, _result} = Secrets.set("tavily_api_key", "tvly-live")

    assert PrimaryConfig.primary() == {:ok, :openai}

    assert [%{"detail_key" => "provider:missing_credentials:openai"}] =
             provider_failures(SetupState.report())
  end

  defp provider_failures(report) do
    Enum.filter(
      report["readiness"]["failures"],
      &String.starts_with?(&1["component"], "provider")
    )
  end

  defp await_completed(view, jobs), do: await_completed(view, jobs, 50)

  defp await_completed(view, _jobs, 0), do: view

  defp await_completed(%{"status" => status} = view, _jobs, _left)
       when status in ["completed", "failed", "timed_out", "cancelled"],
       do: view

  defp await_completed(view, jobs, attempts_left) do
    Process.sleep(10)
    {:ok, polled} = Jobs.get(view["job_id"], jobs)
    await_completed(polled, jobs, attempts_left - 1)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
