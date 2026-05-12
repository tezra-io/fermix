defmodule FermixCore.Prompt.BootstrapPaths do
  @moduledoc """
  Path helpers and agent-id validation for bootstrap prompt files.

  Owns the `~/.fermix/bootstrap/<agent_id>/<FILE>.md` path layout and the
  agent-id pattern guard.
  """

  alias FermixCore.Setup.ConfigStore

  @agent_id_pattern ~r/\A[A-Za-z0-9_-]+\z/

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

  @spec identity_path(String.t(), keyword()) :: String.t()
  def identity_path(agent_id, opts \\ []) when is_binary(agent_id) and is_list(opts) do
    Path.join(agent_dir(agent_id, opts), "IDENTITY.md")
  end

  @spec agents_path(String.t(), keyword()) :: String.t()
  def agents_path(agent_id, opts \\ []) when is_binary(agent_id) and is_list(opts) do
    Path.join(agent_dir(agent_id, opts), "AGENTS.md")
  end

  @spec soul_path(String.t(), keyword()) :: String.t()
  def soul_path(agent_id, opts \\ []) when is_binary(agent_id) and is_list(opts) do
    Path.join(agent_dir(agent_id, opts), "SOUL.md")
  end

  @spec realtime_path(String.t(), keyword()) :: String.t()
  def realtime_path(agent_id, opts \\ []) when is_binary(agent_id) and is_list(opts) do
    Path.join(agent_dir(agent_id, opts), "REALTIME.md")
  end

  @spec validate_agent_id(String.t()) :: :ok | {:error, {:invalid_agent_id, String.t()}}
  def validate_agent_id(agent_id) when is_binary(agent_id) do
    if Regex.match?(@agent_id_pattern, agent_id) do
      :ok
    else
      {:error, {:invalid_agent_id, agent_id}}
    end
  end

  defp validate_agent_id!(agent_id) do
    case validate_agent_id(agent_id) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "invalid agent_id: #{inspect(reason)}"
    end
  end

  defp prompt_bootstrap_config do
    Application.get_env(:fermix_core, :prompt_bootstrap, [])
  end
end
