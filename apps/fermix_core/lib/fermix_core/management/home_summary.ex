defmodule FermixCore.Management.HomeSummary do
  @moduledoc """
  `home.status.summary` (M75 lean v1 §7, Always On setup §3): where Always
  On stands, worked out once here so the Mac app, the Linux app, the setup
  page and the CLI draw the same screen.

      summary: {key, state, sentence, action, detail, notice, outcome}

  `summary/1` is pure: it reads the facts `gather/5` collects (the role, the
  move's phase, the candidates held, the enrollment window and the link as
  the rail says them (`Home.Link.status/0`), the last readiness review, the
  review's items this home's settings decide
  (`MoveReadiness.summary_items/4`), the snapshots, the disk, the owner's
  time zone, and on a linked desktop the server's own `home.status`). Its
  words are `Management.Copy`'s.

  The server is the owner's own: a Linux server they set up, where they run
  the command Use my own Linux server gives. Fermix creates, powers and
  deletes no server.

  `state` is one of `states/0`:

    * the computer that sets Always On up, before the move: `off`, `connect`
      (a code for the owner's server is open, waiting for it; a new code
      beside it ends this one, and its label says so), `creating` (the server
      used its code and connects, Cancel beside it, which closes the code;
      once the code's half hour is over with no server recorded, the screen
      is `off` again), `ready` (and a review that blocks), with Forget this
      server beside Move now, which drops the held server after a confirm,
      `undone` (a move was undone and its server is still held: Try again,
      and Forget this server beside it once the undoing is over);
    * the computer the move left: `moving` (its last word, once it waits on
      the server's confirmation, is that Fermix keeps trying), `undone` while
      it restarts as it was, `on`, `retired` (no link, or the server forgot
      this computer; a server's own copy that a move back left serving
      nothing names where Fermix moved back to, the marker's `to`);
    * the server: `candidate` while it waits for its move, `primary` after;
    * `problem`, with its `kind` (`problems/0`) in `detail` and the one action
      that fixes it, or Learn more where none does.

  Times count the way the design asks: a server that stopped answering is a
  problem after 10 minutes of no session while this computer is awake (the
  link's `down_ms`, a monotonic count). The last backup is old past 3 days.

  **Moving back** (Always On's move back, its design §7 to §9). A linked
  desktop's `on` offers Move back beside Back up now, where this engine
  starts again by itself (`restarts_itself`); one run from a terminal says
  in a Details line, in the move back's own refusal, why it is not offered
  (`Home.Candidate.error_sentence/1`'s `:not_supervised`). Once pressed, the
  desktop's own candidate for the home (`candidate/state.json`, `returning`)
  and the return's record (`device/return.json`, `return`) lead, ahead of
  everything else the desktop shows, its link gone included: `creating`
  while it connects to the server (Cancel), `ready` once it is held (Move
  now with the server's recovery passphrase and a confirm built here from
  this computer's own settings, Cancel beside it; and again once the start
  is recorded while the server answers as the primary with no move),
  `moving` from the recorded start (written before the request leaves)
  while the server moves or cannot answer, to this computer's restart as the
  primary, `undone` when the server undid it (Try again, Cancel), and
  `return_failed` when the candidate ended (Move back again) or stopped
  before any move with no record of it (Cancel). Cancel is never offered
  while the server's move is under way, once it retired, or once the home is
  coming in here. A move back the home went past (the link reached a newer
  epoch than the one it was asked at, without this computer's return) is not
  drawn. Where the server went silent (`cannot_reach`, `retired`) and this
  computer holds a copy of it, Restore here is offered, with the copy's
  date; its confirm asks the owner's word that the server is deleted or
  stopped, and Fermix deletes nothing. While its job runs (`restoring`, the
  job family's own record) beside the return's request for it
  (`restore_requested`), the screen is `moving`. Back on this computer as
  the primary after a move back, the server's retired copy is told once,
  `back:<epoch>`.

  **Every action is one record** wherever it sits (`action`,
  `detail.alternatives`, `on`'s `detail.actions`): `id`, `label`, `needs`
  (what the surface collects: `new_recovery_passphrase`, typed twice and
  compared, where this move's recovery key is not set yet, else
  `recovery_passphrase`, typed once and checked by the move), `confirm` (the
  sentence the owner accepts before Fermix moves or restores, with no time
  in it; nil otherwise), `url` (the docs page for Learn more, nil otherwise)
  and `key` (`action_key/5`). Move now's confirm is built here, before any
  review, from the review's items this home's settings decide and any other
  warning the last review of the same server gave (`s3_size`, `plugins`), so
  the full review at the press moves it, and its key, only when it found
  something the screen did not say.

  `detail` holds what the state draws: on `connect` a new code and Cancel,
  on `ready` the server's facts, the readiness warnings and blocks and until
  when it waits, on `on` the server, each backup, the space this computer's
  copies take, the disk, what lives on the server and the two actions
  Details offers (Back up now, Move back), and on `problem` its kind, what
  Fermix last saw and when, one note, and the other actions; wherever there
  are any, the Details `lines` (`Copy.summary_line/3`), and `progress` while
  a move back or a restore runs.

  **Inbound webhooks** (Always On, "Inbound webhooks without a public IP"):
  on a linked desktop's `on`, `detail.webhooks` holds the Tailscale Funnel
  mounts the owner runs on the server, `{sentence, mounts, notes}`: the
  sentence with the one-time tailnet steps (the `funnel` node attribute for
  `tag:fermix-server`, MagicDNS and HTTPS certificates, and that a new
  address takes minutes to resolve), each mount's `label`, `command`
  (`FermixCore.Funnel`'s, after `sudo`: the server's first boot names no
  Tailscale operator, so only root changes its serve config) and `note`
  (where the sender is pointed: Meta's Callback URL for WhatsApp, the host
  of a webhook source's address in its sender), WhatsApp's first, then each
  webhook source's, and the caveats (port 443 carries only these paths, the
  traffic enters through Tailscale's ingress, Cloudflare Tunnel to the same
  loopback ports without Tailscale). The values are the server's: the
  `webhooks` of its own `home.status` (`primary_home`), never this
  computer's settings. A webhook source's mount is its prefix,
  `/cues/hooks/<ref>` (`Cues.Webhook.prefix_path/1`), so the command carries
  none of its URL's secret, which `home.status`, a read, never hands out:
  Tailscale passes the rest of the path to the door, which answers only that
  source's own paths. No `webhooks` where the server serves none. The
  server's own `primary` draws none: its summary rides inside its desktops'
  `home.status`, where the mounts would pass the protocol's nesting bound.

  A linked desktop whose server refused its protocol as newer than its own
  (`daemon_too_old`: this computer updated first) is a `problem` of kind
  `server_older`, whose sentence says the server updates on its own once the
  app for each computer that keeps the home's backups carries the newer
  Fermix (M97 §3.4: the server leads, from the release channel); never a
  bare `on`.

  Where this computer stands against its server (`standing`,
  `Computers.Versions` of this engine's version and the server's
  `home.status` `version`): past the window (`settings_only`) it is the
  `update` problem in its own sentence (this computer keeps its link for
  settings alone). A server that installed a release ahead of the apps
  (its `update.ahead_of_apps`, an owner's override) whose home this
  computer cannot read (`readable`, `Home.Readable`: by the home format the
  server's `home.status` names, never by its version, M97 D16) is the
  problem `server_ahead`, with Update, until this computer's Fermix catches
  up. Where this computer cannot read the server's home, Move back and
  Restore here are not offered: in their place an Update action says
  "Update Fermix on this computer first". A newer server whose home format
  this computer reads keeps both. A server that says no version (one that
  is silent) is not compared; the restore itself refuses a home it cannot
  read.

  **Computers** (M97 §3.1, §7.5). A linked computer's `on` and the server's
  own `primary` offer Add a computer (`add_computer`, a code a new computer
  joins with). While a computer asks to join (the server's enrollment window
  `awaiting_approval`), that screen's sentence names it and its system and
  asks for the six digits it shows, its action is `approve_computer` (needs
  `sas`, the digits as the owner reads them on the new computer; its key
  binds the computer that asks) and `deny_computer` stands beside it. The
  digits prove the computer the owner looks at is the one asking, so no
  screen of the home shows them: they are read on the new computer and
  typed. On the computer that
  joins (`device/join.json`, `Home.Join`), the screen is `creating`, with
  Cancel, while it dials and while it waits for the owner (outcome `running`,
  then `waiting`, the sentence carrying the digits to type), and once it was
  not added, its sentence says why (outcome `failed`). Move back and Restore
  here are offered only where the home moved from this computer (its moved
  marker): a computer that joined has neither.

  `notice` is the occurrence the apps raise as a system notification, or
  nil: the server ready (`ready:<candidate>`), the move done
  (`moved:<epoch>`, until the first backup after it), the server out of
  reach (`cannot_reach:<since>`), the newest backup a week old
  (`backup_week:<at>`), Fermix back on this computer after a move back
  (`back:<epoch>`), Restore here finished, naming the day of the backup it
  restored (`restored:<epoch>`), a computer that joined the home
  (`computer_joined:<device id>`, while the window names it), and a held
  server whose 24 hours ran out,
  which must be set up again with a new code (`server_lapsed:<candidate>`,
  on the screen it leaves, while the code that enrolled it still names it;
  never a desktop's candidate for a move back).
  An app posts when the id changes.

  `outcome` is what a surface that follows a step reads (review R6), so none
  keeps its own table of states: `running` while Always On is at something
  that moves this screen on by itself (the server connecting; the move, from
  its request here until the restart shows; a server receiving its home; a
  restore; a backup, where Back up now is offered, while it runs there, with
  `progress` saying so), `waiting` while it waits on the owner's server to
  use its code, `failed` on a problem, `done` when the next step is the
  owner's. A backup that failed is the problem `backup_failed` (on a linked
  desktop, and on a server with desktops), in the newest failed try's own
  words, where it went and when, with Back up now, until a backup there is
  stored; so the end of a backup says whether it was.

  `key/1` is the one digest of the summary (`summary.key`, and what
  `FermixCore.Home.StatusWatch` tells by, `watch/1`): every change a surface
  draws moves it, and the clock alone (what was last seen, an age in a
  sentence) never does.
  """

  alias FermixCore.Clock
  alias FermixCore.Computers.Consent
  alias FermixCore.Computers.Switches
  alias FermixCore.Computers.Versions
  alias FermixCore.Cues.Webhook
  alias FermixCore.Funnel
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Candidates
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Join
  alias FermixCore.Home.Move
  alias FermixCore.Home.MoveReadiness
  alias FermixCore.Home.Readable
  alias FermixCore.Home.Return
  alias FermixCore.Home.ServerSandbox
  alias FermixCore.Home.Snapshot.Capture
  alias FermixCore.Home.UnreadableFiles
  alias FermixCore.Management.Copy
  alias FermixCore.Management.Lifecycle
  alias FermixCore.Setup.ConfigStore

  @states ~w(off connect creating ready moving on undone retired candidate primary problem)
  @outcomes ~w(running waiting done failed)
  @problems ~w(cannot_reach not_set_up waited_too_long update server_older server_ahead
               disk_full backup_old backup_failed not_ready return_failed)
  @actions ~w(cancel move_now try_again learn_more update back_up_now check_again own_server
              move_back restore_here review_offers add_computer approve_computer deny_computer)
  @needs ~w(recovery_passphrase new_recovery_passphrase sas)

  @unreachable_ms 10 * 60_000
  @backup_old_s 3 * 86_400
  @day_s 86_400
  # The apps raise their notification once the newest backup is this old.
  @backup_week_s 7 * @day_s
  # A server tells that it left out its inherited settings this long after.
  @server_sandbox_s 7 * @day_s
  # The states whose sentence `key/1` leaves out: on `on` and `problem` it
  # carries a figure that moves with the clock (a backup's age, a count of
  # days, how full a disk is), and their state, action and kind say every
  # change of note; on `off` an app forgets Always On (the owner's rule), so
  # the line naming what stops is read when its pane opens, never told.
  @untold_sentences ~w(off on problem)
  # The problems whose sentence `key/1` tells: a failed backup's names its
  # try's own time and words, which no clock moves, and a later try that
  # fails in other words is a change to draw.
  @told_problems ~w(backup_failed)
  @moving ~w(requested streaming committed)
  @undoing ~w(aborting undoing)
  # A move under way, from its request to its undoing: the screen runs.
  @in_flight @moving ++ ["committing" | @undoing]
  @receiving ~w(receiving staged activating)
  # A move back's candidate that ended (`FermixCore.Home.Candidate`), and
  # one before any move reached it.
  @ended ~w(failed expired)
  @before_move ~w(enrolling enrolled)
  # A move the server reports under way, from its request to its undoing.
  @server_moves ~w(requested streaming committing aborting committed undoing)
  # The states whose Details have lines.
  @detailed_states ~w(ready on problem)
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
          required(:review) => map() | nil,
          required(:move_items) => [MoveReadiness.item()],
          required(:snapshots) => map(),
          required(:disk) => map() | nil,
          required(:primary_home) => map() | nil,
          required(:primary_too_old) => boolean(),
          required(:copies_bytes) => non_neg_integer() | nil,
          required(:stays_here) => [:voice | :meetings | :accessories],
          required(:return_costs) => [:coding_agents | :telegram],
          required(:zone) => String.t(),
          required(:return) => map() | nil,
          required(:returning) => map() | :unreadable | nil,
          required(:restoring) => boolean(),
          required(:copies) => [%{name: String.t(), at: DateTime.t()}],
          required(:lapsed) => String.t() | nil,
          required(:moved_back) => boolean(),
          required(:primary_behind) => boolean(),
          required(:restarts_itself) => boolean() | nil,
          optional(:standing) => FermixCore.Computers.Versions.standing() | nil,
          optional(:readable) => :ok | {:error, term()} | nil
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

  @doc "Every word an action's `needs` lists."
  @spec needs() :: [String.t()]
  def needs, do: @needs

  @doc "The summary for `facts` (`gather/5`'s)."
  @spec summary(facts()) :: summary()
  def summary(facts) when is_map(facts), do: facts |> screen() |> finish(facts)

  defp screen(%{role: :candidate} = facts), do: candidate(facts)
  defp screen(%{role: :device} = facts), do: device(facts)
  defp screen(%{role: :primary} = facts), do: here(facts)

  defp here(%{link: %{desktops: [_ | _]}} = facts), do: server(facts)
  defp here(facts), do: setup(facts)

  @doc """
  The one digest of `summary`, `summary.key`: of everything it holds but
  the key itself, the sentence of an `off`, `on` or `problem` (whose figures
  move with the clock) and what was last seen (`detail.seen_at`). A change
  of the state, the sentence of a step, an action, a confirm, an
  alternative, a line, the progress or the notice moves it.
  """
  @spec key(summary()) :: String.t()
  def key(%{"state" => state, "detail" => detail} = summary) when is_map(detail) do
    sentence = if untold?(state, detail), do: nil, else: summary["sentence"]

    summary
    |> Map.drop(["key", "sentence"])
    |> Map.put("detail", Map.delete(detail, "seen_at"))
    |> Map.put("told", sentence)
    |> digest()
  end

  defp untold?("problem", %{"kind" => kind}) when kind in @told_problems, do: false
  defp untold?(state, _detail), do: state in @untold_sentences

  @doc """
  An action's `key`: the digest of its `id`, `label`, `confirm`, `needs` and
  `target`, the one thing it acts on: the server a move goes to
  (`move_now`, `try_again`, `check_again`), the server Forget this server
  drops (`cancel` on a held server), the copy a restore takes
  (`restore_here`), the computer that asks to join (`approve_computer`, its
  name and system, never its digits), or nil.
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
  sets Always On up, the one its code enrolled, else the newest held; on a
  linked desktop moving back, its own candidate once the server holds it
  (`returning`'s `candidate_id`); nil when there is none. Reads `facts`'
  `role`, `candidates`, `link` and `returning`.
  """
  @spec target(map()) :: map() | nil
  def target(%{role: :device, returning: %{"kind" => "return", "candidate_id" => id} = state})
      when is_binary(id),
      do: %{"candidate_id" => id, "name" => get_in(state, ["primary", "name"])}

  def target(%{role: :device}), do: nil

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
      their summaries read from its `home.status` (its newest backup), which
      its own summary does not show.
    * `off`: whether the summary is `off` with no notice to raise. An `off`
      that carries one (Fermix back on this computer from a server of the
      owner's own) is told as any other summary, or an engine that took the
      home back would never tell the apps.
    * `next_change_ms`: the milliseconds until the summary next changes by
      the clock alone (a link down 10 minutes awake, a held server's 24
      hours, a backup's 3 days and its 7), or nil when nothing does; always nil while
      off. A deadline may change nothing when it comes (another rule decided
      first): the watch then reads a same key and tells nobody.
  """
  @spec watch(facts()) :: %{key: term(), off: boolean(), next_change_ms: pos_integer() | nil}
  def watch(facts) when is_map(facts) do
    summary = summary(facts)
    off = summary["state"] == "off" and summary["notice"] == nil
    next = if off, do: nil, else: next_change(facts)
    %{key: {summary["key"], drawn(facts)}, off: off, next_change_ms: next}
  end

  @doc """
  The facts of `home`'s summary: `status` is the `home.status` record's own
  facts (`Management.Home.status/1` has gathered them, with
  `primary_too_old`, `primary_behind` and `restoring`), `link` the rail's
  status, and `opts`
  the seams `:now`, `:host_os`, `:personalization` (the owner's time zone,
  `FermixCore.Clock`'s seam) and `:unreadable_files`
  (`Home.UnreadableFiles`, or nil for a verb with no engine tree);
  `MoveReadiness.summary_items/4` is given `opts` as they are. Reads the
  last readiness review, what this home's
  settings turn on that runs only on this computer (on the primary, what
  stops after a move; on a desktop, what runs here again after a move back,
  and what of a move back's costs they turn on, `MoveReadiness.costs/1`),
  on the primary the review's items they decide, the record of a move back
  (`Home.Return`), and, on a desktop, its candidate for a move back
  (`Home.Candidate`'s state) and its stored copies, newest first, by the
  time and epoch their names carry. On the computer that sets Always On up,
  the held server whose 24 hours ran out (`Home.Candidates.lapsed/2`) that
  the window still names, unless it enrolled before the home last came back
  here (a return's `moved_at`: the server it moved to and back from) or is
  a desktop's candidate for a move back (`returning`) (`lapsed`); on a
  desktop, whether its own move left it serving nothing (`moved_back`: a
  server's copy after a move back, its move's `keep_as_desktop`; a move's
  record that cannot be read is logged once while it stays so), and whether
  this engine starts again by itself (`restarts_itself`, a move back's need;
  on a desktop only, `opts`' `:restarts_itself` in place of
  `Lifecycle.restarts_itself?/0`).
  """
  @spec gather(Path.t(), map(), map(), map(), keyword()) :: facts()
  def gather(home, %{role: role} = record, link, status, opts)
      when is_binary(home) and is_map(link) and is_map(status) and is_list(opts) do
    host_os = Keyword.get_lazy(opts, :host_os, &host_os/0)
    reads = Keyword.take(opts, [:unreadable_files])
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    return = return_record(home, reads)

    %{
      role: role,
      host_os: host_os,
      now: now,
      linked: DesktopLink.linked?(record, home),
      moved: status.moved,
      move: status.move,
      link: link,
      candidates: status.candidates,
      review: review(home, role, reads),
      move_items: move_items(home, role, host_os, {status, link}, opts),
      snapshots: status.snapshots,
      disk: status.disk,
      primary_home: status.primary_home,
      primary_too_old: Map.get(status, :primary_too_old, false),
      copies_bytes: copies_bytes(home, role, reads),
      stays_here: stays_here(home, role, host_os, reads),
      return_costs: return_costs(home, role, reads),
      zone: Clock.shown_zone(Keyword.take(opts, [:personalization])),
      return: return,
      returning: returning_state(home, role, reads),
      restoring: Map.get(status, :restoring, false),
      copies: copies(home, role),
      lapsed: lapsed(home, role, {link, return}, now, reads),
      moved_back: moved_back(home, role, reads),
      primary_behind: Map.get(status, :primary_behind, false),
      standing: server_compared(status, &Versions.standing/2),
      readable: server_readable(status),
      restarts_itself: restarts_itself(role, opts),
      keeps_on: keeps_on(home, {role, link}, host_os, opts),
      offers_review: offers_review(DesktopLink.linked?(record, home), host_os, opts),
      join: if(role == :device, do: Join.view(home)),
      screen: Map.get(status, :screen),
      server_sandbox: server_sandbox(home, role, reads)
    }
  end

  # -- the computer that sets Always On up ---------------------------------------

  defp setup(facts), do: undone(facts) || own_server(facts) || off(facts)

  # A move undone while its server is still held: Try again, or Forget this
  # server once the undoing is over.
  defp undone(%{move: %{"phase" => phase}} = facts) when phase in ["aborted", "undoing"] do
    if target(facts),
      do:
        view("undone", sentence(:undone, facts), action(:try_again), %{
          "alternatives" => forget(facts)
        })
  end

  defp undone(_facts), do: nil

  # The owner's server (`home.enroll.open`): its code open, used, or the
  # server held.
  defp own_server(facts) do
    case {target(facts), window(facts)} do
      {%{} = candidate, _window} ->
        ready(candidate, facts)

      {nil, %{state: :open}} ->
        connect(facts)

      {nil, %{state: :used, candidate_id: nil}} ->
        view("creating", Copy.summary_sentence(:connecting, %{}), nil, %{
          "alternatives" => [action(:cancel, %{code: true})]
        })

      _nothing ->
        nil
    end
  end

  defp off(facts) do
    view("off", sentence(:off, facts, %{stays_here: facts.stays_here}), action(:own_server), %{})
  end

  # While the code for the owner's server is open: a new code, which ends
  # this one (its label says so), or Cancel, which closes it.
  defp connect(facts) do
    view("connect", sentence(:connect, facts), nil, %{
      "alternatives" => [action(:own_server, %{renew: true}), action(:cancel, %{code: true})]
    })
  end

  # The server is held and waits for Move now, unless the last review blocks;
  # either way it can be forgotten, except while a move to it runs.
  defp ready(candidate, facts) do
    items = review_items(facts.review, candidate["candidate_id"])

    case for(%{"status" => "block", "sentence" => block} <- items, do: block) do
      [block | _more] ->
        problem("not_ready", Copy.summary_sentence(:not_ready, %{block: block}), :check_again, %{
          "readiness" => items,
          "alternatives" => forget(facts)
        })

      [] ->
        view(
          "ready",
          sentence(:ready, facts),
          action(:move_now),
          %{
            "server" => server_facts(candidate),
            "readiness" => items,
            "waits_until" => candidate["expires_at"],
            "alternatives" => forget(facts)
          }
          |> put_some("keeps_on", Map.get(facts, :keeps_on))
        )
    end
  end

  defp forget(facts), do: if(moving?(facts), do: [], else: [action(:cancel, %{forget: true})])

  # The warnings and blocks of the last review of this server; nothing when
  # all is well or none was made.
  defp review_items(%{candidate_id: id, items: items}, id),
    do: Enum.filter(items, &(&1["status"] in ["warn", "block"]))

  defp review_items(_review, _candidate_id), do: []

  defp server_facts(candidate) do
    %{
      "name" => candidate["name"],
      "system" => "#{candidate["os"]} #{candidate["arch"]}",
      "version" => candidate["version"]
    }
  end

  defp moving?(%{move: %{"phase" => phase}}), do: phase in @in_flight
  defp moving?(_facts), do: false

  # The step in hand: a move back's or a restore's, from what this
  # computer's candidate wrote so far, else Restore here's job.
  defp progress(%{"state" => "moving"}, %{role: :device} = facts) do
    case return_progress(facts) do
      nil -> nil
      key -> sentence(key, facts)
    end
  end

  defp progress(view, facts) do
    if backing_up?(view, facts), do: sentence(:progress_backing_up, facts)
  end

  defp return_progress(%{returning: %{"kind" => kind, "phase" => phase}})
       when phase in @receiving,
       do: return_step(kind, phase)

  defp return_progress(%{returning: nil} = facts) do
    if restore_running?(facts), do: :progress_restoring, else: return_placing(facts)
  end

  defp return_progress(_facts), do: nil

  defp return_placing(%{return: %{move_started_at: %DateTime{}}}), do: :progress_return_placing
  defp return_placing(_facts), do: nil

  defp return_step(_kind, "activating"), do: :progress_return_placing
  defp return_step("local", _phase), do: :progress_restoring
  defp return_step("return", "receiving"), do: :progress_return_receiving
  defp return_step("return", "staged"), do: :progress_return_staged

  # -- the computer the move left ------------------------------------------------

  # A move back leads, whatever the link says (its activation ends the
  # tenure's link); then Restore here's job, before its candidate is
  # written; then the computer's own move.
  defp device(facts),
    do: joining(facts) || returning(facts) || restoring(facts) || asking(settled(facts), facts)

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
      view("retired", retired_sentence(facts), action(:learn_more), %{})
      |> restorable(facts)

  # A server's own copy that a move back left serving nothing names where
  # Fermix moved back to; any other retired computer, its server.
  defp retired_sentence(%{moved_back: true, moved: %{to: to}} = facts),
    do: sentence(:retired_back, facts, %{to: to})

  defp retired_sentence(facts), do: sentence(:retired, facts)

  defp desktop(facts) do
    checks = [
      &away_here/1,
      &too_old/1,
      &settings_only/1,
      &server_older/1,
      &server_ahead/1,
      &server_disk/1,
      &backup_failed/1,
      &desktop_backup/1
    ]

    Enum.find_value(checks, & &1.(facts)) || on(facts)
  end

  # No session with the server for ten minutes while this computer is awake.
  defp away(%{link: %{primary: %{status: status} = link}})
       when status in [:unreachable, :stale] do
    if (Map.get(link, :down_ms) || 0) >= @unreachable_ms,
      do: problem("cannot_reach", Copy.summary_sentence(:cannot_reach, %{}), :learn_more, %{})
  end

  defp away(_facts), do: nil

  # A server that stopped answering, with Restore here beside it where this
  # computer can take the home back from its own copy.
  defp away_here(facts), do: facts |> away() |> restorable(facts)

  defp too_old(%{primary_too_old: true} = facts),
    do: problem("update", sentence(:update, facts), :update, %{})

  defp too_old(_facts), do: nil

  # Past the server's window (M97 §3.4): this computer keeps its link for
  # settings alone until its Fermix updates.
  defp settings_only(%{standing: :settings_only} = facts),
    do: problem("update", sentence(:update_settings_only, facts), :update, %{})

  defp settings_only(_facts), do: nil

  # The server refused this computer's protocol as newer than its own: it
  # updates on its own once the apps that keep the home's backups carry it.
  defp server_older(%{primary_behind: true} = facts),
    do: problem("server_older", sentence(:server_older, facts), :learn_more, %{})

  defp server_older(_facts), do: nil

  # The server installed a release ahead of the apps (an owner's override)
  # that this computer cannot read: until its Fermix catches up, a restore
  # here would be refused.
  defp server_ahead(%{readable: {:error, _newer}, primary_home: %{"update" => update}} = facts) do
    if match?(%{"ahead_of_apps" => true}, update),
      do: problem("server_ahead", sentence(:server_ahead, facts), :update, %{})
  end

  defp server_ahead(_facts), do: nil

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
    detail = %{
      "server" => on_server(facts),
      "backups" => backups(get_in(facts, [:primary_home, "snapshots"])),
      "copies_bytes" => facts.copies_bytes,
      "disk_used" => get_in(facts, [:primary_home, "disk", "used"]),
      "data" => sentence(:data, facts),
      "actions" =>
        review_action(facts) ++
          [action(:back_up_now), action(:add_computer)] ++ List.wrap(move_back(facts))
    }

    detail = put_some(detail, "review", Map.get(facts, :offers_review))

    view(
      "on",
      on_sentence(facts),
      nil,
      webhooks(detail, get_in(facts, [:primary_home, "webhooks"]))
    )
  end

  # A computer that moved before M97 offers nothing until the owner reviews
  # what Fermix on the server may use on it (M97 §7.3): the review's block is
  # in Details, with its step.
  defp review_action(facts) do
    if Map.get(facts, :offers_review), do: [action(:review_offers)], else: []
  end

  defp on_sentence(%{primary_home: %{"snapshots" => snapshots}} = facts) do
    case newest_backup(snapshots) do
      nil -> sentence(:on_no_backup, facts)
      at -> sentence(:on_backup, facts, %{age: DateTime.diff(facts.now, at, :second)})
    end
  end

  defp on_sentence(facts), do: sentence(:on, facts)

  defp on_server(facts),
    do: %{"name" => link_name(facts), "version" => get_in(facts, [:primary_home, "version"])}

  defp link_name(%{link: %{primary: %{name: name}}}), do: name
  defp link_name(%{moved: %{to: to}}), do: to
  defp link_name(_facts), do: nil

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
    problem("return_failed", sentence(:return_failed, facts), move_back_again(facts), %{
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

  # Move back, where this engine would start again by itself after it; an
  # engine run from a terminal is refused it at the press, so it is not
  # offered (`move_back_lines/3` says why). Where this computer cannot read
  # the server's home, Update stands in its place.
  defp move_back(%{restarts_itself: true, moved: %{}} = facts),
    do: readable_or_update(facts, action(:move_back, %{machine: machine(facts.host_os)}))

  defp move_back(_facts), do: nil

  # A move back that ended is offered again as it was asked: its engine
  # started again by itself then, and the press checks it once more.
  defp move_back_again(facts),
    do: readable_or_update(facts, action(:move_back, %{machine: machine(facts.host_os)}))

  # "Update Fermix on this computer first" (M97 §3.4) in place of an action
  # that takes the server's home here, which this computer cannot read.
  defp readable_or_update(%{readable: {:error, _newer}} = facts, _act),
    do: action(:update, %{first: true, machine: machine(facts.host_os)})

  defp readable_or_update(_facts, act), do: act

  defp restoring(facts) do
    if restore_running?(facts), do: view("moving", sentence(:restore_moving, facts), nil, %{})
  end

  # Restore here's request beside its running job; a request a restart left
  # stands beside none.
  defp restore_running?(%{restoring: true, return: %{restore_requested: _copy}}), do: true
  defp restore_running?(_facts), do: false

  # Restore here (design §8): wherever the server is silent (`silent?/1`),
  # and only while this computer holds a copy, the newest named.
  defp restore_offer(%{copies: [newest | _], moved: %{}} = facts) do
    if silent?(facts),
      do:
        readable_or_update(
          facts,
          action(:restore_here, %{
            copy: newest.name,
            at: newest.at,
            machine: machine(facts.host_os)
          })
        )
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

  defp started?(%{move_started_at: %DateTime{}} = record), do: not Map.has_key?(record, :moved_at)
  defp started?(_record), do: false

  # The move back of a second desktop the home went past: the link reached a
  # newer epoch than the one it was asked at.
  defp stale?(%{return: %{primary_epoch: asked} = record, link: %{primary: %{epoch: seen}}})
       when is_integer(seen) and seen > asked,
       do: not Map.has_key?(record, :moved_at)

  defp stale?(_facts), do: false

  # The server silent: nothing answers, so no link (none, or forgotten) or
  # no session for the limit. One that answers it forgot this computer
  # (`revoked`), or a retired copy that answers (`stale`: the home lives
  # elsewhere), is not silent.
  defp silent?(%{link: %{primary: nil}}), do: true

  defp silent?(%{link: %{primary: %{status: :unreachable} = link}}),
    do: (Map.get(link, :down_ms) || 0) >= @unreachable_ms

  defp silent?(_facts), do: false

  defp server_move(facts), do: get_in(facts, [:primary_home, "move", "phase"])

  defp server_idle?(%{primary_home: %{"role" => "primary"}} = facts),
    do: server_move(facts) not in @server_moves

  defp server_idle?(_facts), do: false

  # -- a computer joining, and one that asks to join (M97 §3.1, §7.5) ----------------

  # This computer joining a home: `creating` while it dials and while it
  # waits for the owner, with the digits both ends show; how it ended once
  # it was not added. Cancel makes it its own home again.
  defp joining(%{join: %{"phase" => phase} = join} = facts) do
    sentence =
      case phase do
        "dialing" ->
          sentence(:join_dialing, facts, %{to: join["server"]})

        "awaiting_approval" ->
          sentence(:join_waiting, facts, %{to: join["server"], sas: join["sas"]})

        "denied" ->
          join["sentence"]
      end

    view("creating", sentence, action(:cancel), %{})
  end

  defp joining(_facts), do: nil

  # A computer that asks to join the home, on the server's screen and on each
  # linked computer's: the owner adds it by typing the digits it shows, or
  # not. Neither screen holds the digits.
  defp asking(%{"state" => state} = view, facts) when state in ["on", "primary"] do
    case joiner(facts) do
      nil -> view
      joiner -> ask(view, joiner, facts)
    end
  end

  defp asking(view, _facts), do: view

  defp ask(view, joiner, facts) do
    deny = action(:deny_computer)
    values = %{name: joiner.name, system: system(joiner.platform)}

    %{
      view
      | "sentence" => sentence(:computer_asks, facts, values),
        "action" => action(:approve_computer, %{joiner: "#{joiner.name} (#{joiner.platform})"})
    }
    |> update_in(
      ["detail"],
      &Map.update(&1, "alternatives", [deny], fn more -> [deny | more] end)
    )
  end

  # The window as this place reads it: the server's own, or the server's
  # `home.status` on a linked computer.
  defp joiner(%{role: :device} = facts) do
    case get_in(facts, [:primary_home, "enrollment"]) do
      %{"state" => "awaiting_approval", "joiner" => %{"name" => name} = joiner} ->
        %{name: name, platform: joiner["platform"]}

      _none ->
        nil
    end
  end

  defp joiner(facts) do
    case window(facts) do
      %{state: :awaiting_approval, joiner: %{} = joiner} -> joiner
      _none -> nil
    end
  end

  # The computer that joined through the window, while the window names it.
  defp joined(%{role: :device} = facts) do
    case get_in(facts, [:primary_home, "enrollment"]) do
      %{"state" => "approved", "joined" => %{"device_id" => id, "name" => name}} -> {id, name}
      _none -> nil
    end
  end

  defp joined(facts) do
    case window(facts) do
      %{state: :approved, joined: %{device_id: id, name: name}} -> {id, name}
      _none -> nil
    end
  end

  defp system("macos"), do: "macOS"
  defp system(_linux), do: "Linux"

  # -- the server ----------------------------------------------------------------

  defp server(facts) do
    disk = disk_problem(facts.disk, :server_disk_full)

    disk || backup_failed(facts) || server_backup(facts) ||
      asking(
        view("primary", sentence(:primary, facts), nil, %{"actions" => [action(:add_computer)]}),
        facts
      )
  end

  defp server_backup(facts) do
    case newest_backup(facts.snapshots) do
      nil -> nil
      at -> old_backup(at, :server_backup_old, facts)
    end
  end

  # -- the webhooks a server serves ------------------------------------------------

  # The Funnel mounts of what the server serves (the `webhooks` of its
  # `home.status`; absent from an older server's), with the policy step and
  # the caveats; none when it serves nothing.
  defp webhooks(detail, served) when served in [nil, []], do: detail

  defp webhooks(detail, served) do
    Map.put(detail, "webhooks", %{
      "sentence" => Copy.summary_sentence(:webhooks, %{carried: carried(served)}),
      "mounts" => Enum.map(served, &mount/1),
      "notes" => webhook_notes(served)
    })
  end

  defp mount(%{"kind" => "whatsapp", "port" => port}) do
    %{
      "label" => Copy.mount_label(:whatsapp),
      "command" => as_root(Funnel.mount_command(Funnel.whatsapp_path(), port)),
      "note" => Copy.summary_sentence(:webhooks_whatsapp, %{})
    }
  end

  defp mount(%{"kind" => "cue", "ref" => ref, "port" => port}) do
    %{
      "label" => Copy.mount_label({:cue, ref}),
      "command" => as_root(Funnel.mount_command(Webhook.prefix_path(ref), port)),
      "note" => Copy.summary_sentence(:webhooks_cue, %{})
    }
  end

  # The server's first boot names no Tailscale operator, so its serve config
  # is root's to change.
  defp as_root(command), do: "sudo " <> command

  # Port 443's rule, Tailscale's ingress, and the tunnel to the same ports
  # without Tailscale.
  defp webhook_notes(served) do
    ports = served |> Enum.map(&{port_of(&1["kind"]), &1["port"]}) |> Enum.uniq_by(&elem(&1, 0))

    [
      Copy.summary_sentence(:webhooks_port, %{}),
      Copy.summary_sentence(:webhooks_ingress, %{}),
      Copy.summary_sentence(:webhooks_tunnel, %{ports: ports})
    ]
  end

  # What the server serves, each kind once.
  defp carried(served), do: served |> Enum.map(&port_of(&1["kind"])) |> Enum.uniq()

  defp port_of("whatsapp"), do: :whatsapp
  defp port_of("cue"), do: :cues

  # -- the server before its move ------------------------------------------------

  defp candidate(%{move: %{"phase" => "expired"}} = facts),
    do: problem("waited_too_long", sentence(:server_waited_too_long, facts), :learn_more, %{})

  defp candidate(%{move: %{"phase" => "failed"}} = facts),
    do: problem("not_set_up", sentence(:server_not_set_up, facts), :learn_more, %{})

  defp candidate(%{move: %{"phase" => phase}} = facts) when phase in @receiving,
    do: view("candidate", sentence(:candidate_receiving, facts), nil, %{})

  defp candidate(facts), do: view("candidate", sentence(:candidate_waiting, facts), nil, %{})

  # -- problems shared by more than one place ------------------------------------

  defp disk_problem(%{"used" => used, "nearly_full" => true}, key),
    do:
      problem(
        "disk_full",
        Copy.summary_sentence(key, %{percent: round(used * 100)}),
        :learn_more,
        %{}
      )

  defp disk_problem(_disk, _key), do: nil

  # The newest try that failed of a place whose backup has not been stored
  # since (`Snapshot.Status` keeps its error until one is), in its own words,
  # where it went and when: Back up now tries again.
  defp backup_failed(facts) do
    case failed_tries(backup_snapshots(facts)) do
      [] ->
        nil

      tries ->
        {place, at, error} = Enum.max_by(tries, &elem(&1, 1), DateTime)
        values = %{place: place, at: at, zone: facts.zone, error: error}

        problem("backup_failed", sentence(:backup_failed, facts, values), :back_up_now, %{
          "seen_at" => iso(at)
        })
    end
  end

  defp failed_tries(snapshots) do
    for %{"configured" => true, "label" => place, "last_error" => error} = target <-
          targets(snapshots),
        is_binary(error) and is_binary(target["last_attempt_at"]),
        do: {place, time(target["last_attempt_at"]), error}
  end

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

  defp newest_backup(%{"targets" => targets}) do
    targets
    |> Enum.flat_map(&List.wrap(get_in(&1, ["last_verified", "at"])))
    |> Enum.map(&time/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp newest_backup(_snapshots), do: nil

  # The backup Back up now takes: the server's, which a desktop reads from
  # its server's own `home.status`.
  defp backup_snapshots(%{role: :device} = facts), do: get_in(facts, [:primary_home, "snapshots"])
  defp backup_snapshots(facts), do: facts.snapshots

  defp offers_backup?(view), do: Enum.any?(offered(view), &(&1["id"] == "back_up_now"))

  # A backup runs where the screen offers Back up now.
  defp backing_up?(view, facts),
    do: offers_backup?(view) and match?(%{"running" => true}, backup_snapshots(facts))

  defp targets(%{"targets" => targets}) when is_list(targets), do: targets
  defp targets(_snapshots), do: []

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

  # What every sentence may name: this computer.
  defp words(facts), do: %{machine: machine(facts.host_os)}

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

  defp needs(:restore_here, _facts), do: ["recovery_passphrase"]
  defp needs(:approve_computer, _facts), do: ["sas"]
  defp needs(act, facts) when act in [:move_now, :try_again], do: [passphrase_need(facts)]
  defp needs(_act, _facts), do: []

  # A move back checks the server's own key, which every move to it set;
  # here, the key this home's snapshots keep, or a new one when none is set.
  defp passphrase_need(%{role: :device}), do: "recovery_passphrase"
  defp passphrase_need(%{snapshots: %{"recipient_set" => true}}), do: "recovery_passphrase"
  defp passphrase_need(_facts), do: "new_recovery_passphrase"

  # What the owner accepts first: a move, a restore, or forgetting a server.
  defp confirm(:cancel, %{forget: true}, facts), do: sentence(:confirm_forget, facts)

  defp confirm(:restore_here, _values, facts),
    do: sentence(:confirm_restore_here, facts, %{telegram: :telegram in facts.return_costs})

  defp confirm(act, _values, facts) when act in [:move_now, :try_again], do: move_confirm(facts)
  defp confirm(_act, _values, _facts), do: nil

  # A move back's confirm says what runs here again; otherwise each warning
  # this home's settings give, after any other the last review of the same
  # server gave.
  defp move_confirm(%{role: :device} = facts),
    do:
      sentence(:confirm_return_move, facts, %{
        stays_here: facts.stays_here,
        costs: facts.return_costs
      })

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

  defp url(:learn_more, _facts), do: Copy.always_on_docs_url()
  defp url(_act, _facts), do: nil

  defp target_of(act, _values, facts) when act in [:move_now, :try_again, :check_again],
    do: candidate_id(target(facts))

  defp target_of(:cancel, %{forget: true}, facts), do: candidate_id(target(facts))

  defp target_of(:restore_here, %{copy: name}, _facts), do: name
  defp target_of(:approve_computer, %{joiner: joiner}, _facts), do: joiner
  defp target_of(_act, _values, _facts), do: nil

  defp candidate_id(%{"candidate_id" => id}), do: id
  defp candidate_id(nil), do: nil

  # -- Details' lines --------------------------------------------------------------

  # The states whose Details name a server, from the facts the state's
  # detail holds.
  defp lines(view, facts) do
    ctx = %{zone: facts.zone, machine: machine(facts.host_os)}

    Enum.concat([
      state_lines(view, ctx),
      restore_lines(view, ctx),
      again_lines(view, facts, ctx),
      move_back_lines(view, facts, ctx),
      link_lines(view, facts, ctx)
    ])
  end

  defp state_lines(%{"state" => state, "detail" => detail}, ctx)
       when state in @detailed_states do
    Enum.concat([
      server_lines(detail["server"], ctx),
      time_line(:waits_until, detail["waits_until"], ctx),
      backup_lines(detail["backups"], ctx),
      value_line(:copies, detail["copies_bytes"], ctx),
      value_line(:disk, detail["disk_used"], ctx)
    ])
  end

  defp state_lines(_view, _ctx), do: []

  # Where Restore here is offered: the date of the copy it restores (design
  # §8).
  defp restore_lines(view, ctx) do
    case Enum.find(offered(view), &(&1["id"] == "restore_here")) do
      %{values: %{at: at}} -> [Copy.summary_line(:backup_here, at, ctx)]
      nil -> []
    end
  end

  # A move back's ready: what this computer's settings turn on that runs
  # here again.
  defp again_lines(%{"state" => "ready"}, %{role: :device, returning: %{}} = facts, ctx) do
    case facts.stays_here do
      [] -> []
      features -> [Copy.summary_line(:runs_again, features, ctx)]
    end
  end

  defp again_lines(_view, _facts, _ctx), do: []

  # On, where Move back is not offered to an engine run from a terminal: the
  # move back's own refusal, so the owner reads it before any press.
  defp move_back_lines(%{"state" => "on"}, %{restarts_itself: false}, ctx),
    do: [Copy.summary_line(:move_back, Candidate.error_sentence(:not_supervised), ctx)]

  defp move_back_lines(_view, _facts, _ctx), do: []

  # On: whether the link runs direct or through Fermix's relay, while its
  # session is up and the helper has named its path (step 7).
  defp link_lines(%{"state" => "on"}, %{link: %{primary: %{connected: true} = primary}}, ctx) do
    case Map.get(primary, :path) do
      path when path in [:direct, :relay] -> [Copy.summary_line(:connection, path, ctx)]
      nil -> []
    end
  end

  defp link_lines(_view, _facts, _ctx), do: []

  @server_lines [server: "name", system: "system", version: "version"]

  defp server_lines(nil, _ctx), do: []

  defp server_lines(server, ctx) do
    for {key, field} <- @server_lines,
        is_binary(server[field]),
        do: Copy.summary_line(key, server[field], ctx)
  end

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

  # -- the outcome -----------------------------------------------------------------

  # A move under way runs whatever the screen still shows (one asked for
  # here reads `ready` until the restart); a code for the owner's server
  # waits for that server.
  defp outcome(%{"state" => "problem"} = view, facts),
    do: if(backing_up?(view, facts), do: "running", else: "failed")

  defp outcome(_view, %{join: %{"phase" => phase}}),
    do:
      Map.fetch!(
        %{"dialing" => "running", "awaiting_approval" => "waiting", "denied" => "failed"},
        phase
      )

  defp outcome(%{"state" => state}, _facts) when state in ["creating", "moving"], do: "running"
  defp outcome(%{"state" => "candidate"}, facts), do: receiving(facts)

  defp outcome(view, facts) do
    cond do
      moving?(facts) or backing_up?(view, facts) ->
        "running"

      view["state"] == "connect" and match?(%{state: :open}, window(facts)) ->
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

  defp occurrence(view, %{role: :primary, link: %{desktops: [_ | _]}} = facts),
    do:
      week_occurrence(facts, :notice_server_backup_week) || sandbox_occurrence(facts) ||
        joined_occurrence(view, facts)

  defp occurrence(view, %{role: role} = facts) when role in [:primary, :device] do
    Enum.find_value(
      [
        &reach_occurrence/2,
        &review_occurrence/2,
        &ready_occurrence/2,
        fn _view, facts -> week_occurrence(facts, :notice_backup_week) end,
        &moved_occurrence/2,
        &restored_occurrence/2,
        &back_occurrence/2,
        &lapsed_occurrence/2,
        &joined_occurrence/2
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

  # A computer joined the home (M97 §3.1): told once, on the owner's other
  # surfaces, while the window names it.
  defp joined_occurrence(_view, facts) do
    case joined(facts) do
      {id, name} ->
        {"computer_joined:" <> id, sentence(:notice_computer_joined, facts, %{name: name})}

      nil ->
        nil
    end
  end

  # A computer whose switches wait for the owner's review (M97 §7.3): told
  # once, while it waits.
  defp review_occurrence(_view, %{role: :device} = facts) do
    if Map.get(facts, :offers_review),
      do: {"computer_review", sentence(:notice_computer_review, facts)}
  end

  defp review_occurrence(_view, _facts), do: nil

  # A server that left out the settings it inherited (M97 §4): told for a
  # week after, once.
  defp sandbox_occurrence(%{server_sandbox: %DateTime{} = at} = facts) do
    if DateTime.diff(facts.now, at, :second) < @server_sandbox_s,
      do: {"server_sandbox:" <> iso(at), sentence(:notice_server_sandbox, facts)}
  end

  defp sandbox_occurrence(_facts), do: nil

  defp ready_occurrence(%{"state" => "ready"}, facts),
    do: {"ready:" <> target(facts)["candidate_id"], sentence(ready_notice(facts), facts)}

  defp ready_occurrence(_view, _facts), do: nil

  defp ready_notice(%{role: :device}), do: :return_ready
  defp ready_notice(_facts), do: :notice_ready

  # Restore here finished: told once, by the epoch it came back at, naming
  # the day of the backup it restored (`Home.Return`'s `restored`). A record
  # it shares with a move back that had started is still a restore's.
  defp restored_occurrence(
         _view,
         %{role: :primary, return: %{moved_at: %DateTime{}, restored: name} = record} = facts
       ) do
    case copy(name) do
      [%{at: at}] ->
        day = Clock.stated_day(at, personalization: [timezone: facts.zone])
        {"restored:#{record.epoch}", sentence(:notice_restored, facts, %{day: day})}

      [] ->
        nil
    end
  end

  defp restored_occurrence(_view, _facts), do: nil

  # A held server whose 24 hours ran out, on the screen it leaves: told once,
  # by its id, as one to set up again.
  defp lapsed_occurrence(%{"state" => "off"}, %{role: :primary, lapsed: id} = facts)
       when is_binary(id),
       do: {"server_lapsed:" <> id, sentence(:notice_server_lapsed, facts)}

  defp lapsed_occurrence(_view, _facts), do: nil

  # Back on this computer after a move back, whose server still runs its
  # retired copy: told once, by the epoch this computer came back at. A
  # restore here, whose server the owner deleted or stopped, tells only that
  # it finished (`restored_occurrence/2`).
  defp back_occurrence(
         _view,
         %{
           role: :primary,
           return: %{moved_at: %DateTime{}, move_started_at: %DateTime{}} = record
         } =
           facts
       ),
       do: {"back:#{record.epoch}", sentence(:notice_back, facts)}

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
  # (`primary_home`): its newest backup, whether one runs, and each place's
  # failed try; only a server with desktops has anyone to tell.
  defp drawn(%{role: :primary, link: %{desktops: [_ | _]}} = facts) do
    snapshots = facts.snapshots

    {newest_backup(snapshots), match?(%{"running" => true}, snapshots), failed_tries(snapshots)}
  end

  # A linked computer's mark (M97 §7.4): the app draws it from `home.status`'s
  # `screen`, so taking and letting go of the screen is a change it is told of.
  defp drawn(%{role: :device, screen: screen}) when is_map(screen), do: screen

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

    [link_deadline(facts), backup_deadline(since, facts), week_deadline(since, facts)]
  end

  defp deadlines(%{role: :primary, link: %{desktops: [_ | _]}} = facts) do
    since = backup_since(facts)
    [backup_deadline(since, facts), week_deadline(since, facts), sandbox_deadline(facts)]
  end

  defp deadlines(%{role: :primary} = facts), do: expiries(facts.candidates, facts)

  defp sandbox_deadline(%{server_sandbox: %DateTime{} = at} = facts),
    do: ms_until(DateTime.add(at, @server_sandbox_s, :second), facts)

  defp sandbox_deadline(_facts), do: nil

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

  defp ms_until(%DateTime{} = at, facts), do: DateTime.diff(at, facts.now, :millisecond)

  # -- gathering -----------------------------------------------------------------

  defp host_os do
    case :os.type() do
      {:unix, :darwin} -> :macos
      _other -> :linux
    end
  end

  # What this computer keeps on for its server after the move (M97 §7.3),
  # where a move from it is set up: never on a server, which has computers.
  defp keeps_on(home, {:primary, %{desktops: []}}, host_os, opts) do
    snapshot = Keyword.get(opts, :settings_snapshot, &ConfigStore.current_snapshot/0).()
    Consent.view(Consent.keep_on_block(home, os: host_os, snapshot: snapshot))
  end

  defp keeps_on(_home, _role_link, _host_os, _opts), do: nil

  # A linked computer whose switches wait for the owner's review: the block
  # of what they propose to keep on.
  defp offers_review(true, host_os, opts) do
    switches = Keyword.get_lazy(opts, :computer_switches, &Switches.current/0)

    if Switches.reviewed?(switches),
      do: nil,
      else: Consent.view(Consent.block(Consent.proposed(switches), os: host_os, kind: :review))
  end

  defp offers_review(false, _host_os, _opts), do: nil

  # That this server left out the settings it inherited, and when; one that
  # cannot be read is logged once while it stays so.
  defp server_sandbox(home, :primary, reads) do
    read = ServerSandbox.read(home)

    :ok =
      UnreadableFiles.log_read(
        ServerSandbox.path(home),
        "home status",
        read_result(read),
        memory(reads)
      )

    case read do
      {:ok, at} -> at
      _absent_or_unreadable -> nil
    end
  end

  defp server_sandbox(_home, _role, _reads), do: nil

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

  # A move back's need (`Home.Candidate.returnable/3`), read where Move back
  # is offered.
  defp restarts_itself(:device, opts),
    do: Keyword.get_lazy(opts, :restarts_itself, &Lifecycle.restarts_itself?/0)

  defp restarts_itself(_role, _opts), do: nil

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

  # What a move back costs that this desktop's settings turn on, which its
  # confirm names: the settings of the home it left, the facts it holds.
  defp return_costs(home, :device, reads),
    do: home |> MoveReadiness.settings(reads) |> MoveReadiness.costs()

  defp return_costs(_home, _role, _reads), do: []

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

  # This engine's version against the server's (its own `home.status`, on a
  # linked desktop), through `compare`; nil where the server said none or
  # either is not a version.
  defp server_compared(%{version: ours, primary_home: %{"version" => theirs}}, compare)
       when is_binary(ours) and is_binary(theirs) do
    if version?(ours) and version?(theirs), do: compare.(ours, theirs)
  end

  defp server_compared(_status, _compare), do: nil

  defp version?(text), do: match?({:ok, _version}, Version.parse(text))

  # Whether this engine reads the home its server writes (`Home.Readable`,
  # M97 D16): by the home format the server's own `home.status` names, one
  # from before home formats naming none (format 1). Nil where the server
  # said no version (a silent one), as for its standing, or named a format
  # that is not one.
  defp server_readable(%{primary_home: %{"version" => version} = server})
       when is_binary(version) do
    case Map.get(server, "home_format") do
      format when is_nil(format) or (is_integer(format) and format >= 1) ->
        Readable.readable?(%{home_format: format, engine_version: version})

      _not_a_format ->
        nil
    end
  end

  defp server_readable(_status), do: nil

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

  # The held server whose 24 hours ran out that the window still names: the
  # code that enrolled it is the last one opened here. One that enrolled
  # before the home came back here (a return's `moved_at`) is the server the
  # home moved to and back from, and a desktop's candidate for a move back
  # (`returning`) is no server to set up again: neither is a held one that
  # lapsed. The list that cannot be read is logged once while it stays so,
  # and names none.
  defp lapsed(home, :primary, {%{enrollment: %{candidate_id: id}}, return}, now, reads)
       when is_binary(id) do
    read = Candidates.lapsed(home, now)
    file = Candidates.path(home)
    :ok = UnreadableFiles.log_read(file, "home status", lapsed_read(read), memory(reads))

    case read do
      {:ok, records} -> if Enum.any?(records, &lapsed_since?(&1, id, return)), do: id
      {:error, _reason} -> nil
    end
  end

  defp lapsed(_home, _role, _link, _now, _reads), do: nil

  defp lapsed_since?(%{returning: returning}, _id, _return) when is_binary(returning), do: false

  defp lapsed_since?(%{candidate_id: id, enrolled_at: enrolled_at}, id, %{moved_at: back}),
    do: DateTime.compare(enrolled_at, back) == :gt

  defp lapsed_since?(%{candidate_id: id}, id, _return), do: true
  defp lapsed_since?(_record, _id, _return), do: false

  defp lapsed_read({:ok, _records}), do: :ok
  defp lapsed_read(error), do: error

  # A server's own copy after a move back: its move kept it as no desktop.
  # The move's record that cannot be read is logged once while it stays so,
  # and says no.
  defp moved_back(home, :device, reads) do
    read = Move.read_phase(home)
    file = Path.join(Move.dir(home), "phase.json")
    :ok = UnreadableFiles.log_read(file, "home status", read_result(read), memory(reads))
    match?({:ok, %{"keep_as_desktop" => false}}, read)
  end

  defp moved_back(_home, _role, _reads), do: false

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
