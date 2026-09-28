defmodule FermixChannels.Mobile.EventRouter do
  @moduledoc """
  Post-authentication coordinator for decoded mobile client events.

  The chat request path itself is `Companion.Requests`, shared with the local
  companion socket; this module is its mobile front. It admits only the
  Noise-authenticated device context, which is passed separately from the
  decoded payload and never reconstructed from client-controlled JSON, and it
  supplies what only the phone has: attribution of each claim to its device,
  replies addressed to that device, link previews after a user row is written,
  and a push once a request settles without a turn.
  """

  alias FermixChannels.Channels.Mobile
  alias FermixChannels.Companion.Fanout
  alias FermixChannels.Companion.Output
  alias FermixChannels.Companion.Requests
  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.SocketHandler
  alias FermixCore.Companion.Timeline

  # A page above the 4 KiB header travels as continuation frames; this bounds
  # the one event they carry.
  @max_page_bytes 256 * 1_024

  @type ingress_context :: %{
          required(:transport) => :mobile,
          required(:authenticated_device_id) => String.t()
        }

  @spec route(map(), map(), keyword()) :: :ok | {:error, term()}
  def route(event, context, opts \\ [])
      when is_map(event) and is_map(context) and is_list(opts) do
    with {:ok, device_id} <- authenticated_device(context) do
      opts = with_default_sink(opts)
      dispatch(event, transport(device_id, context, opts), opts)
    end
  end

  @doc "Recover one stored authenticated request without re-claiming its client id."
  @spec recover_request(map(), map(), keyword()) :: :ok | {:error, term()}
  def recover_request(row, context, opts \\ [])
      when is_map(row) and is_map(context) and is_list(opts) do
    with {:ok, device_id} <- authenticated_device(context) do
      opts = with_default_sink(opts)
      Requests.recover(row, transport(device_id, context, opts), opts)
    end
  end

  defp dispatch(%{type: type, payload: payload} = event, transport, opts)
       when type in ["msg", "command"] and is_map(payload) do
    Requests.request(event, transport, opts)
  end

  defp dispatch(%{type: "history_pull", payload: payload}, transport, opts),
    do: Requests.history(payload, transport, opts)

  defp dispatch(%{type: "read_state", payload: payload}, _transport, opts),
    do: Requests.read_state(payload, opts)

  defp dispatch(%{type: "cancel", payload: payload}, _transport, opts),
    do: Requests.cancel(payload, opts)

  defp dispatch(%{type: "ping"}, transport, opts) do
    Keyword.fetch!(opts, :event_sink).(transport.reply_to, %{"t" => "pong"})
  end

  defp dispatch(%{type: type}, _transport, _opts),
    do: {:error, {:unsupported_event, type}}

  defp dispatch(_event, _transport, _opts), do: {:error, :invalid_event}

  defp transport(device_id, context, opts) do
    reply_to = {:device, device_id}
    sink = Keyword.fetch!(opts, :event_sink)

    %{
      name: :mobile,
      channel: Mobile,
      claimant: [authenticated_device_id: device_id],
      ingress_context: context,
      reply_to: reply_to,
      # A request that fails after its worker returned is told to the device
      # as the socket tells a failed worker's (`SocketHandler.request_error/2`).
      report_failure: fn client_msg_id, cause ->
        sink.(reply_to, SocketHandler.request_error({:request_failed, cause}, client_msg_id))
      end,
      attempt_key: :mobile_attempt,
      max_page_bytes: @max_page_bytes,
      after_user_append: &after_user_append/4,
      after_settle: &schedule_settled_push/3
    }
  end

  # The phone's row reaches everyone watching the profile as it is written: the
  # Mac's companion connections, and every phone, the sender's own included,
  # each wire in its own shape. A voice note's transcript replaces its text
  # only later (the gateway's enrichment), so the row a phone hears first is
  # the one written.
  defp after_user_append(profile, row, text, opts) do
    :ok = Keyword.fetch!(opts, :event_sink).({:profile, profile}, Output.row(profile, row))

    schedule_user_unfurl(profile, row, text, opts)
  end

  defp schedule_user_unfurl(profile, row, text, opts) do
    Mobile.schedule_unfurl(profile, row.server_seq, text,
      unfurl: Keyword.get(opts, :unfurl),
      unfurl_launcher: Keyword.get(opts, :unfurl_launcher),
      event_sink: Keyword.get(opts, :event_sink),
      store: store(opts),
      store_opts: Keyword.get(opts, :store_opts, [])
    )
  end

  defp schedule_settled_push(profile, request, opts) do
    case Map.get(request, :result_server_seq) do
      server_seq when is_integer(server_seq) and server_seq > 0 ->
        Mobile.schedule_push(profile, server_seq,
          store: store(opts),
          store_opts: Keyword.get(opts, :store_opts, []),
          push: Keyword.get(opts, :push),
          push_launcher: Keyword.get(opts, :push_launcher)
        )

      _none ->
        :ok
    end
  end

  # A caller without a sink of its own (boot recovery) replies through the
  # device registry, which is where every mobile socket attaches.
  defp with_default_sink(opts), do: Keyword.put_new(opts, :event_sink, &emit_registered/2)

  defp emit_registered({:device, device_id}, event),
    do: DeviceRegistry.send_device_event(device_id, event)

  defp emit_registered({:profile, profile}, event), do: Fanout.announce(profile, event)

  defp authenticated_device(%{
         transport: :mobile,
         authenticated_device_id: device_id
       })
       when is_binary(device_id) and device_id != "",
       do: {:ok, device_id}

  defp authenticated_device(_context), do: {:error, :unauthenticated_mobile_transport}

  defp store(opts), do: Keyword.get(opts, :store, Timeline)
end
