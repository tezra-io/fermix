defmodule FermixCore.Home.Snapshot.Settings do
  @moduledoc """
  The writers of `[fermix_core.snapshots]`: the settings door's `snapshots`
  section (`Management.Settings.Snapshots`) and the recovery passphrase
  (`home.snapshots.passphrase`). Both take the path every save takes
  (`Wizard.commit_snapshot/2`: the external-change refusal, the secret
  securing, the apply), and both tell the scheduler to plan again
  (`Snapshot.Scheduler.config_changed/1`), so a section that turns snapshots on
  runs its first one without a restart.

  A value the section refuses raises `ArgumentError` with the sentence
  `Snapshot.Config` writes, which the settings write shows under the control
  that sent it.
  """

  alias FermixCore.Home.Snapshot.Config
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Home.Snapshot.Scheduler
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.Wizard

  @answers [:interval_hours, :s3_bucket, :s3_region, :s3_prefix, :s3_endpoint]

  @doc "The settings door's keys this writer takes."
  @spec answers() :: [atom()]
  def answers, do: @answers

  @doc "Writes the changed keys of one `settings.apply` of the section."
  @spec save(keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  def save(answers, opts \\ []) when is_list(answers) and is_list(opts) do
    unknown = Keyword.keys(answers) -- @answers

    if unknown != [] do
      raise ArgumentError, "unknown snapshot setting(s): #{inspect(unknown)}"
    end

    commit(fn section -> Keyword.merge(section, answers) end, opts)
  end

  @doc """
  Keeps the public half of `recipient` as the section's `recipient`, the one
  the next snapshot is encrypted to. The private half and the passphrase it
  came from are never written.
  """
  @spec put_recipient(Recipient.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def put_recipient(recipient, opts \\ []) when is_map(recipient) and is_list(opts) do
    text = Recipient.encode(recipient)
    commit(&Keyword.put(&1, :recipient, text), opts)
  end

  defp commit(change, opts) do
    snapshot = ConfigStore.current_snapshot()
    section = snapshot.fermix_core |> Keyword.get(:snapshots, []) |> Config.normalize()
    changed = section |> change.() |> Config.normalize()
    core = Keyword.put(snapshot.fermix_core, :snapshots, changed)

    with {:ok, _report} <- Wizard.commit_snapshot(%{snapshot | fermix_core: core}) do
      Scheduler.config_changed(Keyword.get(opts, :scheduler, Scheduler))
      {:ok, %{}}
    end
  end
end
