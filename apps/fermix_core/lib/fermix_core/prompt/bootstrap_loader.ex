defmodule FermixCore.Prompt.BootstrapLoader do
  @moduledoc """
  Loads static prompt bootstrap files for an agent.

  Missing or empty `AGENTS.md` falls back to the embedded default. Missing or
  empty `SOUL.md` is omitted because that layer is optional.
  """

  alias FermixCore.Prompt.BootstrapFile
  alias FermixCore.Prompt.Seeder
  alias FermixCore.Resource.Registry

  require Logger

  @type bootstrap_file :: %{
          name: :agents | :soul,
          path: String.t(),
          content: String.t(),
          approx_size: non_neg_integer(),
          approx_tokens: non_neg_integer(),
          status: :present | :fallback
        }

  @type bootstrap_prompt :: %{
          agents: bootstrap_file(),
          soul: bootstrap_file() | nil
        }

  @spec load(String.t(), keyword()) :: {:ok, bootstrap_prompt()} | {:error, term()}
  def load(agent_id, opts \\ []) when is_binary(agent_id) and is_list(opts) do
    with :ok <- Seeder.validate_agent_id(agent_id) do
      load_seeded(agent_id, opts, maybe_seed(agent_id, opts))
    end
  end

  defp load_seeded(agent_id, opts, seed_status) do
    with {:ok, agents} <- load_agents(agent_id, opts, seed_status),
         {:ok, soul} <- load_soul(agent_id, opts, seed_status) do
      {:ok, %{agents: agents, soul: soul}}
    end
  end

  defp maybe_seed(agent_id, opts) do
    if Seeder.seed_agent_file?(opts) do
      case Seeder.ensure_seeded(agent_id, opts) do
        {:ok, _result} -> :ok
        {:error, reason} -> seed_failed(agent_id, reason)
      end
    else
      :ok
    end
  end

  defp load_agents(agent_id, opts, {:seed_failed, _reason}) do
    path = Seeder.agents_path(agent_id, opts)
    {:ok, BootstrapFile.metadata(:agents, path, Seeder.default_agents_content(), :fallback)}
  end

  defp load_agents(agent_id, opts, :ok) do
    path = Seeder.agents_path(agent_id, opts)

    case BootstrapFile.read_present(path) do
      {:ok, content} ->
        file = BootstrapFile.metadata(:agents, path, content, :present)
        capture_bootstrap_revision(agent_id, :agents_md, file, opts)
        {:ok, file}

      {:missing, _reason} ->
        {:ok, BootstrapFile.metadata(:agents, path, Seeder.default_agents_content(), :fallback)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_soul(_agent_id, _opts, {:seed_failed, _reason}) do
    {:ok, nil}
  end

  defp load_soul(agent_id, opts, :ok) do
    path = Seeder.soul_path(agent_id, opts)

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

  defp seed_failed(agent_id, reason) do
    Logger.warning("prompt bootstrap seed failed for #{agent_id}: #{inspect(reason)}")
    {:seed_failed, reason}
  end
end
