defmodule FermixChannels.Mobile.EventRouter do
  @moduledoc """
  Post-authentication coordinator for decoded mobile client events.

  The chat request path itself is `Companion.Requests`, shared with the local
  companion socket; this module is its mobile front. It admits only the
  Noise-authenticated device context, which is passed separately from the
  decoded payload and never reconstructed from client-controlled JSON, and it
  supplies what only the phone has: attribution of each claim to its device,
  replies addressed to that device, link previews after a user row is written,
  and a push once a command settles.
  """

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Channels.Mobile
  alias FermixChannels.Companion.Requests
  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixCore.Companion.Timeline

  @type ingress_context :: %{
          required(:transport) => :mobile,
          required(:authenticated_device_id) => String.t()
        }

  @spec route(map(), map(), keyword()) :: :ok | {:error, term()}
  def route(event, context, opts \\ [])
      when is_map(event) and is_map(context) and is_list(opts) do
    with {:ok, device_id} <- authenticated_device(context) do
      dispatch(event, transport(device_id, context), with_default_sink(opts))
    end
  end

  @doc "Recover one stored authenticated request without re-claiming its client id."
  @spec recover_request(map(), map(), keyword()) :: :ok | {:error, term()}
  def recover_request(row, context, opts \\ [])
      when is_map(row) and is_map(context) and is_list(opts) do
    with {:ok, device_id} <- authenticated_device(context) do
      Requests.recover(row, transport(device_id, context), with_default_sink(opts))
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

  defp dispatch(%{type: "ping"}, transport, opts) do
    Keyword.fetch!(opts, :event_sink).(transport.reply_to, %{"t" => "pong"})
  end

  defp dispatch(%{type: type}, _transport, _opts),
    do: {:error, {:unsupported_event, type}}

  defp dispatch(_event, _transport, _opts), do: {:error, :invalid_event}

  defp transport(device_id, context) do
    %{
      name: :mobile,
      channel: Mobile,
      claimant: [authenticated_device_id: device_id],
      ingress_context: context,
      reply_to: {:device, device_id},
      attempt_key: :mobile_attempt,
      after_user_append: &after_user_append/4,
      after_command: &schedule_command_push/3
    }
  end

  # The phone's row reaches the Mac's companion connections as it is written;
  # the phone's own wire hears of it as before.
  defp after_user_append(profile, row, text, opts) do
    :ok = Companion.announce_row(profile, row)
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

  defp schedule_command_push(profile, request, opts) do
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

  defp emit_registered({:profile, profile}, event),
    do: profile_emit_result(DeviceRegistry.send_profile_event(profile, event))

  defp profile_emit_result(count) when is_integer(count) and count >= 0, do: :ok

  defp authenticated_device(%{
         transport: :mobile,
         authenticated_device_id: device_id
       })
       when is_binary(device_id) and device_id != "",
       do: {:ok, device_id}

  defp authenticated_device(_context), do: {:error, :unauthenticated_mobile_transport}

  defp store(opts), do: Keyword.get(opts, :store, Timeline)
end
