defmodule FermixChannels.Home.MoveWorker do
  @moduledoc """
  The source of a move (M75 §7.2, B5): the device-role engine of the home
  that was the primary, run while a move is pending (`FermixCore.Home.Move`).
  It is the one writer of `.move/phase.json` after `home.move.start`.

  **Before `move_ready`** (phases `requested`, `streaming`):

    1. the desktop's X25519 key goes to `device/desktop_key` and its row
       (`kind: :desktop`) into `mobile/devices.toml`, before
       anything is captured, so the row travels and the key never does;
    2. the value of every `@keyring` reference in `config.toml` is read from
       the keychain (`FermixCore.Home.MoveSecrets`), and the home is captured
       (`Snapshot.write/4`) into `.move/<id>.fxsnap`, encrypted to the one-time
       recipient the candidate gave at enrollment, those values riding inside
       it as files of the file secret store: never on this disk in clear, in a
       log or in the phase file. A value the keychain will not give, or a disk
       without room for the capture, aborts the move by name. The capture's
       size and SHA-256 are recorded in the phase, and a later attempt (the
       home is unchanged: this engine is in the device role) sends the same
       file again rather than capturing anew;
    3. the worker dials the candidate (`Mobile.Rail`, `:ik_move`: the gateway
       key as its static key, the candidate's Noise key as the responder's),
       sends `move_offer` (the file's size and SHA-256, the source epoch, the
       recovery recipient, and the attempt, which only grows across restarts),
       checks `move_accept` names the same recipient,
       streams the file as `move_chunk`s and `move_end`, and waits for
       `move_ready {epoch}`.

  A transport failure here is tried again from step 3 (at most
  #{3} attempts in all, across restarts); a refusal, or the last attempt
  failing, aborts the move: the desktop row and key go, the role is the
  primary again, `undoing` is recorded and the engine restarts; its boot as
  the primary records `aborted` (`Move.finish_at_boot/2`). Nothing was
  retired.

  **The commit.** On `move_ready` the worker records the ready epoch, writes
  `moved.json` (`to` the candidate's name) and `device/desktop.json` (the
  source's own gateway key and node id, since the identity bundle moves),
  records `committing`, and only then sends `move_commit`. On `move_done` it
  records `committed` and restarts, and the engine boots as a desktop of the
  new primary, whose boot records `done`: an ending is published only by the
  engine that came back, never by one about to stop. Once `moved.json` exists the move is never aborted: a lost
  `move_commit` or `move_done` is resumed (`move_resume` on the candidate,
  answered `move_ready` or `move_done`), and when the candidate no longer
  answers the worker asks the moved identity itself, as the desktop, for its
  `hello_ack`: an answer at the ready epoch or later is the new primary,
  which only an activated candidate can be. Resuming retries 1 s doubling to
  60 s for 24 hours, then stops with a sentence; the next start resumes again.

  A source the request does not keep as a desktop (`keep_as_desktop: false`, a
  server being replaced) makes no desktop key, row or link: it is retired by
  the marker and serves nothing afterwards. Having no desktop key, it cannot
  ask the moved identity for its `hello_ack`, so a lost `move_done` there is
  resumed through the candidate alone.

  The restart is the daemon's deliberate self-restart
  (`Management.Lifecycle.restart_self/0`: the systemd start budget reset
  first, then the one stop path), which the service manager brings back.

  **Kept awake** (L16). From its start until it ends, which is the restart
  every move but an unconfirmed one ends with, the worker holds this computer
  awake (`FermixCore.Home.MoveAwake`: caffeinate on a Mac, systemd-inhibit on
  Linux, each ending with the engine). The hold is released however the worker
  ends, and its holder lets go by itself if the worker dies. A computer
  Fermix cannot keep awake still moves, and the log says why. A test VM holds
  nothing unless a case injects `:awake`.

  A request file that cannot be read is recorded with its sentence, and the
  worker ends without changing anything else.

  Test seams: `:home`, `:helper`, `:connect` (route to a `Mobile.Rail`
  `:connect` function), `:clock`, `:sleep`, `:restart`, `:snapshot_opts`,
  `:resume_for_ms`, `:awake` (0-arity, as `MoveAwake.hold/0`).
  """

  use Task, restart: :transient

  require Logger

  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.Iroh.Key
  alias FermixChannels.Mobile.Iroh.Relays
  alias FermixChannels.Mobile.Noise
  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Mobile.Rail
  alias FermixCore.BuildInfo
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Move
  alias FermixCore.Home.MoveAwake
  alias FermixCore.Home.Moved
  alias FermixCore.Home.MoveSecrets
  alias FermixCore.Home.MoveTelemetry
  alias FermixCore.Home.Snapshot
  alias FermixCore.Home.Snapshot.Run
  alias FermixCore.Management.Lifecycle
  alias FermixCore.Management.Settings
  alias FermixCore.Setup.ConfigStore

  @chunk_bytes 60 * 1_024
  @accept_ms 60_000
  @ready_ms 30 * 60_000
  @done_ms 60_000
  @retry_pause_ms 5_000
  @first_resume_ms 1_000
  @max_resume_ms 60_000
  @resume_for_ms 24 * 3_600_000
  @compiled_env Mix.env()

  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts) when is_list(opts), do: Task.start_link(__MODULE__, :run, [opts])

  @doc "Carries the pending move of `opts[:home]` on from its recorded phase."
  @spec run(keyword()) :: :ok
  def run(opts) do
    ctx = context(opts)
    awake = keep_awake(ctx)

    try do
      case {Move.read_request(ctx.home), Move.read_phase(ctx.home)} do
        {{:ok, request}, {:ok, phase}} -> carry_on(ctx, request, phase)
        {{:error, reason}, _phase} -> unreadable(ctx, reason)
        {_request, other} -> unreadable(ctx, other)
      end
    after
      MoveAwake.release(awake)
    end
  end

  # Before anything of the move is done, so the computer stays awake for all
  # of it; a hold that cannot start leaves the move to run as it would.
  defp keep_awake(ctx) do
    case ctx.awake.() do
      {:ok, holder} ->
        holder

      {:error, reason} ->
        Logger.warning(
          "move: this computer may sleep while the move runs: #{MoveAwake.describe(reason)}"
        )

        nil
    end
  end

  defp carry_on(ctx, request, phase) do
    ctx = Map.merge(ctx, %{request: request, started_ms: started(request, phase)})

    case {phase["phase"], Moved.read(ctx.home)} do
      {_phase, {:ok, _marker}} -> resume(ctx)
      {"aborting", :absent} -> abort(ctx, :recorded_abort, phase["sentence"])
      {_before_commit, :absent} -> transfer(ctx)
      {phase_name, {:error, reason}} -> unconfirmed(ctx, phase_name, marker_sentence(reason))
    end
  end

  defp context(opts) do
    home = Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)

    %{
      home: home,
      helper: Keyword.get(opts, :helper),
      connect: Keyword.get(opts, :connect),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      sleep: Keyword.get(opts, :sleep, &Process.sleep/1),
      restart: Keyword.get(opts, :restart, &Lifecycle.restart_self/0),
      snapshot_opts: Keyword.get(opts, :snapshot_opts, []),
      resume_for_ms: Keyword.get(opts, :resume_for_ms, @resume_for_ms),
      awake: Keyword.get(opts, :awake, default_awake())
    }
  end

  # A test VM never holds its host awake; a case injects `:awake` to see it.
  defp default_awake do
    if @compiled_env == :test, do: fn -> {:ok, nil} end, else: &MoveAwake.hold/0
  end

  defp started(request, %{"phase" => "requested"}),
    do: MoveTelemetry.started(:source, request["move_id"], request["source_epoch"])

  defp started(_request, _phase), do: System.monotonic_time(:millisecond)

  # -- before move_ready -------------------------------------------------------

  defp transfer(ctx) do
    {:ok, phase} = Move.read_phase(ctx.home)
    attempt = (phase["attempts"] || 0) + 1

    if attempt > Move.max_attempts() do
      abort(ctx, :attempts_spent, "The move to #{name(ctx)} failed #{Move.max_attempts()} times.")
    else
      :ok = record(ctx, "streaming", %{"attempts" => attempt, "sentence" => nil})
      attempt_transfer(Map.put(ctx, :attempt, attempt))
    end
  end

  defp attempt_transfer(ctx) do
    with {:ok, desktop} <- ensure_desktop(ctx),
         :ok <- record(ctx, "streaming", %{"device_id" => desktop.device_id}),
         {:ok, snapshot} <- capture(ctx),
         {:ok, rail} <- open_candidate(ctx) do
      case stream(ctx, rail, snapshot) do
        {:ok, epoch} ->
          commit(ctx, rail, desktop, epoch)

        {:error, reason} ->
          close_rail(rail)
          attempt_failed(ctx, reason)
      end
    else
      {:error, reason} -> attempt_failed(ctx, reason)
    end
  end

  defp attempt_failed(ctx, {:refused, code, message}),
    do: abort(ctx, {:refused, code}, "#{name(ctx)} refused the move (#{code}: #{message}).")

  # Neither comes right on another attempt: the owner acts first.
  defp attempt_failed(ctx, {:secrets, sentence}), do: abort(ctx, :secrets, sentence)

  defp attempt_failed(ctx, {:capture, {:insufficient_space, _need, _free} = reason}),
    do: abort(ctx, {:capture, :insufficient_space}, Run.capture_sentence(reason))

  defp attempt_failed(ctx, {:capture, {:free_space_unknown, _reason} = reason}),
    do: abort(ctx, {:capture, :free_space_unknown}, Run.capture_sentence(reason))

  defp attempt_failed(ctx, reason) do
    Logger.warning(
      "move: an attempt to send this home to #{name(ctx)} failed: #{inspect(reason)}"
    )

    ctx.sleep.(@retry_pause_ms)
    transfer(ctx)
  end

  # A source kept as a desktop gets its key and row before anything is
  # captured; one that is not gets neither.
  defp ensure_desktop(ctx) do
    if Move.keep_as_desktop?(ctx.request),
      do: desktop_key(ctx),
      else: {:ok, %{device_id: nil, keypair: nil}}
  end

  defp desktop_key(ctx) do
    case DesktopLink.read_key(ctx.home) do
      {:ok, keypair} -> desktop_row(ctx, keypair)
      {:error, {:file, _path, :enoent}} -> new_desktop(ctx)
      {:error, reason} -> {:error, {:desktop_key, reason}}
    end
  end

  defp new_desktop(ctx) do
    keypair = Noise.generate_keypair()

    with :ok <- DesktopLink.write_key(ctx.home, keypair.private), do: desktop_row(ctx, keypair)
  end

  # The row is found by the key, so a restart between the key and the row (or
  # after both) adds it once.
  defp desktop_row(ctx, keypair) do
    case DeviceStore.find_by_noise_pk(keypair.public, root: ctx.home) do
      {:ok, device} -> {:ok, %{device_id: device.device_id, keypair: keypair}}
      {:error, {:noise_identity_not_found, _key}} -> add_row(ctx, keypair)
      {:error, reason} -> {:error, {:device_store, reason}}
    end
  end

  defp add_row(ctx, keypair) do
    attrs = %{
      device_id: uuid(),
      name: host_name(),
      model: "#{os()} desktop",
      noise_pk: keypair.public,
      created_at: DateTime.truncate(ctx.clock.(), :second),
      kind: :desktop
    }

    case DeviceStore.add(attrs, root: ctx.home) do
      {:ok, device} -> {:ok, %{device_id: device.device_id, keypair: keypair}}
      {:error, reason} -> {:error, {:device_store, reason}}
    end
  end

  # One capture serves every attempt: the home is unchanged while this engine
  # is in the device role, so the file an earlier attempt wrote, of the size
  # the phase recorded, is sent again.
  defp capture(ctx) do
    path = Move.snapshot_path(ctx.home, ctx.request["move_id"])
    {:ok, phase} = Move.read_phase(ctx.home)

    case {phase["capture"], File.stat(path)} do
      {%{"size" => size, "sha256" => sha256}, {:ok, %File.Stat{type: :regular, size: size}}} ->
        {:ok, %{path: path, size: size, sha256: sha256}}

      _none ->
        capture_anew(ctx, path)
    end
  end

  defp capture_anew(ctx, path) do
    _ = File.rm(path)

    recipient = %{
      salt: :crypto.strong_rand_bytes(16),
      public_key: ctx.request["candidate"].recipient
    }

    with {:ok, extra} <- keychain_files(ctx),
         {:ok, written} <- write_capture(ctx, recipient, path, extra),
         :ok <- record(ctx, "streaming", %{"capture" => Map.take(written, ["size", "sha256"])}) do
      {:ok, %{path: path, size: written["size"], sha256: written["sha256"]}}
    end
  end

  defp write_capture(ctx, recipient, path, extra) do
    opts = Keyword.put(ctx.snapshot_opts, :extra_files, extra)

    case Snapshot.write(ctx.home, recipient, path, opts) do
      {:ok, written} -> {:ok, %{"size" => written.size, "sha256" => written.sha256}}
      {:error, reason} -> {:error, {:capture, reason}}
    end
  end

  # The keychain's values for the references in config.toml, as files of the
  # file store inside the capture; their values go nowhere else.
  defp keychain_files(ctx) do
    text =
      case File.read(Path.join(ctx.home, "config.toml")) do
        {:ok, text} -> text
        {:error, :enoent} -> ""
      end

    with {:ok, refs} <- MoveSecrets.references(text),
         {:ok, values} <- MoveSecrets.read(refs, MoveSecrets.profile(text)) do
      {:ok, MoveSecrets.extra_files(values)}
    else
      {:error, {:unreadable, ids}} ->
        Logger.warning("home move: the keychain gave nothing for #{Enum.join(ids, ", ")}")
        secrets = MoveSecrets.described(ids, Settings.secret_names())
        them = if match?([_one], ids), do: "it", else: "them"

        {:error,
         {:secrets,
          "The keychain did not give Fermix #{secrets}, so nothing moved: unlock it, or set " <>
            "#{them} again or clear #{them} in settings, then start the move again."}}

      {:error, {:unknown, keys}} ->
        Logger.warning("home move: no setting names the keychain items #{inspect(keys)}")

        {setting, them} =
          if match?([_one], keys), do: {"setting", "it"}, else: {"settings", "them"}

        {:error,
         {:secrets,
          "Fermix cannot tell which #{setting} #{MoveSecrets.unknown_items(keys)} to, so " <>
            "nothing moved: set #{them} again in settings, then start the move again."}}
    end
  end

  defp stream(ctx, rail, snapshot) do
    move_id = ctx.request["move_id"]

    offer = %{
      "move_id" => move_id,
      "size_bytes" => snapshot.size,
      "sha256" => snapshot.sha256,
      "source_epoch" => ctx.request["source_epoch"],
      "recovery_recipient" => ctx.request["recovery_recipient"],
      "attempt" => ctx.attempt
    }

    with :ok <- Rail.send_event(rail, "move_offer", offer),
         {:ok, accept} <- await(rail, "move_accept", @accept_ms),
         :ok <- same_recipient(accept, ctx),
         :ok <- send_file(rail, move_id, snapshot.path),
         :ok <- Rail.send_event(rail, "move_end", %{"move_id" => move_id}),
         {:ok, %{"epoch" => epoch}} <- await(rail, "move_ready", @ready_ms) do
      {:ok, epoch}
    end
  end

  defp same_recipient(%{"recipient" => recipient}, ctx) do
    if Base.decode64(recipient) == {:ok, ctx.request["candidate"].recipient},
      do: :ok,
      else: {:error, {:refused, "move_mismatch", "the candidate's key changed; enroll it again"}}
  end

  defp send_file(rail, move_id, path) do
    File.open(path, [:read, :binary], fn io -> send_chunks(rail, move_id, io, 0) end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, {:file, path, reason}}
    end
  end

  defp send_chunks(rail, move_id, io, index) do
    case IO.binread(io, @chunk_bytes) do
      :eof ->
        :ok

      {:error, reason} ->
        {:error, {:read, reason}}

      bytes ->
        payload = %{"move_id" => move_id, "index" => index}

        with :ok <- Rail.send_event(rail, "move_chunk", payload, bytes),
             do: send_chunks(rail, move_id, io, index + 1)
    end
  end

  # -- the commit -------------------------------------------------------------

  # The ready epoch is recorded before the marker, so a restart after the
  # marker knows what it resumes; the marker comes before move_commit, so the
  # candidate never activates while this home could still serve. Up to the
  # marker a failure aborts (nothing told the candidate to commit); from it on,
  # a failure only resumes.
  defp commit(ctx, rail, desktop, epoch) do
    with :ok <- record(ctx, "streaming", %{"ready_epoch" => epoch}),
         :ok <- retire(ctx) do
      retired(ctx, rail, desktop, epoch)
    else
      {:error, reason} ->
        close_rail(rail)
        abort(ctx, {:retire, reason}, "This home could not be marked moved (#{inspect(reason)}).")
    end
  end

  defp retired(ctx, rail, desktop, epoch) do
    with :ok <- link(ctx, desktop.device_id, epoch),
         :ok <- record(ctx, "committing", %{"sentence" => nil}),
         :ok <- Rail.send_event(rail, "move_commit", %{"move_id" => ctx.request["move_id"]}),
         {:ok, %{"epoch" => done_epoch}} <- await(rail, "move_done", @done_ms) do
      done(ctx, done_epoch)
    else
      {:error, reason} ->
        close_rail(rail)
        resume_after(ctx, reason)
    end
  end

  defp resume_after(ctx, reason) do
    Logger.warning(
      "move: the commit to #{name(ctx)} was not confirmed (#{inspect(reason)}); resuming"
    )

    resume(ctx)
  end

  defp retire(ctx) do
    marker = %{
      epoch: ctx.request["source_epoch"],
      moved_at: DateTime.truncate(ctx.clock.(), :second),
      to: name(ctx)
    }

    case Moved.write(ctx.home, marker) do
      :ok -> :ok
      {:error, {:already_moved, %{to: to}}} when to == marker.to -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # No desktop, no link: a source that is not kept serves nothing.
  defp link(_ctx, nil, _epoch), do: :ok

  defp link(ctx, device_id, epoch) do
    with {:ok, identity} <- Identity.load(root: ctx.home),
         {:ok, node_id} <- node_id(ctx.home) do
      current = Relays.current()

      DesktopLink.write(ctx.home, %{
        device_id: device_id,
        primary: %{
          name: name(ctx),
          gateway_pk: identity.gateway_public_key,
          node_id: node_id,
          relays: Relays.to_wire(current.relays),
          relays_rev: current.id
        },
        epoch: epoch
      })
    end
  end

  defp node_id(home) do
    case File.read(Key.path(home)) do
      {:ok, <<_::256>> = secret} -> {:ok, Key.endpoint_id(secret)}
      {:ok, _other} -> {:error, {:iroh_key_invalid, Key.path(home)}}
      {:error, reason} -> {:error, {:file, Key.path(home), reason}}
    end
  end

  # -- resuming after the marker ----------------------------------------------

  defp resume(ctx) do
    {:ok, phase} = Move.read_phase(ctx.home)
    epoch = phase["ready_epoch"]

    with :ok <- ensure_link(ctx, phase, epoch),
         :ok <- record(ctx, "committing", %{}) do
      deadline = System.monotonic_time(:millisecond) + ctx.resume_for_ms
      resume_loop(ctx, epoch, deadline, @first_resume_ms)
    else
      {:error, reason} ->
        Logger.error("move: the desktop link could not be written: #{inspect(reason)}")
        unconfirmed(ctx, "committing", "The desktop link to #{name(ctx)} could not be written.")
    end
  end

  defp ensure_link(ctx, phase, epoch) do
    if File.regular?(DesktopLink.path(ctx.home)),
      do: :ok,
      else: link(ctx, phase["device_id"], epoch)
  end

  defp resume_loop(ctx, epoch, deadline, pause_ms) do
    case resume_once(ctx, epoch) do
      {:ok, done_epoch} ->
        done(ctx, done_epoch)

      {:error, reason} ->
        if System.monotonic_time(:millisecond) >= deadline do
          unconfirmed(
            ctx,
            "committing",
            "#{name(ctx)} has not confirmed the move (#{inspect(reason)})."
          )
        else
          ctx.sleep.(pause_ms)
          resume_loop(ctx, epoch, deadline, min(pause_ms * 2, @max_resume_ms))
        end
    end
  end

  defp resume_once(ctx, epoch) do
    case open_candidate(ctx) do
      {:ok, rail} -> with_rail(rail, &resume_on(ctx, &1))
      {:error, _unreachable} -> probe_primary(ctx, epoch)
    end
  end

  defp resume_on(ctx, rail) do
    move_id = ctx.request["move_id"]

    with :ok <- Rail.send_event(rail, "move_resume", %{"move_id" => move_id}),
         {:ok, answer} <- await_any(rail, ["move_ready", "move_done"], @done_ms) do
      resumed(answer, rail, move_id)
    end
  end

  # Activated already, or still staged and committed now.
  defp resumed(%{"t" => "move_done", "epoch" => epoch}, _rail, _move_id), do: {:ok, epoch}

  defp resumed(%{"t" => "move_ready"}, rail, move_id) do
    with :ok <- Rail.send_event(rail, "move_commit", %{"move_id" => move_id}),
         {:ok, %{"epoch" => epoch}} <- await(rail, "move_done", @done_ms),
         do: {:ok, epoch}
  end

  # The moved identity answering as a primary at the ready epoch or later is
  # the candidate activated: only it holds the gateway key and the epoch.
  defp probe_primary(ctx, epoch) do
    with {:ok, link} <- DesktopLink.read(ctx.home),
         {:ok, keypair} <- DesktopLink.read_key(ctx.home),
         route = Map.take(link.primary, [:node_id, :relays, :relays_rev]),
         {:ok, rail} <-
           rail_open(ctx, route, :ik,
             static_keypair: keypair,
             remote_static: link.primary.gateway_pk
           ) do
      with_rail(rail, &hello_epoch(&1, link.device_id, epoch))
    end
  end

  defp hello_epoch(rail, device_id, epoch) do
    with :ok <- Rail.send_event(rail, "hello", hello(device_id, epoch)),
         {:ok, %{"primary_epoch" => seen}} <- await(rail, "hello_ack", @done_ms) do
      if seen >= epoch, do: {:ok, seen}, else: {:error, {:stale_primary, seen}}
    end
  end

  # Runs `fun` on an open session, then ends the session, however `fun` ended.
  defp with_rail(rail, fun) do
    result = fun.(rail)
    close_rail(rail)
    result
  end

  # A session the far end already closed has nothing left to close.
  defp close_rail(rail) do
    Rail.close(rail)
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal] -> :ok
  end

  defp hello(device_id, epoch) do
    %{
      "device_id" => device_id,
      "app_version" => BuildInfo.product_version(),
      "last_server_seq" => 0,
      "protocol_v" => Protocol.protocol_version(),
      "primary_epoch" => epoch
    }
  end

  # Whether this home retired cannot be told, so it neither sends nor undoes
  # anything until the marker is readable again.
  defp marker_sentence(reason),
    do: "The moved marker could not be read (#{inspect(reason)}); fix it and restart Fermix."

  # A request or phase file this worker cannot read: nothing is sent or undone
  # until it can be, and the phase says why.
  defp unreadable(ctx, reason) do
    sentence =
      "The move's own files could not be read; nothing was sent or undone, and Fermix " <>
        "looks again when it restarts."

    Logger.error("move: #{sentence} (#{inspect(reason)})")

    case Move.read_phase(ctx.home) do
      {:ok, %{"phase" => phase}} ->
        :ok = Move.put_phase(ctx.home, phase, %{"sentence" => sentence}, ctx.clock.())

      _unreadable ->
        :ok
    end
  end

  defp unconfirmed(ctx, phase, sentence) do
    :ok = record(ctx, phase, %{"sentence" => sentence})
    Logger.error("move: #{sentence}")
    :ok
  end

  # -- endings ----------------------------------------------------------------

  # `committed`, not `done`: the ending is the relaunched desktop's to say
  # (`Move.finish_at_boot/2`), with its link to the new primary beside it.
  defp done(ctx, epoch) do
    :ok = record(ctx, "committed", %{"sentence" => nil, "epoch" => epoch})
    _ = File.rm(Move.snapshot_path(ctx.home, ctx.request["move_id"]))
    :ok = Move.remove_request(ctx.home)
    MoveTelemetry.finished(:source, ctx.request["move_id"], epoch, :done, ctx.started_ms)

    Logger.info(
      "move: this home moved to #{name(ctx)} at epoch #{epoch}; restarting " <>
        if(Move.keep_as_desktop?(ctx.request), do: "as its desktop", else: "to serve nothing")
    )

    ctx.restart.()
  end

  # Only before the marker: once `moved.json` exists a move is resumed, never
  # undone, so the abort checks for it again before it changes anything.
  defp abort(ctx, reason, sentence) do
    case Moved.read(ctx.home) do
      :absent -> undo(ctx, reason, sentence)
      {:ok, _marker} -> resume(ctx)
      {:error, read_error} -> raise "the moved marker could not be read: #{inspect(read_error)}"
    end
  end

  defp undo(ctx, reason, sentence) do
    {:ok, phase} = Move.read_phase(ctx.home)
    :ok = record(ctx, "aborting", %{"sentence" => sentence})
    :ok = remove_desktop(ctx, phase["device_id"])
    _ = File.rm(Move.snapshot_path(ctx.home, ctx.request["move_id"]))
    :ok = ConfigStore.put_engine_role(ctx.home, :primary)
    :ok = Move.remove_request(ctx.home)
    :ok = record(ctx, "undoing", %{"sentence" => sentence})

    MoveTelemetry.finished(
      :source,
      ctx.request["move_id"],
      nil,
      {:aborted, reason},
      ctx.started_ms
    )

    Logger.warning("move: aborted, this home is the primary again: #{sentence}")
    ctx.restart.()
  end

  defp remove_desktop(ctx, device_id) do
    with :ok <- remove_row(ctx.home, device_id) do
      case File.rm(DesktopLink.key_path(ctx.home)) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, {:file, DesktopLink.key_path(ctx.home), reason}}
      end
    end
  end

  defp remove_row(_home, nil), do: :ok

  defp remove_row(home, device_id) do
    case DeviceStore.delete(device_id, root: home) do
      :ok -> :ok
      {:error, {:device_not_found, _id}} -> :ok
      {:error, reason} -> {:error, {:device_store, reason}}
    end
  end

  # -- the rail ---------------------------------------------------------------

  defp open_candidate(ctx) do
    candidate = ctx.request["candidate"]

    with {:ok, identity} <- Identity.load(root: ctx.home) do
      keypair = %{private: identity.gateway_private_key, public: identity.gateway_public_key}

      route = %{
        node_id: candidate.node_id,
        relays: candidate.relays,
        relays_rev: Relays.current().id
      }

      rail_open(ctx, route, :ik_move, static_keypair: keypair, remote_static: candidate.noise_pk)
    end
  end

  defp rail_open(ctx, route, mode, keys) do
    carrier =
      case ctx.connect do
        nil -> [helper: ctx.helper]
        connect -> [connect: connect.(route)]
      end

    Rail.open(route, mode, keys ++ carrier)
  end

  defp await(rail, type, timeout_ms) do
    case await_any(rail, [type], timeout_ms) do
      {:ok, header} -> {:ok, header}
      {:error, _reason} = error -> error
    end
  end

  defp await_any(rail, types, timeout_ms) do
    receive do
      {:rail, ^rail, {:event, %{"t" => "error", "code" => code} = error, _bytes}} ->
        {:error, {:refused, code, error["message"]}}

      {:rail, ^rail, {:event, %{"t" => type} = header, _bytes}} ->
        if type in types, do: {:ok, header}, else: await_any(rail, types, timeout_ms)

      {:rail, ^rail, {:closed, reason}} ->
        {:error, {:closed, reason}}
    after
      timeout_ms -> {:error, {:timeout, types}}
    end
  end

  # -- facts ------------------------------------------------------------------

  defp record(ctx, phase, fields) do
    fields =
      Map.merge(%{"move_id" => ctx.request["move_id"], "candidate" => name(ctx)}, fields)

    Move.put_phase(ctx.home, phase, fields, ctx.clock.())
  end

  defp name(ctx), do: ctx.request["candidate"].name

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    [<<a::32>>, <<b::16>>, <<c::16>>, <<d::16>>, <<e::48>>]
    |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
  end

  defp host_name do
    {:ok, name} = :inet.gethostname()
    name |> to_string() |> String.slice(0, 64)
  end

  defp os do
    case :os.type() do
      {:unix, :darwin} -> "macOS"
      {:unix, :linux} -> "Linux"
      {_family, other} -> Atom.to_string(other)
    end
  end
end
