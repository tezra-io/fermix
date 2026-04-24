defmodule FermixCore.Prompt.Seeder do
  @moduledoc """
  Seeds file-backed prompt bootstrap resources for an agent.

  `AGENTS.md` gets a default operating prompt on first access. `SOUL.md` is
  intentionally optional and is not created by default.
  """

  alias FermixCore.Setup.ConfigStore

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
    with {:ok, agents} <- ensure_agents(agent_id, opts) do
      {:ok, %{agents: agents, soul: nil}}
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

    case read_present(path) do
      {:ok, content} -> {:ok, metadata(:agents, path, content, :present)}
      {:missing, _reason} -> maybe_write_agents(path, opts)
      {:error, reason} -> {:error, reason}
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

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, content) do
      {:ok, metadata(:agents, path, content, :seeded)}
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

  defp prompt_bootstrap_config do
    Application.get_env(:fermix_core, :prompt_bootstrap, [])
  end
end
