defmodule FermixChannels.Desktop.InvocationRegistry do
  @moduledoc """
  The primary's invocations in flight to its desktops (M75 §11), held outside
  any one desktop session so they outlive a reconnect.

  `invoke/6` sends one `invoke` to a connected desktop (`Desktop.Peer.send/4`)
  and blocks its caller until the invocation is settled, at most until its
  deadline and a short reconciliation after it. The desktop's family
  (`Desktop.Invocations`) hands every `invoke_blob`, `invoke_result` and
  `invoke_receipts` it receives here, and tells this process when the desktop's
  session starts.

  How an invocation is settled:

    * **its result**: `invoke_result`, with the `invoke_blob` that came before
      it for a `read_file`;
    * **a receipt**: when the desktop's session starts again while invocations
      are in flight, it is sent `invoke_status` for each of them (in batches of
      32, each under its own `status_id`), and a receipt in the
      `invoke_receipts` answer naming that `status_id` settles that invocation
      as `:reconciled`: it ran and ended as the receipt says, and is never sent
      again. An answer naming no `status_id` this registry still waits on (one
      a previous session asked, sent late) is refused and settles nothing;
    * **its deadline**: `deadline_s` and a grace for the answer to travel back.
      A desktop still connected is asked once more (`invoke_status`); a receipt
      settles it, and an answer without one, or none within the reconciliation
      window, settles it `:uncertain`. A desktop not connected settles it
      `:uncertain` at once. Nothing is re-sent, ever.

  A desktop's answer for an invocation of another desktop is refused, and one
  for an invocation already settled is logged and dropped. At most 8
  invocations are in flight per desktop; a ninth is refused `{:busy, 8}`
  before anything is sent.

  It runs under the phone channel's subtree (`Mobile.Supervisor`), which only
  the primary starts. Timers go through an injectable `:schedule`, so a test
  delivers a deadline by hand.
  """

  use GenServer

  require Logger

  alias FermixChannels.Desktop.Peer

  @max_in_flight 8
  @status_batch 32
  # Past `deadline_s`, for the answer to travel back over the rail.
  @result_grace_ms 5_000
  # How long a desktop asked about an invocation past its deadline has to answer.
  @reconcile_ms 10_000
  # The caller's bound beyond the deadline, grace and reconciliation, so the
  # registry's own answer always comes first.
  @call_margin_ms 5_000
  @statuses %{"ok" => :ok, "refused" => :refused, "failed" => :failed}

  @typedoc "What a settled invocation answers its caller with (the blob is the facade's to render)."
  @type raw_outcome ::
          %{
            kind: :result,
            status: :ok | :refused | :failed,
            result: map(),
            blob: binary() | nil,
            invocation_id: String.t()
          }
          | %{
              kind: :reconciled,
              status: :ok | :refused | :failed,
              finished_at: String.t(),
              invocation_id: String.t()
            }
          | %{kind: :uncertain, reason: :no_receipt | :disconnected, invocation_id: String.t()}

  @doc "At most this many invocations are in flight to one desktop."
  @spec max_in_flight() :: pos_integer()
  def max_in_flight, do: @max_in_flight

  @doc """
  Starts the registry. Options: `:name` (`nil` for none), `:peers` (the
  `Desktop.Peers` registry it sends through), and the `:schedule` a test
  replaces (a function of the message and the delay in milliseconds).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc false
  def child_spec(opts) when is_list(opts) do
    %{id: Keyword.get(opts, :name) || __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Sends `invocation_id` (`action`, its arguments JSON `payload`) to the
  connected desktop `device_id` and waits until it is settled. `{:error,
  :not_connected}` and `{:error, {:busy, max}}` send nothing.
  """
  @spec invoke(GenServer.server(), String.t(), String.t(), String.t(), binary(), 1..600) ::
          {:ok, raw_outcome()} | {:error, :not_connected | {:busy, pos_integer()} | term()}
  def invoke(server, device_id, invocation_id, action, payload, deadline_s)
      when is_binary(device_id) and is_binary(invocation_id) and is_binary(action) and
             is_binary(payload) and is_integer(deadline_s) and deadline_s in 1..600 do
    timeout = deadline_s * 1_000 + @result_grace_ms + @reconcile_ms + @call_margin_ms

    GenServer.call(
      server,
      {:invoke, device_id, invocation_id, action, payload, deadline_s},
      timeout
    )
  end

  @doc "The desktop `device_id`'s session started: ask it about every invocation still in flight."
  @spec connected(GenServer.server(), String.t()) :: :ok
  def connected(server, device_id) when is_binary(device_id),
    do: GenServer.cast(server, {:connected, device_id})

  @doc "A `read_file`'s bytes, which arrive before its result."
  @spec blob(GenServer.server(), String.t(), String.t(), binary()) :: :ok | {:error, term()}
  def blob(server, device_id, invocation_id, bytes)
      when is_binary(device_id) and is_binary(invocation_id) and is_binary(bytes),
      do: GenServer.call(server, {:blob, device_id, invocation_id, bytes})

  @doc "How an invocation ended, as the desktop said (`status` and its result JSON)."
  @spec result(GenServer.server(), String.t(), String.t(), String.t(), binary()) ::
          :ok | {:error, term()}
  def result(server, device_id, invocation_id, status, payload)
      when is_binary(device_id) and is_binary(invocation_id) and is_binary(status) and
             is_binary(payload),
      do: GenServer.call(server, {:result, device_id, invocation_id, status, payload})

  @doc "The desktop's answer to the `invoke_status` it names by `status_id`."
  @spec receipts(GenServer.server(), String.t(), String.t(), [map()]) ::
          :ok | {:error, term()}
  def receipts(server, device_id, status_id, receipts)
      when is_binary(device_id) and is_binary(status_id) and is_list(receipts),
      do: GenServer.call(server, {:receipts, device_id, status_id, receipts})

  @impl true
  def init(opts) do
    {:ok,
     %{
       entries: %{},
       asked: %{},
       peers: Keyword.get(opts, :peers, FermixChannels.Desktop.Peers),
       schedule: Keyword.get(opts, :schedule, &Process.send_after(self(), &1, &2))
     }}
  end

  @impl true
  def handle_call({:invoke, device_id, id, action, payload, deadline_s}, from, state) do
    cond do
      Map.has_key?(state.entries, id) ->
        {:reply, {:error, {:duplicate_invocation, id}}, state}

      in_flight(state, device_id) >= @max_in_flight ->
        {:reply, {:error, {:busy, @max_in_flight}}, state}

      true ->
        send_invoke(state, from, device_id, id, action, payload, deadline_s)
    end
  end

  def handle_call({:blob, device_id, id, bytes}, _from, state) do
    case owned(state, device_id, id) do
      {:ok, %{action: "read_file", blob: nil} = entry} ->
        {:reply, :ok, put_entry(state, %{entry | blob: bytes})}

      {:ok, _entry} ->
        {:reply, {:error, {:unexpected_blob, id}}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:result, device_id, id, status, payload}, _from, state) do
    case owned(state, device_id, id) do
      {:ok, entry} -> {:reply, :ok, settle(state, entry, result_outcome(entry, status, payload))}
      {:error, {:unknown_invocation, _id}} -> {:reply, late(id, "result"), state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:receipts, device_id, status_id, receipts}, _from, state) do
    case pop_asked(state, device_id, status_id) do
      {:ok, ids, state} -> {:reply, :ok, reconcile(state, device_id, ids, receipts)}
      :none -> {:reply, {:error, :receipts_not_asked}, state}
    end
  end

  @impl true
  def handle_cast({:connected, device_id}, state) do
    state = %{state | asked: Map.delete(state.asked, device_id)}
    ids = for {id, %{device_id: ^device_id}} <- state.entries, do: id
    {:noreply, ask_status(state, device_id, ids)}
  end

  @impl true
  def handle_info({:deadline, id, token}, state) do
    case Map.fetch(state.entries, id) do
      {:ok, %{token: ^token, phase: :sent} = entry} -> {:noreply, past_deadline(state, entry)}
      _settled_or_stale -> {:noreply, state}
    end
  end

  def handle_info({:reconcile_timeout, id, token}, state) do
    case Map.fetch(state.entries, id) do
      {:ok, %{token: ^token, phase: :reconciling} = entry} ->
        {:noreply, settle(state, entry, uncertain(entry, uncertain_reason(state, entry)))}

      _settled_or_stale ->
        {:noreply, state}
    end
  end

  def handle_info(message, state) do
    Logger.warning("desktop invocations ignored an unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  # --- sending -------------------------------------------------------------

  defp send_invoke(state, from, device_id, id, action, payload, deadline_s) do
    event = %{
      "t" => "invoke",
      "invocation_id" => id,
      "action" => action,
      "deadline_s" => deadline_s
    }

    case Peer.send(device_id, event, payload, registry: state.peers) do
      :ok ->
        entry = %{
          id: id,
          device_id: device_id,
          action: action,
          from: from,
          blob: nil,
          phase: :sent,
          token: make_ref()
        }

        _timer =
          state.schedule.({:deadline, id, entry.token}, deadline_s * 1_000 + @result_grace_ms)

        {:noreply, put_entry(state, entry)}

      {:error, :not_connected} ->
        {:reply, {:error, :not_connected}, state}

      {:error, reason} ->
        {:reply, {:error, {:invoke_rejected, reason}}, state}
    end
  end

  defp in_flight(state, device_id),
    do: Enum.count(state.entries, fn {_id, entry} -> entry.device_id == device_id end)

  # One `invoke_status` per batch of ids, each under a `status_id` of its own
  # that its `invoke_receipts` answer names, so an answer is matched to the ids
  # it was asked about and never to a later question.
  defp ask_status(state, _device_id, []), do: state

  defp ask_status(state, device_id, ids) do
    ids
    |> Enum.chunk_every(@status_batch)
    |> Enum.reduce(state, fn batch, state ->
      status_id = "st-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      event = %{"t" => "invoke_status", "status_id" => status_id, "invocation_ids" => batch}

      case Peer.send(device_id, event, <<>>, registry: state.peers) do
        :ok ->
          asked = state.asked |> Map.get(device_id, %{}) |> Map.put(status_id, batch)
          %{state | asked: Map.put(state.asked, device_id, asked)}

        {:error, reason} ->
          Logger.warning(
            "desktop #{device_id}: invoke_status for #{length(batch)} invocation(s) not sent: " <>
              inspect(reason)
          )

          state
      end
    end)
  end

  defp pop_asked(state, device_id, status_id) do
    with {:ok, asked} <- Map.fetch(state.asked, device_id),
         {ids, asked} when is_list(ids) <- Map.pop(asked, status_id) do
      {:ok, ids, %{state | asked: Map.put(state.asked, device_id, asked)}}
    else
      _not_asked -> :none
    end
  end

  # --- settling ------------------------------------------------------------

  defp owned(state, device_id, id) do
    case Map.fetch(state.entries, id) do
      {:ok, %{device_id: ^device_id} = entry} -> {:ok, entry}
      {:ok, _entry} -> {:error, {:not_this_desktops_invocation, id}}
      :error -> {:error, {:unknown_invocation, id}}
    end
  end

  # A desktop answered an invocation already settled (its deadline came first,
  # or a receipt reconciled it): its caller has its answer, so this one is only
  # recorded.
  defp late(id, what) do
    Logger.warning("desktop invocation #{id}: a #{what} arrived after it was settled; dropped")
    :ok
  end

  defp result_outcome(entry, status, payload) do
    case {Map.fetch(@statuses, status), Jason.decode(payload)} do
      {{:ok, status}, {:ok, %{} = result}} ->
        %{
          kind: :result,
          status: status,
          result: result,
          blob: entry.blob,
          invocation_id: entry.id
        }

      other ->
        Logger.error("desktop invocation #{entry.id}: an unreadable result: #{inspect(other)}")

        %{
          kind: :result,
          status: :failed,
          result: %{
            "reason" => "unreadable_result",
            "message" => "its answer could not be read."
          },
          blob: nil,
          invocation_id: entry.id
        }
    end
  end

  defp reconcile(state, device_id, ids, receipts) do
    by_id = Map.new(receipts, &{Map.get(&1, "invocation_id"), &1})

    Enum.reduce(ids, state, fn id, state ->
      case {owned(state, device_id, id), Map.fetch(by_id, id)} do
        {{:ok, entry}, {:ok, receipt}} -> settle(state, entry, reconciled(entry, receipt))
        {{:ok, %{phase: :reconciling} = entry}, :error} -> settle_unreceipted(state, entry)
        _sent_and_still_running_or_settled -> state
      end
    end)
  end

  defp settle_unreceipted(state, entry),
    do: settle(state, entry, uncertain(entry, :no_receipt))

  defp reconciled(entry, receipt) do
    %{
      kind: :reconciled,
      status: Map.fetch!(@statuses, Map.fetch!(receipt, "status")),
      finished_at: Map.fetch!(receipt, "finished_at"),
      invocation_id: entry.id
    }
  end

  defp uncertain(entry, reason), do: %{kind: :uncertain, reason: reason, invocation_id: entry.id}

  defp uncertain_reason(state, entry) do
    case Peer.lookup(state.peers, entry.device_id) do
      {:ok, _peer, _value} -> :no_receipt
      {:error, :not_connected} -> :disconnected
    end
  end

  # Past its deadline with no answer: a desktop still connected is asked once
  # more, and one that is not cannot be, so whether it ran is unknown.
  defp past_deadline(state, entry) do
    case Peer.lookup(state.peers, entry.device_id) do
      {:ok, _peer, _value} ->
        token = make_ref()
        entry = %{entry | phase: :reconciling, token: token}
        _timer = state.schedule.({:reconcile_timeout, entry.id, token}, @reconcile_ms)
        state |> put_entry(entry) |> ask_status(entry.device_id, [entry.id])

      {:error, :not_connected} ->
        settle(state, entry, uncertain(entry, :disconnected))
    end
  end

  defp settle(state, entry, outcome) do
    GenServer.reply(entry.from, {:ok, outcome})
    %{state | entries: Map.delete(state.entries, entry.id)}
  end

  defp put_entry(state, entry), do: %{state | entries: Map.put(state.entries, entry.id, entry)}
end
