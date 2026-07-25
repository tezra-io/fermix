defmodule FermixCore.Harness.ContinuationDispatcher do
  @moduledoc """
  Behaviour for re-ingesting a finished coding run's completion notice into its
  originating conversation (design §23.2).

  `fermix_core` must never compile-depend on `fermix_channels`, so the
  implementation is injected **by module** through
  `config :fermix_core, :harness_continuation_dispatcher` — the same app-env
  module-injection the jobs delivery path uses for channel adapters
  (`[:fermix_core, :jobs, :delivery_channels]` → `Delivery.ChannelSend`). Core
  hands the implementation plain data; the channels side owns the `Message`
  struct, the gateway, and the agent queue.

  A configured module that does not export `dispatch/1` is a configuration error:
  `Harness.Continuation` logs it and the run's outcome is delivered as ordinary
  text (never silently dropped).
  """

  @typedoc """
  The plain-data continuation notice. `platform`/`destination`/`thread` are the
  ledger row's frozen delivery snapshot; `metadata` marks the message a
  continuation and carries the chain depth.
  """
  @type notice :: %{
          platform: String.t(),
          destination: String.t(),
          thread: String.t() | nil,
          content: String.t(),
          metadata: map()
        }

  @doc """
  Re-ingests `notice` into the originating conversation, returning `:ok` only once
  the message has been accepted for ingest — never merely handed to an async hop,
  whose late refusal the caller could not see. Any refusal (unknown channel, no
  owner configured, no live agent, a gateway ingest error) is `{:error, reason}`:
  the caller then leaves the run's durable delivery pending so the outcome still
  reaches the owner as text.

  Implementations may block only briefly; the caller bounds the call with the
  delivery watchdog and treats an expiry as a failed dispatch.
  """
  @callback dispatch(notice()) :: :ok | {:error, term()}
end
