defmodule FermixChannels.Gateway.WebhookIngress do
  @moduledoc """
  What a webhook channel does with a payload it has verified, in one place:
  parse it with the channel's adapter, drop every id `Gateway.Idempotency` has
  seen, and hand the rest to the turn queue in a task.

  The web endpoint's routes (`POST /webhook/slack`, `POST /webhook/whatsapp`)
  call `ingest/3` once their signature checks pass, and Slack's Socket Mode
  client (`Channels.Slack.SocketMode`) calls it with each `events_api`
  envelope's payload, so a Slack event takes exactly one path whichever
  transport carried it.

  The answer tells the transport what to say to the provider: `:ok` once every
  fresh message is handed off, `{:error, {:parse, reason}}` for a payload the
  adapter refused, and `{:error, {:handoff, reason}}` when nothing could be
  handed off (the idempotency store could not answer, or the task could not
  start). On a hand-off failure every id this call recorded is forgotten again
  (audit F-06 follow-up), so the provider's retry runs through the fresh path
  instead of being absorbed as a duplicate.

  WhatsApp's messages go through its album buffer, which coalesces the images
  of one album, sent as separate webhook messages, into one turn; every other
  channel's go straight to `Gateway.ingest/2`.
  """

  require Logger

  alias FermixChannels.Channels.WhatsApp
  alias FermixChannels.Gateway
  alias FermixChannels.Gateway.AlbumBuffer
  alias FermixChannels.Gateway.Idempotency
  alias FermixChannels.Gateway.Queue

  @type result :: :ok | {:error, {:parse, term()} | {:handoff, term()}}

  @doc """
  Parses `payload` with `channel_module` (a `Gateway.Channel` adapter) and
  hands every message not seen before to the turn queue, under the
  idempotency key `channel_key`.
  """
  @spec ingest(atom(), module(), map()) :: result()
  def ingest(channel_key, channel_module, payload)
      when is_atom(channel_key) and is_atom(channel_module) and is_map(payload) do
    case channel_module.parse_webhook(payload) do
      {:ok, messages} when is_list(messages) -> hand_off(channel_key, messages, channel_module)
      {:error, reason} -> {:error, {:parse, reason}}
    end
  end

  defp hand_off(channel_key, messages, channel_module) do
    case filter_fresh(messages, channel_key) do
      {:ok, fresh} -> dispatch_fresh(channel_key, messages, fresh, channel_module)
      {:error, recorded, reason} -> roll_back(channel_key, recorded, reason)
    end
  end

  # Stops at the first id the store cannot answer for: the ones recorded
  # before it are rolled back with the rest of the hand-off.
  defp filter_fresh(messages, channel_key) do
    messages
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, fresh} ->
      case Idempotency.check_and_record(channel_key, message.id) do
        :fresh ->
          {:cont, {:ok, [message | fresh]}}

        :duplicate ->
          Logger.info(
            "#{channel_key} webhook dropped duplicate message #{inspect(message.id)} (idempotency)"
          )

          {:cont, {:ok, fresh}}

        {:error, reason} ->
          {:halt, {:error, Enum.reverse(fresh), reason}}
      end
    end)
    |> then(fn
      {:ok, fresh} -> {:ok, Enum.reverse(fresh)}
      {:error, _recorded, _reason} = error -> error
    end)
  end

  defp dispatch_fresh(channel_key, messages, fresh, channel_module) do
    case dispatch_async(fresh, channel_module) do
      :ok ->
        :telemetry.execute(
          [:fermix, :channel, :webhook],
          %{count: length(fresh), duplicates: length(messages) - length(fresh)},
          %{channel: channel_key}
        )

        :ok

      {:error, reason} ->
        roll_back(channel_key, fresh, reason)
    end
  end

  # A forget that fails logs its own sentence (`Idempotency.forget/3`).
  defp roll_back(channel_key, recorded, reason) do
    Enum.each(recorded, &Idempotency.forget(channel_key, &1.id))

    Logger.error(
      "#{channel_key} webhook handoff failed; idempotency rolled back: #{inspect(reason)}"
    )

    {:error, {:handoff, reason}}
  end

  defp dispatch_async([], _channel_module), do: :ok

  defp dispatch_async(messages, channel_module) do
    work = fn -> run_dispatch(messages, channel_module) end

    case Task.Supervisor.start_child(FermixCore.TaskSupervisor, work) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      :ignore -> :ok
      {:error, _reason} = err -> err
    end
  end

  # Idempotency is already recorded per message id before this point, so the
  # album buffer never sees duplicates.
  defp run_dispatch(messages, WhatsApp) do
    buffer = AlbumBuffer.name_for(WhatsApp)
    Enum.each(messages, &AlbumBuffer.ingest(&1, buffer))
  end

  defp run_dispatch(messages, channel_module) do
    opts = [channel: channel_module, agent: Queue, agent_server: Queue]

    case Gateway.ingest(messages, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Async webhook dispatch failed for #{inspect(channel_module)}: #{inspect(reason)}"
        )
    end
  end
end
