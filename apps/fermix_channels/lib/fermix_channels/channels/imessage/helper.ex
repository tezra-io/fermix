defmodule FermixChannels.Channels.IMessage.Helper do
  @moduledoc """
  The seam between the iMessage channel and the Fermix Messages helper
  (MILESTONE_54 §5). `IMessage.Port` is the production implementation, owning
  the helper's OS process; tests and the bench inject a fake.

  Requests are synchronous: `call/4` answers the helper's result map or a typed
  error `{kind, message, data}`, where `kind` is one of the helper's closed kinds
  (`IMessage.Protocol.error_kind/0`) or one of the engine's own:

    * `:request_timeout` — the helper did not answer within the caller's budget;
    * `:helper_unavailable` — the helper is not running (restarting, refused,
      or the channel was never started); `data["class"]` names why;
    * `:protocol_error` — the helper answered outside the wire contract.

  Subscription delivery is by message to the one attached process
  (`attach/2`), in wire order:

    * `{:imessage_event, event, params}` — a helper notification (`message`,
      `watch.overflow`, `db.state`, `send.reconciled`);
    * `{:imessage_helper, :up, handshake}` — the helper was (re)started and
      answered `initialize`; its subscription, if any, is gone;
    * `{:imessage_helper, :down, class}` — the helper stopped answering.
  """

  alias FermixChannels.Channels.IMessage.Protocol

  @type server :: term()
  @type engine_error_kind :: :request_timeout | :helper_unavailable | :protocol_error
  @type error_kind :: Protocol.error_kind() | engine_error_kind()
  @type error :: {error_kind(), String.t(), map()}

  @doc "Sends one request and waits at most `timeout` ms for its answer."
  @callback call(server(), method :: String.t(), params :: map(), timeout :: pos_integer()) ::
              {:ok, map()} | {:error, error()}

  @doc """
  Makes `pid` the receiver of notifications and lifecycle messages, replacing
  any earlier one. Answers the current `initialize` result, or the reason the
  helper is down (the pid stays attached and hears `:up` later).
  """
  @callback attach(server(), pid()) :: {:ok, handshake :: map()} | {:error, error()}

  @doc "The FERMIX_HOME this helper serves (`--home`): the root of its inbox and outbox."
  @callback home(server()) :: {:ok, String.t()} | {:error, error()}
end
