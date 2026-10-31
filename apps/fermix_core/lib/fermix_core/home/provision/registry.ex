defmodule FermixCore.Home.Provision.Registry do
  @moduledoc """
  The cloud providers Always On creates a server on (M75 lean v1 §4.3), each
  a module of the `FermixCore.Home.Provision` contract, in the order the
  apps offer them: the first is the one Always On speaks of while none holds
  a token or a server (`Provision.current/2`). A new provider is one module
  and one entry here; `home.provision.providers` then answers its display
  data, and the apps draw it with no change of their own.
  """

  @providers [FermixCore.Home.Provision.Hetzner]

  @doc "Every provider, in the order the apps offer them."
  @spec all() :: [module(), ...]
  def all, do: @providers
end
