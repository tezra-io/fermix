defmodule FermixCore.Memory.Config do
  @moduledoc """
  Typed accessors for durable memory runtime configuration.
  """

  @type options :: keyword()
  @type repo_server :: pid() | atom()

  @prompt_base_dir "~/.fermix/memory"
  @prompt_user_token_cap 800
  @prompt_memory_token_cap 1600

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

  @spec prompt_base_dir(options()) :: String.t()
  def prompt_base_dir(opts \\ []) do
    opts
    |> Keyword.get(
      :prompt_base_dir,
      Keyword.get(memory_config(), :prompt_base_dir, @prompt_base_dir)
    )
    |> Path.expand()
  end

  @spec prompt_user_token_cap(options()) :: pos_integer()
  def prompt_user_token_cap(opts \\ []) do
    opts
    |> Keyword.get(
      :prompt_user_token_cap,
      Keyword.get(memory_config(), :prompt_user_token_cap, @prompt_user_token_cap)
    )
    |> normalize_positive_integer!(:prompt_user_token_cap)
  end

  @spec prompt_memory_token_cap(options()) :: pos_integer()
  def prompt_memory_token_cap(opts \\ []) do
    opts
    |> Keyword.get(
      :prompt_memory_token_cap,
      Keyword.get(memory_config(), :prompt_memory_token_cap, @prompt_memory_token_cap)
    )
    |> normalize_positive_integer!(:prompt_memory_token_cap)
  end

  @spec repo_server(options()) :: repo_server()
  def repo_server(opts \\ []) do
    Keyword.get(opts, :repo, Keyword.get(memory_config(), :repo, FermixCore.Memory.Repo))
  end

  defp memory_config do
    Application.get_env(:fermix_core, :memory, [])
  end

  defp normalize_database_path(":memory"), do: ":memory:"
  defp normalize_database_path(":memory:"), do: ":memory:"
  defp normalize_database_path(path), do: Path.expand(path)

  defp normalize_positive_integer!(value, _key) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer!(value, key) do
    raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(value)}"
  end
end
