defmodule FermixWebWeb.HomeSnapshot do
  @moduledoc """
  Initial dashboard snapshot for the web home page.
  """

  alias FermixCore.Introspection.Agents
  alias FermixCore.Introspection.Jobs
  alias FermixCore.Introspection.Overview

  @spec snapshot() :: {:ok, map()} | {:error, term()}
  def snapshot do
    with {:ok, overview} <- Overview.snapshot(),
         {:ok, agents} <- Agents.snapshot(),
         {:ok, jobs} <- Jobs.snapshot() do
      {:ok, %{overview: overview, agents: agents, jobs: jobs}}
    end
  end
end
