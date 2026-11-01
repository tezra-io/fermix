defmodule FermixCore.Home.MoveReadiness do
  @moduledoc """
  What the owner reviews before a move (M75): `home.move.readiness
  {candidate_id}` answers it, and `home.move.start` refuses while any item
  blocks (`FermixCore.Home.Move.start/5`).

  Each item is `ok`, `warn` or `block`, with the one sentence the owner reads:

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
    * `engine_version`: a server that runs an older Fermix than this computer
      blocks (a restore by an older engine is refused anyway,
      `Archive.install/5`), as does a version that cannot be read;
    * `disk`: the capture needs about twice the home free on this computer
      (`FermixCore.Home.Disk`); short of it, or with the free space unknown,
      it blocks, saying how much is needed; the server needs as much again;
    * `s3_size`: a home larger than one S3 upload (5 GiB) warns where the
      server keeps its snapshots in S3: it would never back up there;
    * `plugins`: on a server of another OS or architecture, the plugins
      whose installed version the catalog has no build of for it warn,
      named: they stop working after the move. The server installs every
      other one again for itself right after the move
      (`FermixCore.Plugins.Dist.Reinstall`), through the plugin installer;
    * `stays_here`: what the home has turned on that runs only on this
      computer (iMessage on a Mac, voice calls, meetings; `stays_here/2`)
      stops after the move, each named; with none of them on it is `ok`;
    * `whatsapp`: WhatsApp turned on warns: it needs an inbound address Meta
      can reach, which the server does not have, so it stops after the move;
    * `slack`: Slack turned on in its Events (webhook) mode warns for the
      same reason, unless it is switched to Socket Mode first;
    * `coding_agents`: coding-harness consent given here warns: a move
      withdraws it, as every restore does (`Archive.RestoredConfig`), so
      coding agents ask for the owner's approval again on the server;
    * `cutover_gap`: Telegram messages sent during the move wait until it
      is done (Telegram keeps them, `Channels.Telegram.Poller`), and a
      recurring job more than an hour late is skipped;
    * `serves_nothing`: this computer serves nothing during the move;
    * `service`: Fermix run from a terminal (`fermix run`) warns, since the
      move stops it and nothing starts it again
      (`Management.Lifecycle.restarts_itself?/1`): it has to be started again
      to finish the move.

  `config_items/3` answers the last seven alone, from the settings file and
  facts of this engine: the items that need neither the keychain nor a walk of
  the home, which Move now's confirm names before the owner presses it.

  `opts`: `:free_bytes` (a 1-arity reader of free space), `:supervised` (for
  `CommandRunner` and the keychain read from a tree-less verb), `:version`
  (this engine's, `BuildInfo.product_version/0`), `:host` (this host's plugin
  target, `Archive.host/1`), `:home_bytes` (the home's size, in place of
  walking it), `:index_opts` (`Plugins.Dist.Index.load/1`'s, the catalog),
  `:restarts_itself` (a boolean, in place of
  `Management.Lifecycle.restarts_itself?/0`).
  """

  alias FermixCore.BuildInfo
  alias FermixCore.Home.Archive
  alias FermixCore.Home.Archive.ConfigText
  alias FermixCore.Home.Disk
  alias FermixCore.Home.MoveSecrets
  alias FermixCore.Home.Snapshot.S3
  alias FermixCore.Home.UnreadableFiles
  alias FermixCore.Management.Copy
  alias FermixCore.Management.Lifecycle
  alias FermixCore.Management.Settings
  alias FermixCore.Plugins.Dist.Index

  require Logger

  @plugin_lockfile "plugins/installed.json"
  @unreadable_settings "The settings file could not be read; Fermix's log says why."

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

    items =
      [
        keychain(config, opts),
        version(candidate, Keyword.get_lazy(opts, :version, &BuildInfo.product_version/0)),
        disk(home, home_bytes, name, opts),
        s3_size(candidate, home_bytes),
        plugins(home, host, candidate, opts)
      ] ++ from_config(config, host, name, opts)

    %{ready: not Enum.any?(items, &(&1.status == :block)), items: items}
  end

  @doc """
  The review's items that read the settings file of `home` and this engine's
  own facts alone, for a move to the candidate called `name`: `stays_here`,
  `whatsapp`, `slack`, `coding_agents`, `cutover_gap`, `serves_nothing` and
  `service`, exactly as `report/3` gives them. A summary reads them on every
  poll, so an unreadable file is logged once when it stops being readable
  and once when it reads again (`opts`' `:unreadable_files`, as
  `stays_here/3`); `:host` and `:restarts_itself` as `report/3`'s.
  """
  @spec config_items(Path.t(), String.t(), keyword()) :: [item()]
  def config_items(home, name, opts \\ [])
      when is_binary(home) and is_binary(name) and is_list(opts) do
    file = config_path(home)
    read = config_text(file)
    memory = Keyword.get(opts, :unreadable_files, UnreadableFiles)
    :ok = UnreadableFiles.log_read(file, "home status", read, memory)

    config =
      case read do
        {:ok, text} -> {:ok, text}
        {:error, _reason} -> {:error, @unreadable_settings}
      end

    from_config(config, host(opts), name, opts)
  end

  defp from_config(config, host, name, opts) do
    [
      stays_here_item(config, host, name),
      whatsapp(config, name),
      slack(config, name),
      coding_agents(config, name),
      item("cutover_gap", :warn, cutover_sentence()),
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
  What the home at `home` has turned on that runs only on this computer and
  stops after a move, read from its settings: iMessage (only when `macos?`),
  voice calls and meetings, in that order; or the sentence that says the
  settings could not be read. `home.status` reads it on every poll, so an
  unreadable file is logged once when it stops being readable and once when
  it reads again (`Home.UnreadableFiles`, `opts`' `:unreadable_files`: that
  memory, or nil for none).
  """
  @spec stays_here(Path.t(), boolean(), keyword()) ::
          {:ok, [:imessage | :voice | :meetings]} | {:error, String.t()}
  def stays_here(home, macos?, opts \\ [])
      when is_binary(home) and is_boolean(macos?) and is_list(opts) do
    file = config_path(home)
    read = config_text(file)
    memory = Keyword.get(opts, :unreadable_files, UnreadableFiles)
    :ok = UnreadableFiles.log_read(file, "home status", read, memory)

    case read do
      {:ok, text} -> {:ok, features(text, macos?)}
      {:error, _reason} -> {:error, @unreadable_settings}
    end
  end

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

  defp item_from_view(%{"id" => id, "status" => status, "sentence" => sentence})
       when is_binary(id) and status in ~w(ok warn block) and is_binary(sentence),
       do: item(id, String.to_existing_atom(status), sentence)

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

  # The versions themselves are on the candidate's row; the sentence says
  # which way they differ.
  defp version(%{name: name, version: theirs}, ours) do
    case {Version.parse(theirs), Version.parse(ours)} do
      {{:ok, server}, {:ok, here}} ->
        if Version.compare(server, here) == :lt,
          do:
            item(
              "engine_version",
              :block,
              "#{name} runs an older Fermix than this computer: update Fermix on #{name} " <>
                "first, then check again."
            ),
          else:
            item("engine_version", :ok, "#{name} runs this computer's Fermix, or a newer one.")

      _unreadable ->
        item(
          "engine_version",
          :block,
          "Fermix cannot read which version #{name} runs: enroll it again from an " <>
            "up-to-date Fermix."
        )
    end
  end

  defp disk(_home, {:error, reason}, _name, _opts) do
    Logger.error("move readiness: the home could not be measured: #{inspect(reason)}")
    item("disk", :block, "Fermix could not measure this home; Fermix's log says why.")
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

  defp stays_here_item({:ok, text}, host, name) do
    macos? = String.starts_with?(host, "macos-")

    case features(text, macos?) do
      [] -> item("stays_here", :ok, none_on(macos?))
      features -> item("stays_here", :warn, stops(features, macos?, name))
    end
  end

  defp stays_here_item({:error, sentence}, _host, _name), do: item("stays_here", :warn, sentence)

  defp stops(features, macos?, name) do
    machine = if macos?, do: "Mac", else: "computer"
    them = if features == [:imessage], do: "it", else: "them"
    "#{Copy.stops_after_move(features)}: neither this #{machine} nor #{name} runs #{them}."
  end

  defp none_on(true), do: "iMessage, voice calls and meetings are not turned on."
  defp none_on(false), do: "Voice calls and meetings are not turned on."

  # iMessage runs only on a Mac, so another computer never names it.
  defp features(text, macos?) do
    [
      imessage: macos? and on?(text, "fermix_channels.imessage", "enabled"),
      voice: on?(text, "fermix_core.realtime", "enabled"),
      meetings: on?(text, "fermix_core.meetings", "enabled")
    ]
    |> Enum.filter(fn {_feature, on} -> on end)
    |> Enum.map(fn {feature, _on} -> feature end)
  end

  # WhatsApp's Cloud API reaches Fermix only at an inbound address, and the
  # server takes no inbound connection.
  defp whatsapp({:ok, text}, name) do
    if on?(text, "fermix_channels.whatsapp", "enabled"),
      do:
        item(
          "whatsapp",
          :warn,
          "WhatsApp stops after the move: it needs an address on the internet that " <>
            "WhatsApp can send messages to, and #{name} has none."
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

  # A restore withdraws coding-harness consent (`Archive.RestoredConfig`), and
  # the move restores the home on the server.
  defp coding_agents({:ok, text}, name) do
    if on?(text, "fermix_core.harness", "approved"),
      do: item("coding_agents", :warn, "Coding agents ask for your approval again on #{name}."),
      else: item("coding_agents", :ok, "No coding agent has your approval on this computer.")
  end

  defp coding_agents({:error, sentence}, _name), do: item("coding_agents", :warn, sentence)

  defp on?(text, section, key), do: ConfigText.value(text, section, key) == {:ok, "true"}

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

  defp cutover_sentence,
    do:
      "Messages sent to Telegram while the move runs wait until it is done, and a recurring " <>
        "job more than an hour late is skipped."

  # -- facts ------------------------------------------------------------------

  defp item(id, status, sentence), do: %{id: id, status: status, sentence: sentence}

  # A review is asked for, not polled, so each unreadable read is logged.
  defp read_config(home) do
    case config_text(config_path(home)) do
      {:ok, text} ->
        {:ok, text}

      {:error, reason} ->
        Logger.error("move readiness: config.toml could not be read: #{inspect(reason)}")
        {:error, @unreadable_settings}
    end
  end

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
