defmodule FermixCore.Home.MoveReadiness do
  @moduledoc """
  What the owner reviews before a move (M75): `home.move.readiness
  {candidate_id}` answers it, and `home.move.start` refuses while any item
  blocks (`FermixCore.Home.Move.start/5`).

  Each item is `ok`, `warn` or `block`, with the one sentence the owner reads:

    * `keychain_secrets`: the secrets this computer keeps in its keychain
      move with the home, into the server's secret files
      (`FermixCore.Home.MoveSecrets`); one Fermix cannot read, or a
      reference it cannot name, blocks, named by its id, never its value.
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
    * `plugins`: plugins installed for another OS or architecture warn,
      named: they are installed again on the server;
    * `stays_here`: voice, and iMessage on a Mac, stay on this computer;
    * `cutover_gap`: Telegram messages sent during the move are lost, and a
      recurring job more than an hour late is skipped;
    * `serves_nothing`: this computer serves nothing during the move.

  `opts`: `:free_bytes` (a 1-arity reader of free space), `:supervised` (for
  `CommandRunner` and the keychain read from a tree-less verb), `:version`
  (this engine's, `BuildInfo.product_version/0`), `:host` (this host's plugin
  target, `Archive.host/1`), `:home_bytes` (the home's size, in place of
  walking it).
  """

  alias FermixCore.BuildInfo
  alias FermixCore.Home.Archive
  alias FermixCore.Home.Disk
  alias FermixCore.Home.MoveSecrets
  alias FermixCore.Home.Snapshot.S3

  require Logger

  @plugin_lockfile "plugins/installed.json"

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

    items = [
      keychain(config, opts),
      version(candidate, Keyword.get_lazy(opts, :version, &BuildInfo.product_version/0)),
      disk(home, home_bytes, name, opts),
      s3_size(candidate, home_bytes),
      plugins(home, host, candidate),
      stays_here(host, name),
      item("cutover_gap", :warn, cutover_sentence()),
      item(
        "serves_nothing",
        :warn,
        "This computer serves nothing while the move runs: no chat, channels or jobs " <>
          "until #{name} takes over."
      )
    ]

    %{ready: not Enum.any?(items, &(&1.status == :block)), items: items}
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
        item(
          "keychain_secrets",
          :block,
          "The keychain did not give Fermix #{Enum.join(ids, ", ")}: unlock it, or set " <>
            "#{them(ids)} again or clear #{them(ids)} in settings, then check again."
        )

      {:error, {:unknown, keys}} ->
        item(
          "keychain_secrets",
          :block,
          "Fermix cannot tell which keychain item #{Enum.join(keys, ", ")} names: set " <>
            "#{them(keys)} again in settings, then check again."
        )
    end
  end

  defp keychain({:error, sentence}, _opts), do: item("keychain_secrets", :block, sentence)

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
    item("disk", :block, "Fermix could not measure this home; the daemon log says why.")
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
          "Fermix could not tell how much space this computer's disk has; the daemon log " <>
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

  defp plugins(home, host, %{name: name} = candidate) do
    there = target(candidate)

    case {installed(home), host == there} do
      {[], _same} ->
        item("plugins", :ok, "No plugin is installed.")

      {_names, true} ->
        item("plugins", :ok, "The installed plugins run on #{name} as they are.")

      {names, false} ->
        item(
          "plugins",
          :warn,
          "These plugins were installed for this computer and are installed again on " <>
            "#{name}: #{Enum.join(names, ", ")}."
        )
    end
  end

  defp stays_here("macos-" <> _arch, name),
    do:
      item(
        "stays_here",
        :warn,
        "iMessage and voice stay on this Mac: #{name} cannot use them."
      )

  defp stays_here(_host, name),
    do: item("stays_here", :warn, "Voice stays on this computer: #{name} cannot use it.")

  defp cutover_sentence,
    do:
      "Messages sent to Telegram while the move runs are lost, and a recurring job more " <>
        "than an hour late is skipped."

  # -- facts ------------------------------------------------------------------

  defp item(id, status, sentence), do: %{id: id, status: status, sentence: sentence}

  defp read_config(home) do
    case File.read(Path.join(home, "config.toml")) do
      {:ok, text} ->
        {:ok, text}

      {:error, :enoent} ->
        {:ok, ""}

      {:error, reason} ->
        Logger.error("move readiness: config.toml could not be read: #{inspect(reason)}")
        {:error, "The settings file could not be read; the daemon log says why."}
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

  defp installed(home) do
    with {:ok, json} <- File.read(Path.join(home, @plugin_lockfile)),
         {:ok, %{} = installed} <- Jason.decode(json) do
      installed |> Map.keys() |> Enum.sort()
    else
      _none -> []
    end
  end
end
