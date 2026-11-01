defmodule FermixCore.Home.Provision.Registry do
  @moduledoc """
  The cloud providers Always On creates a server on (M75 lean v1 §4.3), each
  a module of the `FermixCore.Home.Provision` contract, in the order the
  apps offer them: the first is the one Always On speaks of while none holds
  a token or a server (`Provision.current/2`). A new provider is one module
  and one entry here; the summary then offers its token screen
  (`detail.providers`), and every surface draws it with no change of its
  own.
  """

  @providers [FermixCore.Home.Provision.Hetzner]

  @doc "Every provider, in the order the apps offer them."
  @spec all() :: [module(), ...]
  def all, do: @providers
end
