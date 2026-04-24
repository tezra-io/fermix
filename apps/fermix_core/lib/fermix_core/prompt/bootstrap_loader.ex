defmodule FermixCore.Prompt.BootstrapLoader do
  @moduledoc """
  Loads static prompt bootstrap files for an agent.

  Missing or empty `AGENTS.md` falls back to the embedded default. Missing or
  empty `SOUL.md` is omitted because that layer is optional.
  """

  alias FermixCore.Prompt.Seeder

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
    with :ok <- maybe_seed(agent_id, opts),
         {:ok, agents} <- load_agents(agent_id, opts),
         {:ok, soul} <- load_soul(agent_id, opts) do
      {:ok, %{agents: agents, soul: soul}}
    end
  end

  defp maybe_seed(agent_id, opts) do
    if Seeder.seed_agent_file?(opts) do
      case Seeder.ensure_seeded(agent_id, opts) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp load_agents(agent_id, opts) do
    path = Seeder.agents_path(agent_id, opts)

    case read_present(path) do
      {:ok, content} ->
        {:ok, metadata(:agents, path, content, :present)}

      {:missing, _reason} ->
        {:ok, metadata(:agents, path, Seeder.default_agents_content(), :fallback)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_soul(agent_id, opts) do
    path = Seeder.soul_path(agent_id, opts)

    case read_present(path) do
      {:ok, content} -> {:ok, metadata(:soul, path, content, :present)}
      {:missing, _reason} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_present(path) do
    case File.read(path) do
      {:ok, content} ->
        if String.trim(content) == "" do
          {:missing, :empty}
        else
          {:ok, content}
        end

      {:error, :enoent} ->
        {:missing, :enoent}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp metadata(name, path, content, status) do
    size = byte_size(content)

    %{
      name: name,
      path: path,
      content: content,
      approx_size: size,
      approx_tokens: estimated_tokens(content),
      status: status
    }
  end

  defp estimated_tokens(""), do: 0
  defp estimated_tokens(content), do: div(byte_size(content) + 3, 4)
end
