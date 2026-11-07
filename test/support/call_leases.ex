defmodule FermixTestSupport.CallLeases do
  @moduledoc """
  A call lease of its own for a voice session a test starts.

  Every engine session takes the home's one call lease from its `init/1`
  (`FermixCore.Realtime.CallLease`), and no realtime tree runs under
  `mix test`. A test whose sessions must not compete for one call gives each
  its own lease; a test of the one-call rule shares one between them.
  """

  alias FermixCore.Realtime.CallLease

  @doc "Starts a lease under the calling test's supervisor and answers its name."
  @spec own!() :: atom()
  def own! do
    name = :"call_lease_#{System.unique_integer([:positive])}"
    ExUnit.Callbacks.start_supervised!({CallLease, name: name}, id: name)
    name
  end
end
