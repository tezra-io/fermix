defmodule FermixCore.Tools.PlaceSearch.Computer do
  @moduledoc """
  Apple Maps on a Mac of the home (M89 D13 A): the place search a server's
  home runs where no Apple Maps helper is in its own build, by asking a
  computer's `places` capability (`Computers.Capabilities.Places`), which
  runs that Mac's own Apple Maps helper. One of the `PlaceSearch.Backend`s:
  it runs when `[fermix_core.tools.place_search] backend` is `computer`, or
  unset on a build without the helper whose home has a computer offering
  places (`offered/1`).

  **One view of the computers** (`computers/1`): the home's computers as
  `Computers.fetch/1` joins them, on the primary only, from the link's rows,
  with the computers' records (`Computers.Store`) read strictly, so a record
  with no row (a revoke that failed half way, `device/` kept through a move
  back) is no computer. `offered/1` (the resolver's third rule, connected or
  not) and the choice of a computer read this same list. A home with no
  computer record at all has no computer that could offer places (each
  writes its record at its first `hello`), so the link is not asked there,
  and a home that never linked one stays on its other rules. Computers that
  cannot be read, their records or the link's rows, are never read as none:
  `offered/1` answers the error, and the resolver refuses by name rather
  than turning to Brave.

  **Which computer** is `Computers.Choice.places_computer/1`'s: of the
  computers connected now whose latest offers list `places` on, the one seen
  most recently. With none, the search is refused at once, `computer_away`,
  and nothing is sent: never Brave, and never a wait for a Mac to wake.

  **Every turn may ask, by design.** Unlike a tool a computer runs, this
  search does not follow `Computers.visible?/1` (an owner's turn only): a
  guest's turn, a delegated worker's and a scheduled run's search the home's
  Mac too, since the place search is the home's one backend, never chosen
  per turn. It sends a place's name to Apple from that Mac and reads nothing
  of the Mac's own, and the Mac's journal records each search.

  **One invocation per search** (`Computers.call/6`), a read, bounded at
  #{15} s and never past the time its caller has left less twice the link's
  #{2} s allowance (`:send_within_ms`, a trip's lookup passes what its call
  has left), so a Mac that sleeps with its session still up cannot spend a
  trip's 45 s. The Mac's helper runs inside that bound
  (`Places.helper_timeout_ms/1`), so a slow Apple Maps answers as Apple
  Maps. Where the bound leaves less than #{2_500} ms, nothing is sent
  (`deadline`).

  **What it answers, by kind**, each with its own sentence naming the Mac:

    * the places, made into the record by the code a Mac's own search uses
      (`Places.places/2`);
    * `computer_away`: no computer connected now offers places;
    * `computer_off`: the Mac has Apple Maps switched off;
    * `computer_refused`: the Mac refused it otherwise (unavailable there, a
      request from an older copy of the home, stopped by the person there);
    * `computer_busy`: the Mac runs as much as it allows; try again;
    * `computer_timed_out`: the Mac did not answer within the bound;
    * Apple Maps' own tagged failure there (`invalid_location`,
      `rate_limited`, `network`, ...), naming the Mac;
    * anything else, `provider_error` in the outcome's own sentence.

  **The call's stop.** The searches of one trip call share a stop
  (`:stopped` and `:stop`, which `Trips.Lookup` passes): the kinds that
  cannot heal within the call set it (`computer_away`, `computer_off`,
  `computer_refused`, `computer_timed_out`, and Apple Maps' `rate_limited`),
  and a search of the same call reads it before choosing a computer, so the
  lookups after it send nothing. `computer_busy` stops nothing. Any stop the
  call holds, whichever search set it, leaves a search unsent with that
  stop's tag.

  The trace carries the invocation's ids and how it ended
  (`Outcome.exec_metadata/1`, never a name), `attempt` (1 when it was sent,
  0 when not) and `provider_code`, the invocation's status or refusal for a
  stop; and on success `searched_with`, the owner's words for what searched
  ("Apple Maps on studio Mac"), which a trip's answer says and no event
  carries (`PlaceSearch`).

  `opts`: `:context` (the turn's loop context, which names the turn on the
  wire; its `:computer_call_opts` reach `Computers.call/6`, where a test names
  its `Calls`, transport and epoch), the send terms above, and
  `Computers.fetch/1`'s seams (`:rows`, `:live`, `:records`, `:version`,
  `:role`, `:link`, `:home`).
  """

  @behaviour FermixCore.Tools.PlaceSearch.Backend

  alias FermixCore.Computers
  alias FermixCore.Computers.Argument
  alias FermixCore.Computers.Capabilities.Places
  alias FermixCore.Computers.Choice
  alias FermixCore.Computers.Computer
  alias FermixCore.Computers.Outcome
  alias FermixCore.Computers.Store
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Tools.PlaceSearch.Backend

  @max_invoke_ms 15_000
  @grace_ms 2_000
  @min_invoke_ms 2_500
  # The most a search waits when its caller names no bound (the tool).
  @send_within_ms 30_000
  @list_seams [:rows, :live, :version, :role, :link, :home]
  # Apple Maps' own tags, as the computer's search answers them.
  @apple_tags ~w(invalid_location invalid_query rate_limited network provider_error
                 parser_changed response_too_large)

  @away "computer_away: no Mac that looks places up in Apple Maps for this home is online " <>
          "now, so nothing was searched; ask again once one is online"
  @none_offers "provider_error: no computer of this home offers Apple Maps; link a Mac with " <>
                 "the Fermix app to this home, or set [fermix_core.tools.place_search] backend " <>
                 "= \"brave\" to search through Brave"
  @deadline "deadline: the time for place lookups is nearly spent, so this search was not sent"

  @type computers :: {:ok, [Computer.t()]} | {:error, term()}

  @impl true
  @spec name() :: :computer
  def name, do: :computer

  @doc """
  The home's computers, the one view `offered/1` and the choice read (the
  moduledoc): `Computers.fetch/1` with the records read strictly, or why they
  could not be read.
  """
  @spec computers(keyword()) :: computers()
  def computers(opts) when is_list(opts) do
    case records(opts) do
      {:ok, records} when map_size(records) == 0 ->
        {:ok, []}

      {:ok, records} ->
        opts |> Keyword.take(@list_seams) |> Keyword.put(:records, records) |> Computers.fetch()

      {:error, _reason} = error ->
        error
    end
  end

  defp records(opts) do
    case Keyword.fetch(opts, :records) do
      {:ok, records} when is_map(records) -> {:ok, records}
      :error -> Store.read_all(Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0))
    end
  end

  @doc """
  Whether a computer of the home's latest report lists `places` on (M89 D13
  A's third rule), connected or not, from `computers/1`; or why the
  computers could not be read, which is never none.
  """
  @spec offered(keyword()) :: {:ok, boolean()} | {:error, term()}
  def offered(opts) when is_list(opts) do
    with {:ok, computers} <- computers(opts),
         do: {:ok, Enum.any?(computers, &Argument.offers?(&1, Places))}
  end

  @doc """
  Ready while a computer of the home offers places (`offered/1`); not ready,
  by name, when none does or the computers could not be read.
  """
  @impl true
  @spec ready(keyword()) :: :ok | {:error, String.t()}
  def ready(opts) when is_list(opts) do
    case offered(opts) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, @none_offers}
      {:error, reason} -> {:error, unread(reason)}
    end
  end

  @doc "One search on the chosen computer (the moduledoc)."
  @impl true
  @spec search(Backend.request(), keyword()) ::
          {:ok, [Backend.place()], Backend.trace_metadata()}
          | {:error, String.t(), Backend.trace_metadata()}
  def search(%{query: query} = request, opts) when is_binary(query) and is_list(opts) do
    terms = terms!(opts)

    with nil <- terms.stopped.(),
         {:ok, deadline_ms} <- deadline(terms.within_ms),
         {:ok, computers} <- computers(opts),
         {:ok, computer} <- Choice.places_computer(computers) do
      computer
      |> Computers.call(
        Places,
        "search",
        Places.args(request),
        context(opts),
        call_opts(opts, deadline_ms)
      )
      |> answered(computer, request, terms)
    else
      :too_late -> unsent(@deadline)
      :none -> stopped(terms, :computer_away, unsent(@away))
      {:error, reason} -> unsent(unread(reason))
      why when is_atom(why) -> unsent(halted(why))
    end
  end

  defp terms!(opts) do
    terms = %{
      within_ms: Keyword.get(opts, :send_within_ms, @send_within_ms),
      stopped: Keyword.get(opts, :stopped, fn -> nil end),
      stop: Keyword.get(opts, :stop, fn _why -> :ok end)
    }

    case terms do
      %{within_ms: ms, stopped: stopped, stop: stop}
      when is_integer(ms) and ms >= 0 and is_function(stopped, 0) and is_function(stop, 1) ->
        terms
    end
  end

  defp deadline(within_ms) do
    case min(@max_invoke_ms, within_ms - 2 * @grace_ms) do
      ms when ms >= @min_invoke_ms -> {:ok, ms}
      _too_little -> :too_late
    end
  end

  defp context(opts), do: Keyword.get(opts, :context, %{})

  defp call_opts(opts, deadline_ms) do
    opts
    |> context()
    |> Map.get(:computer_call_opts, [])
    |> Keyword.merge(deadline_ms: deadline_ms, grace_ms: @grace_ms)
  end

  defp unsent(reason), do: {:error, reason, %{attempt: 0, provider_code: nil}}

  # -- the answer ----------------------------------------------------------------

  defp answered({:ok, %Outcome{result: result} = outcome}, computer, request, _terms) do
    case Places.places(result, request) do
      {:ok, places} ->
        {:ok, places, Map.put(trace(outcome, nil), :searched_with, searched_with(computer))}

      {:error, reason} ->
        {:error, named_tag(reason, computer.name), trace(outcome, nil)}
    end
  end

  defp answered({:error, %Outcome{} = outcome}, computer, _request, terms) do
    case failure(outcome, computer) do
      {:stop, why, reason} -> stopped(terms, why, {:error, reason, trace(outcome, code(outcome))})
      reason -> {:error, reason, trace(outcome, nil)}
    end
  end

  # Each kind its own words (the moduledoc); the kinds that cannot heal
  # within the call stop it.
  defp failure(%Outcome{status: :timed_out} = outcome, %Computer{name: name}) do
    {:stop, :computer_timed_out,
     "computer_timed_out: #{Outcome.sentence(outcome, name)} No place came back from " <>
       "it in time; try again in a moment."}
  end

  defp failure(%Outcome{status: :refused, refusal: :off} = outcome, %Computer{name: name}),
    do: {:stop, :computer_off, "computer_off: " <> Outcome.sentence(outcome, name)}

  defp failure(%Outcome{status: :refused, refusal: :busy} = outcome, %Computer{name: name}),
    do: "computer_busy: " <> Outcome.sentence(outcome, name)

  defp failure(%Outcome{status: :refused} = outcome, %Computer{name: name}),
    do:
      {:stop, :computer_refused,
       "computer_refused: " <> named(Outcome.sentence(outcome, name), name)}

  defp failure(%Outcome{status: :failed, message: "rate_limited" <> _rest = reason}, computer),
    do: {:stop, :rate_limited, named_tag(reason, computer.name)}

  defp failure(%Outcome{status: :failed, message: message} = outcome, computer) do
    if apple_tagged?(message),
      do: named_tag(message, computer.name),
      else: "provider_error: " <> Outcome.sentence(outcome, computer.name)
  end

  defp failure(%Outcome{} = outcome, computer),
    do: "provider_error: " <> Outcome.sentence(outcome, computer.name)

  defp apple_tagged?(message) when is_binary(message) do
    case String.split(message, ": ", parts: 2) do
      [tag, _words] -> tag in @apple_tags
      [_untagged] -> false
    end
  end

  defp apple_tagged?(_message), do: false

  # Apple Maps' tag kept first, as a search here answers it, with the Mac it
  # came back from.
  defp named_tag(reason, name) do
    [tag, words] = String.split(reason, ": ", parts: 2)
    "#{tag}: on #{name}, #{words}"
  end

  defp named(sentence, name) do
    if String.contains?(sentence, name), do: sentence, else: "#{name}: #{sentence}"
  end

  defp stopped(terms, why, answer) do
    :ok = terms.stop.(why)
    answer
  end

  # Whichever search of the call set the stop, its tag leaves this one unsent.
  defp halted(why),
    do: "#{why}: an earlier search of the same call stopped it, so this one was not sent"

  defp code(%Outcome{refusal: refusal}) when is_atom(refusal) and refusal != nil,
    do: Atom.to_string(refusal)

  defp code(%Outcome{status: status}), do: Atom.to_string(status)

  # An outcome refused before anything was sent names no invocation.
  defp trace(%Outcome{invocation: invocation} = outcome, provider_code) do
    outcome
    |> Outcome.exec_metadata()
    |> Map.merge(%{attempt: if(invocation, do: 1, else: 0), provider_code: provider_code})
  end

  defp searched_with(%Computer{name: name}), do: "Apple Maps on #{name}"

  # Computers that could not be read, never taken for none (AGENTS rule 12).
  defp unread(reason) do
    "provider_error: Fermix cannot tell whether a Mac of yours looks places up, since this " <>
      "home's computers could not be read (#{describe(reason)}); see the daemon log, or set " <>
      "[fermix_core.tools.place_search] backend = \"brave\" to search through Brave"
  end

  defp describe({:invalid_entry, path}), do: "#{Path.basename(path)} is no record Fermix wrote"
  defp describe({:too_many, max}), do: "more than #{max} records"
  defp describe({:file, path, posix}), do: "#{Path.basename(path)}: #{posix}"
  defp describe(:not_started), do: "the home's link has not started yet"
  defp describe(:not_running), do: "the home's link is not running"
  defp describe(other), do: inspect(other)
end
