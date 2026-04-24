defmodule FermixCore.Prompt.Seeder do
  @moduledoc """
  Seeds file-backed prompt bootstrap resources for an agent.

  `AGENTS.md` gets a default operating prompt on first access. `SOUL.md` is
  intentionally optional and is not created by default.
  """

  alias FermixCore.Prompt.BootstrapFile
  alias FermixCore.Setup.ConfigStore

  @agent_id_pattern ~r/\A[A-Za-z0-9_-]+\z/

  @default_agents_content """
  You are a helpful AI assistant with access to tools.
  You can execute shell commands, read and write files, and store or recall memories.

  Use available tools when they are the right way to inspect state, change files, or perform an action.
  Use the `invoke_skill` tool when a specialized skill is a better fit than handling the work directly.
  Think step by step, keep changes focused, and report errors clearly.
  """

  @type bootstrap_file :: %{
          name: :agents | :soul,
          path: String.t(),
          content: String.t(),
          approx_size: non_neg_integer(),
          approx_tokens: non_neg_integer(),
          status: :present | :seeded
        }

  @type seed_result :: %{
          agents: bootstrap_file() | nil,
          soul: nil
        }

  @spec bootstrap_dir(keyword()) :: String.t()
  def bootstrap_dir(opts \\ []) when is_list(opts) do
    opts
    |> Keyword.get(
      :bootstrap_dir,
      Keyword.get(
        prompt_bootstrap_config(),
        :bootstrap_dir,
        ConfigStore.workspace_paths().bootstrap
      )
    )
    |> Path.expand()
  end

  @spec agent_dir(String.t(), keyword()) :: String.t()
  def agent_dir(agent_id, opts \\ []) when is_binary(agent_id) and is_list(opts) do
    validate_agent_id!(agent_id)
    Path.join(bootstrap_dir(opts), agent_id)
  end

  @spec agents_path(String.t(), keyword()) :: String.t()
  def agents_path(agent_id, opts \\ []) when is_binary(agent_id) and is_list(opts) do
    Path.join(agent_dir(agent_id, opts), "AGENTS.md")
  end

  @spec soul_path(String.t(), keyword()) :: String.t()
  def soul_path(agent_id, opts \\ []) when is_binary(agent_id) and is_list(opts) do
    Path.join(agent_dir(agent_id, opts), "SOUL.md")
  end

  @spec default_agents_content() :: String.t()
  def default_agents_content, do: String.trim(@default_agents_content)

  @spec ensure_seeded(String.t(), keyword()) :: {:ok, seed_result()} | {:error, term()}
  def ensure_seeded(agent_id, opts \\ []) when is_binary(agent_id) and is_list(opts) do
    with :ok <- validate_agent_id(agent_id),
         {:ok, agents} <- ensure_agents(agent_id, opts) do
      {:ok, %{agents: agents, soul: nil}}
    end
  end

  @spec validate_agent_id(String.t()) :: :ok | {:error, {:invalid_agent_id, String.t()}}
  def validate_agent_id(agent_id) when is_binary(agent_id) do
    if Regex.match?(@agent_id_pattern, agent_id) do
      :ok
    else
      {:error, {:invalid_agent_id, agent_id}}
    end
  end

  @spec seed_agent_file?(keyword()) :: boolean()
  def seed_agent_file?(opts \\ []) when is_list(opts) do
    Keyword.get(
      opts,
      :seed_agent_file,
      Keyword.get(prompt_bootstrap_config(), :seed_agent_file, true)
    )
  end

  defp ensure_agents(agent_id, opts) do
    path = agents_path(agent_id, opts)

    case BootstrapFile.read_present(path) do
      {:ok, content} -> {:ok, BootstrapFile.metadata(:agents, path, content, :present)}
      {:missing, _reason} -> maybe_write_agents(path, opts)
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  defp maybe_write_agents(path, opts) do
    if seed_agent_file?(opts) do
      write_agents(path)
    else
      {:ok, nil}
    end
  end

  defp write_agents(path) do
    content = default_agents_content()

    case File.mkdir_p(Path.dirname(path)) do
      :ok -> write_agents_file(path, content)
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  defp write_agents_file(path, content) do
    with :ok <- File.write(path, content) do
      {:ok, BootstrapFile.metadata(:agents, path, content, :seeded)}
    else
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  defp prompt_bootstrap_config do
    Application.get_env(:fermix_core, :prompt_bootstrap, [])
  end

  defp validate_agent_id!(agent_id) do
    case validate_agent_id(agent_id) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "invalid agent_id: #{inspect(reason)}"
    end
  end
end
