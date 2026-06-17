defmodule FermixTestSupport.DistFetcherStub do
  @moduledoc """
  Test `Fetcher`: serves preconfigured results per URL from a named ETS table,
  so install tests never touch the network. Unknown URLs fail loud (no silent
  empty download). Mirror of the MCP `StubCaller` pattern.

  Usage:

      DistFetcherStub.init()
      DistFetcherStub.set("https://…/p.tar.gz", {:copy, fixture_path})
      DistFetcherStub.set("https://…/missing", {:error, :not_found})
  """

  @behaviour FermixCore.Plugins.Dist.Fetcher

  @table :dist_fetcher_stub

  def init do
    reset()
    :ets.new(@table, [:named_table, :public, :set])
    :ok
  end

  def cleanup do
    case :ets.whereis(@table) do
      :undefined -> :ok
      tid -> :ets.delete(tid)
    end
  end

  defp reset, do: cleanup()

  @doc "Configure the result for `url`: `{:copy, src_path}` | `:ok` | `{:error, reason}`."
  def set(url, result) when is_binary(url) do
    :ets.insert(@table, {url, result})
    :ok
  end

  @impl true
  def fetch(url, dest) when is_binary(url) and is_binary(dest) do
    case :ets.lookup(@table, url) do
      [{_, {:copy, src}}] -> File.cp(src, dest)
      [{_, :ok}] -> :ok
      [{_, {:error, _} = error}] -> error
      [] -> {:error, {:no_stub, url}}
    end
  end
end
