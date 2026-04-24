defmodule FermixCore.Prompt.BootstrapLoader do
  @moduledoc """
  Loads static prompt bootstrap files for an agent.

  Missing or empty `AGENTS.md` falls back to the embedded default. Missing or
  empty `SOUL.md` is omitted because that layer is optional.
  """

  alias FermixCore.Prompt.BootstrapFile
  alias FermixCore.Prompt.Seeder

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
        {:ok, BootstrapFile.metadata(:agents, path, content, :present)}

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
      {:ok, content} -> {:ok, BootstrapFile.metadata(:soul, path, content, :present)}
      {:missing, _reason} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp seed_failed(agent_id, reason) do
    Logger.warning("prompt bootstrap seed failed for #{agent_id}: #{inspect(reason)}")
    {:seed_failed, reason}
  end
end
