defmodule FermixCore.Prompt.BootstrapLoader do
  @moduledoc """
  Loads static prompt bootstrap files for an agent.

  Missing or empty `IDENTITY.md` and `FERMIX.md` fall back to rendered
  template content from `Prompt.Defaults` (in-memory only, never written
  to disk). Missing or empty `SOUL.md` is omitted because that layer is
  optional. Setup-time seeding (`Prompt.SetupSeeder`) is the only path
  that writes these files.

  Every load records the file in `Resource.Registry`. A file whose bytes the
  registry does not already hold changed outside every reviewed writer, so its
  revision is recorded as `unreviewed_edit` rather than attributed to anyone.
  For `SOUL.md`, the one file with an owner review path (`/soul`), the
  `:unreviewed_edit_notifier` opt (default
  `SoulCuration.UnreviewedEditNotice.notify/1`) is called once with the new
  revision.
  """

  alias FermixCore.Prompt.BootstrapFile
  alias FermixCore.Prompt.BootstrapPaths
  alias FermixCore.Prompt.Defaults
  alias FermixCore.Resource.Registry
  alias FermixCore.Resource.Revision
  alias FermixCore.SoulCuration.UnreviewedEditNotice

  require Logger

  @type bootstrap_file :: BootstrapFile.t()

  @type bootstrap_prompt :: %{
          identity: bootstrap_file(),
          fermix: bootstrap_file(),
          soul: bootstrap_file() | nil,
          realtime: bootstrap_file() | nil
        }

  @spec load(String.t(), keyword()) :: {:ok, bootstrap_prompt()} | {:error, term()}
  def load(agent_id, opts \\ []) when is_binary(agent_id) and is_list(opts) do
    with :ok <- BootstrapPaths.validate_agent_id(agent_id),
         {:ok, identity} <- load_identity(agent_id, opts),
         {:ok, fermix} <- load_fermix(agent_id, opts),
         {:ok, soul} <- load_soul(agent_id, opts),
         {:ok, realtime} <- load_realtime(agent_id, opts) do
      {:ok, %{identity: identity, fermix: fermix, soul: soul, realtime: realtime}}
    end
  end

  @doc """
  Load `LIVE.md`, the Live voice frontend's own prompt (M41 §6.1).

  Deliberately outside `load/2`'s map and not a `PromptComposer` part: LIVE.md
  instructs the voice frontend that delegates to Core, so a Core text prompt
  carrying it would tell the agent it is the frontend. `Realtime.LivePrompt`
  is the only caller. Missing or empty falls back to the shipped template
  (in memory only — the seeder is still the only writer).
  """
  @spec load_live(String.t(), keyword()) :: {:ok, bootstrap_file()} | {:error, term()}
  def load_live(agent_id, opts \\ []) when is_binary(agent_id) and is_list(opts) do
    with :ok <- BootstrapPaths.validate_agent_id(agent_id) do
      do_load_live(agent_id, opts)
    end
  end

  defp do_load_live(agent_id, opts) do
    path = BootstrapPaths.live_path(agent_id, opts)

    case BootstrapFile.read_present(path) do
      {:ok, content} ->
        file = BootstrapFile.metadata(:live, path, content, :present)
        capture_bootstrap_revision(agent_id, :live_md, file, opts)
        {:ok, file}

      {:missing, _reason} ->
        {:ok, BootstrapFile.metadata(:live, path, Defaults.live_md(), :fallback)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_identity(agent_id, opts) do
    path = BootstrapPaths.identity_path(agent_id, opts)

    case BootstrapFile.read_present(path) do
      {:ok, content} ->
        file = BootstrapFile.metadata(:identity, path, content, :present)
        capture_bootstrap_revision(agent_id, :identity_md, file, opts)
        {:ok, file}

      {:missing, _reason} ->
        {:ok, BootstrapFile.metadata(:identity, path, Defaults.identity_md(), :fallback)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_fermix(agent_id, opts) do
    path = BootstrapPaths.fermix_path(agent_id, opts)

    case BootstrapFile.read_present(path) do
      {:ok, content} ->
        file = BootstrapFile.metadata(:fermix, path, content, :present)
        capture_bootstrap_revision(agent_id, :fermix_md, file, opts)
        {:ok, file}

      {:missing, _reason} ->
        {:ok, BootstrapFile.metadata(:fermix, path, Defaults.fermix_md(), :fallback)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_soul(agent_id, opts) do
    path = BootstrapPaths.soul_path(agent_id, opts)

    case BootstrapFile.read_present(path) do
      {:ok, content} ->
        file = BootstrapFile.metadata(:soul, path, content, :present)
        capture_bootstrap_revision(agent_id, :soul_md, file, opts)
        {:ok, file}

      {:missing, _reason} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_realtime(agent_id, opts) do
    if Keyword.get(opts, :realtime?, false) do
      do_load_realtime(agent_id, opts)
    else
      {:ok, nil}
    end
  end

  defp do_load_realtime(agent_id, opts) do
    path = BootstrapPaths.realtime_path(agent_id, opts)

    case BootstrapFile.read_present(path) do
      {:ok, content} ->
        file = BootstrapFile.metadata(:realtime, path, content, :present)
        capture_bootstrap_revision(agent_id, :realtime_md, file, opts)
        {:ok, file}

      {:missing, _reason} ->
        {:ok, BootstrapFile.metadata(:realtime, path, Defaults.realtime_md(), :fallback)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp capture_bootstrap_revision(agent_id, resource_type, file, opts) do
    commit_opts =
      [
        mutation_source: nil,
        provenance: nil,
        resource_path: file.path
      ]
      |> Keyword.merge(registry_opts(opts))

    with {:ok, source} <- bootstrap_mutation_source(agent_id, resource_type, opts),
         {:ok, revision_or_unchanged} <-
           Registry.commit(
             agent_id,
             resource_type,
             "global",
             file.content,
             Keyword.merge(commit_opts,
               mutation_source: source,
               provenance: bootstrap_provenance(source)
             )
           ) do
      notify_unreviewed_soul(resource_type, revision_or_unchanged, file, opts)
    else
      {:error, :disabled} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "prompt bootstrap revision capture failed for #{file.path}: #{inspect(reason)}"
        )

        :ok
    end
  end

  # Only a new unreviewed SOUL.md revision tells the owner: `/soul revert` is the
  # undo it can point at. The registry dedupes identical bytes, so one edit is
  # one notice however many prompt builds see it.
  defp notify_unreviewed_soul(
         :soul_md,
         %Revision{mutation_source: "unreviewed_edit"} = revision,
         file,
         opts
       ) do
    notifier = Keyword.get(opts, :unreviewed_edit_notifier, &UnreviewedEditNotice.notify/1)
    :ok = notifier.(%{path: file.path, revision: revision.revision})
  end

  defp notify_unreviewed_soul(_resource_type, _revision_or_unchanged, _file, _opts), do: :ok

  # A registry that already tracks the file but not these bytes means the file
  # changed outside every writer that records its change (setup, template
  # adoption, `/soul`). Who changed it is unknown, so it is not called an
  # operator edit.
  defp bootstrap_mutation_source(agent_id, resource_type, opts) do
    case Registry.current_hash(agent_id, resource_type, "global", registry_opts(opts)) do
      {:ok, _hash} -> {:ok, :unreviewed_edit}
      {:error, :not_found} -> {:ok, :imported}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bootstrap_provenance(:imported) do
    %{trigger: "imported", description: "Pre-existing bootstrap file imported on load"}
  end

  defp bootstrap_provenance(:unreviewed_edit) do
    %{
      trigger: "unreviewed_edit",
      description: "Bootstrap file changed on disk outside setup, template adoption and /soul"
    }
  end

  defp registry_opts(opts) do
    opts
    |> Keyword.take([:repo, :server])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
