defmodule FermixChannels.Ingress.Authorization do
  @moduledoc """
  Resolved authorization for a `FermixChannels.Ingress.Source`. Always
  represents an authorized message — denial is signaled by the
  `{:error, reason}` tuple returned from
  `FermixChannels.Ingress.Authorizer.resolve/1`.

  See `docs/MESSAGE_GATEWAY_ARCHITECTURE.md` §9.2.
  """

  @enforce_keys [:role, :trust]
  defstruct [:role, :trust]

  @type role :: :operator | :guest
  @type trust :: nil | :operator | :guest

  @type t :: %__MODULE__{role: role(), trust: trust()}
end
