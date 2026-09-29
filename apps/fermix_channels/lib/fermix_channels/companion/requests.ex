defmodule FermixChannels.Companion.Requests do
  @moduledoc """
  The chat request path the two companion transports share: the phone's
  (`Mobile.EventRouter`, behind Noise) and the Mac's (`Companion.Connection`,
  behind `companion.sock`).

  A `msg` or `command` is claimed durably under its `client_msg_id` before
  anything runs, answered `accepted` (a resend is answered `duplicate` and never
  runs twice), fenced to one attempt per boot by the request coordinator,
  written to the timeline as the user's row, and ingested through the Gateway.
  History, search and read state are reads and one monotonic write over the
  same timeline, and a `cancel` stops one request's turn.

  `Companion.Turns` is the Gateway's agent for both transports, so a request
  that becomes a turn is handed to the queue through it and settled by it from
  the turn's outcome. A request the gateway answered without a turn (a slash
  command answered inline, an empty or unauthorized message, an ingress
  failure the gateway already replied to) is settled once ingest returns, by
  `Turns`, in order with the hand-offs, when none was made for it, so none is
  left running: one it cannot complete is failed there, and its client told.
  Nothing here waits on `Turns` for either.

  A command that answers after ingest returns (`/background`, a `/skills`
  review or approval) defers its request, whether it came as a `command` or
  was typed as a `msg`: the request stays running until the command reports
  its end, so its late answer is still the request's output.

  A transport differs only in what it hands in, as a `t:transport/0`: the
  channel adapter the turn runs on, how its claims are attributed, the ingress
  context the Gateway sees, where replies meant for this one client go, how
  it tells that client a request failed, how many bytes one history page may
  take, and the post-commit effects only the phone has (link previews, push).

  Events are logical maps (`%{"t" => type, ...}`) handed to the caller's
  `:event_sink`, a 2-arity function of a target and an event: the transport's
  own `reply_to` for this client, or `{:profile, profile_id}` for everyone
  watching the profile on either transport (`Companion.Fanout`).

  Once ingest returns, the request coordinator's liveness fence moves to the
  settlement owner (`:settlement_owner`, `Companion.Turns` unless a caller
  names another), so its death, not this client's disconnect, releases the
  attempt, and a dead queue fails the request there instead of releasing it.
  """

  require Logger

  alias FermixChannels.Companion.Approvals
  alias FermixChannels.Companion.Fanout
  alias FermixChannels.Companion.Output
  alias FermixChannels.Companion.Turns
  alias FermixChannels.Gateway
  alias FermixChannels.Gateway.Queue
  alias FermixChannels.Mobile.MediaStore
  alias FermixChannels.Mobile.RequestCoordinator
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixCore.Companion.Timeline
  alias FermixCore.Telemetry

  @profile "main"

  @typedoc """
  What one transport hands the shared path.

    * `:name` — the transport, as the durable claim records it.
    * `:channel` — the `Gateway.Channel` adapter the turn runs on; it parses a
      decoded `msg` or `command` with `parse_event/1`.
    * `:claimant` — store options that attribute the claim (the phone's
      authenticated device; nothing for the local socket).
    * `:ingress_context` — handed to `Gateway.ingest/2` as proof of transport.
    * `:reply_to` — the event-sink target for events only this client gets
      (`accepted`, a history page, search results); `nil` when no client is
      waiting (boot recovery).
    * `:report_failure` — a function of a request's `client_msg_id` and the
      cause of its failure that tells this client, in the error its own wire
      builds, that a request failed after its worker returned.
    * `:attempt_key` — the message metadata key the adapter reads the attempt
      from.
    * `:max_page_bytes` — the most a `history_page` may take once encoded, under
      what the transport can carry in one event.
    * `:after_user_append` — `nil`, or a function of the profile, the new user
      row, its text and the options, run once the row is created.
    * `:after_settle` — `nil`, or a function of the profile, the request and the
      options, run when a request is settled here rather than by its turn: an
      inline answer, or a deferred command's end.
  """
  @type transport :: %{
          required(:name) => Fanout.transport(),
          required(:channel) => module(),
          required(:claimant) => keyword(),
          required(:ingress_context) => map(),
          required(:reply_to) => term(),
          required(:report_failure) => (String.t(), term() -> :ok | {:error, term()}),
          required(:attempt_key) => atom(),
          required(:max_page_bytes) => pos_integer(),
          required(:after_user_append) => (String.t(), map(), String.t(), keyword() -> :ok) | nil,
          required(:after_settle) => (String.t(), map(), keyword() -> :ok) | nil
        }

  @doc "Claim, acknowledge and run one decoded `msg` or `command`."
  @spec request(map(), transport(), keyword()) :: :ok | {:error, term()}
  def request(%{type: type, payload: payload} = event, transport, opts)
      when type in ["msg", "command"] and is_map(payload) and is_map(transport) and
             is_list(opts) do
    with {:ok, profile} <- profile(payload),
         {:ok, client_id} <- required(payload, "client_msg_id") do
      claim_and_run(event, type, profile, client_id, transport, opts)
    end
  end

  @doc "Recover one stored request without re-claiming its client id."
  @spec recover(map(), transport(), keyword()) :: :ok | {:error, term()}
  def recover(row, transport, opts) when is_map(row) and is_map(transport) and is_list(opts) do
    with {:ok, event, type, profile, client_id} <- recovered_event(row) do
      acquire_and_run(event, type, profile, client_id, transport, opts)
    end
  end

  @doc """
  Answer one `history_pull` with a page to this client. `after_seq` pages
  forward; `before_seq` (companion only) pages backward. A page is cut to the
  transport's `max_page_bytes`, and its cursor then names the last row sent.
  """
  @spec history(map(), transport(), keyword()) :: :ok | {:error, term()}
  def history(payload, transport, opts) when is_map(payload) and is_list(opts) do
    with {:ok, profile} <- profile(payload),
         {:ok, page} <-
           store(opts).history_page(
             profile,
             store_opts(opts, history_cursor(payload) ++ [limit: payload["limit"]])
           ),
         {:ok, messages} <- timeline_messages(page),
         {:ok, event} <-
           fit_page(history_event(profile, page, messages), payload, transport.max_page_bytes) do
      emit(opts, transport.reply_to, event)
    end
  end

  @doc """
  Cancel one request's turn, whichever client sent it. The cancel is recorded
  on the request first, the mark the hand-off to the queue and boot recovery
  read, then `Companion.Turns` stops its turn if it was handed off. A request
  already settled, or never claimed, is left alone, and other turns are
  untouched. Nothing is answered here: the turn ends on the wire from its
  outcome, a `turn_error` (code `cancelled`), or its `text_done` when it had
  already finished.
  """
  @spec cancel(map(), keyword()) :: :ok | {:error, term()}
  def cancel(payload, opts) when is_map(payload) and is_list(opts) do
    with {:ok, profile} <- profile(payload),
         {:ok, client_id} <- required(payload, "client_msg_id") do
      case store(opts).cancel_client_request(profile, client_id, store_opts(opts)) do
        {:ok, {:marked, _request}} -> Turns.cancel(settlement_owner(opts), profile, client_id)
        {:ok, {:settled, _request}} -> :ok
        {:error, :not_found} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Answer one `history_search` with a page of hits to this client."
  @spec search(map(), transport(), keyword()) :: :ok | {:error, term()}
  def search(payload, transport, opts) when is_map(payload) and is_list(opts) do
    query = payload["query"]
    cursor = if payload["before_seq"], do: [before_seq: payload["before_seq"]], else: []

    with {:ok, profile} <- profile(payload),
         {:ok, page} <-
           store(opts).search(
             profile,
             query,
             store_opts(opts, cursor ++ [limit: payload["limit"]])
           ) do
      emit(opts, transport.reply_to, search_event(profile, query, page))
    end
  end

  @doc "Advance the profile's read frontier and tell everyone watching it."
  @spec read_state(map(), keyword()) :: :ok | {:error, term()}
  def read_state(payload, opts) when is_map(payload) and is_list(opts) do
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

  defp claim_and_run(event, type, profile, client_id, transport, opts) do
    claim_opts =
      store_opts(opts, [transport: Atom.to_string(transport.name)] ++ transport.claimant)

    case store(opts).claim_client_request(profile, client_id, type, event.payload, claim_opts) do
      {:ok, {:claimed, request}} ->
        _ = best_effort_emit(opts, transport.reply_to, accepted_event(client_id, false, request))
        acquire_and_run(event, type, profile, client_id, transport, opts)

      {:ok, {:duplicate, request}} ->
        _ = best_effort_emit(opts, transport.reply_to, accepted_event(client_id, true, request))
        acquire_and_run(event, type, profile, client_id, transport, opts)

      {:ok, {:conflict, _request}} ->
        {:error, :client_message_conflict}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp acquire_and_run(event, type, profile, client_id, transport, opts) do
    case coordinator(opts).acquire(
           coordinator_server(opts),
           profile,
           client_id,
           store_opts(opts)
         ) do
      {:ok, {:started, %{attempt: attempt}}} when is_integer(attempt) and attempt > 0 ->
        run_started(event, type, profile, client_id, attempt, transport, opts)

      {:ok, {state, _row}} when state in [:active, :completed, :failed] ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_started(event, type, profile, client_id, attempt, transport, opts) do
    {deferred_ref, defer_command_fn} =
      deferred_lifecycle(type, profile, client_id, attempt, transport, opts)

    run = %{
      event: event,
      type: type,
      profile: profile,
      client_id: client_id,
      attempt: attempt,
      transport: transport,
      deferred_ref: deferred_ref,
      defer_command_fn: defer_command_fn
    }

    run
    |> guarded_span(opts)
    |> settle_request_error(run, opts)
  end

  # This process owns settlement only until `ingest_gateway` hands the turn to
  # the queue. A raise or exit inside that span would otherwise leave the request
  # `running` under this boot epoch with nobody left to settle it, so the attempt
  # is failed here before the crash continues to propagate untouched.
  defp guarded_span(run, opts) do
    ingest_span(run, opts)
  rescue
    exception ->
      fail_attempt(run, exception, opts)
      reraise exception, __STACKTRACE__
  catch
    kind, value ->
      fail_attempt(run, {kind, value}, opts)
      :erlang.raise(kind, value, __STACKTRACE__)
  end

  defp ingest_span(run, opts) do
    with {:ok, prepared, media_refs} <- resolve_attachments(run.event, opts),
         {:ok, [message]} <- parse_inbound(run.transport, prepared),
         message = with_attempt(message, run.transport.attempt_key, run.attempt),
         {:ok, {append_status, row}} <-
           append_user(run.profile, message, run.client_id, media_refs, opts),
         :ok <- after_user_append(run.transport, append_status, run.profile, row, message, opts),
         :ok <- ingest_gateway(message, run, opts) do
      settle_after_ingest(run, opts)
    end
  end

  # Ingest has returned, and this process may disconnect at any moment, so the
  # settlement owner holds the attempt's fence from here. A deferred command's
  # background run settles the request when it reports. Otherwise the owner
  # decides, after the hand-off this process sent it during ingest: a turn it
  # was handed settles from its outcome, and a request answered inline is
  # settled there and then.
  defp settle_after_ingest(run, opts) do
    with {:ok, owner} <- handoff_settlement(run, settlement_owner(opts), opts) do
      if deferred?(run.deferred_ref), do: :ok, else: settle_unless_handed_off(owner, run, opts)
    end
  end

  defp settle_unless_handed_off(owner, run, opts) do
    settlement = %{
      settle: fn -> settle_inline(run, opts) end,
      fail: fn cause -> fail_attempt(run, cause, opts) end,
      report: fn cause -> report_failure(run, cause) end
    }

    Turns.settle_unless_handed_off(owner, run.profile, run.client_id, run.attempt, settlement)
  end

  # Move the coordinator's liveness fence onto the settlement owner so its
  # death, not this client's disconnect, releases the attempt.
  defp handoff_settlement(run, owner_name, opts) do
    case GenServer.whereis(owner_name) do
      owner when is_pid(owner) ->
        :ok =
          coordinator(opts).handoff(
            coordinator_server(opts),
            run.profile,
            run.client_id,
            run.attempt,
            owner
          )

        {:ok, owner}

      nil ->
        {:error, {:settlement_owner_unavailable, owner_name}}
    end
  end

  defp fail_attempt(run, cause, opts) do
    fields = %{error: %{type: run.type, reason: inspect(cause)}}

    settle_failed(run.profile, run.client_id, run.attempt, fields, opts)
  end

  # A request that fails once its worker has returned is told to its client
  # here, correlated by its `client_msg_id`, in the error its own transport
  # builds for a failed request (`t:transport/0`).
  defp report_failure(run, cause) do
    case run.transport.report_failure.(run.client_id, cause) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "companion request #{run.client_id} failed, and its client could not be told: " <>
            inspect(reason)
        )
    end
  end

  # One client event that becomes a gateway message is one inbound message for
  # its channel, counted here — the single ingress every `msg` and `command`
  # passes through.
  defp parse_inbound(transport, event) do
    {result, duration_us} = Telemetry.timed_us(fn -> transport.channel.parse_event(event) end)

    _ = emit_inbound_message(transport.name, result, duration_us)
    result
  end

  defp emit_inbound_message(channel, {:ok, messages}, duration_us) when messages != [] do
    ChannelTelemetry.emit_message(channel, :inbound, length(messages), duration_us)
  end

  defp emit_inbound_message(_channel, _result, _duration_us), do: :ok

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

  defp after_user_append(%{after_user_append: effect}, :created, profile, row, message, opts)
       when is_function(effect, 4),
       do: effect.(profile, row, message.content, opts)

  defp after_user_append(_transport, _status, _profile, _row, _message, _opts), do: :ok

  # The gateway answered the request without a turn, and any reply it wrote is
  # already the request's output, so the request is complete.
  defp settle_inline(run, opts) do
    with {:ok, request} <-
           store(opts).complete_client_request(
             run.profile,
             run.client_id,
             run.attempt,
             %{},
             store_opts(opts)
           ) do
      after_settle(run.transport, run.profile, request, opts)
    end
  end

  # A `msg` gets the lifecycle a `command` has: the gateway reads a slash
  # command in either, and calls this only for a command that answers later.
  defp deferred_lifecycle(type, profile, client_id, attempt, transport, opts) do
    owner = self()
    ref = make_ref()

    defer = fn ->
      send(owner, {ref, :deferred})

      fn outcome ->
        settle_deferred(outcome, type, profile, client_id, attempt, transport, opts)
      end
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

  defp settle_deferred(:completed, _type, profile, client_id, attempt, transport, opts) do
    with {:ok, request} <-
           store(opts).complete_client_request(
             profile,
             client_id,
             attempt,
             %{},
             store_opts(opts)
           ) do
      after_settle(transport, profile, request, opts)
    end
  end

  defp settle_deferred({:failed, reason}, type, profile, client_id, attempt, transport, opts) do
    fields = %{error: %{type: type, reason: inspect(reason)}}

    with {:ok, request} <-
           store(opts).fail_client_request(
             profile,
             client_id,
             attempt,
             fields,
             store_opts(opts)
           ) do
      after_settle(transport, profile, request, opts)
    end
  end

  defp after_settle(%{after_settle: effect}, profile, request, opts)
       when is_function(effect, 3),
       do: effect.(profile, request, opts)

  defp after_settle(_transport, _profile, _request, _opts), do: :ok

  defp ingest_gateway(message, run, opts) do
    gateway(opts).ingest([message],
      channel: run.transport.channel,
      agent: Keyword.get(opts, :agent, Turns),
      agent_server: Keyword.get(opts, :agent_server, Queue),
      ingress_context: run.transport.ingress_context,
      defer_command_fn: run.defer_command_fn,
      approval_resolution_fn: approval_resolution_fn(message.chat_id, run.transport.name, opts),
      ingest_enriched_fn: enrichment_fn(message.chat_id, run.client_id, run.attempt, opts)
    )
  end

  # A token resolves only on the transport that raised its card, which is the
  # one this request came on, so the card is forgotten and its resolution
  # announced there alone; a client that connects from then on is never sent
  # it again.
  defp approval_resolution_fn(profile_id, transport, opts) do
    fn %{kind: kind, token: token, outcome: outcome} ->
      resolved = Output.approval_resolved(kind, token, outcome)
      Approvals.resolve(approvals(opts), profile_id, resolved, transport)
    end
  end

  defp settle_request_error(:ok, _run, _opts), do: :ok

  defp settle_request_error({:error, reason}, run, opts) do
    fields = %{error: %{type: run.type, reason: inspect(reason)}}
    settle_failed(run.profile, run.client_id, run.attempt, fields, opts)
    {:error, reason}
  end

  # A durable settle that itself fails would otherwise wedge the row in
  # `running` invisibly, so the write's own failure is always reported.
  defp settle_failed(profile, client_id, attempt, fields, opts) do
    case store(opts).fail_client_request(profile, client_id, attempt, fields, store_opts(opts)) do
      {:ok, _request} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "companion request #{inspect({profile, client_id})} attempt #{attempt} could not be " <>
            "settled as failed: #{inspect(reason)}"
        )

        :ok
    end
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

    if type in ["msg", "command"] and is_map(payload) and profile == @profile and
         payload["profile_id"] == profile and payload["client_msg_id"] == client_id do
      {:ok, %{type: type, payload: payload}, type, profile, client_id}
    else
      {:error, :invalid_recovery_envelope}
    end
  end

  defp with_attempt(message, key, attempt) do
    %{message | metadata: Map.put(message.metadata, key, attempt)}
  end

  defp profile(payload) do
    case Map.get(payload, "profile_id") do
      @profile -> {:ok, @profile}
      _other -> {:error, :unsupported_profile}
    end
  end

  defp required(payload, key) do
    case Map.get(payload, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_field, key}}
    end
  end

  defp history_cursor(%{"before_seq" => before_seq}), do: [before_seq: before_seq]
  defp history_cursor(payload), do: [after_seq: payload["after_seq"]]

  defp accepted_event(client_id, duplicate, request) do
    %{"t" => "accepted", "client_msg_id" => client_id, "duplicate" => duplicate}
    |> maybe_put("server_seq", Map.get(request, :result_server_seq))
  end

  defp history_event(profile, page, messages) do
    %{
      "t" => "history_page",
      "profile_id" => profile,
      "messages" => messages,
      "history_head_seq" => Map.get(page, :history_head_seq, Map.get(page, :next_after_seq))
    }
    |> history_cursor_event(page)
  end

  defp history_cursor_event(event, %{next_before_seq: seq}),
    do: maybe_put(event, "next_before_seq", seq)

  defp history_cursor_event(event, page),
    do: Map.put(event, "next_after_seq", page.next_after_seq)

  defp search_event(profile, query, page) do
    %{
      "t" => "search_results",
      "profile_id" => profile,
      "query" => query,
      "hits" => Enum.map(page.hits, &search_hit/1)
    }
    |> maybe_put("next_before_seq", page.next_before_seq)
  end

  defp search_hit(hit) do
    %{
      "server_seq" => hit.server_seq,
      "role" => hit.role,
      "ts" => DateTime.to_iso8601(hit.created_at),
      "excerpt" => hit.excerpt,
      "ranges" => Enum.map(hit.ranges, &%{"start" => &1.start, "length" => &1.length})
    }
  end

  defp timeline_messages(%{messages: rows}) when is_list(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case Output.timeline_message(row) do
        {:ok, message} -> {:cont, {:ok, [message | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      {:error, reason} -> {:error, reason}
    end)
  end

  defp timeline_messages(page), do: {:error, {:invalid_history_page, page}}

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
      "size_bytes" => value(attachment, :size_bytes)
    }
    |> maybe_put("filename", value(attachment, :file_name))
  end

  defp normalize_kind(kind) when kind in ["image", :image], do: :image
  defp normalize_kind(kind) when kind in ["audio", :audio], do: :audio
  defp normalize_kind(kind) when is_atom(kind), do: kind
  defp normalize_kind(_kind), do: :document

  defp emit(opts, target, event), do: Keyword.fetch!(opts, :event_sink).(target, event)

  defp best_effort_emit(opts, target, event) do
    case emit(opts, target, event) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("companion event fanout failed for #{inspect(target)}: #{inspect(reason)}")

        :ok
    end
  end

  # A page's rows are added while the encoded page stays within the budget,
  # oldest first going forward and newest first going back, and at least one
  # always ships so the client moves on. A cut page's cursor names the last
  # row sent, and the client pulls the rest from it.
  defp fit_page(%{"messages" => messages} = event, payload, budget) do
    with {:ok, sizes} <- encoded_sizes(messages),
         {:ok, [base]} <- encoded_sizes([%{event | "messages" => []}]) do
      if base + Enum.sum(sizes) <= budget,
        do: {:ok, event},
        else: {:ok, cut_page(event, Enum.zip(messages, sizes), payload, budget - base)}
    end
  end

  defp cut_page(event, sized, %{"before_seq" => _before}, room) do
    kept = sized |> Enum.reverse() |> take_within(room) |> Enum.reverse()
    event |> Map.put("messages", kept) |> Map.put("next_before_seq", hd(kept)["server_seq"])
  end

  defp cut_page(event, sized, _payload, room) do
    kept = take_within(sized, room)
    event |> Map.put("messages", kept) |> Map.put("next_after_seq", List.last(kept)["server_seq"])
  end

  defp take_within([{first, size} | rest], room) do
    {kept, _left} =
      Enum.reduce_while(rest, {[first], room - size}, fn {message, size}, {kept, left} ->
        if size <= left,
          do: {:cont, {[message | kept], left - size}},
          else: {:halt, {kept, left}}
      end)

    Enum.reverse(kept)
  end

  # Each element's JSON size plus the separator that follows it in a list.
  defp encoded_sizes(terms) do
    Enum.reduce_while(terms, {:ok, []}, fn term, {:ok, sizes} ->
      case Jason.encode(term) do
        {:ok, json} -> {:cont, {:ok, [byte_size(json) + 1 | sizes]}}
        {:error, reason} -> {:halt, {:error, {:unencodable_history_page, reason}}}
      end
    end)
    |> then(fn
      {:ok, sizes} -> {:ok, Enum.reverse(sizes)}
      {:error, reason} -> {:error, reason}
    end)
  end

  defp store(opts), do: Keyword.get(opts, :store, Timeline)
  defp settlement_owner(opts), do: Keyword.get(opts, :settlement_owner, Turns)
  defp gateway(opts), do: Keyword.get(opts, :gateway, Gateway)
  defp coordinator(opts), do: Keyword.get(opts, :coordinator, RequestCoordinator)
  defp approvals(opts), do: Keyword.get(opts, :approvals, Approvals.server())

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
