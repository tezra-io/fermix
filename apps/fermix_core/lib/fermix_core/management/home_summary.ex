defmodule FermixCore.Management.HomeSummary do
  @moduledoc """
  `home.status.summary` (M75 lean v1 §7, Always On setup §3): where Always
  On stands, worked out once here so the Mac app, the Linux app, the setup
  page and the CLI draw the same screen.

      summary: {key, state, sentence, action, detail, notice, outcome, help}

  One sentence and at most one action per screen (the Always On pane, draft
  3, R1 to R12): `action` is a step that changes something, and none while a
  step runs; every other step is in `detail.alternatives`; `detail.note` is
  the one secondary sentence, on any state, of what the owner must know or do
  now; Details (`detail.lines`) holds facts only; and `help` is the Always On
  docs page at the screen's anchor (`Copy.always_on_docs_url/1`), where the
  background and the caveats live.

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
      that fixes it, or none where no step of the owner's does (its note says
      what to check or do).

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
  while it connects to the server (Cancel beside it), `ready` once it is held
  (its sentence says Fermix has not moved yet, its note until when this
  computer waits; Move now with the server's recovery passphrase and a
  confirm built here from this computer's own settings, Cancel beside it;
  and again once the start is recorded while the server answers as the
  primary with no move),
  `moving` from the recorded start (written before the request leaves)
  while the server moves or cannot answer, to this computer's restart as the
  primary, `undone` when the server undid it (Try again, Cancel), and
  `return_failed` when the candidate ended (Move back again) or stopped
  before any move with no record of it (Cancel). Cancel is never offered
  while the server's move is under way, once it retired, or once the home is
  coming in here. A move back the home went past (the link reached a newer
  epoch than the one it was asked at, without this computer's return) is not
  drawn. Where the server went silent (`cannot_reach`, `retired`) and this
  computer holds a copy of it, Restore here is offered; its confirm names the
  date of the copy it restores and asks the owner's word that the server is
  deleted or stopped, and Fermix deletes nothing. While its job runs (`restoring`, the
  job family's own record) beside the return's request for it
  (`restore_requested`), the screen is `moving`. Back on this computer as
  the primary after a move back, the server's retired copy is told once,
  `back:<epoch>`.

  **Every action is one record** wherever it sits (`action`,
  `detail.alternatives`, `detail.backup.change`): `id`, `label`, `needs`
  (what the surface collects: `new_recovery_passphrase`, typed twice and
  compared, where this move's recovery key is not set yet and for a new
  one, else `recovery_passphrase`, typed once and checked by the move),
  `confirm` (the sentence the owner accepts before Fermix moves, restores,
  forgets a server or changes the recovery passphrase, one part per line and
  with no time that moves with the clock; nil otherwise) and `key`
  (`action_key/5`). Move now's confirm is built here, before any review,
  from the review's items this home's settings decide and any other warning
  the last review of the same server gave (`s3_size`, `plugins`), so the
  full review at the press moves it, and its key, only when it found
  something the screen did not say. It is where the review's warnings are
  said: the `ready` screen shows none, and a review that blocks makes the
  screen the `not_ready` problem with its blocks in `detail.readiness`.

  `detail` holds what the state draws, a field only where it has something:
  `note`; `alternatives`; on `ready` the server's facts and until when it
  waits (`waits_until`, which the note says), on `on` the server, each
  backup, the space this computer's copies take and the disk, on `problem`
  its kind, what Fermix last saw and when; the Details `lines`
  (`Copy.summary_line/3`); `progress` while a move, a move back, a restore
  or a backup runs; a flow's `steps` (`[{label, state}]`, `step_states/0`:
  the move's Connect your server, Move now, Send your home, Switch over, and
  the move back's Get this computer ready, Move now, Receive your home, Put
  Fermix in place, on each of their screens), and while either moves its
  `route` (`{from, to, direction}`: this computer, the server, `forward` or
  `back`) and, only while bytes move, `transfer` (`{fraction, label}`, the
  bytes `Home.MoveProgress` counted in whole twentieths); and on a linked
  desktop's `on`, where Backup settings shows, `backup` (`{passphrase:
  {label, value, footer}, change, s3}`, Change being `change_passphrase`).
  The server's own `primary` carries neither `backup` nor `webhooks`: its
  summary rides inside each desktop's `home.status`, where a Change's needs
  would pass the protocol's depth bound (`max_json_depth`).

  **Inbound webhooks** (Always On, "Inbound webhooks without a public IP"):
  on a linked desktop's `on`, `detail.webhooks` holds the Tailscale Funnel
  mounts the owner runs on the server, `{sentence, mounts, notes, url}`: the
  sentence says what needs them, each mount's `label`, `command`
  (`FermixCore.Funnel`'s, after `sudo`: the server's first boot names no
  Tailscale operator, so only root changes its serve config) and `note`
  (where the sender is pointed: Meta's Callback URL for WhatsApp, the host
  of a webhook source's address in its sender), WhatsApp's first, then each
  webhook source's; `notes` the one step a tailnet takes once (`funnel` for
  `tag:fermix-server`, MagicDNS and HTTPS certificates), and `url` the docs
  page that holds the rest (Cloudflare Tunnel instead, port 443, the
  ingress, the wait for a new address). The values are the server's: the
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
  binds the computer that asks) and `deny_computer` stands first beside it,
  then the step the screen led with before. The digits prove the computer
  the owner looks at is the one asking, so no screen of the home shows them:
  they are read on the new computer and typed. On the computer that joins
  (`device/join.json`, `Home.Join`), the screen is `creating`, with Cancel
  beside it while it dials and while it waits for the owner (outcome
  `running`, then `waiting`, the sentence carrying the digits to type), and
  once it was not added, its sentence says why and Cancel is its action
  (outcome `failed`). Move back and Restore here are offered only where the
  home moved from this computer (its moved marker): a computer that joined
  has neither.

  **What Fermix on the server may use** (M97 §7.3, D27). On the computer
  that sets Always On up, `ready` carries `keeps_on`, the block of what this
  computer keeps on for its server after the move, each line a tick Move now
  sends. A linked computer that moved before M97, whose switches wait for the
  owner's review, sets them in one place, its `computer` settings section
  (This computer): its `on` says so in its note, and its action is
  `review_offers` (Keep these switches), which takes them as they are.

  **What Always On does not do yet** (M97). `detail.not_yet` lists what
  does not work, or takes a terminal on the server, while the home runs
  there, each `{id, sentence}` in `Copy.not_yet_ids/0`'s order and only
  where it applies to this home: on the computer that sets Always On up, on
  every screen before a move but `off` (the pane's D1), from its own
  settings and recorder; on the server's own `primary`, what the home's
  settings and its own turn on (`@server_not_yet`); on a linked computer's
  `on`, its server's entries as the server's screen says them (but
  WhatsApp's where the Funnel mounts already say it), then its own
  (`@computer_not_yet`). Absent where nothing applies, on a problem and on
  every other screen: a detail, never a notice.

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
  never a desktop's candidate for a move back), and the server's sandbox or
  coding approval changed from one of its computers (M97 §19.5, the newest
  change, `computer_change:<what>:<at>`, for a week after, on the server and
  on every linked computer, which reads it from its server's `home.status`).
  An app posts when the id changes.

  **Restarting the server** (M97 D28c). A change made from a linked
  computer to the server's settings waits for the server's next start, so
  while the server's own `home.status` says its restart is required
  (`primary_home.restart.required`), every screen of a linked computer's
  `desktop` (its `on` and the problems of a server that answers) offers
  `restart_server` first in `detail.alternatives`, labelled with the name
  this computer knows its server by (`restart_server_action/1`); none where
  it knows no name.

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
  alias FermixCore.ComputerHistory
  alias FermixCore.Computers.Consent
  alias FermixCore.Computers.Switches
  alias FermixCore.Computers.Versions
  alias FermixCore.Cues.Webhook
  alias FermixCore.Funnel
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Candidates
  alias FermixCore.Home.ChangedFromComputer
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Join
  alias FermixCore.Home.Move
  alias FermixCore.Home.MoveProgress
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
  @actions ~w(cancel move_now try_again update back_up_now check_again own_server move_back
              restore_here review_offers add_computer approve_computer deny_computer
              change_passphrase restart_server)
  @needs ~w(recovery_passphrase new_recovery_passphrase sas)
  @step_states ~w(done active yours pending)
  # What Always On does not do yet (M97) by where its fact lives: the home's
  # settings and the server's own, which the server's screen lists and its
  # computers read from it, and one computer's own, which only that
  # computer's screen lists (`Copy.not_yet_ids/0` holds every one).
  @server_not_yet ~w(google_meet coding_signin whatsapp slack)a
  @computer_not_yet ~w(stackchan dev_plugins computer_history)a

  @unreachable_ms 10 * 60_000
  @backup_old_s 3 * 86_400
  @day_s 86_400
  # The apps raise their notification once the newest backup is this old.
  @backup_week_s 7 * @day_s
  # A server tells that it left out its inherited settings this long after.
  @server_sandbox_s 7 * @day_s
  # A change from a computer to the server's sandbox or coding approval is
  # told this long after (M97 §19.5).
  @computer_change_s 7 * @day_s
  # The states whose sentence `key/1` leaves out: on `on` and `problem` it
  # carries a figure that moves with the clock (a backup's age, a count of
  # days, how full a disk is), and their state, action and kind say every
  # change of note (a failed backup's own words and time are its note, in
  # `detail`); on `off` an app forgets Always On (the owner's rule).
  @untold_sentences ~w(off on problem)
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
          required(:stays_here) => [:meetings | :accessories],
          required(:return_costs) => [:telegram | :meet_notetaker],
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
          optional(:readable) => :ok | {:error, term()} | nil,
          optional(:offers_review) => boolean(),
          optional(:move_progress) => MoveProgress.t() | nil,
          optional(:computer_changes) => [ChangedFromComputer.change()],
          optional(:not_yet) => [atom()]
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
    sentence = if state in @untold_sentences, do: nil, else: summary["sentence"]

    summary
    |> Map.drop(["key", "sentence"])
    |> Map.put("detail", Map.delete(detail, "seen_at"))
    |> Map.put("told", sentence)
    |> digest()
  end

  @doc "Every word a step of `detail.steps` takes."
  @spec step_states() :: [String.t()]
  def step_states, do: @step_states

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
  The action record a linked computer's summary offers for its server's
  restart (M97 D28c): `restart_server`, labelled "Restart <server_name>",
  `server_name` the name this computer knows its server by
  (`Home.Link.status/0`'s `primary.name`), with no needs, no confirm and its
  `key` (`action_key/5`, acting on nothing else). The summary offers exactly
  this record, first in `detail.alternatives`, while the server's own
  `home.status` says its restart is required; a surface that draws the same
  step elsewhere (Settings) presses it as `home.act` with this key.
  """
  @spec restart_server_action(String.t()) :: map()
  def restart_server_action(server_name) when is_binary(server_name) and server_name != "",
    do: record(action(:restart_server, %{name: server_name}), %{})

  @doc """
  Every action record `summary` offers, wherever it sits: its action, then
  `detail.alternatives`, then the backup settings' Change
  (`detail.backup.change`). The one reading of what a screen offers:
  `find_action/3`, the CLI's steps and menus, and the tests read it here.
  """
  @spec offered(summary()) :: [map()]
  def offered(%{"action" => action, "detail" => detail}) when is_map(detail),
    do:
      List.wrap(action) ++
        Map.get(detail, "alternatives", []) ++ List.wrap(get_in(detail, ["backup", "change"]))

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
  last readiness review, on a desktop what this home's settings turn on that
  runs only on this computer, and so here again after a move back, and what
  of a move back's costs they turn on (`MoveReadiness.costs/2`, `opts`'
  `:meet_notetaker` in place of this computer's notetaker),
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
  `Lifecycle.restarts_itself?/0`); what the move in hand on this
  computer counted (`move_progress`, `Home.MoveProgress.read/0`, or `opts`'
  `:move_progress`); and, but on a candidate, what this engine's settings and
  recorder turn on of what Always On does not do yet (`not_yet`,
  `MoveReadiness.not_yet/2`, then `ComputerHistory.recorder?/0` or `opts`'
  `:recorder?`).
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
      return_costs: return_costs(home, role, reads, opts),
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
      offers_review: offers_review(DesktopLink.linked?(record, home), opts),
      join: if(role == :device, do: Join.view(home)),
      screen: Map.get(status, :screen),
      server_sandbox: server_sandbox(home, role, reads),
      computer_changes: computer_changes(role, status),
      move_progress: Keyword.get_lazy(opts, :move_progress, &MoveProgress.read/0),
      not_yet: not_yet(home, role, host_os, {reads, opts})
    }
  end

  # -- the computer that sets Always On up ---------------------------------------

  defp setup(facts), do: before_move(undone(facts) || own_server(facts), facts) || off(facts)

  # Every screen before a move but the first lists what Always On does not
  # do yet from this computer's own facts (the pane's D1: `off` names nothing
  # of what a move changes), the dev plugins naming the server held.
  defp before_move(nil, _facts), do: nil

  defp before_move(view, facts),
    do: not_yet_listed(view, not_yet_entries(facts, Copy.not_yet_ids(), target(facts)["name"]))

  # A move undone while its server is still held: Try again, or Forget this
  # server once the undoing is over; why, in the move's own words, where its
  # record has them.
  defp undone(%{move: %{"phase" => phase}} = facts) when phase in ["aborted", "undoing"] do
    if target(facts),
      do:
        view("undone", sentence(:undone, facts), action(:try_again), %{
          "alternatives" => forget(facts),
          "steps" => steps(:move, {1, "yours"}, facts)
        })
        |> noted(undone_reason(facts.move))
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
          "alternatives" => [action(:cancel, %{code: true})],
          "steps" => steps(:move, {0, "active"}, facts)
        })

      _nothing ->
        nil
    end
  end

  defp off(facts), do: view("off", sentence(:off, facts), action(:own_server), %{})

  # While the code for the owner's server is open: a new code, which ends
  # this one (its label says so), or Cancel, which closes it. Running the
  # command on the server is the owner's step.
  defp connect(facts) do
    view("connect", sentence(:connect, facts), nil, %{
      "alternatives" => [action(:own_server, %{renew: true}), action(:cancel, %{code: true})],
      "steps" => steps(:move, {0, "yours"}, facts)
    })
  end

  # The server is held and waits for Move now, unless the last review blocks;
  # either way it can be forgotten, except while a move to it runs. Its
  # warnings are Move now's confirm, which the owner reads before anything
  # moves; a block is the screen's.
  defp ready(candidate, facts) do
    items = review_items(facts.review, candidate["candidate_id"])

    case Enum.filter(items, &(&1["status"] == "block")) do
      [_block | _more] = blocks ->
        problem("not_ready", sentence(:not_ready, facts), :check_again, %{
          "readiness" => blocks,
          "alternatives" => forget(facts)
        })

      [] ->
        view(
          "ready",
          sentence(:ready, facts),
          action(:move_now),
          %{
            "server" => server_facts(candidate),
            "waits_until" => candidate["expires_at"],
            "alternatives" => forget(facts),
            "steps" => steps(:move, {1, "yours"}, facts)
          }
          |> put_some("keeps_on", Map.get(facts, :keeps_on))
        )
        |> noted(waits(:ready_waits, candidate["expires_at"], facts, %{to: candidate["name"]}))
    end
  end

  defp forget(facts), do: if(moving?(facts), do: [], else: [action(:cancel, %{forget: true})])

  # Until when a held server, or this computer during a move back, waits.
  defp waits(_key, nil, _facts, _values), do: nil

  defp waits(key, until, facts, values),
    do: sentence(key, facts, Map.merge(values, %{at: time(until), zone: facts.zone}))

  # Why a move was undone, in the words its record keeps: the one the worker
  # wrote when it undid it, never the phase's own (`Move.sentence/2`), which
  # the screen's sentence already says.
  defp undone_reason(%{"phase" => phase, "candidate" => to, "sentence" => said})
       when is_binary(said) do
    if said != Move.sentence(phase, to), do: said
  end

  defp undone_reason(_move), do: nil

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
  # computer's candidate wrote so far, else Restore here's job, else the
  # move's from this computer.
  defp progress(%{"state" => "moving"}, %{role: :device} = facts) do
    case return_progress(facts) || forward_progress(facts) do
      nil -> nil
      key -> sentence(key, facts, %{to: get_in(facts, [:move, "candidate"])})
    end
  end

  defp progress(view, facts) do
    if backing_up?(view, facts), do: sentence(:progress_backing_up, facts)
  end

  # The move from this computer: packing, then the worker's own step while
  # it streams (`Home.MoveProgress`), then switching over once the server
  # took it. While it commits the screen's sentence says it waits.
  defp forward_progress(%{move: %{"phase" => "requested"}}), do: :progress_packing
  defp forward_progress(%{move: %{"phase" => "committed"}}), do: :progress_switching

  defp forward_progress(%{move: %{"phase" => "streaming"}} = facts) do
    case Map.get(facts, :move_progress) do
      %{step: :capture} -> :progress_packing
      %{step: :send} -> :progress_sending
      %{step: :staging} -> :progress_unpacking
      _other -> nil
    end
  end

  defp forward_progress(_facts), do: nil

  # -- a flow's steps, route and transfer (the pane's §3.13, P1 to P3) ---------

  # The flow's steps, the one at `at` marked (`active` while it runs,
  # `yours` where the owner takes it), those before it done.
  defp steps(flow, {at, mark}, facts) when mark in @step_states do
    flow
    |> Copy.step_labels(machine(facts.host_os))
    |> Enum.with_index()
    |> Enum.map(fn {label, index} ->
      %{"label" => label, "state" => step_state(index, at, mark)}
    end)
  end

  defp step_state(index, at, _mark) when index < at, do: "done"
  defp step_state(at, at, mark), do: mark
  defp step_state(_index, _at, _mark), do: "pending"

  # This computer first, the server second, and which way the home goes.
  defp route(to, direction, facts) when is_binary(to),
    do: %{"from" => Copy.route_here(machine(facts.host_os)), "to" => to, "direction" => direction}

  defp route(_to, _direction, _facts), do: nil

  # The bytes the move in hand counted (`Home.MoveProgress`), only while
  # they move, in whole twentieths: the fill never runs ahead of the count.
  defp transfer(%{move_progress: %{step: step, bytes: bytes, size: size}}, step, way)
       when is_integer(size) and size > 0 do
    counted = min(bytes, size)

    %{
      "fraction" => div(counted * 20, size) / 20,
      "label" => Copy.transfer_label(counted, size, way)
    }
  end

  defp transfer(_facts, _step, _way), do: nil

  # -- the backup settings (the pane's §3.12, S2 and S3) -------------------------

  # Where Backup settings shows: whether the recovery passphrase is set, with
  # Change, and the line that says the server keeps an S3 copy.
  defp backup(%{"recipient_set" => set?} = snapshots) when is_boolean(set?) do
    words = Copy.backup_words(set?)

    %{
      "passphrase" => %{"label" => words.label, "value" => words.value, "footer" => words.footer},
      "change" => action(:change_passphrase),
      "s3" => if(s3_bucket(snapshots), do: words.s3)
    }
  end

  defp backup(_snapshots), do: nil

  # The bucket of the server's S3 copy, from its target's destination.
  defp s3_bucket(%{"targets" => targets}) when is_list(targets) do
    case Enum.find(targets, &match?(%{"id" => "s3", "configured" => true}, &1)) do
      %{"destination" => "s3://" <> _rest = destination} -> URI.parse(destination).host
      _none -> nil
    end
  end

  defp s3_bucket(_snapshots), do: nil

  # -- the screen's help page (the pane's R7 and §4) ------------------------------

  defp anchor(%{"action" => %{"id" => "approve_computer"}}, _facts), do: "add-a-computer"
  defp anchor(_view, %{join: %{}}), do: "add-a-computer"

  defp anchor(%{"state" => "problem", "detail" => detail}, facts),
    do: problem_anchor(detail, facts)

  defp anchor(%{"state" => "off"}, _facts), do: "what-you-need"

  defp anchor(%{"state" => state}, _facts) when state in ~w(connect candidate),
    do: "set-up-your-server"

  defp anchor(%{"state" => "creating"}, %{role: :primary}), do: "set-up-your-server"
  defp anchor(%{"state" => state}, _facts) when state in ~w(on primary), do: "on-your-server"
  defp anchor(%{"state" => "retired"}, _facts), do: "when-the-server-is-gone"
  defp anchor(_view, %{role: :primary}), do: flow_anchor(:move)
  defp anchor(_view, facts), do: flow_anchor(device_flow(facts))

  defp problem_anchor(%{"kind" => "cannot_reach"}, _facts), do: "when-the-server-is-gone"

  defp problem_anchor(%{"kind" => kind}, _facts) when kind in ~w(not_set_up waited_too_long),
    do: "set-up-your-server"

  defp problem_anchor(%{"kind" => kind}, _facts)
       when kind in ~w(update server_older server_ahead),
       do: "updates"

  defp problem_anchor(%{"kind" => "disk_full"}, _facts), do: "server-disk"

  defp problem_anchor(%{"kind" => kind}, _facts) when kind in ~w(backup_old backup_failed),
    do: "backups"

  defp problem_anchor(%{"kind" => "not_ready"}, _facts), do: "the-move"
  defp problem_anchor(%{"kind" => "return_failed"}, facts), do: flow_anchor(device_flow(facts))

  defp flow_anchor(:move), do: "the-move"
  defp flow_anchor(:return), do: "move-back"
  defp flow_anchor(:restore), do: "when-the-server-is-gone"

  # On a linked computer: a restore here, a move back to it, or the move
  # from it.
  defp device_flow(%{returning: %{"kind" => "local"}}), do: :restore
  defp device_flow(%{returning: returning}) when returning != nil, do: :return

  defp device_flow(facts) do
    cond do
      restore_running?(facts) -> :restore
      started?(facts.return) -> :return
      true -> :move
    end
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
    do: view("moving", sentence(:waiting, facts), nil, forward_detail(facts))

  defp settled(%{move: %{"phase" => phase}} = facts) when phase in @moving,
    do: view("moving", sentence(:moving, facts), nil, forward_detail(facts))

  defp settled(%{move: %{"phase" => phase}} = facts) when phase in @undoing,
    do: view("undone", sentence(:undone, facts), nil, %{}) |> noted(undone_reason(facts.move))

  defp settled(%{linked: false} = facts), do: retired(facts)
  defp settled(%{link: %{primary: %{status: :revoked}}} = facts), do: retired(facts)
  defp settled(facts), do: desktop(facts)

  # The move from this computer under way: its steps, its route to the
  # server, and the bytes sent while they move (the pane's §3.13).
  defp forward_detail(%{move: %{"phase" => phase, "candidate" => to}} = facts) do
    at = if phase in ["committing", "committed"], do: 3, else: 2

    %{"steps" => steps(:move, {at, "active"}, facts), "route" => route(to, "forward", facts)}
    |> put_some("transfer", transfer(facts, :send, :sent))
  end

  defp retired(facts), do: view("retired", retired_sentence(facts), nil, %{}) |> restorable(facts)

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

    (Enum.find_value(checks, & &1.(facts)) || on(facts)) |> restartable(facts)
  end

  # The server's restart a change from this computer waits for (M97 D28c):
  # first beside whatever this screen offers, while the server's own
  # `home.status` says its restart is required, under the name this computer
  # knows it by; Settings offers the same step (`restart_server_action/1`).
  defp restartable(view, %{primary_home: %{"restart" => %{"required" => true}}} = facts) do
    case get_in(facts, [:link, :primary, :name]) do
      name when is_binary(name) and name != "" ->
        restart = action(:restart_server, %{name: name})

        update_in(
          view,
          ["detail"],
          &Map.update(&1, "alternatives", [restart], fn more -> [restart | more] end)
        )

      _no_name ->
        view
    end
  end

  defp restartable(view, _facts), do: view

  # No session with the server for ten minutes while this computer is awake:
  # what to check, and, where this computer can take the home back from its
  # own copy, that Restore here is the answer once it is gone for good.
  defp away(%{link: %{primary: %{status: status} = link}} = facts)
       when status in [:unreachable, :stale] do
    if (Map.get(link, :down_ms) || 0) >= @unreachable_ms do
      restore? = match?(%{"id" => "restore_here"}, restore_offer(facts))
      note = sentence(:cannot_reach_note, facts, %{restore: restore?})

      problem("cannot_reach", sentence(:cannot_reach, facts), nil, %{"note" => note})
    end
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
    do:
      problem("server_older", sentence(:server_older, facts), nil, %{
        "note" => sentence(:server_older_note, facts)
      })

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
    snapshots = get_in(facts, [:primary_home, "snapshots"])

    detail = %{
      "server" => on_server(facts),
      "backups" => backups(snapshots),
      "copies_bytes" => facts.copies_bytes,
      "disk_used" => get_in(facts, [:primary_home, "disk", "used"]),
      "alternatives" =>
        [action(:back_up_now), action(:add_computer)] ++ List.wrap(move_back(facts))
    }

    view(
      "on",
      on_sentence(facts),
      nil,
      detail
      |> webhooks(get_in(facts, [:primary_home, "webhooks"]))
      |> put_some("backup", backup(snapshots))
      |> put_some("not_yet", linked_not_yet(facts))
    )
    |> reviewing(facts)
  end

  # A computer that moved before M97 offers nothing until the owner reviews
  # what Fermix on the server may use on it (M97 §7.3). Its switches, under
  # This computer, are where it is done: changing any is the review, and the
  # screen's one step keeps them as they are, so the five things are set in
  # one place.
  defp reviewing(view, facts) do
    if Map.get(facts, :offers_review),
      do: %{view | "action" => action(:review_offers)} |> noted(sentence(:review_note, facts)),
      else: view
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

  # Nothing is the owner's to do while this computer connects: Cancel
  # stands beside it.
  defp return_view(%{"phase" => "enrolling"}, facts),
    do:
      view("creating", sentence(:return_connecting, facts), nil, %{
        "alternatives" => [return_cancel()],
        "steps" => steps(:return, {0, "active"}, facts)
      })

  defp return_view(%{"phase" => phase}, facts) when phase in @ended,
    do: problem("return_failed", sentence(:return_failed, facts), move_back_again(facts), %{})

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

  # Fermix has not moved yet: Move now moves it, and the screen says so.
  defp return_ready(state, facts) do
    view("ready", sentence(:return_ready, facts), action(:move_now), %{
      "server" => %{"name" => facts.return.from},
      "waits_until" => state["listen_until"],
      "alternatives" => [return_cancel()],
      "steps" => steps(:return, {1, "yours"}, facts)
    })
    |> noted(waits(:return_waits, state["listen_until"], facts, %{}))
  end

  # The home comes back: received, then put in place here.
  defp return_moving(facts) do
    at = if return_progress(facts) == :progress_return_placing, do: 3, else: 2

    detail =
      %{
        "steps" => steps(:return, {at, "active"}, facts),
        "route" => route(return_server(facts), "back", facts)
      }
      |> put_some("transfer", transfer(facts, :receive, :received))

    view("moving", sentence(:return_moving, facts), nil, detail)
  end

  # The server a move back takes the home from: as the return's record names
  # it, or, before the record is kept, as its candidate's code named it.
  defp return_server(%{return: %{from: from}}), do: from
  defp return_server(%{returning: %{"primary" => %{"name" => name}}}), do: name
  defp return_server(_facts), do: nil

  # The server undid the move before its marker: it is the primary again,
  # and this computer's candidate still waits.
  defp return_undone(facts) do
    view("undone", sentence(:return_undone, facts), action(:try_again), %{
      "alternatives" => [return_cancel()],
      "steps" => steps(:return, {1, "yours"}, facts)
    })
  end

  # A move back left part-way by a stop between two writes (a candidate with
  # no record, a record with no candidate, or a state that cannot be read):
  # Cancel clears what is left where no move can be under way.
  defp return_stopped(facts, cancellable?) do
    act = if cancellable?, do: return_cancel()
    problem("return_failed", sentence(:return_stopped, facts), act, %{})
  end

  defp restore_view(%{"phase" => "failed"} = state, facts) do
    problem("return_failed", sentence(:restore_failed, facts), restore_offer(facts), %{
      "note" => state["sentence"]
    })
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
  # it was not added. Cancel makes it its own home again: beside the step
  # that runs or waits, and the one step left once it was not added.
  defp joining(%{join: %{"phase" => phase} = join} = facts) do
    case phase do
      "dialing" ->
        view("creating", sentence(:join_dialing, facts, %{to: join["server"]}), nil, %{
          "alternatives" => [action(:cancel)]
        })

      "awaiting_approval" ->
        said = sentence(:join_waiting, facts, %{to: join["server"], sas: join["sas"]})
        view("creating", said, nil, %{"alternatives" => [action(:cancel)]})

      "denied" ->
        view("creating", join["sentence"], action(:cancel), %{})
    end
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

  # The ask leads: Add it is the step, Do not add it beside it, then the step
  # the screen led with before (a review's), then the others.
  defp ask(view, joiner, facts) do
    first = [action(:deny_computer) | List.wrap(view["action"])]
    values = %{name: joiner.name, system: system(joiner.platform)}

    %{
      view
      | "sentence" => sentence(:computer_asks, facts, values),
        "action" => action(:approve_computer, %{joiner: "#{joiner.name} (#{joiner.platform})"})
    }
    |> update_in(
      ["detail"],
      &Map.update(&1, "alternatives", first, fn more -> first ++ more end)
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

  # The server's own screen: its summary rides inside each linked desktop's
  # `home.status` (`primary_home`), so it carries nothing nested past the
  # protocol's depth bound: no webhooks and no backup settings, which its
  # desktops draw (a Change's needs would sit one level past it).
  defp server(facts) do
    disk = disk_problem(facts.disk, :server_disk_full)

    disk || backup_failed(facts) || server_backup(facts) ||
      asking(
        view("primary", sentence(:primary, facts), nil, %{
          "alternatives" => [action(:add_computer)]
        })
        |> not_yet_listed(not_yet_entries(facts, @server_not_yet, nil)),
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
  # `home.status`; absent from an older server's), with the one step a
  # tailnet takes once and the docs page that holds the rest (Cloudflare
  # Tunnel instead, port 443, the ingress, the wait for a new address);
  # none when it serves nothing.
  defp webhooks(detail, served) when served in [nil, []], do: detail

  defp webhooks(detail, served) do
    Map.put(detail, "webhooks", %{
      "sentence" => Copy.summary_sentence(:webhooks, %{carried: carried(served)}),
      "mounts" => Enum.map(served, &mount/1),
      "notes" => [Copy.summary_sentence(:webhooks_tailnet, %{})],
      "url" => Copy.always_on_docs_url("webhooks")
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

  # What the server serves, each kind once.
  defp carried(served), do: served |> Enum.map(&port_of(&1["kind"])) |> Enum.uniq()

  defp port_of("whatsapp"), do: :whatsapp
  defp port_of("cue"), do: :cues

  # -- what Always On does not do yet (M97) -----------------------------------------

  defp not_yet_listed(view, entries),
    do: update_in(view, ["detail"], &put_some(&1, "not_yet", entries))

  # The ids among `place`'s that this engine's own facts turn on (`gather/5`'s
  # `not_yet`), each `{id, sentence}` in the list's order, the dev plugins
  # naming the server `name` (nil: "your server").
  defp not_yet_entries(facts, place, name) do
    own = Map.get(facts, :not_yet, [])
    values = %{machine: machine(facts.host_os), to: name}

    for id <- Copy.not_yet_ids(),
        id in own and id in place,
        do: %{"id" => Atom.to_string(id), "sentence" => Copy.not_yet(id, values)}
  end

  # On a linked computer: its server's entries, as the server's own screen
  # says them (the home's settings and the server's), then this computer's
  # own, its dev plugins naming its server.
  defp linked_not_yet(facts) do
    (served_not_yet(facts) ++ not_yet_entries(facts, @computer_not_yet, link_name(facts)))
    |> Enum.uniq_by(& &1["id"])
  end

  # The server's entries from its own `home.status` summary, but one this
  # screen's Funnel mounts already say (`detail.webhooks` starts with
  # WhatsApp's sentence); none from a server that sends none.
  defp served_not_yet(%{primary_home: %{"summary" => %{"detail" => %{"not_yet" => said}}} = home})
       when is_list(said) do
    mounted = for %{"kind" => "whatsapp"} <- home["webhooks"] || [], do: "whatsapp"

    for %{"id" => id, "sentence" => sentence} <- said,
        is_binary(id) and is_binary(sentence) and id not in mounted,
        do: %{"id" => id, "sentence" => sentence}
  end

  defp served_not_yet(_facts), do: []

  # -- the server before its move ------------------------------------------------

  defp candidate(%{move: %{"phase" => "expired"}} = facts),
    do: problem("waited_too_long", sentence(:server_waited_too_long, facts), nil, %{})

  defp candidate(%{move: %{"phase" => "failed"}} = facts),
    do: problem("not_set_up", sentence(:server_not_set_up, facts), nil, %{})

  defp candidate(%{move: %{"phase" => phase}} = facts) when phase in @receiving,
    do: view("candidate", sentence(:candidate_receiving, facts), nil, %{})

  defp candidate(facts), do: view("candidate", sentence(:candidate_waiting, facts), nil, %{})

  # -- problems shared by more than one place ------------------------------------

  # How full the server's disk is, and what to do about it.
  defp disk_problem(%{"used" => used, "nearly_full" => true}, key),
    do:
      problem("disk_full", Copy.summary_sentence(key, %{percent: round(used * 100)}), nil, %{
        "note" => Copy.summary_sentence(:disk_note, %{})
      })

  defp disk_problem(_disk, _key), do: nil

  # The newest try that failed of a place whose backup has not been stored
  # since (`Snapshot.Status` keeps its error until one is): where it went,
  # then in its note its own words and when: Back up now tries again. The
  # note is in `detail`, so a later try that fails in other words moves the
  # key by itself.
  defp backup_failed(facts) do
    case failed_tries(backup_snapshots(facts)) do
      [] ->
        nil

      tries ->
        {place, at, error} = Enum.max_by(tries, &elem(&1, 1), DateTime)
        values = %{place: place, at: at, zone: facts.zone, error: error}

        problem("backup_failed", sentence(:backup_failed, facts, values), :back_up_now, %{
          "note" => sentence(:backup_failed_note, facts, values),
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

  # A problem's one step, or none where no step of the owner's fixes it.
  defp problem(kind, sentence, act, extra) when kind in @problems and is_map(extra) do
    detail =
      Map.merge(%{"kind" => kind, "note" => nil, "seen_at" => nil, "alternatives" => []}, extra)

    view("problem", sentence, problem_action(act), detail)
  end

  defp problem_action(nil), do: nil
  defp problem_action(%{"id" => _id} = act), do: act
  defp problem_action(act) when is_atom(act), do: action(act)

  # A screen's one secondary sentence, where it has one.
  defp noted(view, nil), do: view
  defp noted(view, note) when is_binary(note), do: put_in(view, ["detail", "note"], note)

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

  # Every action a record, then what Details draws, the notice, the outcome,
  # the screen's help page and the key.
  defp finish(view, facts) do
    summary =
      view
      |> Map.update!("action", &(&1 && record(&1, facts)))
      |> Map.update!("detail", &finish_detail(&1, view, facts))
      |> Map.put("notice", notice(view, facts))
      |> Map.put("outcome", outcome(view, facts))
      |> Map.put("help", Copy.always_on_docs_url(anchor(view, facts)))

    Map.put(summary, "key", key(summary))
  end

  defp finish_detail(detail, view, facts) do
    detail
    |> records_at("alternatives", facts)
    |> backup_record(facts)
    |> put_some("lines", lines(view, facts))
    |> put_some("progress", progress(view, facts))
  end

  defp backup_record(%{"backup" => %{"change" => change} = backup} = detail, facts),
    do: %{detail | "backup" => %{backup | "change" => record(change, facts)}}

  defp backup_record(detail, _facts), do: detail

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
      "key" => action_key(id, label, confirm, needs, target_of(act, values, facts))
    }
  end

  defp needs(:restore_here, _facts), do: ["recovery_passphrase"]
  defp needs(:approve_computer, _facts), do: ["sas"]
  defp needs(:change_passphrase, _facts), do: ["new_recovery_passphrase"]
  defp needs(act, facts) when act in [:move_now, :try_again], do: [passphrase_need(facts)]
  defp needs(_act, _facts), do: []

  # A move back checks the server's own key, which every move to it set;
  # here, the key this home's snapshots keep, or a new one when none is set.
  defp passphrase_need(%{role: :device}), do: "recovery_passphrase"
  defp passphrase_need(%{snapshots: %{"recipient_set" => true}}), do: "recovery_passphrase"
  defp passphrase_need(_facts), do: "new_recovery_passphrase"

  # What the owner accepts first: a move, a restore (naming the date of the
  # backup it takes), forgetting a server, or a new recovery passphrase.
  defp confirm(:cancel, %{forget: true}, facts), do: sentence(:confirm_forget, facts)

  defp confirm(:change_passphrase, _values, facts),
    do: sentence(:confirm_change_passphrase, facts)

  defp confirm(:restore_here, %{at: at}, facts),
    do:
      sentence(:confirm_restore_here, facts, %{
        telegram: :telegram in facts.return_costs,
        at: at,
        zone: facts.zone
      })

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
      reviewed ++ for(%{status: :warn} = item <- facts.move_items, do: item.sentence),
      machine(facts.host_os)
    )
  end

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
      state_lines(view, facts, ctx),
      move_back_lines(view, facts, ctx),
      link_lines(view, facts, ctx)
    ])
  end

  # Facts only (the pane's R8): until when a held server waits is the
  # screen's note, never a line.
  defp state_lines(%{"state" => state, "detail" => detail} = view, facts, ctx)
       when state in @detailed_states do
    Enum.concat([
      server_lines(detail["server"], ctx),
      backup_lines(detail["backups"], ctx),
      bucket_lines(view, facts, ctx),
      value_line(:copies, detail["copies_bytes"], ctx),
      value_line(:disk, detail["disk_used"], ctx)
    ])
  end

  defp state_lines(_view, _facts, _ctx), do: []

  # On: the bucket the server keeps its S3 copy in, where it keeps one.
  defp bucket_lines(%{"state" => "on"}, facts, ctx) do
    case s3_bucket(get_in(facts, [:primary_home, "snapshots"])) do
      nil -> []
      bucket -> [Copy.summary_line(:s3_bucket, bucket, ctx)]
    end
  end

  defp bucket_lines(_view, _facts, _ctx), do: []

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
      week_occurrence(facts, :notice_server_backup_week) || change_occurrence(view, facts) ||
        sandbox_occurrence(facts) || joined_occurrence(view, facts)

  defp occurrence(view, %{role: role} = facts) when role in [:primary, :device] do
    Enum.find_value(
      [
        &reach_occurrence/2,
        &review_occurrence/2,
        &ready_occurrence/2,
        fn _view, facts -> week_occurrence(facts, :notice_backup_week) end,
        &moved_occurrence/2,
        &change_occurrence/2,
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

  # The server's sandbox or coding approval changed from a computer (M97
  # §19.5): the newest change told for a week, once, on the server and on
  # every linked computer, which names the server as it knows it. Its id is
  # its own: what it changed, and when to the millisecond.
  defp change_occurrence(
         _view,
         %{computer_changes: [%{at: %DateTime{} = at} = change | _]} = facts
       ) do
    if DateTime.diff(facts.now, at, :second) < @computer_change_s do
      values = %{name: change.computer, change: {change.what, change.value}}
      %{"what" => what, "at" => said_at} = ChangedFromComputer.view(change)

      {"computer_change:#{what}:#{said_at}",
       sentence(:notice_computer_change, facts, changed_on(values, facts))}
    end
  end

  defp change_occurrence(_view, _facts), do: nil

  # The server's words for itself; a linked computer's for its server, by
  # its name where it knows one.
  defp changed_on(values, %{role: :primary}), do: Map.put(values, :server, :this)
  defp changed_on(values, facts), do: Map.put(values, :server, link_name(facts) || :yours)

  defp ready_occurrence(%{"state" => "ready"}, facts),
    do: {"ready:" <> target(facts)["candidate_id"], sentence(ready_notice(facts), facts)}

  defp ready_occurrence(_view, _facts), do: nil

  defp ready_notice(%{role: :device}), do: :notice_return_ready
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

    [
      link_deadline(facts),
      backup_deadline(since, facts),
      week_deadline(since, facts),
      change_deadline(facts)
    ]
  end

  defp deadlines(%{role: :primary, link: %{desktops: [_ | _]}} = facts) do
    since = backup_since(facts)

    [
      backup_deadline(since, facts),
      week_deadline(since, facts),
      sandbox_deadline(facts),
      change_deadline(facts)
    ]
  end

  defp deadlines(%{role: :primary} = facts), do: expiries(facts.candidates, facts)

  defp sandbox_deadline(%{server_sandbox: %DateTime{} = at} = facts),
    do: ms_until(DateTime.add(at, @server_sandbox_s, :second), facts)

  defp sandbox_deadline(_facts), do: nil

  defp change_deadline(%{computer_changes: [%{at: %DateTime{} = at} | _]} = facts),
    do: ms_until(DateTime.add(at, @computer_change_s, :second), facts)

  defp change_deadline(_facts), do: nil

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

  # Whether a linked computer's switches wait for the owner's review.
  defp offers_review(true, opts) do
    switches = Keyword.get_lazy(opts, :computer_switches, &Switches.current/0)
    not Switches.reviewed?(switches)
  end

  defp offers_review(false, _opts), do: false

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

  # The changes from a computer to the server's limits (M97 §19.5), newest
  # first: on the server, what its `home.status` read (`Management.Home`); on
  # a linked computer, its server's `home.status`, where a change this engine
  # does not know is left out.
  defp computer_changes(:primary, status), do: Map.get(status, :computer_changes, [])

  defp computer_changes(:device, %{primary_home: %{"computer_changes" => views}})
       when is_list(views) do
    views
    |> Enum.flat_map(fn view ->
      case ChangedFromComputer.from_view(view) do
        {:ok, change} -> [change]
        :error -> []
      end
    end)
    |> ChangedFromComputer.newest_first()
  end

  defp computer_changes(_role, _status), do: []

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

  # What runs only on this computer and so here again after a move back,
  # which a desktop's Move now confirm says. The computer that sets Always
  # On up says what stops at Move now, from the review's own items.
  defp stays_here(home, :device = _role, host_os, reads) do
    case MoveReadiness.stays_here(home, host_os == :macos, reads) do
      {:ok, features} -> features
      {:error, _sentence} -> []
    end
  end

  defp stays_here(_home, _role, _host_os, _reads), do: []

  # What this engine's own facts turn on of what Always On does not do yet
  # (M97): its settings (`MoveReadiness.not_yet/2`), then whether this
  # computer records its history (`ComputerHistory.recorder?/0`, `opts`'
  # `:recorder?` in a test). The summary lists each where it applies.
  defp not_yet(_home, :candidate, _host_os, _reads_opts), do: []

  defp not_yet(home, _role, host_os, {reads, opts}) do
    settings = MoveReadiness.settings(home, reads)
    recorder? = Keyword.get_lazy(opts, :recorder?, &ComputerHistory.recorder?/0)
    history = if recorder?, do: [], else: [:computer_history]
    MoveReadiness.not_yet(settings, host_os == :macos) ++ history
  end

  # What a move back costs that this desktop's settings turn on, which its
  # confirm names: the settings of the home it left, the facts it holds.
  # The notetaker this desktop kept is its own (`:meet_notetaker` in a test).
  defp return_costs(home, :device, reads, opts),
    do:
      home
      |> MoveReadiness.settings(reads)
      |> MoveReadiness.costs(Keyword.take(opts, [:meet_notetaker]))

  defp return_costs(_home, _role, _reads, _opts), do: []

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
