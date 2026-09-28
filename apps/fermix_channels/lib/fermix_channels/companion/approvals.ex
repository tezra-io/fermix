defmodule FermixChannels.Companion.Approvals do
  @moduledoc """
  The approval cards still waiting for the owner, so a client that was not
  connected when one went out still gets it.

  A sandbox or soul token resolves only from the transport whose turn raised
  it (the confirmation stores bind it to its origin, M19 §9.5), so a card
  belongs to that transport: it is announced, re-sent, withdrawn and resolved
  there alone, and the other transport never shows a card it could not answer.

  A card is kept from the moment it is announced until it resolves (the owner
  approved or denied it through `Companion.Requests`) or its own `ttl_s` runs
  out. The card and either end are announced here, to the card's transport,
  through the one announce the store was started with: the resolution as
  `Requests` names it, the end of its ttl as
  `approval_resolved{outcome: "expired"}`, so no client keeps a card whose
  token is gone. Right after a phone's `hello_ack` and a Mac client's
  `server_hello`, the transport sends its own cards again, each with the time
  it has left as its `ttl_s`.

  The tokens behind the cards live in memory (the sandbox and soul
  confirmation stores) and die with the daemon, so the cards are kept in
  memory too. The store is bounded: past `max_pending/0` a card still goes out
  live but is not kept, and the refusal is logged.
  """

  use GenServer

  require Logger

  alias FermixChannels.Companion.Fanout

  @max_pending 64

  @typedoc "An `approval` event as `Companion.Output.approval/1` builds it."
  @type card :: %{required(String.t()) => term()}

  # The transport whose turn raised a card, the only one that can answer it.
  @transports [:companion, :mobile]

  @doc "How many cards are kept at once."
  @spec max_pending() :: pos_integer()
  def max_pending, do: @max_pending

  @doc """
  The store the channel adapters and transports use: the one the companion
  supervisor runs, unless `:companion_approvals` names another (a test's own).
  """
  @spec server() :: GenServer.server()
  def server, do: Application.get_env(:fermix_channels, :companion_approvals, __MODULE__)

  @doc false
  def child_spec(opts) when is_list(opts) do
    %{id: Keyword.get(opts, :name) || __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Start the store. Options: `:name` (`nil` for none), `:announce` (how a
  card and its end reach its transport's watchers of the profile, a function
  of the profile, the event and the transport, `Companion.Fanout.announce/3`
  with that audience by default), and the `:clock` (monotonic milliseconds)
  and `:schedule` (the expiry timer) a test stands in for.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Keep one card for the transport that raised it until it resolves or its ttl
  runs out, then announce it to that transport's watchers of the profile. A
  card kept again keeps its deadline. A card the store refuses still goes out
  live, and the refusal is logged.
  """
  @spec announce(GenServer.server(), String.t(), card(), Fanout.transport()) :: :ok
  def announce(
        server,
        profile_id,
        %{"t" => "approval", "approval_id" => id, "ttl_s" => ttl_s} = card,
        transport
      )
      when is_binary(profile_id) and is_binary(id) and is_integer(ttl_s) and ttl_s > 0 and
             transport in @transports do
    GenServer.call(server, {:announce, profile_id, card, transport})
  end

  @doc """
  Forget a card the owner resolved, then announce its resolution to the
  transport that resolved it, which, a token being bound to its origin, is
  the one that raised it. A card the store never kept is no error: its
  resolution is still announced.
  """
  @spec resolve(GenServer.server(), String.t(), map(), Fanout.transport()) :: :ok
  def resolve(
        server,
        profile_id,
        %{"t" => "approval_resolved", "approval_id" => id} = resolved,
        transport
      )
      when is_binary(profile_id) and is_binary(id) and transport in @transports do
    GenServer.call(server, {:resolve, profile_id, resolved, transport})
  end

  @doc """
  The profile's unresolved, unexpired cards raised on `transport`, oldest
  first, each `ttl_s` what it has left.
  """
  @spec pending(GenServer.server(), String.t(), Fanout.transport()) :: [card()]
  def pending(server, profile_id, transport)
      when is_binary(profile_id) and transport in @transports do
    GenServer.call(server, {:pending, profile_id, transport})
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       cards: %{},
       order: 0,
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
       schedule: Keyword.get(opts, :schedule, &Process.send_after(self(), &1, &2)),
       announce: Keyword.get(opts, :announce, &Fanout.announce(&1, &2, audience: &3))
     }}
  end

  @impl true
  def handle_call({:announce, profile_id, card, transport}, _from, state) do
    {kept, state} = keep_card(state, profile_id, card, transport)
    :ok = log_unkept(kept, card)
    {:reply, state.announce.(profile_id, card, transport), state}
  end

  def handle_call(
        {:resolve, profile_id, %{"approval_id" => id} = resolved, transport},
        _from,
        state
      ) do
    state = %{state | cards: Map.delete(state.cards, id)}
    {:reply, state.announce.(profile_id, resolved, transport), state}
  end

  def handle_call({:pending, profile_id, transport}, _from, state) do
    {:reply, pending_cards(state, profile_id, transport), state}
  end

  @impl true
  def handle_info({:approval_expired, id, order}, state) do
    case Map.fetch(state.cards, id) do
      {:ok, %{order: ^order} = kept} -> {:noreply, expire(state, id, kept)}
      _resolved_or_replaced -> {:noreply, state}
    end
  end

  def handle_info(message, state) do
    Logger.warning("companion approvals ignored an unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  defp keep_card(state, profile_id, %{"approval_id" => id, "ttl_s" => ttl_s} = card, transport) do
    cond do
      Map.has_key?(state.cards, id) ->
        {:ok, state}

      map_size(state.cards) >= @max_pending ->
        {{:error, {:pending_approvals_full, @max_pending}}, state}

      true ->
        order = state.order + 1
        ttl_ms = ttl_s * 1_000
        _timer = state.schedule.({:approval_expired, id, order}, ttl_ms)

        kept = %{
          profile_id: profile_id,
          transport: transport,
          card: card,
          deadline: state.clock.() + ttl_ms,
          order: order
        }

        {:ok, %{state | cards: Map.put(state.cards, id, kept), order: order}}
    end
  end

  defp log_unkept(:ok, _card), do: :ok

  defp log_unkept({:error, reason}, card) do
    Logger.error(
      "approval #{card["approval_id"]} goes out live only, no reconnect will show it: " <>
        inspect(reason)
    )
  end

  defp pending_cards(state, profile_id, transport) do
    now = state.clock.()

    state.cards
    |> Map.values()
    |> Enum.filter(
      &(&1.profile_id == profile_id and &1.transport == transport and &1.deadline > now)
    )
    |> Enum.sort_by(& &1.order)
    |> Enum.map(&Map.put(&1.card, "ttl_s", div(&1.deadline - now + 999, 1_000)))
  end

  defp expire(state, id, kept) do
    :ok =
      state.announce.(
        kept.profile_id,
        %{"t" => "approval_resolved", "approval_id" => id, "outcome" => "expired"},
        kept.transport
      )

    %{state | cards: Map.delete(state.cards, id)}
  end
end
