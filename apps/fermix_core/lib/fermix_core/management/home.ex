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
      while not connected), `epoch` (the highest primary epoch seen) and
      `sentence`; null otherwise.
    * `desktops`: on the primary, its desktop peers: `device_id`, `name`,
      `connected` and `since` (null while not connected); empty otherwise.
    * `primary_home`: on a linked desktop, the primary's own `home.status`
      (its recovery, enrollment, candidates and move), asked within
      `Management.Placement.composed_deadline_ms/0`; null on any other engine
      and while the primary's answer is missing, when `primary_missing` holds
      the sentence that says why (null otherwise). A desktop's own snapshot
      status file is a retired copy, so its `snapshots` lists no target: the
      primary's are in `primary_home`.

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

  `summary` is where Always On stands in one sentence and at most one action
  (`FermixCore.Management.HomeSummary`, M75 lean v1 §7), gathered from the
  rest of this record and the provisioner's ledger; every surface prints it
  first. `disk` is how full this primary's disk is (`Home.Disk.usage/2`:
  `used`, a fraction, and `nearly_full` from 85%), null in any other role and
  when it cannot be read, so a linked desktop reads its server's from
  `primary_home`. `version` is this engine's.

  `home.snapshots.run` starts a snapshot now (`busy` while one runs);
  `home.snapshots.passphrase` derives the recovery key from
  `recovery_passphrase` and keeps only its public half in
  `[fermix_core.snapshots] recipient`: the passphrase is never stored, logged
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
  `:version`, `:now` and `:host_os`. `:supervised` is the caller's world for
  the disk's `df` (false from a tree-less verb), and `:unreadable_files` the
  memory that logs what this record reads (the disk, the ledger, the settings,
  the last review, a desktop's copies) once per stretch it cannot be read
  (`Home.UnreadableFiles`, the default; nil from a tree-less verb).
  `:primary_forward` is the daemon's way to the primary, given only on a
  linked desktop.
  """

  alias FermixCore.BuildInfo
  alias FermixCore.Home.Disk
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Link
  alias FermixCore.Home.Moved
  alias FermixCore.Home.MoveSecrets
  alias FermixCore.Home.Role
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Home.Snapshot.Scheduler
  alias FermixCore.Home.Snapshot.Settings, as: SnapshotSettings
  alias FermixCore.Home.Snapshot.Status
  alias FermixCore.Home.UnreadableFiles
  alias FermixCore.Management.HomeMove
  alias FermixCore.Management.HomeSummary
  alias FermixCore.Management.Placement
  alias FermixCore.Setup.ConfigStore

  require Logger

  @device_sentence "Snapshots are the primary's to write; this engine runs in the device role."
  @candidate_sentence "Snapshots are the primary's to write; this engine is a candidate " <>
                        "waiting for its move."
  @not_running_sentence "Snapshots are not running in this engine."
  @short_sentence "The recovery passphrase must be at least 12 bytes long."
  @max_passphrase_bytes 1_024
  @primary_statuses ~w(connected renewing unreachable revoked stale)a

  @doc "The closed set of words `home.status`'s `primary.status` takes, in order."
  @spec primary_statuses() :: [String.t()]
  def primary_statuses, do: Enum.map(@primary_statuses, &Atom.to_string/1)

  @doc "The capability a refusal of this family names."
  @spec capability() :: String.t()
  def capability, do: "snapshots"

  @doc "`home.status`: the whole picture of this home."
  @spec status(keyword()) :: {:ok, map()}
  def status(opts \\ []) when is_list(opts) do
    home = home(opts)
    role = role(opts)
    link = Keyword.get(opts, :link_status, fn -> Link.impl().status() end).()
    move = HomeMove.facts(home, role, link, opts)
    {primary_home, primary_missing, too_old?} = primary_home(opts)

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
      version: Keyword.get_lazy(opts, :version, &BuildInfo.product_version/0)
    }

    gathered =
      HomeSummary.gather(home, role, link, Map.put(facts, :primary_too_old, too_old?), opts)

    {:ok, picture(Map.put(facts, :summary, HomeSummary.summary(gathered)))}
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

  defp secrets_missing(%{role: :primary}, opts),
    do:
      MoveSecrets.missing(
        Keyword.get(opts, :settings_snapshot, &ConfigStore.current_snapshot/0).()
      )

  defp secrets_missing(_record, _opts), do: []

  # A linked desktop adds the primary's own picture, or why it is missing,
  # and whether the server speaks a protocol this engine is too old for.
  defp primary_home(opts) do
    case Keyword.fetch(opts, :primary_forward) do
      {:ok, forward} ->
        case Placement.primary_part(forward, "home.status") do
          {:ok, status} -> {status, nil, false}
          {:too_old, sentence} -> {nil, sentence, true}
          {:missing, sentence} -> {nil, sentence, false}
        end

      :error ->
        {nil, nil, false}
    end
  end

  @doc """
  The `home.status` record from its facts: the role, the epoch (or nil), the
  marker (or nil), the snapshots view, the summary, this engine's version,
  the rail's `primary` (or nil) and `desktops` (none when absent),
  `HomeMove.facts/4`'s `enrollment`, `candidates` and `move` (null, none and
  null when absent), a linked desktop's `primary_home` and `primary_missing`
  (null when absent), and the primary's `disk` (null when absent). Pure, so
  the CLI's goldens are built from it.
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
          optional(:secrets_missing) => [String.t()]
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
      "version" => version
    }
  end

  defp primary_view(nil), do: nil

  defp primary_view(
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
  end

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
         {:ok, passphrase} <- passphrase(passphrase),
         {:ok, pair} <- Recipient.from_passphrase(passphrase),
         recipient = Recipient.public(pair),
         {:ok, _saved} <- saved(save_recipient(opts).(recipient)) do
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

  # The settings write's own refusals cross as they are; anything else names
  # files on this disk, so it goes to the log and the answer stays fixed.
  defp saved({:ok, _report} = ok), do: ok
  defp saved({:error, {:external_change, _sections}} = error), do: error
  defp saved({:error, {:config_unreadable, _sentence}} = error), do: error

  defp saved({:error, reason}) do
    Logger.error("home.snapshots.passphrase: the recovery key was not saved: #{inspect(reason)}")

    {:error,
     {:unavailable, capability(), "The recovery key could not be saved. See the daemon log."}}
  end

  defp passphrase(value)
       when is_binary(value) and byte_size(value) >= 12 and
              byte_size(value) <= @max_passphrase_bytes,
       do: {:ok, value}

  defp passphrase(value) when is_binary(value) and byte_size(value) < 12,
    do: {:error, {:invalid_params, "recovery_passphrase", @short_sentence}}

  defp passphrase(_value),
    do:
      {:error,
       {:invalid_params, "recovery_passphrase",
        "The recovery passphrase is text of at most #{@max_passphrase_bytes} bytes."}}

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
        targets: Scheduler.targets(),
        running: running,
        profile: profile(opts)
      })

    device_view(view, role)
  end

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

  defp save_recipient(opts),
    do: Keyword.get(opts, :save_recipient, &SnapshotSettings.put_recipient/1)

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
