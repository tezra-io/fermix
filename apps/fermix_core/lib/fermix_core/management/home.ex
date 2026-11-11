defmodule FermixCore.Management.Home do
  @moduledoc """
  The `home.*` management family (M75 §14): the one source every surface
  draws the home from, answered locally in every role.

  `home.status` is the whole picture: `role`, `epoch` (null before the
  home's first boot as the primary), `moved` (the marker, or null), and
  `snapshots` (the view `home.snapshots.status` answers alone), and what the
  rail knows (`FermixCore.Home.Link.status/0`):

    * `primary`: in the device role with a desktop link, the primary this
      desktop reaches: `name`, `connected`, `status` (one word from a closed
      set, `@primary_statuses`: `connected`, `renewing` (a session opening
      with nothing known wrong, drawn quietly), `unreachable`, `revoked` or
      `stale`, as `FermixChannels.Desktop.Relay` says them), `since` (null
      while not connected), `epoch` (the highest primary epoch seen),
      `sentence`, and `path` while a session is up and its helper has named
      it: `direct` or `relay` (through Fermix's relay), absent otherwise;
      null otherwise.
    * `desktops`: on the primary, its desktop peers: `device_id`, `name`,
      `connected` and `since` (null while not connected); empty otherwise.
      Kept for the apps that read it; `computers` says more of the same.
    * `computers` (M97 §3.2): on the primary, each computer of the home
      (`FermixCore.Computers.list/1`): `device_id`, `name`, `platform`
      (`macos`, `linux`, or null before it said), `engine_version`,
      `connected`, `since`, `last_seen`, `path` (`direct` or `relay` while
      its session is up and it said, else null), `offers` (each `{id,
      label, state, sentence, detail}`: what it offers in its session,
      nothing before its first offers; while away, what it last offered;
      `label` the words it goes by, `Computers.Offers.label/1`, null for one
      this engine does not know), `backups` and `this_computer` (true on the
      row of the linked computer whose forward this answers, so its app
      never offers Remove on its own row; false everywhere else); empty
      otherwise. Optional: a server older than the computer record answers
      none, and one older than `label` and `this_computer` answers neither.
    * `primary_home`: on a linked desktop, the primary's own `home.status`
      (its recovery, enrollment, candidates and move), asked within
      `Management.Placement.composed_deadline_ms/0`; null on any other engine
      and while the primary's answer is missing, when `primary_missing` holds
      the sentence that says why (null otherwise). A desktop's own snapshot
      status file is a retired copy, so its `snapshots` lists no target: the
      primary's are in `primary_home`.

  `screen` (M97 §7.4): on a linked computer, while Fermix on its server
  controls this computer's screen, `since` (when it took it) and the
  `sentence` the app's mark carries, with Stop beside it
  (`computer.screen.stop`); null while it does not, absent on every other
  engine. A change tells the Always On watch (`:screen`).

  `join` (M97 §3.1): on a computer joining a home (`Home.Join`), `phase`
  (`dialing`, `awaiting_approval` or `denied`), the `server`'s name, `sas`
  (the six digits this computer shows once the server answered, which the
  owner types where the home asks; else null) and the `sentence`; absent on
  every other engine. The digits are shown here alone: the home's other
  screens name the computer that asks, never its digits.

  Enrollment and the move (`FermixCore.Management.HomeMove`):

    * `enrollment`: the enrollment window on the primary (`state` and
      `expires_at`, never the code), null when none was opened.
    * `candidates`: the candidate primaries the primary holds; empty in any
      other role.
    * `move`: the move this home started or, on a candidate, the one it waits
      for: `phase`, `candidate` and `sentence`; null when there is none.

  `secrets_missing`: on the primary, the ids (`secret.set`'s) of the secret
  references in its settings that did not resolve on this host
  (`FermixCore.Home.MoveSecrets.missing/1`): a keychain reference a restore
  carried here without its value, a locked keychain, a file the store lacks.
  Empty in any other role.

  `webhooks`: on the primary, what it serves on loopback that the internet
  must reach (Always On, "Inbound webhooks without a public IP"), each
  `{kind, ref, port}`: `whatsapp` (`ref` null) on the web listener's port
  while the WhatsApp channel is on, then each enabled cue webhook source with
  a URL (`cue`, `ref` its name) on the door's port, by name. Whether a source
  has a URL is its sentinel in the settings, never a read of the secret
  store, and the URL itself is never here: `cues.sources.url.get` alone
  hands it out. Empty in any other role, so a linked desktop's summary prints
  its server's, from `primary_home`, and from a verb with no engine tree
  (`supervised: false`), since a stopped Fermix serves nothing.

  `summary` is where Always On stands in one sentence and at most one action
  (`FermixCore.Management.HomeSummary`, M75 lean v1 §7, Always On setup §3),
  gathered from the rest of this record and, on a desktop, whether Restore
  here's job runs (the job family's own record; a tree without the job
  family, a test or a verb with no engine, has none), with its `key`; every
  surface draws it.

  **A move back the home went past.** On a desktop whose move back was
  asked at an older epoch than its link has since reached (another desktop
  took the home back), a read stops that candidate and removes it with the
  return's record, saying nothing to the owner (Always On's move back design
  §14); the log says it.

  **The wait** (`status_after/3`, `home.status {after, wait_ms}`): answered
  at once when the summary's key is not `after`; else held in the caller,
  subscribed to the Always On watch (`Home.StatusWatch`), reading the
  summary again at each word from it, until its key differs or `wait_ms`
  (at most `max_wait_ms/0`) passed. Off tells nothing and a candidate runs
  no watch, so a wait there runs out. The caller stays subscribed until it
  exits: the daemon serves each request in a process of its own. `disk` is how full this primary's disk is (`Home.Disk.usage/2`:
  `used`, a fraction, and `nearly_full` from 85%), null in any other role and
  when it cannot be read, so a linked desktop reads its server's from
  `primary_home`. `version` is this engine's.

  **The server leads** (M97 §3.4, D14). On an Always On server
  (`Home.AlwaysOn.server?/1`), `update` is what its update may install, from
  the release table it keeps (`Home.ReleaseTable`) and its computers:
  `running` (this engine's version), `eligible` (the newest release, at or
  above it, that the app of each system whose computers keep backups
  carries, `Home.Releases.eligible/3`; null when none, or when no table was
  read: the update installs nothing then), `held` (a newer release not
  eligible yet: its `version`, the systems it `waits_for` and a `sentence`
  that names no version; null when there is none), `ahead_of_apps` (this
  engine runs past what some backup system's app carries, an owner's
  override) and `table` (`read_at`, when the table was last read, and the
  `sentence` of a fetch that failed or of why none was read, each null
  otherwise). Null on every other engine. `update_ceiling` is `update`'s
  `eligible`, null where `update` is: the field every server's update script
  reads, kept so a script an older first boot wrote follows the server too.
  `restart_hold` is what holds the engine's restart after an update
  (`Home.RestartHold`): a move under way, or work in progress on a computer
  for at most ten minutes, `{reason, count, wait_s, sentence}`; null when
  nothing does.

  `home.snapshots.run` starts a snapshot now (`busy` while one runs);
  `home.snapshots.passphrase` derives a new recovery key from
  `recovery_passphrase` and keeps only its public half in
  `[fermix_core.snapshots] recipient` (`Snapshot.Recovery.set/2`, the
  derivation a move's check shares): the passphrase is never stored, logged
  or answered; the answer's `sentence` says that snapshots written before it
  open only with the earlier passphrase, and each attempt in the status names
  the key it was written for (`key_id`). Both are the primary's; the device
  role answers `unavailable` with the sentence that says so.

  Test seams in `opts`: `:home`, `:engine_role` (a `Role` record), `:config`
  (the snapshots section), `:scheduler` (the scheduler's name, or nil for
  none), `:profile`, `:save_recipient` (in place of
  `Snapshot.Settings.put_recipient/2`), and `:link_status` (in place of
  `FermixCore.Home.Link.impl().status/0`), `:settings_snapshot` (a 0-arity
  reader of the live settings, `ConfigStore.current_snapshot/0`),
  `:disk_usage` (a 1-arity reader of a home's disk, `Home.Disk.usage/2`),
  `:webhook_settings` (a 0-arity reader of what `webhooks` is read from:
  `%{whatsapp, cues, web_port}`, the WhatsApp channel's and the cues'
  applied settings and the web listener's port, `Setup.Endpoint.port/1`),
  `:version`, `:now`, `:host_os`, `:always_on_server` (a boolean),
  `:release_table` (in place of `Home.ReleaseTable.current/0`),
  `:computer_work` (0-arity, the work in progress on the computers),
  `:return_boot` (in place of
  `Home.Return.boot_done/0`) and `:stop_return` (in place of the rail's,
  which a desktop's move back the home went past is stopped with); `:jobs`
  (the job family Restore here's job runs in); for the wait, `:status_watch` (the
  watch's name) and `:wait_timer` (a 2-arity `Process.send_after/3` to the
  caller, given the message and the delay). `:supervised` is the caller's world for
  the disk's `df` (false from a tree-less verb), and `:unreadable_files` the
  memory that logs what this record reads (the disk, the settings,
  the last review, a desktop's copies) once per stretch it cannot be read
  (`Home.UnreadableFiles`, the default; nil from a tree-less verb).
  `:primary_forward` is the daemon's way to the primary, given only on a
  linked desktop.
  """

  alias FermixCore.BuildInfo
  alias FermixCore.Computers
  alias FermixCore.Computers.Calls
  alias FermixCore.Computers.Computer
  alias FermixCore.ComputerUse.Seat
  alias FermixCore.Cues.Config, as: CuesConfig
  alias FermixCore.Home.AlwaysOn
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Disk
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Join
  alias FermixCore.Home.Link
  alias FermixCore.Home.Moved
  alias FermixCore.Home.MoveSecrets
  alias FermixCore.Home.Releases
  alias FermixCore.Home.ReleaseTable
  alias FermixCore.Home.RestartHold
  alias FermixCore.Home.Return
  alias FermixCore.Home.Role
  alias FermixCore.Home.ServerPrimary
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Home.Snapshot.Recovery
  alias FermixCore.Home.Snapshot.Scheduler
  alias FermixCore.Home.Snapshot.Status
  alias FermixCore.Home.StatusWatch
  alias FermixCore.Home.UnreadableFiles
  alias FermixCore.Management.HomeMove
  alias FermixCore.Management.HomeSummary
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.Placement
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.Endpoint

  require Logger

  @device_sentence "Snapshots are the primary's to write; this engine runs in the device role."
  @candidate_sentence "Snapshots are the primary's to write; this engine is a candidate " <>
                        "waiting for its move."
  @not_running_sentence "Snapshots are not running in this engine."
  @primary_statuses ~w(connected renewing unreachable revoked stale)a
  @max_wait_ms 25_000
  # Each word from the watch is one read again; a wait answers at the first
  # that moved the key, and reads at most this many.
  @max_rereads 64

  @doc "The closed set of words `home.status`'s `primary.status` takes, in order."
  @spec primary_statuses() :: [String.t()]
  def primary_statuses, do: Enum.map(@primary_statuses, &Atom.to_string/1)

  @doc "The capability a refusal of this family names."
  @spec capability() :: String.t()
  def capability, do: "snapshots"

  @doc "`home.status`: the whole picture of this home."
  @spec status(keyword()) :: {:ok, map()}
  def status(opts \\ []) when is_list(opts) do
    {facts, gathered} = gather(opts)
    {:ok, picture(Map.put(facts, :summary, HomeSummary.summary(gathered)))}
  end

  @doc "The longest a `home.status` wait holds, in milliseconds."
  @spec max_wait_ms() :: pos_integer()
  def max_wait_ms, do: @max_wait_ms

  @doc """
  `home.status {after, wait_ms}`: the picture once its summary's key is not
  `after_key`, or when `wait_ms` passed (the moduledoc's *The wait*).
  """
  @spec status_after(String.t(), non_neg_integer(), keyword()) :: {:ok, map()}
  def status_after(after_key, wait_ms, opts \\ [])
      when is_binary(after_key) and is_integer(wait_ms) and wait_ms >= 0 and
             wait_ms <= @max_wait_ms and is_list(opts) do
    {:ok, record} = status(opts)

    if record["summary"]["key"] == after_key and wait_ms > 0,
      do: hold(after_key, wait_ms, opts),
      else: {:ok, record}
  end

  # Subscribed first, then the timer: a change between the read and the
  # subscribe is told by the watch's first word, which always comes unless
  # Always On is off.
  defp hold(after_key, wait_ms, opts) do
    :ok = StatusWatch.subscribe(Keyword.get(opts, :status_watch, StatusWatch), self())
    token = make_ref()
    timer = Keyword.get(opts, :wait_timer, &Process.send_after(self(), &1, &2))
    _timer = timer.({:home_status_wait, token}, wait_ms)
    held(after_key, token, opts, @max_rereads)
  end

  defp held(_after_key, _token, opts, 0), do: status(opts)

  defp held(after_key, token, opts, rereads) do
    receive do
      :home_status_changed -> reread(after_key, token, opts, rereads)
      {:home_status_wait, ^token} -> status(opts)
    end
  end

  defp reread(after_key, token, opts, rereads) do
    {:ok, record} = status(opts)

    if record["summary"]["key"] == after_key,
      do: held(after_key, token, opts, rereads - 1),
      else: {:ok, record}
  end

  defp jobs?(opts),
    do: opts |> Keyword.get(:jobs, []) |> Keyword.get(:server, Jobs) |> GenServer.whereis() != nil

  # Restore here's job runs on this desktop (`Management.AlwaysOn`): the job
  # family's own record, so a restart that ended the job ends it here too.
  defp restoring?(%{role: :device}, opts) do
    if jobs?(opts) do
      {:ok, views} = Jobs.list(Keyword.get(opts, :jobs, []))
      Enum.any?(views, &match?(%{"kind" => "home_restore", "status" => "running"}, &1))
    else
      false
    end
  end

  defp restoring?(_record, _opts), do: false

  @doc """
  The facts `home.status`'s summary is worked out from
  (`HomeSummary.gather/5`), gathered with `opts` exactly as `status/1`
  gathers them: what `FermixCore.Home.StatusWatch` reads (companion protocol
  6), so the summary it watches is the one the apps then read.
  """
  @spec summary_facts(keyword()) :: HomeSummary.facts()
  def summary_facts(opts \\ []) when is_list(opts) do
    {_facts, gathered} = gather(opts)
    gathered
  end

  defp gather(opts) do
    home = home(opts)
    role = role(opts)
    :ok = return_done(home, role, opts)
    link = Keyword.get(opts, :link_status, fn -> Link.impl().status() end).()
    :ok = passed_return(home, role, link, opts)
    move = HomeMove.facts(home, role, link, opts)
    {primary_home, primary_missing, gap} = primary_home(opts)

    facts = %{
      role: role.role,
      epoch: epoch(home),
      moved: moved(home),
      snapshots: snapshots_view(home, role, opts),
      primary: link.primary,
      desktops: link.desktops,
      enrollment: move.enrollment,
      candidates: move.candidates,
      move: move.move,
      primary_home: primary_home,
      primary_missing: primary_missing,
      secrets_missing: secrets_missing(role, opts),
      disk: disk(home, role, opts),
      version: Keyword.get_lazy(opts, :version, &BuildInfo.product_version/0),
      webhooks: webhooks(role, opts),
      computers: computers(home, role, opts),
      asking: asking(opts),
      join: joining(home, role),
      screen: screen(role, opts),
      restart_hold: restart_hold(move.move, opts)
    }

    facts = put_update(facts, role, opts)

    summary_status =
      Map.merge(facts, %{
        primary_too_old: gap == :too_old,
        primary_behind: gap == :behind,
        restoring: restoring?(role, opts)
      })

    gathered = HomeSummary.gather(home, role, link, summary_status, opts)

    {facts, gathered}
  end

  # That this computer took Fermix back (Always On's move back), which the
  # primary's boot could not record: tried again at each read, and logged once
  # while it fails (`Home.UnreadableFiles`). An engine whose boot recorded it,
  # or had none to record, writes nothing here.
  defp return_done(home, %{role: :primary}, opts) do
    case Keyword.get_lazy(opts, :return_boot, &Return.boot_done/0) do
      :recorded ->
        :ok

      :unrecorded ->
        done = Return.done(home, Keyword.get_lazy(opts, :now, &DateTime.utc_now/0))
        memory = Keyword.get(opts, :unreadable_files, UnreadableFiles)
        UnreadableFiles.log_read(Return.path(home), "home status", done, memory)
    end
  end

  defp return_done(_home, _record, _opts), do: :ok

  # A desktop's move back the home went past (Always On's move back design
  # §14: another desktop took the home back, and the link reached it at a
  # newer epoch than the one this one was asked at): its candidate stops and
  # goes with the record, saying nothing to the owner; the log says it.
  defp passed_return(home, %{role: :device}, %{primary: %{epoch: seen}}, opts)
       when is_integer(seen) do
    case Return.read(home) do
      {:ok, %{primary_epoch: asked} = record} when seen > asked ->
        if Map.has_key?(record, :moved_at), do: :ok, else: forget_return(home, seen, opts)

      _none_or_current ->
        :ok
    end
  end

  defp passed_return(_home, _record, _link, _opts), do: :ok

  defp forget_return(home, seen, opts) do
    :ok = Keyword.get(opts, :stop_return, fn -> Link.impl().stop_return() end).()

    with :ok <- Candidate.remove(home),
         :ok <- Return.remove(home) do
      Logger.info("move back: the home moved on to epoch #{seen}; this computer's is dropped")
    else
      {:error, reason} ->
        Logger.error("move back: one the home went past could not be dropped: #{inspect(reason)}")
    end
  end

  # How full a primary's disk is; a desktop reads its server's in
  # `primary_home`, and a disk that cannot be read is said in the log, once
  # while it stays so (`Home.UnreadableFiles`).
  defp disk(home, %{role: :primary}, opts) do
    supervised = Keyword.get(opts, :supervised, true)
    usage = Keyword.get(opts, :disk_usage, &Disk.usage(&1, supervised: supervised))
    read = usage.(home)
    memory = Keyword.get(opts, :unreadable_files, UnreadableFiles)
    :ok = UnreadableFiles.log_read("the disk of #{home}", "home status", read, memory)

    case read do
      {:ok, %{used: used, nearly_full: nearly_full}} ->
        %{"used" => Float.round(used * 1.0, 2), "nearly_full" => nearly_full}

      {:error, _reason} ->
        nil
    end
  end

  defp disk(_home, _record, _opts), do: nil

  # What an Always On server's update may install (M97 §3.4), and the field
  # every update script reads (`update_ceiling`, its `eligible`); null on any
  # other engine.
  defp put_update(facts, role, opts) do
    case update(role, facts, opts) do
      nil -> Map.merge(facts, %{update: nil, update_ceiling: nil})
      update -> Map.merge(facts, %{update: update, update_ceiling: update["eligible"]})
    end
  end

  defp update(role, facts, opts) do
    if always_on_server?(role, facts.epoch, opts) do
      reader = Keyword.get(opts, :release_table, &ReleaseTable.current/0)
      backups = backup_systems(facts.computers)
      update_view(reader.(), facts.version, backups)
    end
  end

  defp update_view({:ok, table, read_at, failure}, running, backups) do
    %{eligible: eligible, held: held, ahead_of_apps: ahead} =
      Releases.eligible(table, running, backups)

    %{
      "running" => running,
      "eligible" => eligible,
      "held" => held_view(held),
      "ahead_of_apps" => ahead,
      "table" => %{"read_at" => iso8601(read_at), "sentence" => failure}
    }
  end

  defp update_view({:error, sentence}, running, _backups) do
    %{
      "running" => running,
      "eligible" => nil,
      "held" => nil,
      "ahead_of_apps" => false,
      "table" => %{"read_at" => nil, "sentence" => sentence}
    }
  end

  defp held_view(nil), do: nil

  defp held_view(%{version: version, waits_for: waits_for}),
    do: %{
      "version" => version,
      "waits_for" => Enum.map(waits_for, &Atom.to_string/1),
      "sentence" => held_sentence(waits_for)
    }

  @doc "The sentence a held release says for the systems it `waits_for`, naming no version."
  @spec held_sentence([Releases.backup_system()]) :: String.t()
  def held_sentence(waits_for) when is_list(waits_for) do
    "A newer Fermix is released. Your server takes it once " <> waits_on(waits_for) <> "."
  end

  defp waits_on([:macos]), do: "the Mac app that carries it is published"
  defp waits_on([:linux]), do: "the Linux app that carries it is published"
  defp waits_on([:macos, :linux]), do: "the Mac and Linux apps that carry it are published"

  defp waits_on(_with_unknown),
    do: "every computer that keeps your backups has updated Fermix and its app carries it"

  # The systems of the computers that keep the home's backups; one that has
  # not said its system could need either app (`Releases.eligible/3`).
  defp backup_systems(computers) do
    computers
    |> Enum.filter(& &1.backups)
    |> Enum.map(&(&1.platform || :unknown))
    |> Enum.uniq()
  end

  # This engine is an Always On server's (`Home.AlwaysOn`): its primary, a
  # Linux package with no app, at an epoch above 1, from the facts its boot
  # recorded and the epoch this record read. A verb with no engine tree
  # recorded none, and a stopped Fermix reads no table: no `update` there.
  # `:always_on_server` in a test.
  defp always_on_server?(%{role: role}, epoch, opts) do
    Keyword.get_lazy(opts, :always_on_server, fn ->
      case Application.get_env(:fermix_core, :host_facts) do
        %{install: install, os: os, linux_app: linux_app} ->
          AlwaysOn.server?(%{
            role: role,
            install: install,
            os: os,
            linux_app: linux_app,
            epoch: epoch
          })

        nil ->
          false
      end
    end)
  end

  # What holds the restart after an update: a move under way, or work in
  # progress on a computer (`Home.RestartHold`).
  defp restart_hold(move, opts) do
    phase = if is_map(move), do: move["phase"]
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    phase |> RestartHold.view(computer_work(opts), now) |> RestartHold.to_map()
  end

  # The work in progress on the home's computers: the invocations that
  # change something and are still waited on (M97 §6,
  # `Computers.Calls.running_effects/1`, each with its `started_at`).
  # `:computer_work` in a test.
  defp computer_work(opts), do: Keyword.get(opts, :computer_work, &running_effects/0).()

  # Only the primary's engine tree waits on computers: a device, a candidate
  # and a verb with no engine tree run no `Calls`, and ask nothing of one.
  defp running_effects do
    if GenServer.whereis(Calls), do: Calls.running_effects(Calls), else: []
  end

  # The home's computers (M97 §3.2), on the primary; none anywhere else. A
  # caller with no engine tree reads a stopped Fermix, whose computers have
  # no session.
  defp computers(home, %{role: role}, opts),
    do: Keyword.get_lazy(opts, :computers, fn -> Computers.list(home: home, role: role) end)

  # The computer whose request this answers (a linked computer's forward),
  # which finds its own row marked in `computers`; nil for every other caller.
  defp asking(opts), do: Computer.asking(Keyword.get(opts, :actor))

  # What the primary serves on loopback that the internet must reach, from
  # its applied settings; a source's URL is its sentinel, never a store read.
  # A verb with no engine tree reads a stopped Fermix, which serves nothing.
  defp webhooks(%{role: :primary}, opts) do
    if Keyword.get(opts, :supervised, true) do
      settings = Keyword.get(opts, :webhook_settings, &live_webhook_settings/0).()
      whatsapp_hook(settings) ++ cue_hooks(settings.cues)
    else
      []
    end
  end

  defp webhooks(_record, _opts), do: []

  defp whatsapp_hook(%{whatsapp: whatsapp, web_port: port}) when port in 1..65_535 do
    if Keyword.get(whatsapp, :enabled, false) == true,
      do: [%{"kind" => "whatsapp", "ref" => nil, "port" => port}],
      else: []
  end

  defp cue_hooks(cues) do
    port = CuesConfig.door_port(cues)

    for %{kind: :webhook, enabled?: true, secrets: %{path_secret: _store}, ref: ref} <-
          CuesConfig.sources(cues),
        do: %{"kind" => "cue", "ref" => ref, "port" => port}
  end

  # The daemon that answers bound the web listener on this port: the
  # resolver refused its boot otherwise.
  defp live_webhook_settings do
    {:ok, web_port} = Endpoint.port()

    %{
      whatsapp: Application.get_env(:fermix_channels, :whatsapp, []),
      cues: Application.get_env(:fermix_core, :cues, []),
      web_port: web_port
    }
  end

  defp secrets_missing(%{role: :primary}, opts),
    do:
      MoveSecrets.missing(
        Keyword.get(opts, :settings_snapshot, &ConfigStore.current_snapshot/0).()
      )

  defp secrets_missing(_record, _opts), do: []

  # A linked desktop adds the primary's own picture, or why it is missing,
  # and whether the server speaks a protocol this engine is too old for
  # (`:too_old`) or one older than this engine's (`:behind`, until its
  # update takes this version).
  defp primary_home(opts) do
    case Keyword.fetch(opts, :primary_forward) do
      {:ok, forward} ->
        case Placement.primary_part(forward, "home.status") do
          {:ok, status} -> {status, nil, nil}
          {gap, sentence} when gap in [:too_old, :behind] -> {nil, sentence, gap}
          {:missing, sentence} -> {nil, sentence, nil}
        end

      :error ->
        {nil, nil, nil}
    end
  end

  @doc """
  The `home.status` record from its facts: the role, the epoch (or nil), the
  marker (or nil), the snapshots view, the summary, this engine's version,
  the rail's `primary` (or nil) and `desktops` (none when absent),
  `HomeMove.facts/4`'s `enrollment`, `candidates` and `move` (null, none and
  null when absent), a linked desktop's `primary_home` and `primary_missing`
  (null when absent), the primary's `disk` (null when absent), the
  `update_ceiling` (null when absent) and the primary's `webhooks` (none when
  absent) and the primary's `computers` (none when absent, the row of the
  linked computer `asking` marked), and the server's `update` and
  `restart_hold` (null when absent). Pure, so the CLI's goldens are built
  from it.
  """
  @spec picture(%{
          required(:role) => Role.role(),
          required(:epoch) => pos_integer() | nil,
          required(:moved) => Moved.marker() | nil,
          required(:snapshots) => map(),
          required(:summary) => map(),
          required(:version) => String.t(),
          optional(:disk) => map() | nil,
          optional(:primary) => map() | nil,
          optional(:desktops) => [map()],
          optional(:enrollment) => map() | nil,
          optional(:candidates) => [map()],
          optional(:move) => map() | nil,
          optional(:primary_home) => map() | nil,
          optional(:primary_missing) => String.t() | nil,
          optional(:secrets_missing) => [String.t()],
          optional(:update_ceiling) => String.t() | nil,
          optional(:update) => map() | nil,
          optional(:restart_hold) => map() | nil,
          optional(:webhooks) => [map()],
          optional(:computers) => [Computer.t()],
          optional(:asking) => String.t() | nil,
          optional(:join) => map() | nil,
          optional(:screen) => map() | nil | :absent
        }) :: map()
  def picture(
        %{
          role: role,
          epoch: epoch,
          moved: moved,
          snapshots: snapshots,
          summary: %{"state" => _state} = summary,
          version: version
        } = facts
      )
      when role in [:primary, :device, :candidate] and is_map(snapshots) and is_binary(version) do
    %{
      "summary" => summary,
      "role" => Atom.to_string(role),
      "epoch" => epoch,
      "moved" => marker(moved),
      "primary" => primary_view(Map.get(facts, :primary)),
      "desktops" => Enum.map(Map.get(facts, :desktops, []), &desktop_view/1),
      "snapshots" => snapshots,
      "enrollment" => Map.get(facts, :enrollment),
      "candidates" => Map.get(facts, :candidates, []),
      "move" => Map.get(facts, :move),
      "primary_home" => Map.get(facts, :primary_home),
      "primary_missing" => Map.get(facts, :primary_missing),
      "secrets_missing" => Map.get(facts, :secrets_missing, []),
      "disk" => Map.get(facts, :disk),
      "version" => version,
      "update_ceiling" => Map.get(facts, :update_ceiling),
      "update" => Map.get(facts, :update),
      "restart_hold" => Map.get(facts, :restart_hold),
      "webhooks" => Map.get(facts, :webhooks, []),
      "computers" =>
        Enum.map(Map.get(facts, :computers, []), &Computer.view(&1, Map.get(facts, :asking)))
    }
    |> put_join(Map.get(facts, :join))
    |> put_screen(Map.get(facts, :screen, :absent))
  end

  # Only on a linked computer: absent everywhere else.
  defp put_screen(record, :absent), do: record
  defp put_screen(record, screen), do: Map.put(record, "screen", screen)

  @screen_sentence "Fermix on your server is controlling this screen."

  @doc "The sentence the mark carries while the server controls this screen."
  @spec screen_sentence() :: String.t()
  def screen_sentence, do: @screen_sentence

  # This computer's screen while its server controls it (M97 §7.4,
  # `ComputerUse.Seat`): the view on a linked computer, `:absent` elsewhere.
  # Seam `:screen` (0-arity, the seat's view).
  defp screen(%{role: :device}, opts) do
    case Keyword.get(opts, :screen, &Seat.view/0).() do
      %{since: %DateTime{} = since} ->
        %{
          "since" => since |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "sentence" => @screen_sentence
        }

      nil ->
        nil
    end
  end

  defp screen(_record, _opts), do: :absent

  # Only on a computer that joins a home: absent everywhere else, so a
  # client before the join reads the record it always read.
  defp put_join(record, nil), do: record
  defp put_join(record, join), do: Map.put(record, "join", join)

  # This computer joining a home (M97 §3.1, `Home.Join`), in the device role
  # it joins in; nil otherwise.
  defp joining(home, %{role: :device}), do: Join.view(home)
  defp joining(_home, _record), do: nil

  @doc """
  A desktop's link to its primary as `home.status` answers it in `primary`
  (nil where there is none), from `FermixCore.Home.Link.status/0`'s
  `primary`.
  """
  @spec primary_view(map() | nil) :: map() | nil
  def primary_view(nil), do: nil

  def primary_view(
        %{name: name, connected: connected, status: status, sentence: sentence} = primary
      )
      when is_boolean(connected) and status in @primary_statuses and is_binary(sentence) do
    %{
      "name" => name,
      "connected" => connected,
      "status" => Atom.to_string(status),
      "since" => iso8601(Map.get(primary, :since)),
      "epoch" => Map.get(primary, :epoch),
      "sentence" => sentence
    }
    |> put_path(connected, Map.get(primary, :path))
  end

  # Added after `home.status`'s minimum: absent while no session is up, or
  # while its helper has not named the path.
  defp put_path(view, true, path) when path in [:direct, :relay],
    do: Map.put(view, "path", Atom.to_string(path))

  defp put_path(view, _connected, path) when path in [nil, :direct, :relay], do: view

  defp desktop_view(%{device_id: id, name: name, connected: connected} = desktop)
       when is_binary(id) and is_boolean(connected) do
    %{
      "device_id" => id,
      "name" => name,
      "connected" => connected,
      "since" => iso8601(Map.get(desktop, :since))
    }
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp marker(nil), do: nil

  defp marker(%{to: to, moved_at: at, epoch: epoch}),
    do: %{"to" => to, "moved_at" => DateTime.to_iso8601(at), "epoch" => epoch}

  @doc "`home.snapshots.status`: the snapshots view on its own."
  @spec snapshots_status(keyword()) :: {:ok, map()}
  def snapshots_status(opts \\ []) when is_list(opts),
    do: {:ok, snapshots_view(home(opts), role(opts), opts)}

  @doc "`home.snapshots.run`: one snapshot now."
  @spec snapshots_run(keyword()) ::
          {:ok, map()} | {:error, {:busy, String.t()} | {:unavailable, String.t(), String.t()}}
  def snapshots_run(opts \\ []) when is_list(opts) do
    with :ok <- primary(role(opts)),
         {:ok, scheduler} <- scheduler(opts) do
      case Scheduler.run_now(scheduler) do
        {:ok, :started} -> snapshots_status(opts) |> started()
        {:error, :busy} -> {:error, {:busy, "home.snapshots.run"}}
        {:error, :not_configured} -> {:error, {:unavailable, capability(), off_sentence(opts)}}
      end
    end
  end

  @doc "`home.snapshots.passphrase`: derive the recovery key and keep its public half."
  @spec snapshots_passphrase(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def snapshots_passphrase(passphrase, opts \\ []) when is_list(opts) do
    with :ok <- primary(role(opts)),
         {:ok, recipient} <- recovery_result(Recovery.set(passphrase, opts)) do
      {:ok, view} =
        snapshots_status(Keyword.put(opts, :config, recipient_config(recipient, opts)))

      key_id = Base.encode16(Recipient.key_id(recipient.public_key), case: :lower)

      {:ok,
       %{
         "recipient" => Recipient.encode(recipient),
         "key_id" => key_id,
         "snapshots" => view,
         "sentence" =>
           "Snapshots from now on open with this passphrase (key #{key_id}); those written " <>
             "before now open only with the earlier passphrase."
       }}
    end
  end

  defp started({:ok, view}), do: {:ok, %{"started" => true, "snapshots" => view}}

  @doc """
  `Snapshot.Recovery`'s answer as this family answers it, for
  `home.snapshots.passphrase` and `home.move.start`: the key, or a passphrase
  the owner must type again (`invalid_params` on `recovery_passphrase`, with
  the sentence), or a key that cannot be read or kept (`unavailable`). The
  settings write's own refusals cross as they are; any other names files on
  this disk, so it goes to the log and the answer stays fixed.
  """
  @spec recovery_result({:ok, Recipient.t()} | {:error, Recovery.error()}) ::
          {:ok, Recipient.t()} | {:error, term()}
  def recovery_result({:ok, %{salt: _salt, public_key: _public_key} = recipient}),
    do: {:ok, recipient}

  def recovery_result({:error, {:not_saved, {:external_change, _sections} = reason}}),
    do: {:error, reason}

  def recovery_result({:error, {:not_saved, {:config_unreadable, _sentence} = reason}}),
    do: {:error, reason}

  def recovery_result({:error, {:not_saved, reason} = error}) do
    Logger.error("recovery passphrase: the recovery key was not saved: #{inspect(reason)}")
    {:error, {:unavailable, capability(), Recovery.error_sentence(error)}}
  end

  def recovery_result({:error, :key_unreadable}),
    do: {:error, {:unavailable, capability(), Recovery.error_sentence(:key_unreadable)}}

  def recovery_result({:error, reason})
      when reason in [:passphrase_too_short, :passphrase_not_text, :wrong_passphrase],
      do: {:error, {:invalid_params, "recovery_passphrase", Recovery.error_sentence(reason)}}

  defp snapshots_view(home, role, opts) do
    status =
      case Status.read(home) do
        {:ok, status} ->
          status

        {:error, reason} ->
          Logger.error("home status: the snapshot status could not be read: #{inspect(reason)}")
          Status.empty()
      end

    # A running scheduler knows the next run; without one, the file says what
    # the last one planned.
    {running, next_run_at} =
      case scheduler(opts) do
        {:ok, scheduler} ->
          %{running: running, next_run_at: next} = Scheduler.info(scheduler)
          {running, next}

        {:error, _none} ->
          {false, status.next_run_at}
      end

    view =
      Status.view(%{status | next_run_at: next_run_at}, %{
        config: config(opts),
        targets: targets(home, opts),
        running: running,
        profile: profile(opts)
      })

    device_view(view, role)
  end

  # The targets of an Always On server's primary, none on any other (D18);
  # `:snapshot_targets` names them for a test.
  defp targets(home, opts),
    do:
      Keyword.get_lazy(opts, :snapshot_targets, fn ->
        Scheduler.targets(ServerPrimary.check(home))
      end)

  # A device writes none of the primary's snapshots, whatever its copy of the
  # section says, and its status file is a retired copy of what it wrote as the
  # primary: no target, recipient or run of its own is shown.
  defp device_view(view, %{role: :primary}), do: view
  defp device_view(view, %{role: :device}), do: retired_view(view, @device_sentence)
  defp device_view(view, %{role: :candidate}), do: retired_view(view, @candidate_sentence)

  defp retired_view(view, sentence) do
    %{
      view
      | "configured" => false,
        "recipient_set" => false,
        "running" => false,
        "next_run_at" => nil,
        "targets" => [],
        "sentence" => sentence
    }
  end

  defp off_sentence(opts) do
    {:ok, view} = snapshots_status(opts)
    view["sentence"]
  end

  defp recipient_config(recipient, opts),
    do: Keyword.put(config(opts), :recipient, Recipient.encode(recipient))

  defp primary(%{role: :primary}), do: :ok
  defp primary(%{role: :device}), do: {:error, {:unavailable, capability(), @device_sentence}}

  defp primary(%{role: :candidate}),
    do: {:error, {:unavailable, capability(), @candidate_sentence}}

  defp scheduler(opts) do
    case Keyword.get(opts, :scheduler, Scheduler) do
      nil ->
        {:error, {:unavailable, capability(), @not_running_sentence}}

      name ->
        if GenServer.whereis(name),
          do: {:ok, name},
          else: {:error, {:unavailable, capability(), @not_running_sentence}}
    end
  end

  defp epoch(home) do
    case Epoch.read(home) do
      {:ok, epoch} ->
        epoch

      :absent ->
        nil

      {:error, reason} ->
        Logger.error("home status: #{Epoch.error_sentence(reason)}")
        nil
    end
  end

  defp moved(home) do
    case Moved.read(home) do
      {:ok, marker} ->
        marker

      :absent ->
        nil

      {:error, reason} ->
        Logger.error("home status: the moved marker could not be read: #{inspect(reason)}")
        nil
    end
  end

  defp home(opts), do: Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)
  defp role(opts), do: Keyword.get_lazy(opts, :engine_role, &Role.recorded/0)

  defp config(opts),
    do:
      Keyword.get_lazy(opts, :config, fn -> Application.get_env(:fermix_core, :snapshots, []) end)

  defp profile(opts) do
    Keyword.get_lazy(opts, :profile, fn ->
      case Application.get_env(:fermix_core, :profile) do
        profile when is_binary(profile) and profile != "" -> profile
        _unset -> "general"
      end
    end)
  end
end
