defmodule FermixChannels.Accessories.Transport do
  @moduledoc """
  The byte transport under one accessory link (M91 §05): a port opened for
  the link's own use, raw bytes in both directions, and the enumeration the
  port watcher polls. `FermixChannels.Accessories.Serial` is the USB serial
  implementation; tests use an in-memory double or a pseudo-terminal.

  The process that calls `open/2` owns the handle: the transport's messages
  arrive in that process's mailbox, and the owner hands every message it does
  not recognise to `message/2`, which answers whether it was the transport's:

    * `{:data, bytes}`: bytes read from the port, any fragment of the stream;
    * `{:closed, reason}`: the port is gone, and the handle with it. Nothing
      more arrives for the handle, and `close/1` on it is a no-op;
    * `:unknown`: not this handle's message.

  Every function returns a result its caller matches; none raises on what the
  port or the peer does.
  """

  @typedoc "A transport's own handle for one open port."
  @type handle :: term()

  @typedoc """
  One port as enumeration found it: its path, the USB vendor and product IDs
  and the USB serial string, each `nil` when the port did not report it.
  """
  @type port_info :: %{
          path: String.t(),
          vendor_id: 0..65_535 | nil,
          product_id: 0..65_535 | nil,
          serial: String.t() | nil
        }

  @typedoc """
  Why a port did not open: another program holds it (`:busy`), it is not
  there (`:not_found`), the account may not open it (`:permission`), this
  build or platform has no serial transport (`{:unavailable, reason}`, with
  the sentence a log says it in), or another
  failure the transport names.
  """
  @type open_error ::
          :busy | :not_found | :permission | {:unavailable, String.t()} | {atom(), term()}

  @typedoc """
  Why an open port went: it vanished (unplugged, or the device reset), its
  writes stalled, or another failure the transport names.
  """
  @type close_reason :: :vanished | :write_stall | {atom(), term()}

  @doc "The ports attached now, each with what it reports."
  @callback enumerate(opts :: keyword()) :: {:ok, [port_info()]} | {:error, term()}

  @doc "Opens `path` for the calling process alone; another opener is refused `:busy`."
  @callback open(path :: String.t(), opts :: keyword()) ::
              {:ok, handle()} | {:error, open_error()}

  @doc "Queues bytes for the port, in order. A bounded backlog refuses past its bound."
  @callback write(handle(), iodata()) :: :ok | {:error, term()}

  @doc "Closes the port. Safe on a handle that is already closed."
  @callback close(handle()) :: :ok

  @doc "Whether a message the owner received is this handle's, and what it says."
  @callback message(handle(), term()) ::
              {:data, binary()} | {:closed, close_reason()} | :unknown
end
