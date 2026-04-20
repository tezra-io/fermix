defmodule FermixCore.Memory.Config do
  @moduledoc """
  Typed accessors for durable memory runtime configuration.
  """

  @type options :: keyword()

  @spec enabled?(options()) :: boolean()
  def enabled?(opts \\ []) do
    Keyword.get(opts, :enabled, Keyword.get(memory_config(), :enabled, true))
  end

  @spec database_path(options()) :: String.t()
  def database_path(opts \\ []) do
    opts
    |> Keyword.get(
      :database_path,
      Keyword.get(memory_config(), :database_path, "~/.fermix/memory.db")
    )
    |> normalize_database_path()
  end

  @spec owner_id(options()) :: String.t()
  def owner_id(opts \\ []) do
    Keyword.get(opts, :owner_id, Keyword.get(memory_config(), :owner_id, "default"))
  end

  @spec agent_id(options()) :: String.t()
  def agent_id(opts \\ []) do
    Keyword.get(opts, :agent_id, Keyword.get(memory_config(), :agent_id, "main"))
  end

  defp memory_config do
    Application.get_env(:fermix_core, :memory, [])
  end

  defp normalize_database_path(":memory"), do: ":memory:"
  defp normalize_database_path(":memory:"), do: ":memory:"
  defp normalize_database_path(path), do: Path.expand(path)
end
