defmodule FermixCore.Management.HomeSummary do
  @moduledoc """
  `home.status.summary` (M75 lean v1 §7, Always On setup §3): where Always
  On stands, worked out once here so the Mac app, the Linux app, the setup
  page and the CLI draw the same screen.

      summary: {key, state, sentence, action, detail, notice, outcome}

  `summary/1` is pure: it reads the facts `gather/5` collects (the role, the
  move's phase, the candidates held, the cloud provider Always On speaks of
  (`Home.Provision.current/2`), every provider offered, and the ledger of
  the one in use (`Provision.Ledger.state/3`), the enrollment window and the
  link as the rail says them (`Home.Link.status/0`), the last readiness
  review, the review's items this home's settings decide
  (`MoveReadiness.summary_items/4`), the snapshots, the disk, the owner's
  time zone, and on a linked desktop the server's own `home.status`). Its
  words are `Management.Copy`'s, with the provider's own (its name, its
  token's label, its cities, its type names and its "How to get one" steps)
  from its display data; nothing here names a provider.

  `state` is one of `states/0`:

    * the computer that sets Always On up, before the move: `off`, `connect`
      (a code for a server of the owner's own is open, or the provider refused
      the token before anything was created), `choose` (the token works),
      `creating` (a step's job runs, or the server starts, installs or
      connects), `ready`, `undone` (a move was undone and its server is still
      held);
    * the computer the move left: `moving` (its last word, once it waits on
      the server's confirmation, is that Fermix keeps trying), `undone` while
      it restarts as it was, `on`, `retired` (no link, or the server forgot
      this computer), and `creating` while a step's job runs;
    * the server: `candidate` while it waits for its move, `primary` after;
    * `problem`, with its `kind` (`problems/0`) in `detail` and the one action
      that fixes it, or Learn more where none does.

  **A step that runs.** While the ledger names a step's job (its `action`,
  written before the job starts), the summary is `creating` in that step's
  sentence (creating, deleting, turning on, restarting), with Cancel during
  a create, before anything the job writes; `detail.progress` says the step
  in hand, from what the job wrote so far. An action the job outlived reads
  as the failure `interrupted` (`Ledger.state/3`), and every step's failure
  is a problem: the create's by its reason, a power action's `power_failed`,
  a delete's `delete_failed`.

  Times count the way the design asks: a server that never checked in is a
  problem after 30 minutes of its code being open while this computer is
  awake (the window's `awake_ms`, a monotonic count), and one that stopped
  answering after 10 minutes of no session, counted the same way (the link's
  `down_ms`). The last backup is old past 3 days.

  On the computer the home left, a replace of the server Fermix created
  (`Ledger.state/3`'s `replace`) leads while it runs: creating the
  new server (`creating`, with Cancel), its code and its enrollment as the
  old server's own `home.status` draws them (`primary_home`'s `enrollment`
  and `candidates`: starting, installing, connecting, then `ready` with Move
  now), the move to it (`moving`, before any silence of the old server, which
  serves nothing while it runs), removing the old server, or deleting the new
  one; a failure is a `problem` with its one action (`delete_failed` and
  Delete when the old server could not be deleted). Until the move is done
  the old server is the one the home lives on, and the provider's power
  actions, which reach only the new one, are not offered for it. The new
  server's code lives on the old server, which never sleeps, so its 30
  minutes count from its creation.

  **Moving back** (Always On's move back, its design §7 to §9). A linked
  desktop's `on` offers Move back beside Back up now and Replace the
  server. Once pressed, the desktop's own candidate for the home
  (`candidate/state.json`, `returning`) and the return's record
  (`device/return.json`, `return`) lead, ahead of everything else the
  desktop shows, its link gone included: `creating` while it connects to the
  server (Cancel), `ready` once it is held (Move now with the server's
  recovery passphrase and a confirm built here from this computer's own
  settings, Cancel beside it; and again once the start is recorded while
  the server answers as the primary with no move), `moving` from the
  recorded start (written before the request leaves) while the server moves
  or cannot answer, to this computer's restart as the primary, `undone` when
  the server undid it (Try again, Cancel), and `return_failed` when the
  candidate ended (Move back again) or stopped before any move with no
  record of it (Cancel). Cancel is never offered while the server's move is
  under way, once it retired, or once the home is coming in here. A move
  back the home went past (the link reached a newer epoch than the one it
  was asked at, without this computer's return) is not drawn. Where a server
  Fermix created stopped answering (`cannot_reach`, `turned_off`,
  `deleted`, `retired`) and this computer holds a copy of it, Restore here
  is offered, with the copy's date; while it runs it deletes the server
  first and a delete the provider refused restores nothing
  (`delete_failed`). Back on this computer as the primary, while the server
  Fermix created for the home stands, the screen is `server_retired` with
  Delete your server, ahead of the server's own screen and the setup's; a
  server of the owner's own is told once, `back:<epoch>`.

  **Every action is one record** wherever it sits (`action`,
  `detail.alternatives`, `on`'s `detail.actions`): `id`, `label`, `needs`
  (what the surface collects: `token`; `new_recovery_passphrase`, typed
  twice and compared, where this move's recovery key is not set yet, else
  `recovery_passphrase`, typed once and checked by the move; `choice`),
  `confirm` (the sentence the owner accepts before Fermix spends money,
  deletes, restarts a server or moves, with no time or price in it; nil
  otherwise), `url` (the docs page at the provider's part for Learn more,
  the provider's console for Open, nil otherwise) and `key` (`action_key/5`).
  Move now's confirm is built here, before any review, from the review's
  items this home's settings decide and any other warning the last review of
  the same server gave (`s3_size`, `plugins`), so the full review at the
  press moves it, and its key, only when it found something the screen did
  not say.

  `detail` holds what the state draws: on `off` and `connect` the token
  screen of every provider (`providers`) and the own-server link, on
  `choose` how the provider bills, on `ready` the server's facts, the
  readiness warnings and blocks and until when it waits, on `on` the server,
  each backup, the space this computer's copies take, the disk, what lives on
  the server and the two actions Details offers (Back up now, Replace the
  server), and on `problem` its kind, what Fermix last saw and when, one note,
  and the other actions; wherever there are any, the Details `lines`
  (`Copy.summary_line/3`), `providers` wherever a token is asked for, and
  `progress` while a step runs.

  `notice` is the occurrence the apps raise as a system notification, or
  nil: the server ready (`ready:<candidate>`), the move done
  (`moved:<epoch>`, until the first backup after it), the server out of
  reach (`cannot_reach:<since>`), a server that must be set up again
  (`not_set_up:<created_at>`), the newest backup a week old
  (`backup_week:<at>`) and Fermix back on this computer from a server of
  the owner's own (`back:<epoch>`). An app posts when the id changes.

  `outcome` is what a surface that follows a step reads (review R6), so none
  keeps its own table of states: `running` while Always On is at something
  that moves this screen on by itself (a step's job; the server starting,
  installing and connecting; the move, from its request here until the
  restart shows; a server receiving its home), `waiting` while it waits on a
  server of the owner's own to use its code, `failed` on a problem, `done`
  when the next step is the owner's.

  `key/1` is the one digest of the summary (`summary.key`, and what
  `FermixCore.Home.StatusWatch` tells by, `watch/1`): every change a surface
  draws moves it, and the clock alone (the last check, what was last seen,
  an age in a sentence) never does.
  """

  alias FermixCore.Clock
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Move
  alias FermixCore.Home.MoveReadiness
  alias FermixCore.Home.Provision
  alias FermixCore.Home.Provision.Ledger
  alias FermixCore.Home.Provision.Registry
  alias FermixCore.Home.Return
  alias FermixCore.Home.Snapshot.Capture
  alias FermixCore.Home.UnreadableFiles
  alias FermixCore.Management.Copy

  @states ~w(off connect choose creating ready moving on undone retired candidate primary problem)
  @outcomes ~w(running waiting done failed)
  @problems ~w(turned_off cannot_reach deleted not_set_up waited_too_long no_capacity
               account_limit read_only_token token_refused create_failed update disk_full
               backup_old not_ready unreadable delete_failed power_failed server_retired
               return_failed)
  @actions ~w(create_server cancel move_now try_again learn_more turn_on restart_server
              start_again create_in open_console paste_token update back_up_now replace_server
              check_again own_server delete_server move_back restore_here)
  @needs ~w(token recovery_passphrase new_recovery_passphrase choice)

  @unreachable_ms 10 * 60_000
  @setup_ms 30 * 60_000
  @backup_old_s 3 * 86_400
  @day_s 86_400
  # The apps raise their notification once the newest backup is this old.
  @backup_week_s 7 * @day_s
  # The states whose sentence `key/1` leaves out: on `on` and `problem` it
  # carries a figure that moves with the clock (a backup's age, a count of
  # days, how full a disk is), and their state, action and kind say every
  # change of note; on `off` an app forgets Always On (the owner's rule), so
  # the line naming what stops is read when its pane opens, never told.
  @untold_sentences ~w(off on problem)
  @moving ~w(requested streaming committed)
  @undoing ~w(aborting undoing)
  # A move under way, from its request to its undoing: nothing it goes to is
  # offered for deletion.
  @in_flight @moving ++ ["committing" | @undoing]
  @receiving ~w(receiving staged activating)
  # A move back's candidate that ended (`FermixCore.Home.Candidate`), and
  # one before any move reached it.
  @ended ~w(failed expired)
  @before_move ~w(enrolling enrolled)
  # A move the server reports under way, from its request to its undoing.
  @server_moves ~w(requested streaming committing aborting committed undoing)
  @power_steps ~w(power_on power_reset)
  # The states whose Details have lines.
  @detailed_states ~w(creating ready on problem)
  # The bytes of a digest a key keeps.
  @key_bytes 16

  @type facts :: %{
          required(:role) => :primary | :device | :candidate,
          required(:host_os) => :macos | :linux,
          required(:now) => DateTime.t(),
          required(:linked) => boolean(),
          required(:moved) => map() | nil,
          required(:move) => map() | nil,
          required(:link) => map(),
          required(:candidates) => [map()],
          required(:provider) => module(),
          required(:providers) => [module(), ...],
          required(:provision) => map(),
          required(:review) => map() | nil,
          required(:move_items) => [MoveReadiness.item()],
          required(:snapshots) => map(),
          required(:disk) => map() | nil,
          required(:primary_home) => map() | nil,
          required(:primary_too_old) => boolean(),
          required(:copies_bytes) => non_neg_integer() | nil,
          required(:stays_here) => [:imessage | :voice | :meetings],
          required(:zone) => String.t(),
          required(:return) => map() | nil,
          required(:returning) => map() | :unreadable | nil,
          required(:copies) => [%{name: String.t(), at: DateTime.t()}]
        }
  @type summary :: %{String.t() => term()}

  @doc "Every state a summary takes, in the order the protocol lists them."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "Every problem kind a `problem` names in `detail.kind`."
  @spec problems() :: [String.t()]
  def problems, do: @problems

  @doc "Every action id a summary offers, as its action or in `detail`."
  @spec actions() :: [String.t()]
  def actions, do: @actions

  @doc "Every word `outcome` takes, in the protocol's order."
  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes

  @doc """
  How long a linked desktop's server may be silent, while this computer is
  awake, before the summary says it cannot be reached (and Restore here may
  delete it as its fence), in milliseconds.
  """
  @spec unreachable_ms() :: pos_integer()
  def unreachable_ms, do: @unreachable_ms

  @doc "Every word an action's `needs` lists."
  @spec needs() :: [String.t()]
  def needs, do: @needs

  @doc "The summary for `facts` (`gather/5`'s)."
  @spec summary(facts()) :: summary()
  def summary(facts) when is_map(facts), do: facts |> screen() |> finish(facts)

  defp screen(%{role: :candidate} = facts), do: candidate(facts)
  defp screen(%{role: :device} = facts), do: device(facts)
  defp screen(%{role: :primary} = facts), do: back(facts) || here(facts)

  defp here(%{link: %{desktops: [_ | _]}} = facts), do: server(facts)
  defp here(facts), do: setup(facts)

  @doc """
  The one digest of `summary`, `summary.key`: of everything it holds but
  the key itself, the sentence of an `off`, `on` or `problem` (whose figures
  move with the clock), what was last seen (`detail.seen_at`) and the line
  that says when the provider was last checked. A change of the state, the
  sentence of a step, an action, a confirm, an alternative, a line, the
  progress or the notice moves it; a check of the provider that found
  nothing new does not.
  """
  @spec key(summary()) :: String.t()
  def key(%{"state" => state, "detail" => detail} = summary) when is_map(detail) do
    sentence = if state in @untold_sentences, do: nil, else: summary["sentence"]

    summary
    |> Map.drop(["key", "sentence"])
    |> Map.put("detail", keyed_detail(detail))
    |> Map.put("told", sentence)
    |> digest()
  end

  defp keyed_detail(detail) do
    clock = [Copy.checked_label(), Copy.summary_line_label(:seen)]

    detail
    |> Map.delete("seen_at")
    |> Map.update("lines", [], fn lines -> Enum.reject(lines, &(&1["label"] in clock)) end)
  end

  @doc """
  An action's `key`: the digest of its `id`, `label`, `confirm`, `needs` and
  `target`, the one thing it acts on: the server a move goes to
  (`move_now`, `try_again`, `check_again`), the provider's id of the server
  Fermix created (`turn_on`, `restart_server`, `delete_server`,
  `start_again`, `cancel`; the old server's for Delete your old server), the
  provider's id (`paste_token`), the place (`create_in`), or nil.
  """
  @spec action_key(String.t(), String.t(), String.t() | nil, [String.t()], String.t() | nil) ::
          String.t()
  def action_key(id, label, confirm, needs, target)
      when id in @actions and is_binary(label) and is_list(needs),
      do: digest([id, label, confirm, needs, target])

  @doc """
  Every action record `summary` offers, wherever it sits: its action, then
  `detail.alternatives`, then `detail.actions` (review simplification 3).
  The one reading of what a screen offers: `find_action/3`, the CLI's
  steps and menus, and the tests read it here.
  """
  @spec offered(summary()) :: [map()]
  def offered(%{"action" => action, "detail" => detail}) when is_map(detail),
    do: List.wrap(action) ++ Map.get(detail, "alternatives", []) ++ Map.get(detail, "actions", [])

  @doc """
  The action `id` that `summary` offers under `key` (`offered/1`), or
  `:error` when it offers none such: what says the owner saw the step they
  asked for.
  """
  @spec find_action(summary(), String.t(), String.t()) :: {:ok, map()} | :error
  def find_action(summary, id, key) when is_binary(id) and is_binary(key) do
    case Enum.find(offered(summary), &(&1["id"] == id and &1["key"] == key)) do
      nil -> :error
      found -> {:ok, found}
    end
  end

  @doc """
  The server a move goes to, by the engine's one rule: on the computer that
  sets Always On up, the one the created server's code enrolled, else the
  newest held; on a linked desktop moving back, its own candidate once the
  server holds it (`returning`'s `candidate_id`); on a linked desktop during
  a replace, the one the old server's code for the new server enrolled, as
  the old server's own `home.status` holds it (`primary_home`); nil when
  there is none. Reads `facts`' `role`, `candidates`, `link`, `returning`
  and `primary_home`.
  """
  @spec target(map()) :: map() | nil
  def target(%{role: :device, returning: %{"kind" => "return", "candidate_id" => id} = state})
      when is_binary(id),
      do: %{"candidate_id" => id, "name" => get_in(state, ["primary", "name"])}

  def target(%{role: :device, returning: %{} = _getting_ready}), do: nil

  def target(%{role: :device} = facts) do
    case new_window(facts) do
      %{"candidate_id" => id} when is_binary(id) -> held_by_server(facts, id)
      _none -> nil
    end
  end

  def target(%{candidates: []}), do: nil

  def target(%{candidates: [_ | _]} = facts) do
    case window(facts) do
      %{candidate_id: id} when is_binary(id) -> held(facts, id) || newest(facts.candidates)
      _window -> newest(facts.candidates)
    end
  end

  @doc """
  What `FermixCore.Home.StatusWatch` watches, from `facts` (`gather/5`'s):

    * `key`: the summary's own (`key/1`), and on a server with desktops what
      their summaries read from its `home.status` (its newest backup, its
      enrollment code's kind, state and who used it, and the servers it
      holds), which its own summary does not show.
    * `off`: whether the summary is `off`.
    * `next_change_ms`: the milliseconds until the summary next changes by
      the clock alone (a created server's code open 30 minutes awake, a link
      down 10 minutes awake, a held server's 24 hours, a backup's 3 days and
      its 7, a step's job budget), or nil when nothing does; always nil while
      off. A deadline may change nothing when it comes (another rule decided
      first): the watch then reads a same key and tells nobody.
  """
  @spec watch(facts()) :: %{key: term(), off: boolean(), next_change_ms: pos_integer() | nil}
  def watch(facts) when is_map(facts) do
    summary = summary(facts)
    off = summary["state"] == "off"
    next = if off, do: nil, else: next_change(facts)
    %{key: {summary["key"], drawn(facts)}, off: off, next_change_ms: next}
  end

  @doc """
  The facts of `home`'s summary: `status` is the `home.status` record's own
  facts (`Management.Home.status/1` has gathered them, with
  `primary_too_old`), `link` the rail's status, and `opts` the seams `:now`,
  `:host_os`, `:providers` (in place of `Provision.Registry.all/0`),
  `:personalization` (the owner's time zone, `FermixCore.Clock`'s seam) and
  `:unreadable_files` (`Home.UnreadableFiles`, or nil for a verb with no
  engine tree); `MoveReadiness.summary_items/4` is given `opts` as they are.
  Reads the provider's ledger, the last readiness review, what this home's
  settings turn on that runs only on this computer (on the primary, what
  stops after a move; on a desktop, what runs here again after a move back),
  on the primary the review's items they decide, the record of a move back
  (`Home.Return`), and, on a desktop, its candidate for a move back
  (`Home.Candidate`'s state) and its stored copies, newest first, by the
  time and epoch their names carry.
  """
  @spec gather(Path.t(), map(), map(), map(), keyword()) :: facts()
  def gather(home, %{role: role} = record, link, status, opts)
      when is_binary(home) and is_map(link) and is_map(status) and is_list(opts) do
    host_os = Keyword.get_lazy(opts, :host_os, &host_os/0)
    reads = Keyword.take(opts, [:unreadable_files])
    providers = Keyword.get_lazy(opts, :providers, &Registry.all/0)
    provider = Provision.current(home, providers)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    %{
      role: role,
      host_os: host_os,
      now: now,
      linked: DesktopLink.linked?(record, home),
      moved: status.moved,
      move: status.move,
      link: link,
      candidates: status.candidates,
      provider: provider,
      providers: providers,
      provision: Ledger.state(home, provider, Keyword.put(reads, :now, now)),
      review: review(home, role, reads),
      move_items: move_items(home, role, host_os, {status, link}, opts),
      snapshots: status.snapshots,
      disk: status.disk,
      primary_home: status.primary_home,
      primary_too_old: Map.get(status, :primary_too_old, false),
      copies_bytes: copies_bytes(home, role, reads),
      stays_here: stays_here(home, role, host_os, reads),
      zone: Clock.shown_zone(Keyword.take(opts, [:personalization])),
      return: return_record(home, reads),
      returning: returning_state(home, role, reads),
      copies: copies(home, role)
    }
  end

  # -- the computer that sets Always On up ---------------------------------------

  defp setup(facts) do
    checks = [&running/1, &undone/1, &ledger_problem/1, &provisioned/1, &own_server/1, &chosen/1]
    Enum.find_value(checks, & &1.(facts)) || off(facts)
  end

  # A move undone while its server is still held: Try again, and, once the
  # undo is over, the delete of a server Fermix created (`cleanup/2`).
  defp undone(%{move: %{"phase" => phase}} = facts) when phase in ["aborted", "undoing"] do
    if target(facts),
      do: view("undone", sentence(:undone, facts), action(:try_again), %{}) |> cleanup(facts)
  end

  defp undone(_facts), do: nil

  # What the ledger itself says is wrong, before anything about a server.
  defp ledger_problem(%{provision: %{state: :unreadable, sentence: sentence}}),
    do: problem("unreadable", sentence, :learn_more, %{})

  defp ledger_problem(%{provision: %{token: :refused, server: server}} = facts) do
    if standing?(server),
      do: problem("token_refused", sentence(:token_refused, facts), :paste_token, %{}),
      else: connect(facts)
  end

  defp ledger_problem(%{provision: %{state: :failed, failure: failure}} = facts),
    do: failure_problem(failure, facts)

  defp ledger_problem(_facts), do: nil

  # A step that stopped, by the step: a power action's and a delete's, then
  # a create's by its reason.
  defp failure_problem(%{action: action} = failure, facts) when action in @power_steps,
    do: failure |> power_failed() |> cleanup(facts)

  defp failure_problem(%{action: "delete"} = failure, facts) do
    {note, delete} = server_costs(facts.provision)

    problem("delete_failed", failure.sentence, delete, %{
      "note" => note,
      "seen_at" => iso(failure.at)
    })
  end

  defp failure_problem(%{reason: "unavailable", next_location: next} = failure, facts)
       when is_binary(next) do
    city = Provision.city(facts.provider, next)

    problem("no_capacity", failure.sentence, action(:create_in, %{city: city, next: next}), %{
      "next_location" => next,
      "seen_at" => iso(failure.at)
    })
    |> cleanup(facts)
  end

  # A refusal the provider may lift by itself (stock) or once the owner did
  # (an account limit) is offered again, Start again with the size and place
  # the failure kept.
  defp failure_problem(%{reason: reason} = failure, facts) do
    {kind, act, alternatives} =
      case reason do
        "unavailable" -> {"no_capacity", :start_again, [:learn_more]}
        "account_limit" -> {"account_limit", :open_console, [:start_again, :own_server]}
        "read_only_token" -> {"read_only_token", :paste_token, []}
        "gone" -> {"deleted", :start_again, []}
        _other -> {"create_failed", :start_again, []}
      end

    problem(kind, failure.sentence, action(act, words(facts)), %{
      "seen_at" => iso(failure.at),
      "alternatives" => Enum.map(alternatives, &action(&1, words(facts)))
    })
    |> cleanup(facts)
  end

  defp power_failed(%{action: action} = failure) do
    act = if action == "power_on", do: :turn_on, else: :restart_server
    problem("power_failed", failure.sentence, act, %{"seen_at" => iso(failure.at)})
  end

  defp provisioned(%{provision: %{state: :deleting}}),
    do: view("creating", Copy.summary_sentence(:deleting, %{}), nil, %{})

  defp provisioned(%{provision: %{state: :creating}}), do: creating(:starting)

  defp provisioned(%{provision: %{state: :gone, server: server}} = facts),
    do: deleted(server, :start_again, facts) |> cleanup(facts)

  defp provisioned(%{provision: %{state: :created, server: server}} = facts),
    do: created(server, facts)

  defp provisioned(_facts), do: nil

  defp created(%{power: "off"} = server, facts),
    do: turned_off(server) |> cleanup(facts)

  defp created(server, facts), do: waiting_server(window(facts), server, facts)

  # The created server, by where its own 24-hour code stands (L15).
  defp waiting_server(%{kind: :provisioned, state: :open} = window, server, facts) do
    cond do
      Map.get(window, :awake_ms, 0) >= @setup_ms -> not_set_up(server, facts)
      server.power == "running" -> creating(:installing)
      true -> creating(:starting)
    end
  end

  defp waiting_server(%{kind: :provisioned, state: :used, candidate_id: nil}, _server, _facts),
    do: creating(:connecting)

  defp waiting_server(%{kind: :provisioned, state: :used, candidate_id: id}, server, facts) do
    case held(facts, id) do
      nil ->
        problem("waited_too_long", sentence(:waited_too_long, facts), :start_again, %{})
        |> cleanup(facts)

      candidate ->
        ready(candidate, server, facts)
    end
  end

  defp waiting_server(_window, server, facts), do: not_set_up(server, facts)

  defp not_set_up(_server, facts) do
    problem("not_set_up", sentence(:not_set_up, facts), :start_again, %{
      "alternatives" => [action(:own_server), action(:open_console, words(facts))]
    })
    |> cleanup(facts)
  end

  # A server of the owner's own (`home.enroll.open`), with none Fermix created.
  defp own_server(facts) do
    case {target(facts), window(facts)} do
      {%{} = candidate, _window} ->
        ready(candidate, nil, facts)

      {nil, %{kind: :manual, state: :open}} ->
        connect(facts)

      {nil, %{kind: :manual, state: :used, candidate_id: nil}} ->
        view("creating", Copy.summary_sentence(:connecting, %{}), nil, %{})

      _nothing ->
        nil
    end
  end

  defp chosen(%{provision: %{state: :connected}} = facts) do
    view("choose", sentence(:choose, facts), action(:create_server), %{
      "billing" => sentence(:billing, facts)
    })
  end

  defp chosen(_facts), do: nil

  defp off(facts) do
    view(
      "off",
      sentence(:off, facts, %{stays_here: facts.stays_here}),
      action(:paste_token, %{first: true}),
      %{"alternatives" => [action(:own_server)]}
    )
  end

  # The token screen: the first one, while a code for a server of the
  # owner's own is open (which Cancel closes), or after the provider refused
  # the token before anything was created.
  defp connect(facts) do
    code? = match?(%{kind: :manual, state: :open}, window(facts))
    paste = action(:paste_token, %{first: facts.provision.token != :refused})
    cancel = if code?, do: [action(:cancel, %{code: true})], else: []

    view("connect", sentence(:connect, facts), paste, %{
      "alternatives" => [action(:own_server) | cancel]
    })
  end

  defp creating(step),
    do: view("creating", Copy.summary_sentence(step, %{}), action(:cancel), %{})

  # The server is held and waits for Move now, unless the last review blocks;
  # either way what Fermix created for it can be deleted.
  defp ready(candidate, server, facts),
    do: candidate |> ready_view(server, facts) |> cleanup(facts)

  defp ready_view(candidate, server, facts) do
    items = review_items(facts.review, candidate["candidate_id"])

    case for(%{"status" => "block", "sentence" => block} <- items, do: block) do
      [block | _more] ->
        problem("not_ready", Copy.summary_sentence(:not_ready, %{block: block}), :check_again, %{
          "readiness" => items
        })

      [] ->
        view("ready", sentence(:ready, facts), action(:move_now), %{
          "server" => server_facts(candidate, server, facts),
          "readiness" => items,
          "waits_until" => candidate["expires_at"]
        })
    end
  end

  # The warnings and blocks of the last review of this server; nothing when
  # all is well or none was made.
  defp review_items(%{candidate_id: id, items: items}, id),
    do: Enum.filter(items, &(&1["status"] in ["warn", "block"]))

  defp review_items(_review, _candidate_id), do: []

  defp server_facts(candidate, server, facts) do
    %{
      "name" => (server && server.name) || candidate["name"],
      "type" => server && facts.provider.type_name(server.type),
      "location" => server && Provision.city(facts.provider, server.location),
      "ipv4" => server && server.ipv4,
      "system" => "#{candidate["os"]} #{candidate["arch"]}",
      "version" => candidate["version"]
    }
  end

  # Before a move, while a server Fermix created for it stands, the screen
  # offers to delete it (during a replace, the new one) beside its own
  # alternatives, and a problem's note says it costs money: built here
  # once, for every screen a waiting server has (review R2). Never the
  # server the home lives on, and never while a move runs.
  defp cleanup(view, facts) do
    if deletable?(facts) do
      {note, delete} = server_costs(facts.provision)
      detail = Map.update(view["detail"], "alternatives", [delete], &(&1 ++ [delete]))
      %{view | "detail" => noted(detail, view["state"], note)}
    else
      view
    end
  end

  defp noted(detail, "problem", note), do: Map.update!(detail, "note", &(&1 || note))
  defp noted(detail, _state, _note), do: detail

  defp deletable?(%{provision: provision} = facts),
    do: standing?(provision.server) and not home_server?(facts) and not moving?(facts)

  # The server the home lives on: a linked desktop's own, outside a replace
  # or once the move to the new one is done.
  defp home_server?(%{role: :device, provision: %{replace: %{current: :old}}}), do: false
  defp home_server?(%{role: :device}), do: true
  defp home_server?(_facts), do: false

  defp moving?(%{move: %{"phase" => phase}}), do: phase in @in_flight
  defp moving?(_facts), do: false

  defp server_costs(%{replace: %{}}),
    do: {Copy.summary_sentence(:new_server_costs, %{}), action(:delete_server, %{which: "new"})}

  defp server_costs(_provision),
    do: {Copy.summary_sentence(:server_costs, %{}), action(:delete_server)}

  # -- a step whose job runs -----------------------------------------------------

  # The ledger names the step's job before it starts, so this is what the
  # summary says from the press on, whatever the job has written yet.
  defp running(%{provision: %{action: %{kind: kind}}} = facts), do: running_step(kind, facts)
  defp running(_facts), do: nil

  # Start again deletes what stands first, which no one cancels.
  defp running_step("create", %{provision: %{state: :deleting}} = facts), do: deleting_step(facts)

  defp running_step("create", %{provision: %{replace: %{}}} = facts),
    do: new_server_step(:replace_creating, facts)

  defp running_step("create", _facts), do: creating(:starting)
  defp running_step("delete", facts), do: deleting_step(facts)

  defp running_step("power_on", %{provision: %{replace: %{}}} = facts),
    do: view("creating", sentence(:replace_turning_on, facts), nil, %{})

  defp running_step("power_on", facts),
    do: view("creating", sentence(:turning_on, facts), nil, %{})

  defp running_step("power_reset", facts),
    do: view("creating", sentence(:restarting, facts), nil, %{})

  defp deleting_step(%{provision: %{replace: %{current: :new}}} = facts),
    do: view("creating", sentence(:replace_deleting, facts), nil, %{})

  defp deleting_step(%{provision: %{replace: %{}}} = facts),
    do: view("creating", sentence(:replace_cancelling, facts), nil, %{})

  defp deleting_step(_facts),
    do: view("creating", Copy.summary_sentence(:deleting, %{}), nil, %{})

  # The step in hand: a move back's, from what this computer's candidate
  # wrote so far, else the job's, from what it wrote so far.
  defp progress(%{"state" => "moving"}, %{role: :device} = facts) do
    case return_progress(facts) do
      nil -> nil
      key -> sentence(key, facts)
    end
  end

  defp progress(_view, %{provision: %{action: %{kind: kind}} = provision} = facts),
    do: Copy.summary_sentence(progress_key(kind, provision), words(facts))

  defp progress(_view, _facts), do: nil

  defp return_progress(%{returning: %{"kind" => kind, "phase" => phase}})
       when phase in @receiving,
       do: return_step(kind, phase)

  defp return_progress(%{returning: nil, return: %{fenced_at: %DateTime{}}}),
    do: :progress_restoring

  defp return_progress(%{returning: nil, return: %{move_started_at: %DateTime{}}}),
    do: :progress_return_placing

  defp return_progress(_facts), do: nil

  defp return_step(_kind, "activating"), do: :progress_return_placing
  defp return_step("local", _phase), do: :progress_restoring
  defp return_step("return", "receiving"), do: :progress_return_receiving
  defp return_step("return", "staged"), do: :progress_return_staged

  defp progress_key(kind, _provision) when kind in @power_steps, do: :progress_power
  defp progress_key(_kind, %{state: :deleting}), do: :progress_deleting
  defp progress_key("delete", _provision), do: :progress_deleting

  defp progress_key("create", %{server: %{status: status}}) when status in [:creating, :created],
    do: :progress_starting

  defp progress_key("create", %{server: %{status: :requested}}), do: :progress_server
  defp progress_key("create", %{state: :creating}), do: :progress_firewall
  defp progress_key("create", _provision), do: :progress_checking

  # -- the computer the move left ------------------------------------------------

  # A move back leads, whatever the link says (its activation ends the
  # tenure's link); then Restore here's job; then the computer's own move.
  defp device(facts), do: returning(facts) || restoring(facts) || settled(facts)

  defp settled(%{move: %{"phase" => "committing"}} = facts),
    do: view("moving", sentence(:waiting, facts), nil, %{})

  defp settled(%{move: %{"phase" => phase}} = facts) when phase in @moving,
    do: view("moving", sentence(:moving, facts), nil, %{})

  defp settled(%{move: %{"phase" => phase}} = facts) when phase in @undoing,
    do: view("undone", sentence(:undone, facts), nil, %{})

  defp settled(%{linked: false} = facts), do: retired(facts)
  defp settled(%{link: %{primary: %{status: :revoked}}} = facts), do: retired(facts)
  defp settled(facts), do: desktop(facts)

  defp retired(facts),
    do:
      view("retired", sentence(:retired, facts), action(:learn_more), %{})
      |> restorable(facts)

  defp desktop(facts) do
    checks = [
      &running/1,
      &failed_step/1,
      &replace_moving/1,
      &away_here/1,
      &too_old/1,
      &token_stopped/1,
      &replace_stopped/1,
      &server_disk/1,
      &replacing/1,
      &desktop_backup/1
    ]

    Enum.find_value(checks, & &1.(facts)) || on(facts)
  end

  # A power action on the server the home lives on that stopped: tried again,
  # and never with a delete beside it, since that server holds the home.
  defp failed_step(%{provision: %{replace: nil, failure: %{action: action} = failure}})
       when action in @power_steps,
       do: power_failed(failure)

  defp failed_step(_facts), do: nil

  # No session with the server: what the provider last said, else ten
  # minutes of silence while this computer is awake.
  defp away(%{link: %{primary: %{status: status} = link}, provision: provision} = facts)
       when status in [:unreachable, :stale] do
    {server, powered?} = home_server(provision)

    cond do
      match?(%{status: :gone}, server) -> deleted(server, :learn_more, facts)
      match?(%{power: "off"}, server) -> turned_off(server, :turned_off, powered?)
      (Map.get(link, :down_ms) || 0) >= @unreachable_ms -> cannot_reach(server, powered?)
      true -> nil
    end
  end

  defp away(_facts), do: nil

  # A server that stopped answering, with Restore here beside it where this
  # computer can take the home back from its own copy.
  defp away_here(facts), do: facts |> away() |> restorable(facts)

  defp cannot_reach(%{status: :created} = server, powered?) do
    act = if powered?, do: :restart_server, else: :learn_more

    problem("cannot_reach", Copy.summary_sentence(:cannot_reach, %{}), act, %{
      "seen_at" => iso(server.seen_at)
    })
  end

  defp cannot_reach(_server, _powered?),
    do: problem("cannot_reach", Copy.summary_sentence(:cannot_reach, %{}), :learn_more, %{})

  # The server the home lives on, and whether the provider's power actions
  # reach it: during a replace the old one until the move is done, which
  # they do not (they act on the new server).
  defp home_server(%{replace: %{current: :old, old: old}}), do: {old, false}
  defp home_server(provision), do: {provision.server, true}

  defp too_old(%{primary_too_old: true} = facts),
    do: problem("update", sentence(:update, facts), :update, %{})

  defp too_old(_facts), do: nil

  defp token_stopped(%{provision: %{token: :refused} = provision} = facts) do
    {server, _powered?} = home_server(provision)

    if standing?(server) or standing?(provision.server),
      do: problem("token_refused", sentence(:token_refused, facts), :paste_token, %{})
  end

  defp token_stopped(_facts), do: nil

  # A replace that stopped before the provider made anything for it (review
  # R4): the server the home lives on is as it was, so Replace is offered
  # again, never a Start again, whose delete would reach that server.
  defp replace_stopped(%{provision: %{replace: nil, failure: %{action: "create"} = failure}}) do
    problem("create_failed", failure.sentence, :replace_server, %{
      "note" => Copy.summary_sentence(:replace_stopped, %{}),
      "seen_at" => iso(failure.at)
    })
  end

  defp replace_stopped(_facts), do: nil

  defp server_disk(%{primary_home: %{"disk" => disk}}), do: disk_problem(disk, :disk_full)
  defp server_disk(_facts), do: nil

  defp desktop_backup(%{primary_home: %{"snapshots" => snapshots}} = facts) do
    case newest_backup(snapshots) do
      nil -> no_backup(facts)
      at -> old_backup(at, :backup_old, facts)
    end
  end

  defp desktop_backup(_facts), do: nil

  # No backup has finished since the move: counted from the move itself.
  defp no_backup(%{moved: %{moved_at: %DateTime{} = moved_at}} = facts) do
    age = DateTime.diff(facts.now, moved_at, :second)

    if age > @backup_old_s,
      do:
        problem(
          "backup_old",
          sentence(:backup_none, facts, %{days: div(age, @day_s)}),
          :back_up_now,
          %{}
        )
  end

  defp no_backup(_facts), do: nil

  defp on(facts) do
    view("on", on_sentence(facts), nil, %{
      "server" => on_server(facts),
      "backups" => backups(get_in(facts, [:primary_home, "snapshots"])),
      "copies_bytes" => facts.copies_bytes,
      "disk_used" => get_in(facts, [:primary_home, "disk", "used"]),
      "data" => sentence(:data, facts, %{provider: provider(facts)}),
      "actions" => [
        action(:back_up_now),
        action(:replace_server),
        action(:move_back, %{machine: machine(facts.host_os)})
      ]
    })
  end

  defp on_sentence(%{primary_home: %{"snapshots" => snapshots}} = facts) do
    case newest_backup(snapshots) do
      nil -> sentence(:on_no_backup, facts)
      at -> sentence(:on_backup, facts, %{age: DateTime.diff(facts.now, at, :second)})
    end
  end

  defp on_sentence(facts), do: sentence(:on, facts)

  defp on_server(%{provision: %{server: server}} = facts) do
    %{
      "name" => (server && server.name) || link_name(facts),
      "location" => server && Provision.city(facts.provider, server.location),
      "version" => get_in(facts, [:primary_home, "version"])
    }
  end

  defp link_name(%{link: %{primary: %{name: name}}}), do: name
  defp link_name(%{moved: %{to: to}}), do: to
  defp link_name(_facts), do: nil

  defp provider(%{provision: %{server: %{}}} = facts), do: facts.provider.display().name
  defp provider(_facts), do: "whoever hosts it"

  # -- a replace of the server, on the computer the home left -------------------

  # The old server serves nothing while the move runs, so its silence then is
  # the move, not a problem.
  defp replace_moving(%{provision: %{replace: %{state: :moving}}} = facts),
    do: view("moving", sentence(:replace_moving, facts), nil, %{})

  defp replace_moving(_facts), do: nil

  defp replacing(%{provision: %{replace: %{state: state} = replace}} = facts),
    do: replace_step(state, replace, facts)

  defp replacing(_facts), do: nil

  defp replace_step(:creating, _replace, facts), do: new_server_step(:replace_creating, facts)
  defp replace_step(:waiting, _replace, facts), do: new_server(facts.provision.server, facts)

  defp replace_step(:deleting, _replace, facts),
    do: view("creating", sentence(:replace_deleting, facts), nil, %{})

  defp replace_step(:cancelling, _replace, facts),
    do: view("creating", sentence(:replace_cancelling, facts), nil, %{})

  defp replace_step(:failed, %{current: :new, failure: failure}, _facts),
    do: delete_failed(failure)

  defp replace_step(:failed, %{failure: failure}, facts), do: failure_problem(failure, facts)
  defp replace_step(state, _replace, _facts) when state in [:moving, :done], do: nil

  # The new server, by where the old server's 24-hour code for it stands.
  defp new_server(%{power: "off"} = server, facts),
    do: server |> turned_off(:replace_turned_off, true) |> cleanup(facts)

  defp new_server(server, facts), do: new_server_window(new_window(facts), server, facts)

  defp new_server_window(%{"state" => "open"}, server, facts) do
    if older_than?(server.created_at, @setup_ms, facts),
      do: new_server_problem("not_set_up", :replace_not_set_up, facts),
      else: new_server_step(power_step(server), facts)
  end

  defp new_server_window(%{"state" => "used", "candidate_id" => nil}, _server, facts),
    do: new_server_step(:replace_connecting, facts)

  defp new_server_window(%{"state" => "used", "candidate_id" => id}, server, facts) do
    case held_by_server(facts, id) do
      nil ->
        new_server_problem("waited_too_long", :replace_waited_too_long, facts)

      candidate ->
        view("ready", sentence(:replace_ready, facts), action(:move_now), %{
          "server" => server_facts(candidate, server, facts),
          "readiness" => [],
          "waits_until" => candidate["expires_at"]
        })
        |> cleanup(facts)
    end
  end

  defp new_server_window(%{"state" => "expired"}, _server, facts),
    do: new_server_problem("not_set_up", :replace_not_set_up, facts)

  # The old server's part is missing, or holds no such code: what the provider
  # says.
  defp new_server_window(nil, server, facts), do: new_server_step(power_step(server), facts)

  defp power_step(%{power: "running"}), do: :replace_installing
  defp power_step(_server), do: :replace_starting

  defp new_server_step(key, facts),
    do: view("creating", sentence(key, facts), action(:cancel), %{})

  defp new_server_problem(kind, key, facts),
    do: problem(kind, sentence(key, facts), :start_again, %{}) |> cleanup(facts)

  # Deleting the old server after the move stopped: it stays, and costs.
  defp delete_failed(failure) do
    problem("delete_failed", failure.sentence, action(:delete_server, %{which: "old"}), %{
      "note" => Copy.summary_sentence(:old_server_costs, %{}),
      "seen_at" => iso(failure.at)
    })
  end

  # The old server's window for the new one, as its own `home.status` says.
  defp new_window(facts) do
    case get_in(facts, [:primary_home, "enrollment"]) do
      %{"kind" => "provisioned"} = window -> window
      _none -> nil
    end
  end

  defp held_by_server(facts, id) do
    candidates = get_in(facts, [:primary_home, "candidates"]) || []
    Enum.find(candidates, &(&1["candidate_id"] == id))
  end

  defp older_than?(%DateTime{} = at, ms, facts),
    do: DateTime.diff(facts.now, at, :millisecond) >= ms

  defp older_than?(nil, _ms, _facts), do: false

  # -- moving back to this computer (design §7 to §9) -------------------------------

  # This computer's own candidate for the home, by its kind and phase, else
  # the move the server started, until this computer is the primary again.
  # A started record with no candidate: the move in its last second, or a
  # leftover whose server answers as the primary with no move under way,
  # which Cancel clears (the move back's TLA spec, HR-2).
  defp returning(%{returning: nil, return: record} = facts) do
    cond do
      not started?(record) or stale?(facts) -> nil
      server_idle?(facts) -> return_stopped(facts, true)
      true -> return_moving(facts)
    end
  end

  defp returning(%{returning: :unreadable} = facts),
    do: return_stopped(facts, not started?(facts.return))

  defp returning(%{returning: %{"kind" => "local"} = state} = facts),
    do: restore_view(state, facts)

  defp returning(%{returning: %{"phase" => phase} = state} = facts) do
    cond do
      stale?(facts) -> nil
      facts.return == nil and phase in @before_move -> return_stopped(facts, true)
      true -> return_view(state, facts)
    end
  end

  defp return_view(%{"phase" => "enrolling"}, facts),
    do: view("creating", sentence(:return_connecting, facts), return_cancel(), %{})

  defp return_view(%{"phase" => phase}, facts) when phase in @ended do
    problem("return_failed", sentence(:return_failed, facts), move_back(facts), %{
      "alternatives" => [action(:learn_more)]
    })
  end

  # Once its start is recorded (before the request leaves), the move back
  # waits on the server: Cancel only where the server undid it, or answers as
  # the primary with no move at all (the request never reached it).
  defp return_view(%{"phase" => "enrolled"} = state, facts) do
    cond do
      not started?(facts.return) -> return_ready(state, facts)
      server_move(facts) == "aborted" -> return_undone(facts)
      server_idle?(facts) -> return_ready(state, facts)
      true -> return_moving(facts)
    end
  end

  # Receiving or staged while the server serves again with no move under
  # way (it undid the move after the offer; a primary holds no marker): as an
  # enrolled candidate, Try again or Cancel, which also lets this computer
  # sleep again (HR-2). Putting the home in place is never stopped.
  defp return_view(%{"phase" => phase}, facts) when phase in ["receiving", "staged"] do
    cond do
      not server_idle?(facts) -> return_moving(facts)
      facts.return == nil -> return_stopped(facts, true)
      true -> return_undone(facts)
    end
  end

  defp return_view(_activating, facts), do: return_moving(facts)

  defp return_ready(state, facts) do
    view("ready", sentence(:return_ready, facts), action(:move_now), %{
      "server" => %{"name" => facts.return.from},
      "readiness" => [],
      "waits_until" => state["listen_until"],
      "alternatives" => [return_cancel()]
    })
  end

  defp return_moving(facts), do: view("moving", sentence(:return_moving, facts), nil, %{})

  # The server undid the move before its marker: it is the primary again,
  # and this computer's candidate still waits.
  defp return_undone(facts) do
    view("undone", sentence(:return_undone, facts), action(:try_again), %{
      "alternatives" => [return_cancel()]
    })
  end

  # A move back left part-way by a stop between two writes (a candidate with
  # no record, a record with no candidate, or a state that cannot be read):
  # Cancel clears what is left where no move can be under way.
  defp return_stopped(facts, cancellable?) do
    act = if cancellable?, do: return_cancel(), else: action(:learn_more)
    problem("return_failed", sentence(:return_stopped, facts), act, %{})
  end

  defp restore_view(%{"phase" => "failed"} = state, facts) do
    problem(
      "return_failed",
      sentence(:restore_failed, facts),
      restore_offer(facts) || :learn_more,
      %{
        "note" => state["sentence"]
      }
    )
  end

  defp restore_view(_state, facts),
    do: view("moving", sentence(:restore_moving, facts), nil, %{})

  defp return_cancel, do: action(:cancel, %{return: true})
  defp move_back(facts), do: action(:move_back, %{machine: machine(facts.host_os)})

  # Restore here's job: the server is deleted first, then the copy restored;
  # a delete the provider refused restored nothing, said while Restore here
  # can be pressed again.
  defp restoring(%{return: %{fence_requested: _} = record, provision: provision} = facts) do
    cond do
      match?(%{action: %{kind: "delete"}}, provision) -> restore_step(record, facts)
      fence_failed?(record, provision) -> fence_failed(provision.failure, facts)
      true -> nil
    end
  end

  defp restoring(_facts), do: nil

  defp restore_step(%{fenced_at: %DateTime{}}, facts),
    do: view("moving", sentence(:restore_moving, facts), nil, %{})

  defp restore_step(_record, facts),
    do: view("creating", sentence(:restore_deleting, facts), nil, %{})

  # A fence whose delete went through holds no server any more, whatever
  # stopped after it (HR-3): that is no failure.
  defp fence_failed?(record, %{failure: %{action: "delete"}, server: %{}}),
    do: not Map.has_key?(record, :fenced_at)

  defp fence_failed?(_record, _provision), do: false

  defp fence_failed(failure, facts) do
    case restore_offer(facts) do
      nil ->
        nil

      restore ->
        problem("delete_failed", failure.sentence, restore, %{"seen_at" => iso(failure.at)})
    end
  end

  # Restore here (design §8): only for a server Fermix created, which is
  # deleted first (the fence), or one a restore asked to delete and whose
  # ledger no longer holds it (deleted for it, its record written or not:
  # HR-3); only while the server is as silent as the fence asks, never
  # during a replace, and only while this computer holds a copy, the newest
  # named.
  defp restore_offer(%{copies: [newest | _], provision: %{replace: nil} = provision} = facts) do
    fence? = provision.server != nil or match?(%{fence_requested: _copy}, facts.return)

    if fence? and silent?(facts),
      do:
        action(:restore_here, %{copy: newest.name, at: newest.at, machine: machine(facts.host_os)})
  end

  defp restore_offer(_facts), do: nil

  defp restorable(nil, _facts), do: nil

  defp restorable(view, facts) do
    case restore_offer(facts) do
      nil ->
        view

      restore ->
        update_in(
          view,
          ["detail"],
          &Map.update(&1, "alternatives", [restore], fn more -> more ++ [restore] end)
        )
    end
  end

  # Back on this computer as the primary, while the server Fermix created
  # for the home stands (design §7): the step that runs on it, else what
  # stopped, else Delete your server. Ahead of the server's own screen and
  # the setup's, which a second desktop's row or a ledger with nothing set up
  # would draw instead.
  defp back(
         %{
           return: %{moved_at: %DateTime{}, provider_server: id},
           provision: %{server: %{id: id} = server}
         } = facts
       ) do
    if standing?(server), do: running(facts) || ledger_problem(facts) || server_retired(facts)
  end

  defp back(_facts), do: nil

  defp server_retired(facts) do
    problem(
      "server_retired",
      sentence(:server_retired, facts),
      action(:delete_server, %{back: true}),
      %{"alternatives" => [action(:learn_more)]}
    )
  end

  defp started?(%{move_started_at: %DateTime{}} = record), do: not Map.has_key?(record, :moved_at)
  defp started?(_record), do: false

  # The move back of a second desktop the home went past: the link reached a
  # newer epoch than the one it was asked at.
  defp stale?(%{return: %{primary_epoch: asked} = record, link: %{primary: %{epoch: seen}}})
       when is_integer(seen) and seen > asked,
       do: not Map.has_key?(record, :moved_at)

  defp stale?(_facts), do: false

  # The server as silent as the fence asks (`Management.Provision`): no link,
  # forgotten, or no session for the limit.
  defp silent?(%{link: %{primary: nil}}), do: true
  defp silent?(%{link: %{primary: %{status: :revoked}}}), do: true

  defp silent?(%{link: %{primary: %{status: status} = link}})
       when status in [:unreachable, :stale],
       do: (Map.get(link, :down_ms) || 0) >= @unreachable_ms

  defp silent?(_facts), do: false

  defp server_move(facts), do: get_in(facts, [:primary_home, "move", "phase"])

  defp server_idle?(%{primary_home: %{"role" => "primary"}} = facts),
    do: server_move(facts) not in @server_moves

  defp server_idle?(_facts), do: false

  # -- the server ----------------------------------------------------------------

  defp server(facts) do
    disk = disk_problem(facts.disk, :server_disk_full)
    disk || server_backup(facts) || view("primary", sentence(:primary, facts), nil, %{})
  end

  defp server_backup(facts) do
    case newest_backup(facts.snapshots) do
      nil -> nil
      at -> old_backup(at, :server_backup_old, facts)
    end
  end

  # -- the server before its move ------------------------------------------------

  defp candidate(%{move: %{"phase" => "expired"}} = facts),
    do: problem("waited_too_long", sentence(:server_waited_too_long, facts), :learn_more, %{})

  defp candidate(%{move: %{"phase" => "failed"}} = facts),
    do: problem("not_set_up", sentence(:server_not_set_up, facts), :learn_more, %{})

  defp candidate(%{move: %{"phase" => phase}} = facts) when phase in @receiving,
    do: view("candidate", sentence(:candidate_receiving, facts), nil, %{})

  defp candidate(facts), do: view("candidate", sentence(:candidate_waiting, facts), nil, %{})

  # -- problems shared by more than one place ------------------------------------

  # `powered?`: whether Turn it on reaches this server.
  defp turned_off(server, key \\ :turned_off, powered? \\ true) do
    act = if powered?, do: :turn_on, else: :learn_more

    problem("turned_off", Copy.summary_sentence(key, %{}), act, %{
      "note" => Copy.summary_sentence(:turned_off_cost, %{}),
      "seen_at" => iso(server.seen_at)
    })
  end

  defp deleted(server, act, facts) do
    problem("deleted", sentence(:deleted, facts), act, %{
      "seen_at" => iso(server && server.seen_at)
    })
  end

  defp disk_problem(%{"used" => used, "nearly_full" => true}, key),
    do:
      problem(
        "disk_full",
        Copy.summary_sentence(key, %{percent: round(used * 100)}),
        :learn_more,
        %{}
      )

  defp disk_problem(_disk, _key), do: nil

  defp old_backup(at, key, facts) do
    age = DateTime.diff(facts.now, at, :second)

    if age > @backup_old_s,
      do:
        problem("backup_old", sentence(key, facts, %{days: div(age, @day_s)}), :back_up_now, %{
          "seen_at" => iso(at)
        })
  end

  # -- facts, read ---------------------------------------------------------------

  defp window(%{link: link}), do: Map.get(link, :enrollment)

  defp held(facts, id), do: Enum.find(facts.candidates, &(&1["candidate_id"] == id))
  defp newest(candidates), do: Enum.max_by(candidates, & &1["enrolled_at"])

  defp standing?(%{status: status}), do: status != :gone
  defp standing?(nil), do: false

  defp newest_backup(%{"targets" => targets}) do
    targets
    |> Enum.flat_map(&List.wrap(get_in(&1, ["last_verified", "at"])))
    |> Enum.map(&time/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp newest_backup(_snapshots), do: nil

  defp backups(%{"targets" => targets}) do
    for %{"label" => label, "last_verified" => %{"at" => at}} <- targets,
        do: %{"place" => label, "at" => at}
  end

  defp backups(_snapshots), do: []

  defp time(text) do
    {:ok, at, 0} = DateTime.from_iso8601(text)
    at
  end

  # -- the summary's shape -------------------------------------------------------

  defp view(state, sentence, action, detail) when state in @states,
    do: %{"state" => state, "sentence" => sentence, "action" => action, "detail" => detail}

  defp problem(kind, sentence, %{"id" => _id} = act, extra) when kind in @problems do
    detail =
      Map.merge(%{"kind" => kind, "note" => nil, "seen_at" => nil, "alternatives" => []}, extra)

    view("problem", sentence, act, detail)
  end

  defp problem(kind, sentence, act, extra) when is_atom(act),
    do: problem(kind, sentence, action(act), extra)

  # An action as a view names it: its id, its label, and the values its
  # record is finished from (`record/2`).
  defp action(id, values \\ %{}) when is_atom(id) do
    true = Atom.to_string(id) in @actions
    %{"id" => Atom.to_string(id), "label" => Copy.summary_label(id, values), values: values}
  end

  defp sentence(key, facts, values \\ %{}),
    do: Copy.summary_sentence(key, Map.merge(words(facts), values))

  # What every sentence may name: this computer, and the provider's own words.
  defp words(facts) do
    display = facts.provider.display()

    %{
      machine: machine(facts.host_os),
      provider: display.name,
      token_label: display.token_label
    }
  end

  defp machine(:macos), do: "Mac"
  defp machine(:linux), do: "computer"

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # -- finishing the screen ------------------------------------------------------

  # Every action a record, then what Details draws, the notice, the outcome
  # and the key.
  defp finish(view, facts) do
    summary =
      view
      |> Map.update!("action", &(&1 && record(&1, facts)))
      |> Map.update!("detail", &finish_detail(&1, view, facts))
      |> Map.put("notice", notice(view, facts))
      |> Map.put("outcome", outcome(view, facts))

    Map.put(summary, "key", key(summary))
  end

  defp finish_detail(detail, view, facts) do
    detail
    |> records_at("alternatives", facts)
    |> records_at("actions", facts)
    |> put_some("lines", lines(view, facts))
    |> put_some("providers", providers(view, facts))
    |> put_some("progress", progress(view, facts))
  end

  defp records_at(detail, field, facts) do
    case Map.fetch(detail, field) do
      {:ok, actions} -> Map.put(detail, field, Enum.map(actions, &record(&1, facts)))
      :error -> detail
    end
  end

  defp put_some(detail, _field, empty) when empty in [nil, []], do: detail
  defp put_some(detail, field, value), do: Map.put(detail, field, value)

  defp record(%{"id" => id, "label" => label, values: values}, facts) do
    act = String.to_existing_atom(id)
    needs = needs(act, facts)
    confirm = confirm(act, values, facts)

    %{
      "id" => id,
      "label" => label,
      "needs" => needs,
      "confirm" => confirm,
      "url" => url(act, facts),
      "key" => action_key(id, label, confirm, needs, target_of(act, values, facts))
    }
  end

  defp needs(:paste_token, _facts), do: ["token"]
  defp needs(:restore_here, _facts), do: ["recovery_passphrase"]
  defp needs(act, _facts) when act in [:create_server, :replace_server], do: ["choice"]
  defp needs(act, facts) when act in [:move_now, :try_again], do: [passphrase_need(facts)]
  defp needs(:start_again, facts), do: again_need(facts.provision)
  defp needs(_act, _facts), do: []

  # Start again creates the server of the size and place the ledger keeps
  # (the server's, else the failure's); with neither, the owner chooses.
  defp again_need(%{server: %{type: type, location: location}})
       when is_binary(type) and is_binary(location),
       do: []

  defp again_need(%{failure: %{type: type, location: location}})
       when is_binary(type) and is_binary(location),
       do: []

  defp again_need(_provision), do: ["choice"]

  # A replace's move checks the server's own key, which every move to it set;
  # here, the key this home's snapshots keep, or a new one when none is set.
  defp passphrase_need(%{role: :device}), do: "recovery_passphrase"
  defp passphrase_need(%{snapshots: %{"recipient_set" => true}}), do: "recovery_passphrase"
  defp passphrase_need(_facts), do: "new_recovery_passphrase"

  # What the owner accepts first: whatever spends money, deletes, restarts a
  # server or moves.
  defp confirm(:create_server, _values, facts), do: sentence(:confirm_create, facts)

  defp confirm(:create_in, %{city: city}, facts),
    do: sentence(:confirm_create_in, facts, %{city: city})

  defp confirm(:start_again, _values, facts), do: sentence(:confirm_start_again, facts)
  defp confirm(:replace_server, _values, facts), do: sentence(:confirm_replace, facts)
  defp confirm(:restart_server, _values, facts), do: sentence(:confirm_restart, facts)
  defp confirm(:delete_server, %{back: true}, facts), do: sentence(:confirm_delete_back, facts)
  defp confirm(:delete_server, values, facts), do: sentence(:confirm_delete, facts, values)
  defp confirm(:restore_here, _values, facts), do: sentence(:confirm_restore_here, facts)
  defp confirm(:cancel, %{code: true}, _facts), do: nil
  defp confirm(:cancel, %{return: true}, _facts), do: nil

  defp confirm(:cancel, _values, %{provision: %{replace: %{}}} = facts),
    do: sentence(:confirm_cancel, facts, %{which: "new"})

  defp confirm(:cancel, _values, facts), do: sentence(:confirm_cancel, facts)
  defp confirm(act, _values, facts) when act in [:move_now, :try_again], do: move_confirm(facts)
  defp confirm(_act, _values, _facts), do: nil

  # During a replace the review is the old server's own, so the confirm
  # says what every such move does; otherwise each warning this home's
  # settings give, after any other the last review of the same server gave.
  defp move_confirm(%{role: :device, returning: %{"kind" => "return"}} = facts),
    do: sentence(:confirm_return_move, facts, %{stays_here: facts.stays_here})

  defp move_confirm(%{role: :device} = facts), do: sentence(:confirm_replace_move, facts)

  defp move_confirm(facts) do
    own = Enum.map(facts.move_items, & &1.id)
    target_id = target(facts)["candidate_id"]

    reviewed =
      for %{"status" => "warn", "id" => id, "sentence" => said} <-
            review_items(facts.review, target_id),
          id not in own,
          do: said

    Copy.move_confirm(
      reviewed ++ for(%{status: :warn} = item <- facts.move_items, do: item.sentence)
    )
  end

  defp url(:learn_more, facts), do: Copy.always_on_docs_url(facts.provider.display().docs_anchor)
  defp url(:open_console, facts), do: facts.provider.display().console_url
  defp url(_act, _facts), do: nil

  defp target_of(act, _values, facts) when act in [:move_now, :try_again, :check_again],
    do: candidate_id(target(facts))

  defp target_of(:delete_server, %{which: "old"}, facts),
    do: server_id(get_in(facts, [:provision, :replace, :old]))

  defp target_of(act, _values, facts)
       when act in [:turn_on, :restart_server, :delete_server, :start_again, :cancel],
       do: server_id(facts.provision.server)

  defp target_of(:paste_token, _values, facts), do: facts.provider.id()
  defp target_of(:restore_here, %{copy: name}, _facts), do: name
  defp target_of(:create_in, %{next: next}, _facts), do: next
  defp target_of(_act, _values, _facts), do: nil

  defp candidate_id(%{"candidate_id" => id}), do: id
  defp candidate_id(nil), do: nil

  defp server_id(%{id: id}), do: id
  defp server_id(nil), do: nil

  # Every provider's token screen, wherever a token is asked for.
  defp providers(view, facts) do
    if Enum.any?(offered(view), &(&1["id"] == "paste_token")),
      do: Enum.map(facts.providers, &provider_screen/1),
      else: []
  end

  defp provider_screen(provider) do
    display = provider.display()

    %{
      "id" => provider.id(),
      "name" => display.name,
      "token_label" => display.token_label,
      "sentence" => Copy.summary_sentence(:connect, %{token_label: display.token_label}),
      "steps" => display.steps,
      "console_url" => display.console_url,
      "docs_url" => Copy.always_on_docs_url(display.docs_anchor)
    }
  end

  # -- Details' lines --------------------------------------------------------------

  # The states whose Details name a server: from the facts the state's
  # detail holds, else the server Fermix created, then when the provider was
  # last read back and what the servers cost.
  defp lines(view, facts) do
    ctx = %{zone: facts.zone, machine: machine(facts.host_os)}

    state_lines(view, facts, ctx) ++
      restore_lines(view, facts, ctx) ++ again_lines(view, facts, ctx)
  end

  defp state_lines(%{"state" => state, "detail" => detail}, facts, ctx)
       when state in @detailed_states do
    Enum.concat([
      server_lines(detail["server"] || created_facts(facts), ctx),
      time_line(:waits_until, detail["waits_until"], ctx),
      backup_lines(detail["backups"], ctx),
      value_line(:copies, detail["copies_bytes"], ctx),
      value_line(:disk, detail["disk_used"], ctx),
      checked_line(facts, ctx),
      cost_line(:costs, facts.provision.server, ctx),
      cost_line(:old_costs, get_in(facts, [:provision, :replace, :old]), ctx)
    ])
  end

  defp state_lines(_view, _facts, _ctx), do: []

  # Where Restore here is offered: the date of the copy it restores, and when
  # the server was last seen (design §8).
  defp restore_lines(view, facts, ctx) do
    case Enum.find(offered(view), &(&1["id"] == "restore_here")) do
      %{values: %{at: at}} -> [Copy.summary_line(:backup_here, at, ctx) | seen_line(facts, ctx)]
      nil -> []
    end
  end

  defp seen_line(%{provision: %{server: %{seen_at: %DateTime{} = at}}}, ctx),
    do: [Copy.summary_line(:seen, at, ctx)]

  defp seen_line(_facts, _ctx), do: []

  # A move back's ready: what this computer's settings turn on that runs
  # here again.
  defp again_lines(%{"state" => "ready"}, %{role: :device, returning: %{}} = facts, ctx) do
    case facts.stays_here do
      [] -> []
      features -> [Copy.summary_line(:runs_again, features, ctx)]
    end
  end

  defp again_lines(_view, _facts, _ctx), do: []

  @server_lines [
    server: "name",
    size: "type",
    place: "location",
    address: "ipv4",
    system: "system",
    version: "version"
  ]

  defp server_lines(nil, _ctx), do: []

  defp server_lines(server, ctx) do
    for {key, field} <- @server_lines,
        is_binary(server[field]),
        do: Copy.summary_line(key, server[field], ctx)
  end

  # The server Fermix created, while it stands and no state names another.
  defp created_facts(%{provision: %{server: %{status: status} = server}} = facts)
       when status != :gone do
    %{
      "name" => server.name,
      "type" => facts.provider.type_name(server.type),
      "location" => Provision.city(facts.provider, server.location),
      "ipv4" => server.ipv4
    }
  end

  defp created_facts(_facts), do: nil

  defp time_line(key, text, ctx) when is_binary(text),
    do: [Copy.summary_line(key, time(text), ctx)]

  defp time_line(_key, _text, _ctx), do: []

  defp backup_lines(nil, _ctx), do: []

  defp backup_lines(backups, ctx),
    do:
      for(
        %{"place" => place, "at" => at} <- backups,
        do: Copy.summary_line(:backup, {place, time(at)}, ctx)
      )

  defp value_line(_key, nil, _ctx), do: []
  defp value_line(key, value, ctx), do: [Copy.summary_line(key, value, ctx)]

  defp checked_line(%{provision: %{checked_at: %DateTime{} = at, server: server}}, ctx) do
    if standing?(server), do: [Copy.summary_line(:checked, at, ctx)], else: []
  end

  defp checked_line(_facts, _ctx), do: []

  defp cost_line(key, %{status: status, total_monthly: total, currency: currency}, ctx)
       when status != :gone and is_binary(total) and is_binary(currency),
       do: [Copy.summary_line(key, {total, currency}, ctx)]

  defp cost_line(_key, _server, _ctx), do: []

  # -- the outcome -----------------------------------------------------------------

  # A move under way runs whatever the screen still shows (one asked for
  # here reads `ready` until the restart); a code for a server of the owner's
  # own waits for that server.
  defp outcome(%{"state" => "problem"}, _facts), do: "failed"
  defp outcome(%{"state" => state}, _facts) when state in ["creating", "moving"], do: "running"
  defp outcome(%{"state" => "candidate"}, facts), do: receiving(facts)

  defp outcome(view, facts) do
    cond do
      moving?(facts) ->
        "running"

      view["state"] == "connect" and match?(%{kind: :manual, state: :open}, window(facts)) ->
        "waiting"

      true ->
        "done"
    end
  end

  defp receiving(%{move: %{"phase" => phase}}) when phase in @receiving, do: "running"
  defp receiving(_facts), do: "done"

  # -- the notice ------------------------------------------------------------------

  # The occurrence the state stands for, newest kind first; nil when none.
  defp notice(view, facts) do
    case occurrence(view, facts) do
      {id, said} -> %{"id" => id, "sentence" => said}
      nil -> nil
    end
  end

  defp occurrence(_view, %{role: :primary, link: %{desktops: [_ | _]}} = facts),
    do: week_occurrence(facts, :notice_server_backup_week)

  defp occurrence(view, %{role: role} = facts) when role in [:primary, :device] do
    Enum.find_value(
      [
        &reach_occurrence/2,
        &set_up_occurrence/2,
        &ready_occurrence/2,
        fn _view, facts -> week_occurrence(facts, :notice_backup_week) end,
        &moved_occurrence/2,
        &back_occurrence/2
      ],
      & &1.(view, facts)
    )
  end

  defp occurrence(_view, _facts), do: nil

  defp reach_occurrence(%{"detail" => %{"kind" => "cannot_reach"}} = view, facts) do
    case get_in(facts, [:link, :primary, :down_at]) do
      %DateTime{} = at -> {"cannot_reach:" <> iso(at), view["sentence"]}
      nil -> nil
    end
  end

  defp reach_occurrence(_view, _facts), do: nil

  defp set_up_occurrence(%{"detail" => %{"kind" => kind}} = view, facts)
       when kind in ["not_set_up", "waited_too_long"] do
    case facts.provision.server do
      %{created_at: %DateTime{} = at} -> {"not_set_up:" <> iso(at), view["sentence"]}
      _none -> nil
    end
  end

  defp set_up_occurrence(_view, _facts), do: nil

  defp ready_occurrence(%{"state" => "ready"}, facts),
    do: {"ready:" <> target(facts)["candidate_id"], sentence(ready_notice(facts), facts)}

  defp ready_occurrence(_view, _facts), do: nil

  defp ready_notice(%{role: :device, returning: %{"kind" => "return"}}), do: :return_ready
  defp ready_notice(%{role: :device}), do: :replace_ready
  defp ready_notice(_facts), do: :notice_ready

  # Back on this computer from a server of the owner's own, which nothing
  # here can delete: told once, by the epoch this computer came back at.
  defp back_occurrence(
         _view,
         %{role: :primary, return: %{moved_at: %DateTime{}} = record} = facts
       ) do
    if not Map.has_key?(record, :provider_server),
      do: {"back:#{record.epoch}", sentence(:notice_back, facts)}
  end

  defp back_occurrence(_view, _facts), do: nil

  defp week_occurrence(facts, key) do
    if backup_week?(facts),
      do: {"backup_week:" <> iso(backup_since(facts)), sentence(key, facts)}
  end

  # The move is told until the first backup after it.
  defp moved_occurrence(%{"state" => "on"}, %{moved: %{epoch: epoch, moved_at: moved_at}} = facts) do
    newest = newest_backup(get_in(facts, [:primary_home, "snapshots"]))

    if newest == nil or DateTime.compare(newest, moved_at) != :gt,
      do: {"moved:#{epoch}", sentence(:notice_moved, facts)}
  end

  defp moved_occurrence(_view, _facts), do: nil

  # -- watching ------------------------------------------------------------------

  defp digest(term) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(term, [:deterministic]))
    |> binary_part(0, @key_bytes)
    |> Base.url_encode64(padding: false)
  end

  # What a desktop's own summary reads from its server's `home.status`
  # (`primary_home`); only a server with desktops has anyone to tell.
  defp drawn(%{role: :primary, link: %{desktops: [_ | _]} = link} = facts) do
    window = link.enrollment && Map.take(link.enrollment, [:kind, :state, :candidate_id])
    {newest_backup(facts.snapshots), window, Enum.map(facts.candidates, & &1["candidate_id"])}
  end

  defp drawn(_facts), do: nil

  # Whether the newest backup this place's summary counts from is a week old.
  defp backup_week?(facts) do
    case backup_since(facts) do
      %DateTime{} = at -> DateTime.diff(facts.now, at, :second) >= @backup_week_s
      nil -> false
    end
  end

  # When the backup this place's summary counts from was taken: on a desktop
  # its server's newest, else the move where none finished since; on a server
  # with desktops its own newest.
  defp backup_since(%{role: :device, primary_home: %{"snapshots" => snapshots}} = facts),
    do: newest_backup(snapshots) || get_in(facts, [:moved, :moved_at])

  defp backup_since(%{role: :primary, link: %{desktops: [_ | _]}} = facts),
    do: newest_backup(facts.snapshots)

  defp backup_since(_facts), do: nil

  # The soonest time rule of this place's summary that has not come yet.
  defp next_change(facts) do
    facts
    |> deadlines()
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> Enum.min(fn -> nil end)
  end

  defp deadlines(%{role: :candidate}), do: []

  defp deadlines(%{role: :device} = facts) do
    since = backup_since(facts)

    [
      link_deadline(facts),
      backup_deadline(since, facts),
      week_deadline(since, facts),
      action_deadline(facts)
    ] ++ replace_deadlines(facts)
  end

  defp deadlines(%{role: :primary, link: %{desktops: [_ | _]}} = facts) do
    since = backup_since(facts)
    [backup_deadline(since, facts), week_deadline(since, facts)]
  end

  defp deadlines(%{role: :primary} = facts),
    do: [
      window_deadline(window(facts)),
      action_deadline(facts) | expiries(facts.candidates, facts)
    ]

  # A created server's code, open while this computer is awake (`not_set_up`).
  defp window_deadline(%{kind: :provisioned, state: :open} = window),
    do: @setup_ms - Map.get(window, :awake_ms, 0)

  defp window_deadline(_window), do: nil

  # A step's action is read as interrupted once its job's budget is out.
  defp action_deadline(%{provision: %{action: %{started_at: at}}} = facts),
    do: ms_until(DateTime.add(at, Ledger.action_budget_ms(), :millisecond), facts)

  defp action_deadline(_facts), do: nil

  # A held server is dropped at its expiry (`Home.Candidates`).
  defp expiries(candidates, facts),
    do: for(%{"expires_at" => at} <- candidates, do: ms_until(time(at), facts))

  # No session with the server, counted while this computer is awake.
  defp link_deadline(%{link: %{primary: %{status: status} = link}})
       when status in [:unreachable, :stale],
       do: @unreachable_ms - (Map.get(link, :down_ms) || 0)

  defp link_deadline(_facts), do: nil

  # A backup is old once it is more than three days old, in whole seconds.
  defp backup_deadline(%DateTime{} = at, facts),
    do: ms_until(DateTime.add(at, @backup_old_s + 1, :second), facts)

  defp backup_deadline(nil, _facts), do: nil

  # A backup is a week old once seven days have passed (`backup_week?/1`).
  defp week_deadline(%DateTime{} = at, facts),
    do: ms_until(DateTime.add(at, @backup_week_s, :second), facts)

  defp week_deadline(nil, _facts), do: nil

  # During a replace: the new server's 30 minutes from its creation while its
  # code is open on the old server, and the day each server the old one holds
  # waits.
  defp replace_deadlines(%{provision: %{replace: %{state: :waiting}} = provision} = facts) do
    held = get_in(facts, [:primary_home, "candidates"]) || []
    [new_server_deadline(new_window(facts), provision.server, facts) | expiries(held, facts)]
  end

  defp replace_deadlines(_facts), do: []

  defp new_server_deadline(%{"state" => "open"}, %{created_at: %DateTime{} = at}, facts),
    do: ms_until(DateTime.add(at, @setup_ms, :millisecond), facts)

  defp new_server_deadline(_window, _server, _facts), do: nil

  defp ms_until(%DateTime{} = at, facts), do: DateTime.diff(at, facts.now, :millisecond)

  # -- gathering -----------------------------------------------------------------

  defp host_os do
    case :os.type() do
      {:unix, :darwin} -> :macos
      _other -> :linux
    end
  end

  # The last review of the move, whatever its age: on the computer that moves.
  # One that cannot be read is logged once while it stays so.
  defp review(home, :primary, reads) do
    read = Move.last_review(home)
    subject = "the last review of the move in #{Move.dir(home)}"
    :ok = UnreadableFiles.log_read(subject, "home status", read_result(read), memory(reads))

    case read do
      {:ok, review} -> review
      _none_or_unreadable -> nil
    end
  end

  defp review(_home, _role, _reads), do: nil

  defp read_result(:none), do: :ok
  defp read_result(:absent), do: :ok
  defp read_result(read), do: read

  defp memory(reads), do: Keyword.get(reads, :unreadable_files, UnreadableFiles)

  # What runs only on this computer: what stops after a move, which the
  # computer that sets it up says, and what runs here again after a move
  # back, which a desktop says.
  defp stays_here(home, role, host_os, reads) when role in [:primary, :device] do
    case MoveReadiness.stays_here(home, host_os == :macos, reads) do
      {:ok, features} -> features
      {:error, _sentence} -> []
    end
  end

  defp stays_here(_home, _role, _host_os, _reads), do: []

  # The review's items this home's settings decide, for the server a move
  # would go to, which Move now's confirm names: only the computer that sets
  # Always On up, while a server is held.
  defp move_items(home, :primary, host_os, {status, link}, opts) do
    case target(%{role: :primary, candidates: status.candidates, link: link}) do
      %{"name" => name} ->
        settings = MoveReadiness.settings(home, Keyword.take(opts, [:unreadable_files]))
        MoveReadiness.summary_items(settings, host_os == :macos, name, opts)

      nil ->
        []
    end
  end

  defp move_items(_home, _role, _host_os, _status_link, _opts), do: []

  # The space the server's backups take on this desktop (`Desktop.SnapshotStore`).
  defp copies_bytes(home, :device, reads) do
    home
    |> Capture.dir()
    |> Path.join("*.fxsnap")
    |> Path.wildcard()
    |> Enum.reduce(0, &(&2 + copy_bytes(&1, reads)))
  end

  defp copies_bytes(_home, _role, _reads), do: nil

  # The record of a move back, on any engine; one that cannot be read is
  # none, logged once while it stays so.
  defp return_record(home, reads) do
    read = Return.read(home)

    :ok =
      UnreadableFiles.log_read(Return.path(home), "home status", read_result(read), memory(reads))

    case read do
      {:ok, record} -> record
      _absent_or_unreadable -> nil
    end
  end

  # A desktop's candidate for a move back: its state, or `:unreadable` (a
  # stop that left the directory without one), logged once while it stays so.
  defp returning_state(home, :device, reads) do
    if Candidate.present?(home) do
      read = Candidate.read_state(home)
      file = Candidate.path(home, "state.json")
      :ok = UnreadableFiles.log_read(file, "home status", state_result(read), memory(reads))

      case read do
        {:ok, state} -> state
        {:error, _reason} -> :unreadable
      end
    end
  end

  defp returning_state(_home, _role, _reads), do: nil

  defp state_result({:ok, _state}), do: :ok
  defp state_result(error), do: error

  # The copies a desktop keeps of its server's snapshots, newest first, by
  # the time their names carry (`Snapshot.name/2`); a name that is no
  # copy's is not one.
  defp copies(home, :device) do
    home
    |> Capture.dir()
    |> Path.join("*.fxsnap")
    |> Path.wildcard()
    |> Enum.flat_map(&copy/1)
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
  end

  defp copies(_home, _role), do: []

  defp copy(path) do
    name = Path.basename(path)

    with [_all, stamp] <- Regex.run(~r/\A(\d{8}T\d{6}Z)-e\d{1,12}\.fxsnap\z/, name),
         {:ok, at} <- copy_time(stamp) do
      [%{name: name, at: at}]
    else
      _not_a_copy -> []
    end
  end

  defp copy_time(
         <<y::binary-4, mo::binary-2, d::binary-2, "T", h::binary-2, mi::binary-2, sec::binary-2,
           "Z">>
       ) do
    case DateTime.from_iso8601("#{y}-#{mo}-#{d}T#{h}:#{mi}:#{sec}Z") do
      {:ok, at, 0} -> {:ok, at}
      {:error, _reason} = error -> error
    end
  end

  # A copy the store rotated out between the listing and the read takes no
  # space; any other failure counts as none and is logged once while it
  # stays so.
  defp copy_bytes(file, reads) do
    stat = File.stat(file)
    read = if match?({:error, :enoent}, stat), do: :ok, else: stat
    :ok = UnreadableFiles.log_read(file, "home status", read, memory(reads))

    case stat do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _reason} -> 0
    end
  end
end
