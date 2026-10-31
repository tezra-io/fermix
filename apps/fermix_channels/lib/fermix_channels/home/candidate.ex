defmodule FermixChannels.Home.Candidate do
  @moduledoc """
  The candidate process (M75 §7.1, §7.2, B4): what a `candidate`-role engine
  runs, beside its own iroh helper and bridge (`Home.CandidateSupervisor`),
  and the one writer of `<home>/candidate/state.json`
  (`FermixCore.Home.Candidate`) after `fermix home enroll`.

  **Enrollment.** In phase `enrolling` it dials the primary the code names
  (`Mobile.Rail`, `:ikpsk2_enroll`: its Noise key, the code's gateway key and
  secret) and sends `enroll_request` with its host, its own iroh route, the
  one-time snapshot recipient, and the destination facts it was given. On
  `enroll_accepted` it removes the code and waits for the move, up to 24
  hours (`enrolled`); after that it stops waiting (`expired`). A
  refusal (`enrollment_expired`, `used`, `limit`) ends it (`failed`), logged
  by its code; an unreachable primary is tried again, 1 s doubling to 60 s,
  until the code expires. Every ending removes the code: a burnt or expired
  code is worth nothing, and it is not kept on the disk.

  **The move.** `FermixChannels.Home.MoveResponder`, on the candidate's own
  endpoint, asks this process for each step, so every phase change goes
  through here and is written before it is answered: an offer starts
  `receiving` (any earlier stream or staging is discarded) when the disk
  holds twice the offered stream plus a floor (the stream and the restored
  home, `FermixCore.Home.Disk`; `move_failed` naming the need otherwise,
  before any byte moves), but only an offer
  later than the move it holds (a later move id, which is ordered by when the
  move started, or a later attempt of the same move), so a late offer from a
  session its source gave up on never discards a staged home; `stage/3`
  restores the stream into `candidate/staging` in a task and records
  `staged`; `commit/2` records `activating`, renames the staged home into
  place (`FermixCore.Home.Candidate.Activation`) and restarts the engine,
  which then boots as the primary. Nothing activates without `move_commit`.
  A restart in `activating` finishes the renames and restarts again.

  An activation that fails part-way (a rename refused, a full disk) records
  its sentence and is tried again on a timer, 1 s doubling to 5 minutes, at
  most #{12} times in a run of the engine (the next start tries again). Until
  the renames are done, `move_resume` is answered `move_failed`, never
  `move_done`, so the source keeps resuming rather than finishing beside a
  primary that does not exist yet.

  The restart is the daemon's deliberate self-restart
  (`Management.Lifecycle.restart_self/0`: the systemd start budget reset first,
  then the one stop path), which the service manager brings back.

  Test seams: `:home`, `:helper`, `:name`, `:clock` (0-arity `DateTime`),
  `:schedule` (2-arity `Process.send_after/3` stand-in), `:restart`,
  `:rail_opts` (extra `Mobile.Rail.open/3` options, such as `:connect`),
  `:restore_opts` (for `Snapshot.restore/4`), `:task_supervisor`, `:host`,
  `:free_bytes` (a 1-arity reader of free space).
  """

  use GenServer

  require Logger

  alias FermixChannels.Mobile.Iroh.Relays
  alias FermixChannels.Mobile.Rail
  alias FermixCore.BuildInfo
  alias FermixCore.Home.Candidate, as: Files
  alias FermixCore.Home.Candidate.Activation
  alias FermixCore.Home.Disk
  alias FermixCore.Home.MoveTelemetry
  alias FermixCore.Management.Lifecycle
  alias FermixCore.Setup.ConfigStore

  @listen_s 24 * 3_600
  @first_retry_ms 1_000
  @max_retry_ms 60_000
  @answer_ms 30_000
  @restart_after_ms 1_000
  @first_activation_retry_ms 1_000
  @max_activation_retry_ms 300_000
  @max_activation_tries 12
  @moving ~w(enrolled receiving staged activating)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Whether this candidate takes a move now (it enrolled and has not finished)."
  @spec serving?(GenServer.server()) :: boolean()
  def serving?(server \\ __MODULE__) do
    if GenServer.whereis(server), do: GenServer.call(server, :serving?), else: false
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] -> false
  end

  @doc "The keys the move responder needs: its own, the source's, and the recipient."
  @spec keys(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def keys(server \\ __MODULE__), do: GenServer.call(server, :keys)

  @doc """
  A `move_offer` arrived: answers the recipient (standard base64) and where to
  write the stream, or `{:error, code, sentence}`.
  """
  @spec offer(GenServer.server(), map()) :: {:ok, map()} | {:error, String.t(), String.t()}
  def offer(server \\ __MODULE__, facts) when is_map(facts),
    do: GenServer.call(server, {:offer, facts})

  @doc """
  The stream of `move_id` is complete: restore it. `reply_to` later gets
  `{:candidate_staged, move_id, {:ok, epoch} | {:error, sentence}}`.
  """
  @spec stage(GenServer.server(), String.t(), pid()) :: :ok | {:error, String.t(), String.t()}
  def stage(server \\ __MODULE__, move_id, reply_to) when is_pid(reply_to),
    do: GenServer.call(server, {:stage, move_id, reply_to})

  @doc "`move_commit`: activate, then restart. Answers the epoch."
  @spec commit(GenServer.server(), String.t()) ::
          {:ok, pos_integer()} | {:error, String.t(), String.t()}
  def commit(server \\ __MODULE__, move_id),
    do: GenServer.call(server, {:commit, move_id}, 60_000)

  @doc "`move_resume`: where `move_id` stands here."
  @spec resume(GenServer.server(), String.t()) ::
          {:staged, pos_integer()} | {:activated, pos_integer()} | :activating | :unknown
  def resume(server \\ __MODULE__, move_id), do: GenServer.call(server, {:resume, move_id})

  @impl true
  def init(opts) do
    home = Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)

    state = %{
      home: home,
      helper: Keyword.get(opts, :helper),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      schedule: Keyword.get(opts, :schedule, &Process.send_after(self(), &1, &2)),
      restart: Keyword.get(opts, :restart, &Lifecycle.restart_self/0),
      rail_opts: Keyword.get(opts, :rail_opts, []),
      restore_opts: Keyword.get(opts, :restore_opts, []),
      tasks: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
      host: Keyword.get_lazy(opts, :host, &host_facts/0),
      free_bytes: Keyword.get(opts, :free_bytes, &Disk.free_bytes/1),
      activation_tries: 0,
      phase: nil,
      enroll: nil,
      retry_ms: @first_retry_ms,
      restore: nil,
      started_ms: nil,
      activated?: false
    }

    {:ok, state, {:continue, :resume}}
  end

  @impl true
  def handle_continue(:resume, state) do
    case Files.read_state(state.home) do
      {:ok, phase_state} -> {:noreply, carry_on(%{state | phase: phase_state})}
      {:error, reason} -> {:stop, {:candidate_state, reason}, state}
    end
  end

  defp carry_on(%{phase: %{"phase" => "activating"}} = state), do: finish_activation(state)
  defp carry_on(%{phase: %{"phase" => "enrolling"}} = state), do: start_enroll(state)
  defp carry_on(%{phase: %{"phase" => "enrolled"}} = state), do: arm_listen_end(state)
  defp carry_on(state), do: state

  @impl true
  def handle_call(:serving?, _from, state),
    do: {:reply, state.phase["phase"] in @moving, state}

  def handle_call(:keys, _from, state) do
    reply =
      with {:ok, noise} <- Files.noise_keypair(state.home),
           {:ok, pair} <- Files.recipient_pair(state.home),
           {:ok, source_pk} <- Base.decode64(state.phase["primary"]["gateway_pk"]) do
        {:ok, %{noise: noise, source_pk: source_pk, recipient: pair}}
      end

    {:reply, reply, state}
  end

  def handle_call({:offer, facts}, _from, state), do: offer_move(facts, state)

  def handle_call({:stage, move_id, reply_to}, _from, state),
    do: stage_move(move_id, reply_to, state)

  def handle_call({:commit, move_id}, _from, state), do: commit_move(move_id, state)

  def handle_call({:resume, move_id}, _from, state) do
    reply =
      case state.phase do
        %{"phase" => "staged", "move" => %{"move_id" => ^move_id, "epoch" => epoch}} ->
          {:staged, epoch}

        %{"phase" => "activating", "move" => %{"move_id" => ^move_id, "epoch" => epoch}}
        when state.activated? ->
          {:activated, epoch}

        %{"phase" => "activating", "move" => %{"move_id" => ^move_id}} ->
          :activating

        _other ->
          :unknown
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info({ref, result}, %{enroll: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, enrolled(result, %{state | enroll: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{enroll: ref} = state),
    do: {:noreply, enrolled({:error, {:crashed, reason}}, %{state | enroll: nil})}

  def handle_info({ref, result}, %{restore: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, restored(result, state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{restore: %{ref: ref}} = state),
    do: {:noreply, restored({:error, {:crashed, reason}}, state)}

  def handle_info(:enroll, state), do: {:noreply, start_enroll(state)}

  def handle_info(:activate, %{phase: %{"phase" => "activating"}, activated?: false} = state),
    do: {:noreply, finish_activation(state)}

  def handle_info(:activate, state), do: {:noreply, state}
  def handle_info(:listen_end, state), do: {:noreply, listen_end(state)}

  def handle_info(:restart, state) do
    :ok = state.restart.()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- enrollment -------------------------------------------------------------

  defp start_enroll(state) do
    case enroll_params(state) do
      {:ok, params} ->
        task = Task.Supervisor.async_nolink(state.tasks, fn -> enroll_once(params) end)
        %{state | enroll: task.ref}

      {:error, reason} ->
        fail(state, "The candidate's files could not be read (#{inspect(reason)}).")
    end
  end

  defp enroll_params(state) do
    with {:ok, code} <- Files.read_code(state.home),
         {:ok, noise} <- Files.noise_keypair(state.home),
         {:ok, pair} <- Files.recipient_pair(state.home),
         {:ok, destination} <- Files.destination(state.home),
         {:ok, iroh} <- File.read(Path.join([Files.dir(state.home), "mobile", "iroh_key"])) do
      {:ok,
       %{
         code: code,
         route: %{node_id: code.node_id, relays: code.relays, relays_rev: code.relays_rev},
         rail_opts:
           [static_keypair: noise, remote_static: code.gateway_pk, psk: code.secret] ++
             helper_opts(state),
         request: enroll_request(state.host, iroh, pair, destination)
       }}
    end
  end

  defp helper_opts(%{rail_opts: []} = state), do: [helper: state.helper]
  defp helper_opts(state), do: state.rail_opts

  defp enroll_request(host, iroh_secret, pair, destination) do
    {iroh_public, _secret} = :crypto.generate_key(:eddsa, :ed25519, iroh_secret)

    %{
      "host" => host,
      "candidate" => %{
        "node_id" => Base.encode16(iroh_public, case: :lower),
        "relays" => Relays.to_wire(Relays.acknowledged([])),
        "recipient" => Base.encode64(pair.public_key)
      }
    }
    |> put_unless_empty("snapshots", destination)
  end

  defp put_unless_empty(map, _key, facts) when facts == %{}, do: map
  defp put_unless_empty(map, key, facts), do: Map.put(map, key, facts)

  @doc false
  @spec enroll_once(map()) :: {:ok, map()} | {:error, term()}
  def enroll_once(%{route: route, rail_opts: rail_opts, request: request}) do
    case Rail.open(route, :ikpsk2_enroll, rail_opts) do
      {:ok, rail} ->
        with :ok <- Rail.send_event(rail, "enroll_request", request), do: await_answer(rail)

      {:error, reason} ->
        {:error, {:rail, reason}}
    end
  end

  defp await_answer(rail) do
    receive do
      {:rail, ^rail, {:event, %{"t" => "enroll_accepted"} = accepted, _bytes}} ->
        {:ok, accepted}

      {:rail, ^rail, {:event, %{"t" => "error", "code" => code} = error, _bytes}} ->
        {:error, {:refused, code, error["message"]}}

      {:rail, ^rail, {:event, _other, _bytes}} ->
        await_answer(rail)

      {:rail, ^rail, {:closed, reason}} ->
        {:error, {:closed, reason}}
    after
      @answer_ms -> {:error, :no_answer}
    end
  end

  defp enrolled({:ok, %{"candidate_id" => id, "primary_name" => name}}, state) do
    now = state.clock.()

    with :ok <- Files.drop_code(state.home) do
      Logger.info("candidate: enrolled with #{name} as #{id}")

      put(state, "enrolled", %{
        "candidate_id" => id,
        "enrolled_at" => iso(now),
        "listen_until" => iso(DateTime.add(now, @listen_s, :second)),
        "sentence" => nil
      })
      |> arm_listen_end()
    else
      {:error, reason} ->
        fail(state, "The enrollment code could not be removed (#{inspect(reason)}).")
    end
  end

  defp enrolled({:error, {:refused, code, message}}, state) do
    Logger.warning("candidate: the primary refused the enrollment: #{code}")
    fail(state, refused_sentence(code, message, state))
  end

  defp enrolled({:error, reason}, state) do
    case Files.read_code(state.home) do
      {:ok, code} -> retry_or_fail(code, reason, state)
      {:error, _gone} -> fail(state, "The enrollment code is gone (#{inspect(reason)}).")
    end
  end

  defp retry_or_fail(code, reason, state) do
    if DateTime.compare(state.clock.(), code.expires_at) == :lt do
      Logger.info("candidate: #{code.name} not reached yet (#{inspect(reason)}); trying again")
      state.schedule.(:enroll, state.retry_ms)
      %{state | retry_ms: min(state.retry_ms * 2, @max_retry_ms)}
    else
      fail(state, "The enrollment code expired before this host reached #{code.name}.")
    end
  end

  defp refused_sentence("enrollment_used", _message, state),
    do: "The enrollment code was already used at #{primary_name(state)}; open a new one there."

  defp refused_sentence("enrollment_expired", _message, state),
    do: "The enrollment code expired at #{primary_name(state)}; open a new one there."

  defp refused_sentence("enrollment_limit", _message, state),
    do: "#{primary_name(state)} already holds four candidates."

  defp refused_sentence(code, message, state),
    do: "#{primary_name(state)} refused the enrollment (#{code}: #{message})."

  defp arm_listen_end(state) do
    {:ok, until, _offset} = DateTime.from_iso8601(state.phase["listen_until"])
    delay = max(DateTime.diff(until, state.clock.(), :millisecond), 0)
    state.schedule.(:listen_end, delay)
    state
  end

  defp listen_end(%{phase: %{"phase" => "enrolled"}} = state) do
    put(state, "expired", %{
      "sentence" => "No move came from #{primary_name(state)} within 24 hours; enroll again."
    })
  end

  defp listen_end(state), do: state

  # -- the move ---------------------------------------------------------------

  defp offer_move(facts, state) do
    case state.phase["phase"] do
      phase when phase in ~w(enrolled receiving staged) ->
        fenced_offer(facts, state)

      phase ->
        {:reply, {:error, "move_failed", "This candidate takes no move now (#{phase})."}, state}
    end
  end

  # An offer replaces the move under way only when it is later: a later move
  # (move ids are ordered by when the move started) or a later attempt of the
  # same one. An earlier offer that arrives late, on a session its source
  # already gave up on, would discard a staged home its source may already
  # have retired for.
  defp fenced_offer(facts, state) do
    if later?(facts, state.phase["move"]),
      do: accept_offer(facts, state),
      else:
        {:reply,
         {:error, "move_mismatch", "That offer is older than the move this candidate holds."},
         state}
  end

  defp later?(_offer, nil), do: true

  defp later?(%{"move_id" => id, "attempt" => attempt}, %{"move_id" => held_id} = held),
    do: {id, attempt} > {held_id, held["attempt"] || 0}

  defp accept_offer(facts, state) do
    with :ok <- room_for(facts["size_bytes"], state),
         :ok <- discard(Files.incoming_path(state.home)),
         :ok <- discard_tree(Files.staging_path(state.home)),
         {:ok, pair} <- Files.recipient_pair(state.home) do
      state = started(facts["move_id"], facts["source_epoch"], state)
      state = put(state, "receiving", %{"move" => facts, "sentence" => nil})

      {:reply,
       {:ok,
        %{recipient: Base.encode64(pair.public_key), incoming: Files.incoming_path(state.home)}},
       state}
    else
      {:error, {:no_room, sentence}} ->
        {:reply, {:error, "move_failed", sentence}, state}

      {:error, reason} ->
        {:reply, {:error, "move_failed", "The candidate could not prepare: #{inspect(reason)}."},
         state}
    end
  end

  # The stream and the home restored from it sit on this disk together.
  defp room_for(size, state) do
    need = Disk.capture_need(size)

    case state.free_bytes.(state.home) do
      {:ok, free} when free >= need ->
        :ok

      {:ok, free} ->
        {:error,
         {:no_room,
          "This server needs about #{Disk.gib(need)} free for the move and has " <>
            "#{Disk.gib(free)}: give its disk more space, then move again."}}

      {:error, reason} ->
        Logger.error("candidate: the free space could not be read: #{inspect(reason)}")
        {:error, {:no_room, "This server could not tell how much space its disk has."}}
    end
  end

  defp stage_move(
         move_id,
         reply_to,
         %{phase: %{"phase" => "receiving", "move" => %{"move_id" => move_id} = move}} = state
       ) do
    {:ok, pair} = Files.recipient_pair(state.home)
    {:ok, destination} = Files.destination(state.home)
    facts = %{"destination" => destination, "recovery_recipient" => move["recovery_recipient"]}
    incoming = Files.incoming_path(state.home)
    restore_opts = state.restore_opts
    home = state.home

    task =
      Task.Supervisor.async_nolink(state.tasks, fn ->
        Activation.stage(home, incoming, pair, facts, restore_opts)
      end)

    {:reply, :ok, %{state | restore: %{ref: task.ref, move_id: move_id, reply_to: reply_to}}}
  end

  defp stage_move(_move_id, _reply_to, state),
    do:
      {:reply, {:error, "move_mismatch", "That is not the move this candidate is receiving."},
       state}

  defp restored({:ok, epoch}, %{restore: %{move_id: move_id, reply_to: reply_to}} = state) do
    _ = discard(Files.incoming_path(state.home))
    move = Map.put(state.phase["move"], "epoch", epoch)
    state = put(%{state | restore: nil}, "staged", %{"move" => move})
    send(reply_to, {:candidate_staged, move_id, {:ok, epoch}})
    state
  end

  defp restored({:error, reason}, %{restore: %{move_id: move_id, reply_to: reply_to}} = state) do
    Logger.error("candidate: the move #{move_id} could not be restored: #{inspect(reason)}")
    sentence = "The home from #{primary_name(state)} could not be restored here."
    finished(move_id, nil, {:failed, reason}, state)

    state =
      %{state | restore: nil}
      |> put("enrolled", %{"move" => nil, "sentence" => sentence})
      |> arm_listen_end()

    send(reply_to, {:candidate_staged, move_id, {:error, sentence}})
    state
  end

  # A second move_commit after the home is in place (from a session its source
  # gave up on) is answered as the first was: the candidate's files are gone.
  defp commit_move(
         move_id,
         %{activated?: true, phase: %{"move" => %{"move_id" => move_id} = move}} = state
       ),
       do: {:reply, {:ok, move["epoch"]}, state}

  defp commit_move(
         move_id,
         %{phase: %{"phase" => phase, "move" => %{"move_id" => move_id} = move}} = state
       )
       when phase in ["staged", "activating"] do
    state = put(state, "activating", %{"move" => move})

    case Activation.activate(state.home) do
      :ok ->
        finished(move_id, move["epoch"], :done, state)
        Logger.info("candidate: the move #{move_id} committed; restarting as the primary")
        state.schedule.(:restart, @restart_after_ms)
        {:reply, {:ok, move["epoch"]}, %{state | activated?: true}}

      {:error, reason} ->
        state = activation_failed(state, reason)

        {:reply, {:error, "move_failed", "The staged home could not be put in place here."},
         state}
    end
  end

  defp commit_move(_move_id, state),
    do:
      {:reply, {:error, "move_unknown", "This candidate holds no staged home for that move."},
       state}

  defp finish_activation(state) do
    case Activation.activate(state.home) do
      :ok ->
        Logger.info("candidate: finished putting the moved home in place; restarting")
        state.schedule.(:restart, @restart_after_ms)
        %{state | activated?: true}

      {:error, reason} ->
        activation_failed(state, reason)
    end
  end

  # The renames are idempotent, so the next try carries on from where this one
  # stopped; the sentence says so in home.status meanwhile. Bounded per run of
  # the engine: its next start tries again.
  defp activation_failed(state, reason) do
    Logger.error("candidate: the staged home could not be put in place: #{inspect(reason)}")
    tries = state.activation_tries + 1

    if tries < @max_activation_tries do
      delay =
        min(@first_activation_retry_ms * Integer.pow(2, tries - 1), @max_activation_retry_ms)

      state.schedule.(:activate, delay)

      put(%{state | activation_tries: tries}, "activating", %{
        "sentence" =>
          "The home from #{primary_name(state)} could not be put in place yet; Fermix " <>
            "tries again shortly, and Fermix's log says why."
      })
    else
      put(%{state | activation_tries: tries}, "activating", %{
        "sentence" =>
          "The home from #{primary_name(state)} could not be put in place; Fermix tries " <>
            "again when it restarts, and Fermix's log says why."
      })
    end
  end

  # -- state ------------------------------------------------------------------

  defp put(state, phase, fields) do
    phase_state =
      state.phase
      |> Map.merge(fields)
      |> Map.put("phase", phase)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    case Files.put_state(state.home, phase_state, state.clock.()) do
      :ok ->
        %{state | phase: phase_state}

      {:error, reason} ->
        raise "the candidate's state could not be written: #{inspect(reason)}"
    end
  end

  # Every ending of an enrollment drops the code with it.
  defp fail(state, sentence) do
    case Files.drop_code(state.home) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("candidate: the code could not be removed: #{inspect(reason)}")
    end

    put(state, "failed", %{"sentence" => sentence})
  end

  defp started(move_id, epoch, state) do
    if state.phase["move"]["move_id"] == move_id and state.started_ms,
      do: state,
      else: %{state | started_ms: MoveTelemetry.started(:candidate, move_id, epoch)}
  end

  defp finished(move_id, epoch, outcome, state),
    do:
      MoveTelemetry.finished(
        :candidate,
        move_id,
        epoch,
        outcome,
        state.started_ms || System.monotonic_time(:millisecond)
      )

  defp primary_name(state), do: state.phase["primary"]["name"]

  defp discard(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:file, path, reason}}
    end
  end

  defp discard_tree(path) do
    case File.rm_rf(path) do
      {:ok, _removed} -> :ok
      {:error, reason, file} -> {:error, {:file, file, reason}}
    end
  end

  defp host_facts do
    {:ok, name} = :inet.gethostname()
    {_family, os} = :os.type()
    arch = :erlang.system_info(:system_architecture) |> to_string() |> String.split("-") |> hd()

    %{
      "name" => name |> to_string() |> String.slice(0, 64),
      "os" => Atom.to_string(os),
      "arch" => arch,
      "version" => BuildInfo.product_version()
    }
  end

  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
