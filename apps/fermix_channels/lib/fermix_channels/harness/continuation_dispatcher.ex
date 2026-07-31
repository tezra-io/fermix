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
    * a remote channel must have an explicit owner user id — a chat-origin run is
      always an operator turn (`Harness.Authorization` refuses guests), so the
      continuation re-ingests as that owner and never escalates trust;
    * the agent queue must be alive.

  One window is deliberately left open: if the queue dies *between* that liveness
  check and the enqueue, the gateway replies "I'm restarting…" into the same chat
  and reports `:ok` — the owner is told something, just not the outcome. Making
  that branch an error would turn every transport's restart-in-progress inbound
  into a transport failure (a webhook 5xx → provider redelivery → duplicate
  turns), which is worse than this one chat message.
  """

  @behaviour FermixCore.Harness.ContinuationDispatcher

  require Logger

  alias FermixChannels.Gateway
  alias FermixChannels.Gateway.ChannelRegistry
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.Queue
  alias FermixCore.Config

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
         :ok <- ensure_agent_alive(agent_server(opts)) do
      notice
      |> build_message(platform, destination, sender_id)
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

  defp owner_id(platform) do
    case ChannelRegistry.channel_key(platform) do
      nil -> local_channel(platform)
      key -> configured_owner(key, platform)
    end
  end

  # A loopback channel (cli, daemon) is operator-equivalent by channel, so it
  # needs no sender id at all.
  defp local_channel(platform) do
    if ChannelRegistry.local?(platform) do
      {:ok, nil}
    else
      {:error, {:unknown_continuation_channel, platform}}
    end
  end

  defp configured_owner(key, platform) do
    case Config.channel_explicit_owner_user_id(key) do
      owner when is_binary(owner) and owner != "" -> {:ok, owner}
      _absent -> {:error, {:no_owner_configured, platform}}
    end
  end

  defp ensure_agent_alive(agent_server) do
    if alive?(agent_server), do: :ok, else: {:error, {:agent_unavailable, agent_server}}
  end

  defp alive?(server) when is_pid(server), do: Process.alive?(server)
  defp alive?(server) when is_atom(server), do: is_pid(Process.whereis(server))

  # --- Message + ingest ---------------------------------------------------

  defp build_message(notice, platform, destination, sender_id) do
    Message.new!(%{
      id: "harness-continuation-#{System.unique_integer([:positive])}",
      content: Map.fetch!(notice, :content),
      sender: "fermix",
      channel: platform,
      chat_id: destination,
      reply_target: destination,
      thread_ts: Map.get(notice, :thread),
      metadata: metadata(notice, sender_id)
    })
  end

  defp metadata(notice, sender_id) do
    notice
    |> Map.get(:metadata, %{})
    |> put_user_id(sender_id)
  end

  defp put_user_id(metadata, sender_id) when is_binary(sender_id),
    do: Map.put(metadata, :user_id, sender_id)

  defp put_user_id(metadata, nil), do: metadata

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
