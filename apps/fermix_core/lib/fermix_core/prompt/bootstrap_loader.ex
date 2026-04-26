defmodule FermixCore.Prompt.BootstrapLoader do
  @moduledoc """
  Loads static prompt bootstrap files for an agent.

  Missing or empty `IDENTITY.md` and `AGENTS.md` fall back to rendered
  template content from `Prompt.Defaults` (in-memory only, never written
  to disk). Missing or empty `SOUL.md` is omitted because that layer is
  optional. Setup-time seeding (`Prompt.SetupSeeder`) is the only path
  that writes these files.
  """

  alias FermixCore.Prompt.BootstrapFile
  alias FermixCore.Prompt.BootstrapPaths
  alias FermixCore.Prompt.Defaults
  alias FermixCore.Resource.Registry

  require Logger

  @type bootstrap_file :: BootstrapFile.t()

  @type bootstrap_prompt :: %{
          identity: bootstrap_file(),
          agents: bootstrap_file(),
          soul: bootstrap_file() | nil
        }

  @spec load(String.t(), keyword()) :: {:ok, bootstrap_prompt()} | {:error, term()}
  def load(agent_id, opts \\ []) when is_binary(agent_id) and is_list(opts) do
    with :ok <- BootstrapPaths.validate_agent_id(agent_id),
         {:ok, identity} <- load_identity(agent_id, opts),
         {:ok, agents} <- load_agents(agent_id, opts),
         {:ok, soul} <- load_soul(agent_id, opts) do
      {:ok, %{identity: identity, agents: agents, soul: soul}}
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

  defp load_agents(agent_id, opts) do
    path = BootstrapPaths.agents_path(agent_id, opts)

    case BootstrapFile.read_present(path) do
      {:ok, content} ->
        file = BootstrapFile.metadata(:agents, path, content, :present)
        capture_bootstrap_revision(agent_id, :agents_md, file, opts)
        {:ok, file}

      {:missing, _reason} ->
        {:ok, BootstrapFile.metadata(:agents, path, Defaults.agents_md(), :fallback)}

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

  defp capture_bootstrap_revision(agent_id, resource_type, file, opts) do
    commit_opts =
      [
        mutation_source: nil,
        provenance: nil,
        resource_path: file.path
      ]
      |> Keyword.merge(registry_opts(opts))

    with {:ok, source} <- bootstrap_mutation_source(agent_id, resource_type, opts),
         {:ok, _revision_or_unchanged} <-
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
      :ok
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

  defp bootstrap_mutation_source(agent_id, resource_type, opts) do
    case Registry.current_hash(agent_id, resource_type, "global", registry_opts(opts)) do
      {:ok, _hash} -> {:ok, :manual_edit}
      {:error, :not_found} -> {:ok, :imported}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bootstrap_provenance(:imported) do
    %{trigger: "imported", description: "Pre-existing bootstrap file imported on load"}
  end

  defp bootstrap_provenance(:manual_edit) do
    %{trigger: "manual_edit", description: "Operator edited bootstrap file directly"}
  end

  defp registry_opts(opts) do
    opts
    |> Keyword.take([:repo, :server])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
