defmodule FermixCore.Computers.Transport do
  @moduledoc """
  How the server reaches a computer's session for an invocation (M97 §6.1):
  the channels side of the link, which core never compile-depends on, so it
  is injected by module (`config :fermix_core, :computers_transport`), as
  `FermixCore.Home.Link` is. `FermixChannels.Desktop.InvokeTransport` is
  the one implementation.

  A transport is `{module, opts}`: `impl/0` names the configured module
  with no options, and a test hands its own (its peers' registry).

  - `open/5` sends `invoke_open` (its header and args JSON) and then the
    part it announces, when there is one: `:ok` once all of it was handed
    to the session; `{:error, :not_connected}` when the computer has no
    session, before anything was sent; `{:error, {:part, reason}}` when the
    request went and its part did not (the computer answers `failed`);
    any other `{:error, reason}` when nothing was sent.
  - `cancel/3` and `status/3` send `invoke_cancel` and `invoke_status`.
  """

  @typedoc "A transport and its options."
  @type t :: {module(), keyword()}

  @doc "Sends an invocation, then its part (the moduledoc)."
  @callback open(
              device_id :: String.t(),
              header :: map(),
              payload :: binary(),
              part :: binary() | nil,
              opts :: keyword()
            ) :: :ok | {:error, :not_connected | {:part, term()} | term()}

  @doc "Sends `invoke_cancel` for the invocation `id`."
  @callback cancel(device_id :: String.t(), id :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc "Sends `invoke_status` for the invocation `id`."
  @callback status(device_id :: String.t(), id :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc "The configured transport, with no options."
  @spec impl() :: t()
  def impl, do: {Application.fetch_env!(:fermix_core, :computers_transport), []}
end
