defmodule FermixChannels.Mobile.EventRouter do
  @moduledoc """
  Post-authentication coordinator for decoded mobile client events.

  Durable request claim happens before Gateway ingress. The Noise-authenticated
  device context is passed separately from the decoded payload and is never
  reconstructed from client-controlled JSON.
  """

  require Logger

  alias FermixChannels.Channels.Mobile
  alias FermixChannels.Gateway
  alias FermixChannels.Gateway.Queue
  alias FermixChannels.Mobile.MediaStore
  alias FermixChannels.Mobile.RequestCoordinator
  alias FermixCore.Mobile.Store

  @type ingress_context :: %{
          required(:transport) => :mobile,
          required(:authenticated_device_id) => String.t()
        }

  @spec route(map(), map(), keyword()) :: :ok | {:error, term()}
  def route(event, context, opts \\ [])
      when is_map(event) and is_map(context) and is_list(opts) do
    with {:ok, device_id} <- authenticated_device(context) do
      dispatch(event, device_id, context, opts)
    end
  end

  @doc "Recover one stored authenticated request without re-claiming its client id."
  @spec recover_request(map(), map(), keyword()) :: :ok | {:error, term()}
  def recover_request(row, context, opts \\ [])
      when is_map(row) and is_map(context) and is_list(opts) do
    with {:ok, device_id} <- authenticated_device(context),
         {:ok, event, type, profile, client_id} <- recovered_event(row) do
      acquire_and_run(event, type, profile, client_id, device_id, context, true, opts)
    end
  end

  defp dispatch(%{type: type, payload: payload} = event, device_id, context, opts)
       when type in ["msg", "command"] and is_map(payload) do
    route_request(event, type, payload, device_id, context, opts)
  end

  defp dispatch(%{type: "history_pull", payload: payload}, device_id, _context, opts) do
    with {:ok, profile} <- profile(payload),
         {:ok, page} <-
           store(opts).history_page(
             profile,
             store_opts(opts, after_seq: payload["after_seq"], limit: payload["limit"])
           ) do
      emit(opts, {:device, device_id}, history_event(profile, page))
    end
  end

  defp dispatch(%{type: "read_state", payload: payload}, _device_id, _context, opts) do
    with {:ok, profile} <- profile(payload),
         {:ok, frontier} <-
           store(opts).advance_read_frontier(
             profile,
             payload["read_up_to_seq"],
             store_opts(opts)
           ) do
      emit(opts, {:profile, profile}, %{
        "t" => "read_state",
        "profile_id" => profile,
        "read_up_to_seq" => frontier
      })
    end
  end

  defp dispatch(%{type: "ping"}, device_id, _context, opts) do
    emit(opts, {:device, device_id}, %{"t" => "pong"})
  end

  defp dispatch(%{type: type}, _device_id, _context, _opts),
    do: {:error, {:unsupported_event, type}}

  defp dispatch(_event, _device_id, _context, _opts), do: {:error, :invalid_event}

  defp route_request(event, type, payload, device_id, context, opts) do
    with {:ok, profile} <- profile(payload),
         {:ok, client_id} <- required(payload, "client_msg_id") do
      case store(opts).claim_client_request(
             profile,
             client_id,
             type,
             payload,
             store_opts(opts, authenticated_device_id: device_id)
           ) do
        {:ok, {:claimed, request}} ->
          _ =
            best_effort_emit(
              opts,
              {:device, device_id},
              accepted_event(client_id, false, request)
            )

          acquire_and_run(event, type, profile, client_id, device_id, context, false, opts)

        {:ok, {:duplicate, request}} ->
          _ =
            best_effort_emit(opts, {:device, device_id}, accepted_event(client_id, true, request))

          acquire_and_run(event, type, profile, client_id, device_id, context, true, opts)

        {:ok, {:conflict, _request}} ->
          {:error, :client_message_conflict}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp acquire_and_run(event, type, profile, client_id, device_id, context, duplicate?, opts) do
    case coordinator(opts).acquire(
           coordinator_server(opts),
           profile,
           client_id,
           store_opts(opts)
         ) do
      {:ok, {:started, %{attempt: attempt}}} when is_integer(attempt) and attempt > 0 ->
        run_started(
          event,
          type,
          profile,
          client_id,
          device_id,
          context,
          duplicate?,
          attempt,
          opts
        )

      {:ok, {state, _row}} when state in [:active, :completed, :failed] ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_started(
         event,
         type,
         profile,
         client_id,
         _device_id,
         context,
         _duplicate?,
         attempt,
         opts
       ) do
    {deferred_ref, defer_command_fn} = deferred_lifecycle(type, profile, client_id, attempt, opts)

    result =
      with {:ok, prepared, media_refs} <- resolve_attachments(event, opts),
           {:ok, [message]} <- Mobile.parse_event(prepared),
           message = with_attempt(message, attempt),
           {:ok, {append_status, row}} <-
             append_user(profile, message, client_id, media_refs, opts),
           :ok <- schedule_user_unfurl(append_status, profile, row, message.content, opts),
           :ok <- ingest_gateway(message, context, attempt, defer_command_fn, opts),
           :ok <-
             finish_synchronous_request(
               type,
               profile,
               client_id,
               attempt,
               deferred?(deferred_ref),
               opts
             ) do
        :ok
      end

    settle_request_error(result, profile, client_id, type, attempt, opts)
  end

  defp resolve_attachments(%{type: "command"} = event, _opts), do: {:ok, event, []}

  defp resolve_attachments(%{type: "msg", payload: payload} = event, opts) do
    ids = Map.get(payload, "attach_ids", [])

    with {:ok, attachments} <- fetch_attachments(ids, opts) do
      refs = Enum.map(attachments, &timeline_ref/1)
      payload = Map.put(payload, "attachments", Enum.map(attachments, &gateway_attachment/1))
      {:ok, %{event | payload: payload}, refs}
    end
  end

  defp fetch_attachments(ids, opts) when is_list(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn attach_id, {:ok, acc} ->
      case media_store(opts).attachment(media_server(opts), attach_id) do
        {:ok, attachment} -> {:cont, {:ok, [attachment | acc]}}
        {:error, reason} -> {:halt, {:error, {:attachment_unavailable, attach_id, reason}}}
      end
    end)
    |> then(fn
      {:ok, attachments} -> {:ok, Enum.reverse(attachments)}
      error -> error
    end)
  end

  defp fetch_attachments(_ids, _opts), do: {:error, {:invalid_field, "attach_ids"}}

  defp append_user(profile, message, client_id, media_refs, opts) do
    store(opts).append_client_message(
      profile,
      client_id,
      %{
        content: message.content,
        kind: if(media_refs == [], do: "text", else: "media"),
        media_refs: media_refs
      },
      store_opts(opts)
    )
  end

  defp schedule_user_unfurl(:created, profile, row, text, opts) do
    Mobile.schedule_unfurl(profile, row.server_seq, text,
      unfurl: Keyword.get(opts, :unfurl),
      unfurl_launcher: Keyword.get(opts, :unfurl_launcher),
      event_sink: Keyword.get(opts, :event_sink)
    )
  end

  defp schedule_user_unfurl(:existing, _profile, _row, _text, _opts), do: :ok

  defp finish_synchronous_request("msg", _profile, _client_id, _attempt, _deferred?, _opts),
    do: :ok

  defp finish_synchronous_request("command", _profile, _client_id, _attempt, true, _opts),
    do: :ok

  defp finish_synchronous_request("command", profile, client_id, attempt, false, opts) do
    with {:ok, request} <-
           store(opts).complete_client_request(
             profile,
             client_id,
             attempt,
             %{},
             store_opts(opts)
           ) do
      schedule_command_push(profile, request, opts)
    end
  end

  defp deferred_lifecycle("msg", _profile, _client_id, _attempt, _opts),
    do: {nil, nil}

  defp deferred_lifecycle("command", profile, client_id, attempt, opts) do
    owner = self()
    ref = make_ref()

    defer = fn ->
      send(owner, {ref, :deferred})
      fn outcome -> settle_deferred(outcome, profile, client_id, attempt, opts) end
    end

    {ref, defer}
  end

  defp deferred?(nil), do: false

  defp deferred?(ref) when is_reference(ref) do
    receive do
      {^ref, :deferred} -> true
    after
      0 -> false
    end
  end

  defp settle_deferred(:completed, profile, client_id, attempt, opts) do
    with {:ok, request} <-
           store(opts).complete_client_request(
             profile,
             client_id,
             attempt,
             %{},
             store_opts(opts)
           ) do
      schedule_command_push(profile, request, opts)
    end
  end

  defp settle_deferred({:failed, reason}, profile, client_id, attempt, opts) do
    fields = %{error: %{type: "command", reason: inspect(reason)}}

    with {:ok, request} <-
           store(opts).fail_client_request(
             profile,
             client_id,
             attempt,
             fields,
             store_opts(opts)
           ) do
      schedule_command_push(profile, request, opts)
    end
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

  defp ingest_gateway(message, context, attempt, defer_command_fn, opts) do
    gateway(opts).ingest([message],
      channel: Mobile,
      agent: Keyword.get(opts, :agent, Queue),
      agent_server: Keyword.get(opts, :agent_server, Queue),
      ingress_context: context,
      defer_command_fn: defer_command_fn,
      approval_resolution_fn: approval_resolution_fn(message.chat_id, opts),
      ingest_enriched_fn:
        enrichment_fn(message.chat_id, client_message_id(message), attempt, opts)
    )
  end

  defp approval_resolution_fn(profile_id, opts) do
    fn %{kind: kind, token: token, outcome: outcome} ->
      event = %{
        "t" => "approval_resolved",
        "approval_id" => Mobile.approval_id(kind, token),
        "outcome" => Atom.to_string(outcome)
      }

      best_effort_emit(opts, {:profile, profile_id}, event)
    end
  end

  defp settle_request_error(:ok, _profile, _client_id, _type, _attempt, _opts), do: :ok

  defp settle_request_error({:error, reason}, profile, client_id, type, attempt, opts) do
    fields = %{error: %{type: type, reason: inspect(reason)}}
    _ = store(opts).fail_client_request(profile, client_id, attempt, fields, store_opts(opts))
    {:error, reason}
  end

  defp enrichment_fn(profile, client_id, attempt, opts) do
    fn message ->
      store(opts).update_client_message(
        profile,
        client_id,
        attempt,
        %{content: message.content},
        store_opts(opts)
      )
      |> case do
        {:ok, _row} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp recovered_event(row) do
    type = Map.get(row, :request_type)
    payload = Map.get(row, :payload)
    profile = Map.get(row, :profile_id)
    client_id = Map.get(row, :client_msg_id)

    if type in ["msg", "command"] and is_map(payload) and profile == "main" and
         payload["profile_id"] == profile and payload["client_msg_id"] == client_id do
      {:ok, %{type: type, payload: payload}, type, profile, client_id}
    else
      {:error, :invalid_recovery_envelope}
    end
  end

  defp with_attempt(message, attempt) do
    %{message | metadata: Map.put(message.metadata, :mobile_attempt, attempt)}
  end

  defp client_message_id(message), do: Map.get(message.metadata, :client_msg_id) || message.id

  defp authenticated_device(%{
         transport: :mobile,
         authenticated_device_id: device_id
       })
       when is_binary(device_id) and device_id != "",
       do: {:ok, device_id}

  defp authenticated_device(_context), do: {:error, :unauthenticated_mobile_transport}

  defp profile(payload) do
    case Map.get(payload, "profile_id") do
      "main" -> {:ok, "main"}
      _other -> {:error, :unsupported_profile}
    end
  end

  defp required(payload, key) do
    case Map.get(payload, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_field, key}}
    end
  end

  defp accepted_event(client_id, duplicate, request) do
    %{"t" => "accepted", "client_msg_id" => client_id, "duplicate" => duplicate}
    |> maybe_put("server_seq", Map.get(request, :result_server_seq))
  end

  defp history_event(profile, page) do
    %{
      "t" => "history_page",
      "profile_id" => profile,
      "messages" => page.messages,
      "next_after_seq" => page.next_after_seq,
      "history_head_seq" => Map.get(page, :history_head_seq, page.next_after_seq)
    }
  end

  defp gateway_attachment(attachment) do
    %{
      file_id: value(attachment, :attach_id),
      kind: attachment |> value(:kind) |> normalize_kind(),
      mime_type: value(attachment, :mime_type),
      size_bytes: value(attachment, :size_bytes)
    }
  end

  defp timeline_ref(attachment) do
    %{
      "ref" => value(attachment, :ref),
      "kind" => value(attachment, :kind),
      "mime" => value(attachment, :mime_type),
      "size_bytes" => value(attachment, :size_bytes),
      "filename" => value(attachment, :file_name)
    }
  end

  defp normalize_kind(kind) when kind in ["image", :image], do: :image
  defp normalize_kind(kind) when kind in ["audio", :audio], do: :audio
  defp normalize_kind(kind) when is_atom(kind), do: kind
  defp normalize_kind(_kind), do: :document

  defp emit(opts, target, event) do
    case Keyword.get(opts, :event_sink) do
      sink when is_function(sink, 2) -> sink.(target, event)
      nil -> emit_registered(target, event)
    end
  end

  defp emit_registered({:device, device_id}, event),
    do: FermixChannels.Mobile.DeviceRegistry.send_device_event(device_id, event)

  defp emit_registered({:profile, profile}, event),
    do:
      profile_emit_result(FermixChannels.Mobile.DeviceRegistry.send_profile_event(profile, event))

  defp profile_emit_result(count) when is_integer(count) and count >= 0, do: :ok

  defp best_effort_emit(opts, target, event) do
    case emit(opts, target, event) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("mobile event fanout failed for #{inspect(target)}: #{inspect(reason)}")

        :ok
    end
  end

  defp store(opts), do: Keyword.get(opts, :store, Store)
  defp gateway(opts), do: Keyword.get(opts, :gateway, Gateway)
  defp coordinator(opts), do: Keyword.get(opts, :coordinator, RequestCoordinator)

  defp coordinator_server(opts),
    do: Keyword.get(opts, :request_coordinator, RequestCoordinator)

  defp media_store(opts), do: Keyword.get(opts, :media_store, MediaStore)
  defp media_server(opts), do: Keyword.get(opts, :media_server, MediaStore)

  defp store_opts(opts, extra \\ []) do
    Keyword.get(opts, :store_opts, []) |> Keyword.merge(extra)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
