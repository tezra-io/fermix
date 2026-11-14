defmodule FermixCore.Home.MoveReadiness do
  @moduledoc """
  What the owner reviews before a move (M75): `home.move.readiness
  {candidate_id}` answers it, and `home.move.start` refuses while any item
  blocks (`FermixCore.Home.Move.start/5`).

  Each item is `ok`, `warn` or `block`, with the one sentence the owner reads:

    * `call_in_progress`, first and only while a voice call is in progress
      (`Realtime.CallLease`; `:call_holder` in a test), warns, naming whom
      the call is with: the move restarts this engine, which ends the call
      before the move's capture starts;
    * `keychain_secrets`: the secrets this computer keeps in its keychain
      move with the home, into the server's secret files
      (`FermixCore.Home.MoveSecrets`); one Fermix cannot read, or a
      reference it cannot name, blocks, named as its settings row labels it
      (`Management.Settings.secret_names/1`, `:secret_names` in a test), one
      no row shows counted, and never by its id (logged) or its value.
      Checking reads each value, which opens the keychain (and can raise its
      prompt), and the sentence says so; a start soon after a ready review
      takes the review rather than reading again (`Move.review/3`), so a move
      opens the keychain here and once more in its capture;
    * `engine_version`, by the one rule of what an engine reads
      (`Home.Readable`, M97 D16: a home's format, never the engine that
      wrote it): a server whose Fermix cannot read this home blocks (its
      staging would refuse it anyway, `Archive.install/5`), by the home
      format its enrollment named, or, from an engine before formats, by
      its version, which blocks when it cannot be read. A server whose home
      this computer could not read back is `ok` once a published update for
      this computer's system reads it (M97 §3.4: the server leads; the
      release table read once, `Home.ReleaseTable.fetch/1`, `:release_table`
      in a test, `Home.Releases.restorable?/3`), and blocks otherwise, or
      when the table cannot be read, since the home could never move back
      here; a newer server of this computer's format is `ok` with no table
      read. A move back, to the desktop the home left (a candidate that
      enrolled through the window that desktop opened, `Home.Candidates`'
      `returning`), blocks only a desktop that cannot read the server's
      home;
    * `disk`: the capture needs about twice the home free on this computer
      (`FermixCore.Home.Disk`); short of it, or with the free space unknown,
      it blocks, saying how much is needed; the server needs as much again.
      A home the walk refuses blocks too, naming the path and what to do
      in `fermix home export`'s words (`Archive.collect_sentence/1`);
    * `s3_size`: a home larger than one S3 upload (5 GiB) warns where the
      server keeps its snapshots in S3: it would never back up there;
    * `plugins`: on a server of another OS or architecture, the plugins
      whose installed version the catalog has no build of for it warn,
      named: they stop working after the move. The server installs every
      other one again for itself right after the move
      (`FermixCore.Plugins.Dist.Reinstall`), through the plugin installer;
    * `dev_plugins`, only while this computer's settings name a dev plugin
      folder (`[fermix_core.plugins] dev_local`, in its `machine.toml`), warns:
      the folder and its links to checkouts stay on this computer
      (`FermixCore.Home.DeviceLocal`), so the server runs none of them, and
      the walk never blocks on them;
    * `stays_here`: what the home has turned on that runs only on this
      computer (voice calls, meetings, StackChan on a Mac; `stays_here/2`;
      iMessage is not among them: the Mac carries it for the server, M97
      §6.4, as the move's keep-on block shows)
      stops after the move, each named; with none of them on it is `ok`.
      Voice is this computer's own (its socket): calls from the phone carry
      on at the server when Talk to Fermix is on there and its key is in the
      server's secret store (M87 §07). On
      a move back, what the server's settings turn on of them runs there
      again, named, and is `ok`;
    * `whatsapp`: WhatsApp turned on warns: it stops after the move until
      the owner runs the Tailscale Funnel mount Always On shows once Fermix
      runs there, which gives it an inbound address Meta can reach, and
      points Meta at that address;
    * `slack`: Slack turned on in its Events (webhook) mode warns for the
      same reason, unless it is switched to Socket Mode first;
    * `coding_agents`: coding agents approved here warn that they stop on
      this computer after the move: the approval is this computer's own
      (M98 D5, its `machine.toml`), which stays here, and the server runs
      them only with its own, which the apps' Settings allow after the move
      (M97 D28);
    * `settings`, always `ok` on a move (none on a move back): after the
      move the apps' Settings change Fermix on the server, its sandbox and
      coding agents included, a new server's sandbox starts open, and what
      the server may use on this computer and this computer's own sandbox
      are under This Mac (This computer on Linux), M97 §19.8;
    * `cutover_gap`: a recurring job more than an hour late is skipped, and
      while Telegram is set up (a bot token, and not turned off), its
      messages sent during the move wait until it is done (Telegram keeps
      them, `Channels.Telegram.Poller`);
    * `serves_nothing`: this computer serves nothing during the move;
    * `service`: Fermix run from a terminal (`fermix run`) warns, since the
      move stops it and nothing starts it again
      (`Management.Lifecycle.restarts_itself?/1`): it has to be started again
      to finish the move.

  The last eight (seven on a move back) are `summary_items/4`: what a review reads from this home's
  settings alone, needing neither the keychain nor a walk of the home, so
  `home.status`'s summary builds Move now's confirm from them before any
  review (`Management.HomeSummary`), in the words the review says them.

  `opts`: `:free_bytes` (a 1-arity reader of free space), `:supervised` (for
  `CommandRunner` and the keychain read from a tree-less verb), `:version`
  and `:home_format` (this engine's, `BuildInfo.product_version/0` and
  `Readable.home_format/0`), `:host` (this host's plugin
  target, `Archive.host/1`), `:home_bytes` (the home's size, in place of
  walking it), `:index_opts` (`Plugins.Dist.Index.load/1`'s, the catalog),
  `:restarts_itself` (a boolean, in place of
  `Management.Lifecycle.restarts_itself?/0`). `summary_items/4` also reads
  `:returning` (a boolean, `report/3` gives the candidate's), which tells a
  move back from a move.
  """

  alias FermixCore.BuildInfo
  alias FermixCore.Home.Archive
  alias FermixCore.Home.Archive.ConfigText
  alias FermixCore.Home.Disk
  alias FermixCore.Home.MoveSecrets
  alias FermixCore.Home.Readable
  alias FermixCore.Home.Releases
  alias FermixCore.Home.ReleaseTable
  alias FermixCore.Home.Snapshot.S3
  alias FermixCore.Home.UnreadableFiles
  alias FermixCore.Management.Copy
  alias FermixCore.Management.Lifecycle
  alias FermixCore.Management.Settings
  alias FermixCore.Plugins.Dist.Index
  alias FermixCore.Realtime.CallLease
  alias FermixCore.Setup.MachineFile

  require Logger

  @plugin_lockfile "plugins/installed.json"
  @unreadable_settings "The settings file could not be read; Fermix's log says why."
  # Every id a review can say, in its order: no item is made with another.
  # The management schema and PROTOCOL.md name exactly these.
  @ids ~w(call_in_progress keychain_secrets engine_version disk s3_size plugins dev_plugins
          stays_here whatsapp slack coding_agents settings cutover_gap serves_nothing service)

  @type status :: :ok | :warn | :block
  @type item :: %{id: String.t(), status: status(), sentence: String.t()}
  @type report :: %{ready: boolean(), items: [item()]}

  @doc "The readiness of moving the home at `home` to `candidate` (a `Candidates` record)."
  @spec report(Path.t(), map(), keyword()) :: report()
  def report(home, %{name: name} = candidate, opts \\ [])
      when is_binary(home) and is_binary(name) and is_list(opts) do
    config = read_config(home)
    host = host(opts)

    home_bytes =
      case Keyword.fetch(opts, :home_bytes) do
        {:ok, bytes} -> {:ok, bytes}
        :error -> home_bytes(home)
      end

    macos? = String.starts_with?(host, "macos-")

    items =
      call_in_progress(Keyword.get(opts, :call_holder, &call_holder/0)) ++
        [
          keychain(config, opts),
          version(candidate, this_engine(opts), {system(macos?), opts}),
          disk(home, home_bytes, name, opts),
          s3_size(candidate, home_bytes),
          plugins(home, host, candidate, opts)
        ] ++
        dev_plugins(config, macos?, name) ++
        summary_items(config, macos?, name, Keyword.put(opts, :returning, returning?(candidate)))

    %{ready: not Enum.any?(items, &(&1.status == :block)), items: items}
  end

  @doc """
  The items of a review of the move to the server `name` that read nothing
  but `config` (this home's settings, as `settings/2` reads them) and this
  engine, in the review's order and words: `stays_here` (StackChan only when
  `macos?`), `whatsapp`, `slack`, `coding_agents`, `settings` (not on a
  move back), `cutover_gap`, `serves_nothing`, `service`. `report/3` ends with them, and `home.status`'s
  summary builds Move now's confirm from them before any review. `opts` are
  `report/3`'s.
  """
  @spec summary_items({:ok, String.t()} | {:error, String.t()}, boolean(), String.t(), keyword()) ::
          [item()]
  def summary_items(config, macos?, name, opts)
      when is_boolean(macos?) and is_binary(name) and is_list(opts) do
    returning? = Keyword.get(opts, :returning, false)

    [
      stays_here_item(config, macos?, name, returning?),
      whatsapp(config, name),
      slack(config, name),
      coding_agents(config, macos?, name)
    ] ++
      settings_item(macos?, name, returning?) ++
      [
        item("cutover_gap", :warn, cutover_sentence(config)),
        item(
          "serves_nothing",
          :warn,
          "This computer serves nothing while the move runs: no chat, channels or jobs " <>
            "until #{name} takes over."
        ),
        service(Keyword.get_lazy(opts, :restarts_itself, &Lifecycle.restarts_itself?/0))
      ]
  end

  @doc """
  This home's settings as `summary_items/4` reads them: the text of its
  `config.toml` followed by this computer's `machine.toml` (none is an empty
  one; `settings_text/2`), or the sentence that says one could not be read.
  `home.status` reads it on every poll, so an unreadable file is logged once
  when it stops being readable and once when it reads again
  (`Home.UnreadableFiles`, `opts`' `:unreadable_files`: that memory, or nil
  for none).
  """
  @spec settings(Path.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def settings(home, opts \\ []) when is_binary(home) and is_list(opts) do
    memory = Keyword.get(opts, :unreadable_files, UnreadableFiles)

    [config, machine] =
      for file <- [config_path(home), MachineFile.path(home)] do
        read = config_text(file)
        :ok = UnreadableFiles.log_read(file, "home status", read, memory)
        read
      end

    case settings_text(config, machine) do
      {:ok, text} -> {:ok, text}
      {:error, _reason} -> {:error, @unreadable_settings}
    end
  end

  @doc """
  What the home at `home` has turned on that runs only on this computer and
  stops after a move, read from its settings: voice calls and meetings, in
  that order; or the sentence that says the settings could not be read.
  StackChan (`:accessories`, M91) is named last, on a Mac only. iMessage is
  never named: after the move this Mac carries it for the server (M97
  §6.4). `home.status` reads it on every poll, so an
  unreadable file is logged once when it stops being readable and once when
  it reads again (`Home.UnreadableFiles`, `opts`' `:unreadable_files`: that
  memory, or nil for none).
  """
  @spec stays_here(Path.t(), boolean(), keyword()) ::
          {:ok, [:voice | :meetings | :accessories]} | {:error, String.t()}
  def stays_here(home, macos?, opts \\ [])
      when is_binary(home) and is_boolean(macos?) and is_list(opts) do
    with {:ok, text} <- settings(home, opts), do: {:ok, features(text, macos?)}
  end

  @doc """
  What a move costs that this home's settings (`settings/2`'s answer) turn
  on: `:telegram` (set up, so its messages wait while the move runs). None
  when the settings could not be read. Coding agents cost a move back
  nothing: this computer kept its own approval (M98 D5).
  """
  @spec costs({:ok, String.t()} | {:error, String.t()}) :: [:telegram]
  def costs({:ok, text}), do: if(telegram?(text), do: [:telegram], else: [])

  def costs({:error, _sentence}), do: []

  @doc "Every id a review's item can carry, in the review's order."
  @spec ids() :: [String.t()]
  def ids, do: @ids

  @doc "The block sentences of `report`, in order; none when it is ready."
  @spec blocks(report()) :: [String.t()]
  def blocks(%{items: items}), do: for(%{status: :block} = item <- items, do: item.sentence)

  @doc "The report as `home.move.readiness` answers it."
  @spec view(report()) :: map()
  def view(%{ready: ready, items: items}) do
    %{
      "ready" => ready,
      "items" =>
        Enum.map(items, fn item ->
          %{"id" => item.id, "status" => Atom.to_string(item.status), "sentence" => item.sentence}
        end)
    }
  end

  @doc "The report a `view/1` answered, read back: `{:ok, report}`, or `:error` for anything else."
  @spec from_view(map()) :: {:ok, report()} | :error
  def from_view(%{"ready" => ready, "items" => items})
      when is_boolean(ready) and is_list(items) do
    decoded = Enum.map(items, &item_from_view/1)

    if Enum.all?(decoded, &is_map/1),
      do: {:ok, %{ready: ready, items: decoded}},
      else: :error
  end

  def from_view(_other), do: :error

  # A kept review is read back as it was written, whichever engine wrote it.
  defp item_from_view(%{"id" => id, "status" => status, "sentence" => sentence})
       when is_binary(id) and status in ~w(ok warn block) and is_binary(sentence),
       do: %{id: id, status: String.to_existing_atom(status), sentence: sentence}

  defp item_from_view(_other), do: nil

  # -- items ------------------------------------------------------------------

  defp keychain({:ok, text}, opts) do
    with {:ok, refs} <- MoveSecrets.references(text),
         {:ok, values} <- MoveSecrets.read(refs, MoveSecrets.profile(text), opts) do
      item("keychain_secrets", :ok, carried_sentence(length(values)))
    else
      {:error, {:unreadable, ids}} ->
        Logger.warning("move readiness: the keychain gave nothing for #{Enum.join(ids, ", ")}")
        names = Keyword.get_lazy(opts, :secret_names, &Settings.secret_names/0)

        item(
          "keychain_secrets",
          :block,
          "The keychain did not give Fermix #{MoveSecrets.described(ids, names)}: unlock it, " <>
            "or set #{them(ids)} again or clear #{them(ids)} in settings, then check again."
        )

      {:error, {:unknown, keys}} ->
        Logger.warning("move readiness: no setting names the keychain items #{inspect(keys)}")

        item(
          "keychain_secrets",
          :block,
          "Fermix cannot tell which #{setting(keys)} #{MoveSecrets.unknown_items(keys)} to: " <>
            "set #{them(keys)} again in settings, then check again."
        )
    end
  end

  defp keychain({:error, sentence}, _opts), do: item("keychain_secrets", :block, sentence)

  defp setting([_one]), do: "setting"
  defp setting(_many), do: "settings"

  defp carried_sentence(0), do: "No secret is kept in this computer's keychain."

  # Reading a value opens the keychain, which can ask the owner to allow it:
  # here, and once more when the move's capture carries it.
  defp carried_sentence(1),
    do:
      "1 secret kept in this computer's keychain moves with the home, into the server's " <>
        "files. Checking it opened this computer's keychain, and the move opens it once " <>
        "more to carry it."

  defp carried_sentence(count),
    do:
      "#{count} secrets kept in this computer's keychain move with the home, into the " <>
        "server's files. Checking them opened this computer's keychain, and the move opens " <>
        "it once more to carry them."

  defp them([_one]), do: "it"
  defp them(_many), do: "them"

  # By the one rule of what an engine reads (`Home.Readable`, M97 D16): the
  # candidate's Fermix must read this home, by the home format its
  # enrollment named (one from before formats names none and reads by its
  # version, which must then be one). On a move this computer must also read
  # the candidate's home back, now or once an update for it is published
  # (M97 §3.4: the server leads), read from the release table at the review;
  # otherwise the home could never move back here. A move back needs only
  # the first.
  defp version(%{name: name} = candidate, ours, system_opts) do
    theirs = %{home_format: Map.get(candidate, :home_format), engine_version: candidate.version}

    if known?(theirs) do
      versions(read_both(theirs, ours), returning?(candidate), name, {theirs, system_opts})
    else
      item(
        "engine_version",
        :block,
        "Fermix cannot read which version #{name} runs: enroll it again from an " <>
          "up-to-date Fermix."
      )
    end
  end

  defp known?(%{home_format: format}) when is_integer(format), do: true
  defp known?(%{engine_version: version}), do: match?({:ok, _parsed}, Version.parse(version))

  # Whether the candidate reads this home, and whether this computer reads
  # the candidate's.
  defp read_both(theirs, ours) do
    cond do
      not Readable.reads?(theirs, ours) -> :older
      not Readable.reads?(ours, theirs) -> :newer
      true -> :both
    end
  end

  defp versions(:older, _returning?, name, _newer),
    do:
      item(
        "engine_version",
        :block,
        "#{name} runs an older Fermix than this computer, one that cannot read this home: " <>
          "update Fermix on #{name} first, then check again."
      )

  defp versions(:newer, false, name, {theirs, {system, opts}}),
    do: newer_server(published_for(theirs, system, opts), name)

  defp versions(:both, false, name, _newer),
    do:
      item(
        "engine_version",
        :ok,
        "#{name} runs a Fermix that reads this home, and this computer could read it back."
      )

  defp versions(_reads, true, name, _newer),
    do: item("engine_version", :ok, "#{name} runs a Fermix that reads this home.")

  defp newer_server(:published, name),
    do:
      item(
        "engine_version",
        :ok,
        "#{name} runs a newer Fermix than this computer. The update for this computer is " <>
          "published: install it before you move Fermix back here."
      )

  defp newer_server(:not_published, name),
    do:
      item(
        "engine_version",
        :block,
        "#{name} runs a newer Fermix than this computer, and no update for this computer " <>
          "reads its home yet, so Fermix could not move back. Set the server up with this " <>
          "computer's version, or wait for that update."
      )

  defp newer_server({:unread, _sentence}, name),
    do:
      item(
        "engine_version",
        :block,
        "#{name} runs a newer Fermix than this computer, and Fermix could not read which " <>
          "updates are published. Check again."
      )

  # Whether a published app for this computer's system reads the server's
  # home, by the release table (`Home.Releases.restorable?/3`,
  # `Home.ReleaseTable.fetch/1`; `:release_table` in a test).
  defp published_for(theirs, system, opts) do
    case Keyword.get(opts, :release_table, &ReleaseTable.fetch/0).() do
      {:ok, table} ->
        if Releases.restorable?(table, system, theirs), do: :published, else: :not_published

      {:error, sentence} ->
        {:unread, sentence}
    end
  end

  defp system(true), do: :macos
  defp system(false), do: :linux

  # This engine as a reader and a writer of homes: its version and its home
  # format (`:version` and `:home_format` in a test).
  defp this_engine(opts),
    do: %{
      engine_version: Keyword.get_lazy(opts, :version, &BuildInfo.product_version/0),
      home_format: Keyword.get_lazy(opts, :home_format, &Readable.home_format/0)
    }

  # A move back goes to the desktop the home left: the candidate that
  # enrolled through the window that desktop opened on this server.
  defp returning?(%{returning: desktop}), do: is_binary(desktop)

  # What the walk refused, in the words `fermix home export` says it in.
  defp disk(_home, {:error, reason}, _name, _opts) do
    Logger.error("move readiness: the home could not be measured: #{inspect(reason)}")
    item("disk", :block, Archive.collect_sentence(reason))
  end

  defp disk(home, {:ok, home_bytes}, name, opts) do
    need = Disk.capture_need(home_bytes)

    free_bytes =
      Keyword.get(opts, :free_bytes, &Disk.free_bytes(&1, Keyword.take(opts, [:supervised])))

    size = "This home is about #{Disk.gib(home_bytes)}"

    case free_bytes.(home) do
      {:ok, free} when free >= need ->
        item(
          "disk",
          :ok,
          "#{size}; the move needs about #{Disk.gib(need)} free here and on #{name}, and " <>
            "#{Disk.gib(free)} is free here."
        )

      {:ok, free} ->
        item(
          "disk",
          :block,
          "#{size}; the move needs about #{Disk.gib(need)} free on this computer's disk and " <>
            "#{Disk.gib(free)} is free: make room first."
        )

      {:error, reason} ->
        Logger.error("move readiness: the free space could not be read: #{inspect(reason)}")

        item(
          "disk",
          :block,
          "Fermix could not tell how much space this computer's disk has; Fermix's log " <>
            "says why."
        )
    end
  end

  defp s3_size(%{name: name, snapshots: %{"s3_bucket" => bucket}}, {:ok, home_bytes})
       when is_binary(bucket) do
    if home_bytes > S3.max_put_bytes(),
      do:
        item(
          "s3_size",
          :warn,
          "This home is about #{Disk.gib(home_bytes)}, more than one S3 upload carries " <>
            "(5 GiB), so #{name} cannot back it up to S3 until it is smaller."
        ),
      else: item("s3_size", :ok, "#{name}'s snapshots fit one S3 upload.")
  end

  defp s3_size(%{snapshots: %{"s3_bucket" => bucket}}, {:error, _reason})
       when is_binary(bucket),
       do: item("s3_size", :warn, "Fermix could not measure this home against one S3 upload.")

  defp s3_size(%{name: name}, _home_bytes),
    do: item("s3_size", :ok, "#{name} keeps no snapshots in S3.")

  defp plugins(home, host, %{name: name} = candidate, opts) do
    there = target(candidate)

    case {installed(home), host == there} do
      {[], _same} ->
        item("plugins", :ok, "No plugin is installed.")

      {_installed, true} ->
        item("plugins", :ok, "The installed plugins run on #{name} as they are.")

      {installed, false} ->
        plugins_elsewhere(installed, there, name, opts)
    end
  end

  # The server installs again every plugin whose installed version the
  # catalog has a build of for it; only the rest stop.
  defp plugins_elsewhere(installed, there, name, opts) do
    case Index.load(Keyword.get(opts, :index_opts, [])) do
      {:ok, index} ->
        installed
        |> Enum.reject(fn {plugin, version} -> built?(index, plugin, version, there) end)
        |> Enum.map(fn {plugin, _version} -> plugin end)
        |> no_build(name)

      {:error, reason} ->
        Logger.error("move readiness: the plugin catalog could not be read: #{inspect(reason)}")

        item(
          "plugins",
          :warn,
          "Fermix could not read its plugin catalog, so it cannot tell which plugins " <>
            "#{name} installs again; Fermix's log says why."
        )
    end
  end

  defp built?(_index, _plugin, nil, _target), do: false

  defp built?(index, plugin, version, target),
    do: Index.build_for?(index, plugin, version, target)

  defp no_build([], name),
    do:
      item("plugins", :ok, "#{name} installs the plugins again for itself right after the move.")

  defp no_build(names, name),
    do:
      item(
        "plugins",
        :warn,
        "These plugins have no build for #{name}, so they stop working after the move: " <>
          "#{Enum.join(names, ", ")}."
      )

  # The dev plugin folder is this computer's (its `machine.toml`): no move
  # carries it, so the server runs none of its plugins.
  defp dev_plugins({:ok, text}, macos?, name) do
    machine = if macos?, do: "Mac", else: "computer"

    if dev_folder?(text),
      do: [
        item(
          "dev_plugins",
          :warn,
          "Dev plugins stay on this #{machine}: #{name} runs none of them."
        )
      ],
      else: []
  end

  defp dev_plugins({:error, _sentence}, _macos?, _name), do: []

  defp dev_folder?(text) do
    case ConfigText.value(text, "fermix_core.plugins", "dev_local") do
      {:ok, raw} -> ConfigText.string(raw) != {:ok, ""}
      :absent -> false
    end
  end

  # M87: a move restarts this engine, and the restart ends a voice call in
  # progress before the move's capture starts; the review names it first.
  defp call_in_progress(holder) do
    case holder.() do
      {:ok, %{endpoint: endpoint}} ->
        [
          item(
            "call_in_progress",
            :warn,
            "A voice call #{call_with(endpoint)} is in progress: the move ends it before it starts."
          )
        ]

      :none ->
        []
    end
  end

  defp call_with("desktop"), do: "on this computer"
  defp call_with("phone:" <> _device_id), do: "from your phone"
  defp call_with("accessory:" <> _device_id), do: "from an accessory"

  # Voice's tree runs only where Talk to Fermix is on: no lease, no call.
  defp call_holder do
    if Process.whereis(CallLease), do: CallLease.holder(CallLease), else: :none
  end

  defp stays_here_item({:ok, text}, macos?, name, returning?) do
    case {features(text, macos?), returning?} do
      {[], _returning?} -> item("stays_here", :ok, none_on(macos?))
      {features, false} -> item("stays_here", :warn, stops(features, macos?, name))
      {features, true} -> item("stays_here", :ok, "#{Copy.runs_again(features, name)}.")
    end
  end

  defp stays_here_item({:error, sentence}, _macos?, _name, _returning?),
    do: item("stays_here", :warn, sentence)

  defp stops(features, macos?, name) do
    machine = if macos?, do: "Mac", else: "computer"

    [stays_behind(features -- [:voice], machine, name), voice_moves(features, machine, name)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp stays_behind([], _machine, _name), do: ""

  defp stays_behind(features, machine, name) do
    them = if features == [:accessories], do: "it", else: "them"
    "#{Copy.stops_after_move(features)}: neither this #{machine} nor #{name} runs #{them}."
  end

  # M87 §07: this computer's own voice reaches only its socket, so it stops;
  # a phone's calls ride its session to wherever the home runs.
  defp voice_moves(features, machine, name) do
    if :voice in features, do: "#{Copy.voice_after_move(machine, name)}.", else: ""
  end

  defp none_on(_macos?), do: "Voice calls and meetings are not turned on."

  # iMessage is not here: after a move the Mac carries it for the server
  # (M97 §6.4), and the move's keep-on block names it.
  defp features(text, macos?) do
    [
      voice: on?(text, "fermix_core.realtime", "enabled"),
      meetings: on?(text, "fermix_core.meetings", "enabled"),
      # M91 D7, D13: a server carries the pairing and starts no accessory link.
      accessories: macos? and on?(text, "fermix_channels.accessories", "enabled")
    ]
    |> Enum.filter(fn {_feature, on} -> on end)
    |> Enum.map(fn {feature, _on} -> feature end)
  end

  # WhatsApp's Cloud API reaches Fermix only at an inbound address, and the
  # server opens no port of its own: a Funnel mount, whose command Always On
  # shows after the move, gives it one, and Meta posts to the old address
  # until it is pointed at that one.
  defp whatsapp({:ok, text}, name) do
    if on?(text, "fermix_channels.whatsapp", "enabled"),
      do:
        item(
          "whatsapp",
          :warn,
          "WhatsApp stops after the move until you run the Tailscale Funnel command " <>
            "Always On shows for #{name} and point Meta at the address it prints."
        ),
      else: item("whatsapp", :ok, "WhatsApp is not turned on.")
  end

  defp whatsapp({:error, sentence}, _name), do: item("whatsapp", :warn, sentence)

  # Slack's Events API needs the same inbound address; Socket Mode dials out.
  defp slack({:ok, text}, name) do
    cond do
      not on?(text, "fermix_channels.slack", "enabled") ->
        item("slack", :ok, "Slack is not turned on.")

      slack_mode(text) == {:ok, "socket"} ->
        item("slack", :ok, "Slack uses Socket Mode and keeps working on #{name}.")

      true ->
        item(
          "slack",
          :warn,
          "Slack stops after the move unless it uses Socket Mode, which you turn on in " <>
            "your Slack app's settings and then in Fermix's Slack settings."
        )
    end
  end

  defp slack({:error, sentence}, _name), do: item("slack", :warn, sentence)

  # The approval is this computer's own (M98 D5): it stays here, where no
  # coding agent runs after the move, and each machine decides with its own.
  defp coding_agents({:ok, text}, macos?, name) do
    machine = if macos?, do: "Mac", else: "computer"

    if on?(text, "fermix_core.harness", "approved"),
      do:
        item(
          "coding_agents",
          :warn,
          "Coding agents stop on this #{machine} after the move. They run on #{name} only " <>
            "with your approval there. To run them on #{name} too, allow them there in " <>
            "Settings, Coding agents, after the move."
        ),
      else: item("coding_agents", :ok, "No coding agent has your approval on this computer.")
  end

  defp coding_agents({:error, sentence}, _macos?, _name),
    do: item("coding_agents", :warn, sentence)

  # M97 D28 (§19.8): after the move, every app's Settings are the server's,
  # its own machine settings included; what the server may use on this
  # computer, and this computer's own sandbox, are under This Mac (This
  # computer on Linux). A move back makes this computer its own home again,
  # so it says nothing of the kind.
  defp settings_item(_macos?, _name, true = _returning?), do: []

  defp settings_item(macos?, name, false) do
    machine = if macos?, do: "Mac", else: "computer"

    [
      item(
        "settings",
        :ok,
        "After the move, Settings in this app change Fermix on #{name}, its sandbox and " <>
          "coding agents included. A new server's sandbox starts Open. What #{name} may use " <>
          "on this #{machine}, and this #{machine}'s own sandbox, are under This #{machine}."
      )
    ]
  end

  defp on?(text, section, key), do: ConfigText.value(text, section, key) == {:ok, "true"}

  # Telegram runs once it has a bot token, unless turned off: it ships on.
  defp telegram?(text) do
    ConfigText.value(text, "fermix_channels.telegram", "enabled") != {:ok, "false"} and
      telegram_token(text) not in [:absent, :error, {:ok, ""}]
  end

  defp telegram_token(text) do
    case ConfigText.value(text, "fermix_channels.telegram", "bot_token") do
      {:ok, raw} -> ConfigText.string(raw)
      :absent -> :absent
    end
  end

  defp slack_mode(text) do
    case ConfigText.value(text, "fermix_channels.slack", "mode") do
      {:ok, raw} -> ConfigText.string(raw)
      :absent -> :absent
    end
  end

  # The move stops this engine to hand the home over; one started from a
  # terminal is not brought back, so the move waits until it is started again.
  defp service(true),
    do: item("service", :ok, "Fermix starts again by itself here once the move stops it.")

  defp service(false),
    do:
      item(
        "service",
        :warn,
        "Fermix runs from a terminal here, so it stops when the move starts. Start it again " <>
          "to finish."
      )

  # Telegram keeps what it holds until the poller asks again, so its messages
  # wait out the move: named only where this home has it set up.
  defp cutover_sentence({:ok, text}) do
    if telegram?(text),
      do:
        "Messages sent to Telegram while the move runs wait until it is done, and a " <>
          "recurring job more than an hour late is skipped.",
      else: jobs_gap()
  end

  defp cutover_sentence({:error, _sentence}), do: jobs_gap()

  defp jobs_gap, do: "A recurring job more than an hour late while the move runs is skipped."

  # -- facts ------------------------------------------------------------------

  defp item(id, status, sentence) when id in @ids,
    do: %{id: id, status: status, sentence: sentence}

  # A review is asked for, not polled, so each unreadable read is logged.
  defp read_config(home) do
    case settings_text(logged_read(config_path(home)), logged_read(MachineFile.path(home))) do
      {:ok, text} -> {:ok, text}
      {:error, _reason} -> {:error, @unreadable_settings}
    end
  end

  defp logged_read(file) do
    read = config_text(file)

    case read do
      {:ok, _text} ->
        read

      {:error, reason} ->
        Logger.error(
          "move readiness: #{Path.basename(file)} could not be read: #{inspect(reason)}"
        )

        read
    end
  end

  # This home's settings and this computer's own as one text, each read where
  # it lives: `config.toml` without any machine setting it still holds, then
  # `machine.toml` (`Setup.MachineFile`).
  defp settings_text({:ok, config}, {:ok, machine}),
    do: {:ok, elem(MachineFile.strip(config), 0) <> "\n" <> machine}

  defp settings_text({:error, _reason} = error, _machine), do: error
  defp settings_text(_config, {:error, _reason} = error), do: error

  defp config_path(home), do: Path.join(home, "config.toml")

  # A home with no settings file turns nothing on.
  defp config_text(file) do
    case File.read(file) do
      {:error, :enoent} -> {:ok, ""}
      read -> read
    end
  end

  # A host the plugin installer has no name for compares as another host:
  # every installed plugin is then named for reinstalling.
  defp host(opts) do
    case Archive.host(opts) do
      {:ok, host} -> host
      {:error, {:host_unsupported, _reason}} -> "unsupported-host"
    end
  end

  defp target(%{os: os, arch: arch}) do
    os = if os in ["darwin", "macos"], do: "macos", else: os
    "#{os}-#{arch}"
  end

  defp home_bytes(home) do
    case Archive.collect(home, :infinity) do
      {:ok, found, _links} ->
        {:ok, Enum.reduce(found, 0, fn {_rel, stat}, sum -> sum + stat.size end)}

      {:error, _reason} = error ->
        error
    end
  end

  # Each installed plugin with the version its lockfile entry names (nil
  # when it names none).
  defp installed(home) do
    with {:ok, json} <- File.read(Path.join(home, @plugin_lockfile)),
         {:ok, %{} = installed} <- Jason.decode(json) do
      installed |> Enum.map(fn {name, entry} -> {name, locked_version(entry)} end) |> Enum.sort()
    else
      _none -> []
    end
  end

  defp locked_version(%{"version" => version}) when is_binary(version), do: version
  defp locked_version(_entry), do: nil
end
