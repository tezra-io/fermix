defmodule FermixCore.Jobs.SignInConfirm do
  @moduledoc """
  The owner's setting for the question about a job that signs in to websites
  (`Capabilities.AccessGate.confirm_sign_in_job/4`): `[fermix_core.jobs]
  confirm_sign_in_jobs` in `config.toml`. Absent is true, so the question is
  asked; the owner's Always allow turns it off for every job from then on
  (`stop_asking/1`).
  """

  alias FermixCore.Setup.ConfigStore

  @doc """
  Whether a set-up or a task change of such a job asks the owner. Read from
  the context's `:jobs_config` when a caller hands one in (a test), else from
  the application's jobs settings. A value other than true or false raises.
  """
  @spec asks?(map()) :: boolean()
  def asks?(context) when is_map(context) do
    config =
      Map.get_lazy(context, :jobs_config, fn -> Application.get_env(:fermix_core, :jobs, []) end)

    case Keyword.get(config, :confirm_sign_in_jobs, true) do
      asks when is_boolean(asks) -> asks
    end
  end

  @doc """
  Turn the question off: write `confirm_sign_in_jobs = false` into the home's
  `config.toml` and apply it to what runs, as every runtime settings writer
  does (`Sandbox.ConfigMutation.persist/2`). `opts`: `:supervised`, handed to
  the settings store.
  """
  @spec stop_asking(keyword()) :: :ok | {:error, term()}
  def stop_asking(opts \\ []) when is_list(opts) do
    supervised = Keyword.take(opts, [:supervised])

    with {:ok, snapshot} <- ConfigStore.load_runtime_config(supervised),
         updated = Map.update!(snapshot, :fermix_core, &without_question/1),
         :ok <- ConfigStore.save_snapshot(updated, supervised) do
      ConfigStore.apply_snapshot(updated, supervised)
    end
  end

  defp without_question(fermix_core) do
    jobs = fermix_core |> Keyword.get(:jobs, []) |> Keyword.put(:confirm_sign_in_jobs, false)
    Keyword.put(fermix_core, :jobs, jobs)
  end
end
