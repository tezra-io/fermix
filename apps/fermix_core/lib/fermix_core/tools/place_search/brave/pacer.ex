defmodule FermixCore.Tools.PlaceSearch.Brave.Pacer do
  @moduledoc """
  The one door a home's Brave place searches go through: one request at a
  time, each sent only when Brave's last answer allows it, and none sent into
  a window Brave said is spent.

  Brave answers a request with its rate windows in `X-RateLimit-Limit`,
  `X-RateLimit-Remaining` and `X-RateLimit-Reset`, each a comma-separated list
  with one value per window, in the same order: the per-second window first,
  then the month's ("1, 15000", "0, 14999", "1, 1419704"). `Reset` is the
  seconds until each window resets. `pacing/2` reads every window off an
  answer:

    * a window with none remaining whose reset comes within 2 s holds the
      next request until it resets, at least 1 s (a reset of "0" is under a
      second left, and one that cannot be read is taken as 1 s);
    * a window with none remaining whose reset comes later, a month's spent
      quota most of all, spends the key until then: every turn asked before
      that reset is refused at once (`{:spent, ms}`), so nothing is sent
      knowingly into it;
    * windows with requests left in every one hold nothing.

  A 2xx answer that carries no window, or one that cannot be read, is no
  pacing information: the next request goes at once, and the first such
  answer of the pacer's life is logged. A refusal that carries none holds
  nothing and is not logged: an error answer need not carry a window. A 429
  holds the next request the same way, 1 s when it says nothing readable, and
  the request it refused is the one sent again (`PlaceSearch.Brave`). `Limit`
  says nothing the other two do not.

  The pacer never waits itself, and never blocks a call. A caller asks for a
  turn (`turn/2`) and says how long it may wait to send; it is answered at
  once when nothing is ahead of it, else when the turn ahead ends, with how
  long to wait before sending. The caller waits that long in its own process,
  sends, tells the pacer what the answer said (`answered/3`), may send once
  more in the same turn (`again/2`), and ends the turn (`done/2`) however its
  sends end. A turn that would send after the caller's wait ends is refused
  (`:deadline`): when it is asked for, when it comes, and when the caller's
  wait ends while it is still queued, so no caller waits past it. A caller
  that dies holding a turn or queued for one is forgotten (each is
  monitored), and a turn held past 20 s is taken back and logged, so no
  caller keeps the door: what a caller says of a turn it no longer holds
  changes nothing.

  One engine is one home, so the application's pacer, registered under this
  module's name in `FermixCore.Supervisor`, is the home's: every Brave place
  search the engine sends goes through it, the `place_search` tool's and a
  trip's lookups. A caller names another only for a test, or in `fermix
  doctor --full`, whose probe runs in a command that starts no engine.
  """

  use GenServer

  require Logger

  @max_hold_ms 2_000
  @min_hold_ms 1_000
  # The longest any caller may wait for a turn (a trip's lookups have 45 s,
  # the tool 30 s), which also bounds every timer the pacer sets for one.
  @max_within_ms 120_000
  # How long one turn may hold the door: a wait of at most 2 s, a request, and
  # once after a 429 another wait and request.
  @max_turn_ms 20_000
  # A turn's answer comes within the caller's wait (its own timer ends a
  # queued wait); this is only how long past that a caller gives a pacer that
  # stopped answering before the call fails.
  @reply_margin_ms 5_000
  @max_header_chars 32

  @typedoc "A turn the pacer gave, which its caller ends."
  @type turn :: reference()

  @typedoc """
  What an answer says of the next request: wait this long from now (none for
  0), the key is spent for this long, or nothing can be read off it, and why.
  """
  @type pacing ::
          {:hold_ms, non_neg_integer()} | {:spent_ms, pos_integer()} | {:unread, String.t()}

  @typedoc "Why a turn is not given: it would send too late, or the key is spent this long."
  @type refusal :: :deadline | {:spent, pos_integer()}

  @typedoc "Response headers as Req keeps them: lower-case names, each a list of values."
  @type headers :: %{optional(String.t()) => [String.t()]}

  @doc "The longest wait `turn/2` takes."
  @spec max_within_ms() :: pos_integer()
  def max_within_ms, do: @max_within_ms

  @doc """
  Starts a pacer. `:name` is this module's by default, `nil` for none;
  `:now_ms` is its clock (monotonic milliseconds), for a test.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    now_ms = Keyword.get(opts, :now_ms, &monotonic_ms/0)
    true = is_function(now_ms, 0)

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, now_ms)
      name -> GenServer.start_link(__MODULE__, now_ms, name: name)
    end
  end

  @doc """
  A turn to send one request, waiting at most `within_ms` from now: the turn
  and how long to wait before sending, or why none is given. The call
  returns when the turn comes.
  """
  @spec turn(GenServer.server(), non_neg_integer()) ::
          {:ok, turn(), non_neg_integer()} | {:error, refusal()}
  def turn(pacer, within_ms)
      when is_integer(within_ms) and within_ms >= 0 and within_ms <= @max_within_ms,
      do: GenServer.call(pacer, {:turn, within_ms}, within_ms + @reply_margin_ms)

  @doc """
  What the answer to the held `turn`'s request said (`pacing/2`), for the
  requests after it. Said of a turn no longer held, it changes nothing.
  """
  @spec answered(GenServer.server(), turn(), pacing()) :: :ok
  def answered(pacer, turn, pacing) when is_reference(turn),
    do: GenServer.call(pacer, {:answered, turn, checked(pacing)})

  @doc """
  Whether the held `turn` may send once more, after its last answer: how long
  to wait first, or why not (the turn stays held until `done/2`).
  """
  @spec again(GenServer.server(), turn()) ::
          {:ok, non_neg_integer()} | {:error, refusal() | :not_holder}
  def again(pacer, turn) when is_reference(turn), do: GenServer.call(pacer, {:again, turn})

  @doc "Ends the held `turn`. Said of a turn no longer held, it changes nothing."
  @spec done(GenServer.server(), turn()) :: :ok
  def done(pacer, turn) when is_reference(turn), do: GenServer.call(pacer, {:done, turn})

  @doc """
  What an answer with `status` and `headers` says of the next request
  (moduledoc). Pure.
  """
  @spec pacing(100..599, headers()) :: pacing()
  def pacing(429, headers) when is_map(headers) do
    case windows(headers) do
      {:ok, windows} -> refused_pacing(windows)
      # A 429 says this second's window at least is spent.
      {:error, _why} -> windows_pacing([{0, first_reset(headers)}])
    end
  end

  def pacing(status, headers) when is_integer(status) and is_map(headers) do
    case windows(headers) do
      {:ok, windows} -> windows_pacing(windows)
      {:error, why} when status in 200..299 -> {:unread, why}
      {:error, _why} -> {:hold_ms, 0}
    end
  end

  # -- server ------------------------------------------------------------------

  @impl true
  def init(now_ms) do
    {:ok,
     %{
       now_ms: now_ms,
       holder: nil,
       waiting: :queue.new(),
       send_after: nil,
       spent_until: nil,
       unread_said?: false
     }}
  end

  @impl true
  def handle_call({:turn, within_ms}, from, state), do: ask(state, from, within_ms)

  def handle_call({:answered, turn, pacing}, _from, %{holder: %{ref: turn}} = state),
    do: {:reply, :ok, record(state, pacing, state.now_ms.())}

  def handle_call({:again, turn}, _from, %{holder: %{ref: turn} = holder} = state),
    do: {:reply, resend(state, holder, state.now_ms.()), state}

  def handle_call({:done, turn}, _from, %{holder: %{ref: turn}} = state),
    do: {:reply, :ok, release(state, state.now_ms.())}

  def handle_call({:again, _turn}, _from, state), do: {:reply, {:error, :not_holder}, state}

  def handle_call({:answered, _turn, _pacing}, _from, state), do: {:reply, :ok, state}

  def handle_call({:done, _turn}, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state),
    do: {:noreply, gone(state, monitor)}

  def handle_info({:expired, ref}, state), do: {:noreply, expire(state, ref)}
  def handle_info({:overran, turn}, state), do: {:noreply, overran(state, turn)}

  # Nothing else is sent here. It is said, never raised on: under
  # `FermixCore.Supervisor`'s `:rest_for_one`, a crash here would restart every
  # agent after it.
  def handle_info(message, state) do
    Logger.warning("place search pacer: unexpected message #{inspect(message, limit: 5)}")
    {:noreply, state}
  end

  # -- turns -------------------------------------------------------------------

  # With nothing ahead, the turn is answered now; otherwise the caller is
  # queued, monitored, and its own wait timed.
  defp ask(state, {pid, _tag} = from, within_ms) do
    now = state.now_ms.()
    asking = %{ref: make_ref(), from: from, pid: pid, deadline_at: now + within_ms}

    if state.holder == nil and :queue.is_empty(state.waiting) do
      case grant(state, asking, Process.monitor(pid), now) do
        {:ok, reply, state} -> {:reply, reply, state}
        {:error, refusal, monitor} -> refuse_now(state, refusal, monitor)
      end
    else
      waiter =
        Map.merge(asking, %{
          monitor: Process.monitor(pid),
          timer: Process.send_after(self(), {:expired, asking.ref}, within_ms)
        })

      {:noreply, %{state | waiting: :queue.in(waiter, state.waiting)}}
    end
  end

  defp refuse_now(state, refusal, monitor) do
    Process.demonitor(monitor, [:flush])
    {:reply, {:error, refusal}, state}
  end

  # The door to `asking`, or why not: the key is spent, or its send would come
  # after its wait ends.
  defp grant(state, asking, monitor, now) do
    case refusal(state, asking.deadline_at, now) do
      nil ->
        holder = %{
          ref: asking.ref,
          monitor: monitor,
          deadline_at: asking.deadline_at,
          timer: Process.send_after(self(), {:overran, asking.ref}, @max_turn_ms)
        }

        {:ok, {:ok, asking.ref, delay_ms(state, now)}, %{state | holder: holder}}

      refusal ->
        {:error, refusal, monitor}
    end
  end

  defp resend(state, holder, now) do
    case refusal(state, holder.deadline_at, now) do
      nil -> {:ok, delay_ms(state, now)}
      refusal -> {:error, refusal}
    end
  end

  defp refusal(%{spent_until: until}, _deadline_at, now) when is_integer(until) and until > now,
    do: {:spent, until - now}

  defp refusal(state, deadline_at, now) do
    if now + delay_ms(state, now) > deadline_at, do: :deadline
  end

  defp release(%{holder: holder} = state, now) do
    Process.demonitor(holder.monitor, [:flush])
    Process.cancel_timer(holder.timer)
    next(%{state | holder: nil}, now)
  end

  # The turn goes to the first caller queued whose wait it still fits; each
  # it would not fit is refused. Bounded: every step takes one off the queue.
  defp next(%{holder: nil} = state, now) do
    case :queue.out(state.waiting) do
      {:empty, _waiting} -> state
      {{:value, waiter}, rest} -> hand_over(%{state | waiting: rest}, waiter, now)
    end
  end

  defp hand_over(state, waiter, now) do
    Process.cancel_timer(waiter.timer)

    case grant(state, waiter, waiter.monitor, now) do
      {:ok, reply, state} ->
        GenServer.reply(waiter.from, reply)
        state

      {:error, refusal, monitor} ->
        Process.demonitor(monitor, [:flush])
        GenServer.reply(waiter.from, {:error, refusal})
        next(state, now)
    end
  end

  # The holder's death frees its turn; a queued caller's leaves its place.
  defp gone(%{holder: %{monitor: monitor} = holder} = state, monitor) do
    Process.cancel_timer(holder.timer)
    next(%{state | holder: nil}, state.now_ms.())
  end

  defp gone(state, monitor), do: drop_waiter(state, &(&1.monitor == monitor), & &1)

  # A turn still held at its bound is taken back, so a request that never
  # ends cannot keep the door; its caller's later word changes nothing.
  defp overran(%{holder: %{ref: turn}} = state, turn) do
    Logger.warning(
      "place search: a Brave search held its turn past #{div(@max_turn_ms, 1_000)} s, so the " <>
        "next one goes on"
    )

    release(state, state.now_ms.())
  end

  defp overran(state, _turn), do: state

  # A queued caller's wait ended before its turn came. A timer for a caller
  # already handed its turn or refused finds no one: it was cancelled after it
  # had fired.
  defp expire(state, ref) do
    drop_waiter(state, &(&1.ref == ref), fn waiter ->
      Process.demonitor(waiter.monitor, [:flush])
      GenServer.reply(waiter.from, {:error, :deadline})
    end)
  end

  defp drop_waiter(state, match?, on_drop) do
    {dropped, kept} = state.waiting |> :queue.to_list() |> Enum.split_with(match?)

    Enum.each(dropped, fn waiter ->
      Process.cancel_timer(waiter.timer)
      on_drop.(waiter)
    end)

    %{state | waiting: :queue.from_list(kept)}
  end

  # -- pacing ------------------------------------------------------------------

  defp record(state, {:hold_ms, hold_ms}, now),
    do: %{state | send_after: now + hold_ms, spent_until: nil}

  defp record(state, {:spent_ms, spent_ms}, now),
    do: %{state | send_after: nil, spent_until: now + spent_ms}

  defp record(state, {:unread, why}, _now) do
    unless state.unread_said? do
      Logger.warning(
        "place search: Brave's answer carried no rate window to pace by (#{why}), so the " <>
          "next search goes at once; said once while this engine runs"
      )
    end

    %{state | send_after: nil, spent_until: nil, unread_said?: true}
  end

  defp delay_ms(%{send_after: nil}, _now), do: 0
  defp delay_ms(%{send_after: send_after}, now), do: max(send_after - now, 0)

  # A 429 holds 1 s at least, whatever its windows say.
  defp refused_pacing(windows) do
    case windows_pacing(windows) do
      {:hold_ms, 0} -> {:hold_ms, @min_hold_ms}
      pacing -> pacing
    end
  end

  # The longest reset among the spent windows decides: within 2 s it holds
  # (1 s at least), past that it spends the key.
  defp windows_pacing(windows) do
    resets = for {0, reset_s} <- windows, do: reset_ms(reset_s)

    case resets do
      [] -> {:hold_ms, 0}
      _spent -> hold_or_spend(Enum.max(resets))
    end
  end

  defp hold_or_spend(reset_ms) when reset_ms > @max_hold_ms, do: {:spent_ms, reset_ms}
  defp hold_or_spend(reset_ms), do: {:hold_ms, max(reset_ms, @min_hold_ms)}

  defp reset_ms({:ok, reset_s}), do: reset_s * 1_000
  defp reset_ms(:unread), do: @min_hold_ms

  # Each window's remaining count with its reset, in Brave's order. Without a
  # readable count for every window there is nothing to pace by; a reset that
  # cannot be read is `:unread` for its window alone.
  defp windows(headers) do
    with {:ok, remaining} <- counts(headers, "x-ratelimit-remaining") do
      resets = header_words(headers, "x-ratelimit-reset")

      {:ok,
       remaining
       |> Enum.with_index()
       |> Enum.map(fn {count, index} -> {count, word_count(Enum.at(resets, index))} end)}
    end
  end

  defp counts(headers, name) do
    case header_words(headers, name) do
      [] -> {:error, "no #{name} header"}
      words -> all_counts(words, name)
    end
  end

  defp all_counts(words, name) do
    counts = Enum.map(words, &word_count/1)

    case Enum.find_index(counts, &(&1 == :unread)) do
      nil -> {:ok, Enum.map(counts, fn {:ok, count} -> count end)}
      index -> {:error, "#{name} #{inspect(Enum.at(words, index))} is not a count"}
    end
  end

  defp first_reset(headers),
    do: headers |> header_words("x-ratelimit-reset") |> List.first() |> word_count()

  defp header_words(headers, name) do
    headers
    |> Map.get(name, [])
    |> Enum.join(",")
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.slice(0, @max_header_chars)))
  end

  defp word_count(word) when is_binary(word) do
    case Integer.parse(word) do
      {count, ""} when count >= 0 -> {:ok, count}
      _other -> :unread
    end
  end

  defp word_count(nil), do: :unread

  defp checked({:hold_ms, hold_ms} = pacing) when is_integer(hold_ms) and hold_ms >= 0,
    do: pacing

  defp checked({:spent_ms, spent_ms} = pacing) when is_integer(spent_ms) and spent_ms > 0,
    do: pacing

  defp checked({:unread, why} = pacing) when is_binary(why), do: pacing

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
