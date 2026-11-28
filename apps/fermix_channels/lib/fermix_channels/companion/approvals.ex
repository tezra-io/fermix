defmodule FermixChannels.Companion.Approvals do
  @moduledoc """
  The approval cards still waiting for the owner, so a client that was not
  connected when one went out still gets it: the one way every approval card
  reaches the Fermix apps, announced, offered again after a hello, and
  resolved.

  A sandbox or soul token resolves only from the transport whose turn raised
  it (the confirmation stores bind it to its origin, M19 §9.5), so a card a
  turn raised belongs to that transport: it is announced, re-sent, withdrawn
  and resolved there alone, and the other transport never shows a card it
  could not answer. A card asked in the app with no turn (M106 §8, D12) goes
  to the owner's inbox there, the Mac chat's conversation the phones share,
  and is answered from either transport (`Delivery.OwnerInbox.app_origin/1`),
  so it belongs to both (`:all`): an access confirmation that had no chat of
  its own, and a heal's proposal for a job.

  A card kept in memory (a turn's, or an access confirmation) is kept from
  the moment it is announced until it resolves (the owner approved or denied
  it through `Companion.Requests`) or its own `ttl_s` runs out. The card and
  either end are announced here, to the card's transport, through the one
  announce the store was started with: the resolution as `Requests` names it,
  the end of its ttl as `approval_resolved{outcome: "expired"}`, so no client
  keeps a card whose token is gone. The tokens behind these cards live in
  memory (the sandbox and soul confirmation stores) and die with the daemon,
  so the cards are kept in memory too. The store is bounded: past
  `max_pending/0` a card still goes out live but is not kept, and the refusal
  is logged.

  A heal's proposal is never kept here: its record is durable
  (`Jobs.HealCard`), so it is offered live when it is sent (`offer/3`), read
  again from that record after every hello, an engine restart included,
  each with what is left of its seven days as its `ttl_s` (the store's
  `:durable` source, which `pending/3` runs in its caller, so this store
  never waits on another), and resolved to both transports when it ends by
  any road (`heal_card_ended/3`, the listener core is given).

  Right after a phone's `hello_ack` and a Mac client's `server_hello`, the
  transport sends its cards again (`pending/3`), each with the time it has
  left as its `ttl_s`.
  """

  use GenServer

  require Logger

  alias FermixChannels.Companion.Fanout
  alias FermixChannels.Companion.Output
  alias FermixCore.Jobs.HealCard

  @max_pending 64

  @typedoc "An `approval` event as `Companion.Output.approval/1` builds it."
  @type card :: %{required(String.t()) => term()}

  @typedoc """
  Who a card belongs to: the transport whose turn raised it, or both, for a
  card asked in the app with no turn.
  """
  @type audience :: Fanout.transport() | :all

  @typedoc """
  Where a heal's proposals are read again after a hello: a function of the
  profile, `{:ok, cards}` or `{:error, reason}`.
  """
  @type durable_source :: (String.t() -> {:ok, [card()]} | {:error, term()})

  # The transport whose turn raised a card, the only one that can answer it.
  @transports [:companion, :mobile]
  @audiences [:all | @transports]

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
  of the profile, the event and the audience, `Companion.Fanout.announce/3`
  with that audience by default), `:durable` (where a heal's proposals are
  read again after a hello, `t:durable_source/0`; none by default), and the
  `:clock` (monotonic milliseconds) and `:schedule` (the expiry timer) a
  test stands in for.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Keep one card for its audience until it resolves or its ttl runs out, then
  announce it to that audience's watchers of the profile. A card kept again
  keeps its deadline. A card the store refuses still goes out live, and the
  refusal is logged.
  """
  @spec announce(GenServer.server(), String.t(), card(), audience()) :: :ok
  def announce(
        server,
        profile_id,
        %{"t" => "approval", "approval_id" => id, "ttl_s" => ttl_s} = card,
        audience
      )
      when is_binary(profile_id) and is_binary(id) and is_integer(ttl_s) and ttl_s > 0 and
             audience in @audiences do
    GenServer.call(server, {:announce, profile_id, card, audience})
  end

  @doc """
  Offer a heal's proposal (`kind` `job_change`) to both transports' watchers
  of the profile, without keeping it: its durable record offers it again
  after every hello.
  """
  @spec offer(GenServer.server(), String.t(), card()) :: :ok
  def offer(
        server,
        profile_id,
        %{"t" => "approval", "kind" => "job_change", "approval_id" => id, "ttl_s" => ttl_s} =
          card
      )
      when is_binary(profile_id) and is_binary(id) and is_integer(ttl_s) and ttl_s > 0 do
    GenServer.call(server, {:offer, profile_id, card})
  end

  @doc """
  Forget a card the owner resolved, then announce its resolution to the card's
  own audience when the store kept it (a card a turn raised: its transport,
  which, a token being bound to its origin, is the one that resolved it; a
  card asked in the app: both), else to `audience`. A card the store never
  kept is no error: its resolution is still announced.
  """
  @spec resolve(GenServer.server(), String.t(), map(), audience()) :: :ok
  def resolve(
        server,
        profile_id,
        %{"t" => "approval_resolved", "approval_id" => id} = resolved,
        audience
      )
      when is_binary(profile_id) and is_binary(id) and audience in @audiences do
    GenServer.call(server, {:resolve, profile_id, resolved, audience})
  end

  @doc """
  The profile's unresolved, unexpired cards for `transport`, oldest first,
  each `ttl_s` what it has left: those kept in memory for it or for both
  transports, then a heal's proposals read from their record through the
  store's `:durable` source, run here in the caller. A source that fails, or
  answers anything but a list of approval cards, is logged and gives none:
  the cards in memory still go out.
  """
  @spec pending(GenServer.server(), String.t(), Fanout.transport()) :: [card()]
  def pending(server, profile_id, transport)
      when is_binary(profile_id) and transport in @transports do
    {kept, durable} = GenServer.call(server, {:pending, profile_id, transport})
    kept ++ durable_cards(durable, profile_id)
  end

  @doc """
  The heal proposals waiting in `profile_id`'s app chat, as the approval
  cards a hello offers again (`Jobs.HealCard.app_cards/2`, whose `opts` these
  are): the source the companion supervisor gives the store.
  """
  @spec job_change_cards(String.t(), keyword()) :: {:ok, [card()]} | {:error, term()}
  def job_change_cards(profile_id, opts \\ []) when is_binary(profile_id) and is_list(opts) do
    with {:ok, specs} <- HealCard.app_cards(profile_id, opts),
         do: {:ok, Enum.map(specs, &Output.approval/1)}
  end

  @doc """
  Core's listener for the end of a heal's proposal bound to the app
  (`:app_approval_listener`, `Jobs.HealCard.announce_ended/3`): its card is
  resolved to both transports, `approved`, `denied` or `expired`. With no
  store running (the companion tree down) nobody watches, and nothing is
  announced.
  """
  @spec heal_card_ended(String.t(), String.t(), :approved | :denied | :expired) :: :ok
  def heal_card_ended(profile_id, heal_id, outcome)
      when is_binary(profile_id) and is_binary(heal_id) and
             outcome in [:approved, :denied, :expired] do
    case GenServer.whereis(server()) do
      nil ->
        :ok

      store ->
        resolve(store, profile_id, Output.approval_resolved(:job_change, heal_id, outcome), :all)
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       cards: %{},
       order: 0,
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
       schedule: Keyword.get(opts, :schedule, &Process.send_after(self(), &1, &2)),
       announce: Keyword.get(opts, :announce, &Fanout.announce(&1, &2, audience: &3)),
       durable: Keyword.get(opts, :durable)
     }}
  end

  @impl true
  def handle_call({:announce, profile_id, card, audience}, _from, state) do
    {kept, state} = keep_card(state, profile_id, card, audience)
    :ok = log_unkept(kept, card)
    {:reply, state.announce.(profile_id, card, audience), state}
  end

  def handle_call({:offer, profile_id, card}, _from, state),
    do: {:reply, state.announce.(profile_id, card, :all), state}

  def handle_call(
        {:resolve, profile_id, %{"approval_id" => id} = resolved, audience},
        _from,
        state
      ) do
    {kept, cards} = Map.pop(state.cards, id)
    audience = if kept, do: kept.audience, else: audience
    {:reply, state.announce.(profile_id, resolved, audience), %{state | cards: cards}}
  end

  def handle_call({:pending, profile_id, transport}, _from, state) do
    {:reply, {pending_cards(state, profile_id, transport), state.durable}, state}
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

  defp keep_card(state, profile_id, %{"approval_id" => id, "ttl_s" => ttl_s} = card, audience) do
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
          audience: audience,
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
      &(&1.profile_id == profile_id and &1.audience in [transport, :all] and &1.deadline > now)
    )
    |> Enum.sort_by(& &1.order)
    |> Enum.map(&Map.put(&1.card, "ttl_s", div(&1.deadline - now + 999, 1_000)))
  end

  # A heal's proposals, read in the caller: whatever the source answers that
  # is not a list of approval cards is logged and gives none.
  defp durable_cards(nil, _profile_id), do: []

  defp durable_cards(source, profile_id) when is_function(source, 1) do
    case source.(profile_id) do
      {:ok, cards} when is_list(cards) -> Enum.filter(cards, &offerable?/1)
      other -> log_unread(other)
    end
  end

  defp offerable?(%{"t" => "approval", "approval_id" => id, "ttl_s" => ttl_s})
       when is_binary(id) and is_integer(ttl_s) and ttl_s > 0,
       do: true

  defp offerable?(card) do
    Logger.error("a waiting heal card was not offered again, it is no card: #{inspect(card)}")
    false
  end

  defp log_unread(answer) do
    Logger.error(
      "the waiting heal cards could not be read, so none is offered again now: " <>
        inspect(answer)
    )

    []
  end

  defp expire(state, id, kept) do
    :ok =
      state.announce.(
        kept.profile_id,
        %{"t" => "approval_resolved", "approval_id" => id, "outcome" => "expired"},
        kept.audience
      )

    %{state | cards: Map.delete(state.cards, id)}
  end
end
