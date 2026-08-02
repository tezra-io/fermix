defmodule FermixChannels.Harness.ContinuationDispatcher do
  @moduledoc """
  Channels-side implementation of `FermixCore.Harness.ContinuationDispatcher`
  (design §23.2): re-ingests a finished coding run's completion notice into its
  originating conversation.

  Core hands over plain data (platform, destination, thread, content, metadata)
  because `fermix_core` must never compile-depend on `fermix_channels`; this
  module owns the `Message` struct, the gateway, and the agent queue. The
  mechanism is the sandbox-grant `/confirm` auto-resume, reused rather than
  re-invented: synthesize an inbound message and `Gateway.ingest/2` it, so
  authorization, the reply surface, and per-conversation queueing all happen
  exactly as for real inbound.

  The ingest runs **inline** and its result is the return value — the grant
  resume's async hop exists because it re-enters the same `Gateway.ingest`
  pipeline from inside it, which is not the case here, and reporting success
  before the gateway accepted the message would let the manager mark a run
  `delivered` that nobody was ever told about. `Gateway.ingest/2` ends in a
  `GenServer.cast` to the queue, so this never waits on the agent turn; core
  additionally runs the whole call under its delivery watchdog.

  Every precondition is checked first, and any failure — precondition or ingest —
  returns `{:error, reason}` so the manager leaves the run's durable delivery
  pending and the owner still gets the outcome as text:

    * the channel must be known (an adapter to reply through);
    * the sender must be resolvable — a channel that is operator-equivalent *by
      transport* needs no sender id at all, and any other remote channel must have
      an explicit owner user id, because a chat-origin run is always an operator
      turn (`Harness.Authorization` refuses guests) and the continuation
      re-ingests as that owner without ever escalating trust;
    * a client-owned origin's identity must still be in the store;
    * the agent queue must be alive.

  One window is deliberately left open: if the queue dies *between* that liveness
  check and the enqueue, the gateway replies "I'm restarting…" into the same chat
  and reports `:ok` — the owner is told something, just not the outcome. Making
  that branch an error would turn every transport's restart-in-progress inbound
  into a transport failure (a webhook 5xx → provider redelivery → duplicate
  turns), which is worse than this one chat message.

  ## Client-owned origins (M29 §17.6(c))

  On a surface like ACP the launching session is gone minutes before the run
  finishes, and the deliverable is the model's own post with the *client's*
  credentials rather than anything on the ACP wire. So for a notice carrying a
  `client_origin`, `build_message/5` — the single injection point — resolves the
  durable identity record and stamps the turn's `session_env` and `request_cwd`
  from it. `Acp.Identity.to_env/1` stays the one producer of a turn env: core's
  turn path is untouched and still reads `msg.session_env` and nothing else.

  The origin's third field, `reply_context`, is not read here and must not be:
  it is addressed to the continuation turn's model, and `Harness.Continuation`
  has already rendered it into `content` inside its own untrusted frame. Fermix
  parses it nowhere.
  """

  @behaviour FermixCore.Harness.ContinuationDispatcher

  require Logger

  alias FermixChannels.Channels.Acp
  alias FermixChannels.Gateway
  alias FermixChannels.Gateway.ChannelRegistry
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.Queue
  alias FermixCore.Acp.Identity
  alias FermixCore.Acp.IdentityStore
  alias FermixCore.Config
  alias FermixCore.Nostr.Key

  @impl true
  @spec dispatch(FermixCore.Harness.ContinuationDispatcher.notice()) :: :ok | {:error, term()}
  def dispatch(notice) when is_map(notice), do: dispatch(notice, [])

  @doc """
  Same as `dispatch/1` with injectable seams: `:ingest` (default
  `Gateway.ingest/2`), `:agent`, and `:agent_server` (both default to the
  `Gateway.Queue`, the transports' default).
  """
  @spec dispatch(map(), keyword()) :: :ok | {:error, term()}
  def dispatch(notice, opts) when is_map(notice) and is_list(opts) do
    with {:ok, platform, destination} <- target(notice),
         {:ok, adapter} <- adapter(platform),
         {:ok, sender_id} <- owner_id(platform),
         {:ok, origin} <- client_origin(notice),
         :ok <- ensure_agent_alive(agent_server(opts)) do
      notice
      |> build_message(platform, destination, sender_id, origin)
      |> run_ingest(adapter, opts)
    end
  end

  # --- Preconditions ------------------------------------------------------

  defp target(notice) do
    case {Map.get(notice, :platform), Map.get(notice, :destination)} do
      {platform, destination} when is_binary(platform) and is_binary(destination) ->
        {:ok, platform, destination}

      other ->
        {:error, {:invalid_continuation_target, other}}
    end
  end

  defp adapter(platform) do
    case ChannelRegistry.adapter(platform) do
      module when is_atom(module) and not is_nil(module) -> {:ok, module}
      nil -> {:error, {:unknown_continuation_channel, platform}}
    end
  end

  # "Needs no sender id" is a property of transport TRUST, not of `remote?: false`
  # (M29 §17.6(c)). `Authorizer.resolve/1` consults `ChannelRegistry.trust/1`
  # first, so on a `:local_operator` channel the stamped `metadata[:user_id]` is
  # never read — asking for one would be config for a value nothing consults, and
  # a surface like ACP (persistent sessions, hence `remote?: true`) has none to
  # give.
  defp owner_id(platform) do
    if operator_by_transport?(platform) do
      {:ok, nil}
    else
      configured_owner(ChannelRegistry.channel_key(platform), platform)
    end
  end

  defp operator_by_transport?(platform) do
    ChannelRegistry.local?(platform) or ChannelRegistry.trust(platform) == :local_operator
  end

  defp configured_owner(nil, platform), do: {:error, {:unknown_continuation_channel, platform}}

  defp configured_owner(key, platform) do
    case Config.channel_explicit_owner_user_id(key) do
      owner when is_binary(owner) and owner != "" -> {:ok, owner}
      _absent -> {:error, {:no_owner_configured, platform}}
    end
  end

  # A client-owned origin resolves its identity FROM THE STORE at message-build
  # time — never from connection state, which no longer exists (§17.1).
  defp client_origin(notice) do
    case Map.get(notice, :client_origin) do
      origin when is_map(origin) -> resolve_identity(origin)
      _framework_delivered -> {:ok, nil}
    end
  end

  # Its own NAMED refusal, distinct from `unknown_continuation_channel` and
  # `no_owner_configured`, and it must reach the ledger rather than only the log:
  # a forgotten credential reported as an unsupported platform would tell the
  # operator delivery was never implemented, when a reconnect restores it. The
  # store's own kind (missing / quarantined / wrong permissions) rides inside, so
  # the three do not collapse into one message either.
  defp resolve_identity(origin) do
    case Map.get(origin, "identity") do
      id when is_binary(id) -> fetch_identity(id, origin)
      absent -> identity_gone(absent, {:identity_unnamed, absent})
    end
  end

  defp fetch_identity(id, origin) do
    case IdentityStore.fetch(id) do
      {:ok, identity} -> {:ok, %{env: Identity.to_env(identity), cwd: Map.get(origin, "cwd")}}
      {:error, reason} -> identity_gone(id, reason)
    end
  end

  defp identity_gone(id, reason) do
    refusal = {:identity_forgotten, display_id(id), reason}

    Logger.warning(
      "harness continuation refused: the client identity is no longer readable " <>
        "(#{inspect(refusal)}); reconnect the client to restore it"
    )

    {:error, refusal}
  end

  # npub only on any operator-facing surface — never the raw hex, never a value.
  defp display_id(id) when is_binary(id) do
    case Key.npub(id) do
      {:ok, npub} -> npub
      {:error, _malformed} -> :unnamed_identity
    end
  end

  defp display_id(_absent), do: :unnamed_identity

  defp ensure_agent_alive(agent_server) do
    if alive?(agent_server), do: :ok, else: {:error, {:agent_unavailable, agent_server}}
  end

  defp alive?(server) when is_pid(server), do: Process.alive?(server)
  defp alive?(server) when is_atom(server), do: is_pid(Process.whereis(server))

  # --- Message + ingest ---------------------------------------------------

  # The single injection point for a client-owned turn's env and cwd. Without the
  # env the continuation's shell would get the daemon's bare PATH, no client
  # credentials, and — because `TurnRunner` derives its telemetry scrub FROM
  # `session_env` — no redaction either, silently unscrubbing the one turn nobody
  # is watching.
  defp build_message(notice, platform, destination, sender_id, origin) do
    Message.new!(%{
      id: "harness-continuation-#{System.unique_integer([:positive])}",
      content: Map.fetch!(notice, :content),
      sender: "fermix",
      channel: platform,
      chat_id: destination,
      reply_target: destination,
      thread_ts: Map.get(notice, :thread),
      session_env: origin && origin.env,
      request_cwd: origin && origin.cwd,
      metadata: metadata(notice, sender_id, origin)
    })
  end

  defp metadata(notice, sender_id, origin) do
    notice
    |> Map.get(:metadata, %{})
    |> put_user_id(sender_id)
    |> put_detached(origin)
  end

  defp put_user_id(metadata, sender_id) when is_binary(sender_id),
    do: Map.put(metadata, :user_id, sender_id)

  defp put_user_id(metadata, nil), do: metadata

  # The client session that owned this conversation is gone, so every per-turn
  # closure the adapter builds has no turn to fence against. The sentinel makes
  # that a quiet, NAMED no-op instead of a `Logger.error` per stream delta: the
  # deliverable here is the model's own post, and the wire reply is
  # best-effort-if-alive. `nil` still means bug.
  defp put_detached(metadata, nil), do: metadata
  defp put_detached(metadata, _origin), do: Map.put(metadata, Acp.turn_opt(), Acp.detached_turn())

  # The gateway's verdict IS this function's return value: a refusal it can only
  # see here (invalid message, transcription/media, command error) must reach the
  # manager, or the run is marked `delivered` with nobody notified.
  defp run_ingest(message, adapter, opts) do
    ingest = Keyword.get(opts, :ingest, &Gateway.ingest/2)

    ingest_opts = [
      channel: adapter,
      agent: Keyword.get(opts, :agent, Queue),
      agent_server: agent_server(opts)
    ]

    case ingest.([message], ingest_opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("harness continuation ingest failed: #{inspect(reason)}")
        {:error, {:continuation_ingest_failed, reason}}
    end
  end

  defp agent_server(opts), do: Keyword.get(opts, :agent_server, Queue)
end
