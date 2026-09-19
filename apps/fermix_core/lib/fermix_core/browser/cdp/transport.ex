defmodule FermixCore.Browser.CDP.Transport do
  @moduledoc """
  The contract `ProfileServer` drives a browser through.

  `ProfileServer` reaches a browser through exactly one injection point
  (`:connection`) and exactly these three functions, so a second way of speaking
  CDP is a module, not a second ProfileServer. `CDP.Connection` is the WebSocket
  to a Chrome the daemon launched or was pointed at; `CDP.ExtensionTransport` is
  a tab the person granted through the browser extension. The test suites'
  inline fakes implement the same three functions, which is what made this an
  implicit contract long before it was written down.

  Events are the fourth part of the contract and have no callback, because they
  are messages rather than calls: the transport sends `{:cdp_event, method,
  event}` to the `:owner` given to `start_link/2`, where `event` is the decoded
  CDP event object — `%{"method" => method, "params" => params}`. A transport
  that loses the browser under it sends nothing more and lets its process exit;
  `ProfileServer` is linked to it and tears the runtime down on the `:EXIT`.
  """

  alias FermixCore.Browser.Error

  @doc """
  Start a transport for `url` and link it to the caller.

  `opts` carries `:owner` (the process events are sent to) and `:keepalive_ms`.
  """
  @callback start_link(url :: String.t(), opts :: keyword()) :: GenServer.on_start()

  @doc """
  Run one CDP command and wait for its reply.

  Called from the `ProfileServer` process, which blocks in a selective receive
  until the reply arrives or `timeout_ms + grace_ms` passes — the grace lets the
  transport's own timer fire first with a precise error.
  """
  @callback command(
              transport :: pid(),
              method :: String.t(),
              params :: map() | nil,
              session_id :: String.t() | nil,
              timeout_ms :: pos_integer(),
              grace_ms :: non_neg_integer()
            ) :: {:ok, map() | list() | nil} | {:error, Error.t()}

  @doc "Close the transport. Asynchronous: the process exits on its own."
  @callback close(transport :: pid()) :: :ok
end
