defmodule FermixCore.Jobs.HealRun do
  @moduledoc """
  One heal's message to the owner (M106 §5.4): no model runs, and code
  builds and sends the one message.

  The Scheduler claims a heal under a lease (`Memory.Repo.JobHealsSql`, the
  heal `diagnosing`) and starts this process under `Jobs.RunnerSupervisor`,
  one at a time in the engine; it monitors it as it does a runner.
  `restart: :temporary`, and `init/1` does no work (it defers to
  `handle_continue/2`), so the Scheduler never waits on a send.

  The run, every write holding the lease:

    1. resolves the owner's inbox once, if the heal holds none, with
       `Delivery.OwnerInbox.for_approval/1`, and stores it; with no inbox the
       delivery is a dead letter, the heal waits, and nothing else is tried;
    2. builds the message once with `Jobs.HealMessage` from the store's facts
       and stores it, so every later attempt sends the same text;
    3. sends it once through `Delivery.ChannelSend` under the key
       `job_heal:<id>` (never `job:`, the prefix `Companion.OriginBackfill`
       reads as a run), naming the job as its origin, link previews off;
    4. on a confirmed send, FIRST marks the delivery delivered and the heal
       waiting, THEN writes the message to that conversation's history, and
       only for an inbox keyed as a turn there is (`OwnerInbox.dm_origin/1`).
       A history write that exits is logged and the run still ends normally;
    5. on a failed send, counts the attempt and sets the next by the harness
       ladder (30 s doubling to a 30 min cap, a rate limit's wait the floor),
       the heal open again; an error no wait clears, the 20th attempt or a
       heal a day old makes the delivery a dead letter and the heal waits.

  A heal run that dies leaves its lease to run out, and a later pass claims
  the heal again. So the owner can get the message twice: a run that dies
  after its send landed and before its delivered mark (or whose mark found the
  lease gone) leaves a heal the next run sends again. The delivered mark comes
  before the history row so a death between those two never resends.
  """

  use GenServer, restart: :temporary

  require Logger

  alias FermixCore.Delivery.ChannelSend
  alias FermixCore.Delivery.Error
  alias FermixCore.Delivery.OwnerInbox
  alias FermixCore.Jobs.Delivery
  alias FermixCore.Jobs.HealMessage
  alias FermixCore.Jobs.Telemetry, as: JobTelemetry
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo

  @heal_id_key :fermix_job_heal_id
  @send_timeout_ms 60_000
  @backoff_base_ms 30_000
  @backoff_cap_ms 1_800_000
  @max_attempts 20
  @max_age_s 86_400

  @doc """
  The heal a live heal run holds, read from the process-dictionary key it
  publishes in its own start (`put_heal_id/1`), never by calling it.
  """
  @spec heal_id(pid()) :: String.t() | nil
  def heal_id(pid) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> Keyword.get(dictionary, @heal_id_key)
      nil -> nil
    end
  end

  @doc "Publishes the heal this process runs for `heal_id/1`."
  @spec put_heal_id(String.t()) :: :ok
  def put_heal_id(id) when is_binary(id) do
    Process.put(@heal_id_key, id)
    :ok
  end

  @doc """
  Starts the run for a claimed heal. `opts`: `:heal` (the claimed row),
  `:repo`, `:conversation_store`, `:delivery_opts` (`ChannelSend`'s `:adapter`
  or `:channels`), `:inbox_opts` (`OwnerInbox.for_approval/1`'s seams), `:clock`
  and `:clock_opts` (`FermixCore.Clock`'s).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    %{id: id, lease_token: token} = Keyword.fetch!(opts, :heal)
    true = is_binary(id) and is_binary(token)
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    heal = Keyword.fetch!(opts, :heal)
    :ok = put_heal_id(heal.id)

    state = %{
      heal: heal,
      repo: Keyword.fetch!(opts, :repo),
      conversation_store: Keyword.get(opts, :conversation_store, ConversationStore),
      delivery_opts: Keyword.get(opts, :delivery_opts, []),
      inbox_opts: Keyword.get(opts, :inbox_opts, []),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      clock_opts: Keyword.get(opts, :clock_opts, [])
    }

    {:ok, state, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    with {:ok, inbox} <- inbox(state),
         {:ok, text} <- message(state) do
      deliver(state, inbox, text)
    else
      {:error, reason} -> log_unsent(state, reason)
    end

    {:stop, :normal, state}
  end

  # --- the inbox and the message, each settled once -----------------------------

  defp inbox(%{heal: %{inbox_platform: platform} = heal}) when is_binary(platform) do
    {:ok,
     %{
       platform: platform,
       destination: heal.inbox_destination,
       thread_scope: heal.inbox_thread_scope
     }}
  end

  defp inbox(state) do
    case OwnerInbox.for_approval(state.inbox_opts) do
      {:ok, inbox} ->
        with :ok <- write(state, {:put_inbox, state.heal.id, token(state), inbox, now(state)}),
             do: {:ok, inbox}

      :no_delivery_target ->
        dead_letter(state, :no_delivery_target)
        {:error, :no_delivery_target}
    end
  end

  defp message(%{heal: %{message: text}}) when is_binary(text), do: {:ok, text}

  defp message(state) do
    with {:ok, facts} <- Repo.job_heals_call({:message_facts, state.heal.id}, server: state.repo) do
      text = HealMessage.build(facts, state.clock_opts)

      with :ok <- write(state, {:put_message, state.heal.id, token(state), text, now(state)}),
           do: {:ok, text}
    end
  end

  # --- the one send ----------------------------------------------------------------

  defp deliver(state, inbox, text) do
    case send_once(state, inbox, text) do
      :ok -> delivered(state, inbox, text)
      {:error, reason} -> send_failed(state, inbox, reason)
    end
  end

  defp send_once(state, inbox, text) do
    send_opts =
      Delivery.put_origin(
        [proactive_key: "job_heal:#{state.heal.id}", link_previews: false],
        :job,
        job_name(state)
      )

    opts = Keyword.put(state.delivery_opts, :delivery_max_attempts, 1)

    @send_timeout_ms
    |> ChannelSend.with_timeout(fn ->
      ChannelSend.send(inbox.platform, inbox.destination, text, send_opts, opts)
    end)
    |> Error.normalize()
  end

  # The origin a job's message carries names the job; a provider's heal has
  # no one job to name.
  defp job_name(%{heal: %{subject_kind: "job", job_id: job_id}} = state) do
    case Repo.get_scheduled_job(job_id, server: state.repo) do
      {:ok, job} ->
        job.name

      {:error, reason} ->
        Logger.warning(
          "Job heal #{state.heal.id}: its job could not be read (#{inspect(reason)}), " <>
            "so its message names no origin"
        )

        nil
    end
  end

  defp job_name(_state), do: nil

  defp delivered(state, inbox, text) do
    case write(state, {:delivered, state.heal.id, token(state), now(state)}) do
      :ok ->
        trace(state, "delivered", %{platform: inbox.platform})
        record_history(state, inbox, text)

      {:error, reason} ->
        Logger.warning(
          "Job heal #{state.heal.id}: its message was sent, but the delivery could not be " <>
            "marked (#{inspect(reason)}), so a later pass may send it again"
        )
    end
  end

  defp record_history(state, inbox, text) do
    case OwnerInbox.dm_origin(inbox) do
      {:ok, _origin} -> add_history(state, inbox, text)
      :error -> :ok
    end
  end

  defp add_history(state, inbox, text) do
    :ok =
      ConversationStore.add_message({inbox.platform, inbox.destination, :root}, "assistant", text,
        kind: "chat_message",
        metadata: %{job_heal: state.heal.id},
        server: state.conversation_store
      )
  catch
    :exit, reason ->
      Logger.warning(
        "Job heal #{state.heal.id}: its message was delivered, but writing it to the " <>
          "conversation's history exited: #{inspect(reason)}"
      )
  end

  # --- a failed send ----------------------------------------------------------------

  defp send_failed(state, inbox, reason) do
    attempts = state.heal.delivery_attempts + 1
    now = now(state)

    if dead?(reason, attempts, state.heal.opened_at, now) do
      dead_letter(state, reason, attempts, inbox)
    else
      next = DateTime.add(now, backoff_ms(attempts, reason), :millisecond)
      failure = %{attempts: attempts, next_delivery_at: next, error: inspect(reason)}
      trace(state, "delivery_failed", %{attempts: attempts, dead_letter: false, error: reason})

      log_write(
        state,
        write(state, {:delivery_failed, state.heal.id, token(state), failure, now})
      )
    end
  end

  defp dead?(reason, attempts, opened_at, now) do
    not Error.retryable?(reason) or attempts >= @max_attempts or
      DateTime.diff(now, opened_at, :second) >= @max_age_s
  end

  # The harness ladder (`Harness.DeliveryWorker`): 30 s after the first
  # failure, doubling to a 30 min cap, and never sooner than a rate limit's
  # own wait.
  defp backoff_ms(attempts, reason) do
    shift = min(attempts - 1, 20)
    ladder = min(@backoff_base_ms * Bitwise.bsl(1, shift), @backoff_cap_ms)

    case Error.retry_after_hint(reason) do
      {:ok, wait_ms} -> max(ladder, min(wait_ms, @backoff_cap_ms))
      :error -> ladder
    end
  end

  defp dead_letter(state, reason, attempts \\ nil, inbox \\ nil) do
    attempts = attempts || state.heal.delivery_attempts
    platform = inbox && inbox.platform

    Logger.warning("Job heal #{state.heal.id}: its message is a dead letter: #{inspect(reason)}")

    trace(state, "delivery_failed", %{
      attempts: attempts,
      dead_letter: true,
      error: reason,
      platform: platform
    })

    failure = %{attempts: attempts, error: inspect(reason)}

    log_write(
      state,
      write(state, {:dead_letter, state.heal.id, token(state), failure, now(state)})
    )
  end

  # --- shared ------------------------------------------------------------------------

  defp write(state, request), do: Repo.job_heals_call(request, server: state.repo)

  defp log_write(_state, :ok), do: :ok

  defp log_write(state, {:error, reason}) do
    Logger.warning(
      "Job heal #{state.heal.id}: its delivery could not be recorded: #{inspect(reason)}"
    )
  end

  defp log_unsent(_state, :no_delivery_target), do: :ok

  defp log_unsent(state, reason) do
    trace(state, "delivery_failed", %{dead_letter: false, error: reason})

    Logger.warning(
      "Job heal #{state.heal.id}: its message was not sent (#{inspect(reason)}); " <>
        "a later pass tries again once its lease runs out"
    )
  end

  defp trace(state, phase, facts) do
    JobTelemetry.heal(
      phase,
      Map.merge(facts, %{
        heal_id: state.heal.id,
        job_id: state.heal.job_id,
        subject_kind: state.heal.subject_kind,
        subject_id: state.heal.subject_id,
        failure_kind: state.heal.failure_kind
      })
    )
  end

  defp token(state), do: state.heal.lease_token
  defp now(state), do: state.clock.()
end
