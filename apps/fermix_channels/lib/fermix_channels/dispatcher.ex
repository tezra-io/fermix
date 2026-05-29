defmodule FermixChannels.Dispatcher do
  @moduledoc """
  Thin compatibility alias for `FermixChannels.Gateway.ingest/2`.

  Stage 7 collapsed the dispatcher into the gateway ingress facade. Production
  channel transports call `FermixChannels.Gateway.ingest/2` directly; this
  delegate keeps `Dispatcher.dispatch/2` working for existing callers and tests.
  """

  defdelegate dispatch(messages, opts), to: FermixChannels.Gateway, as: :ingest
end
