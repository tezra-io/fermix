defmodule FermixCore.Management.AlwaysOn do
  @moduledoc """
  `home.act` (Always On setup §3.4, §4): every Always On step, run by the
  engine. A surface draws `home.status`'s summary, collects what an action
  `needs`, asks its `confirm`, and sends the action's id, the key it was
  drawn with and the input (`AlwaysOn.Input`); `act/2` runs the step and
  answers `{summary, result}`: the summary after it, and the step's result
  (`own_server`: `{code, expires_at, command}`, the code answered once and
  the command carrying none; `move_now` and `try_again`: `{move_id}`;
  otherwise null).

  **One rule for "the owner saw this".** Acts run one at a time per engine,
  in this process, and each reads the summary first: one that does not offer
  `action` under `key` (`HomeSummary.find_action/3`) is answered `changed`,
  in a sentence and nothing else, and nothing is done; the surface reads
  `home.status` again, as it does after any act. That
  covers a confirm accepted on an older screen, two surfaces pressing at once
  and a server that changed under the owner. An act whose caller stopped
  waiting (its deadline, `deadline_ms/0`, passed while it queued) is not run.

  **The steps.** Placement is decided here: the computer that sets Always On
  up runs every step itself; a linked desktop (`:primary_forward`) runs what
  its own ledger holds and sends its server's steps over the link as the
  rail-only methods (`Management.Placement`).

    * `paste_token`: `Provision.connect/2` with `input.provider`, or the one
      provider offered.
    * `create_server`, `replace_server` (the desktop's create), `create_in`
      (the failure's size at its next place) and `start_again` (one job:
      what stands is deleted, then a server of its size and place is
      created, else of the failure's), with `replace` on a linked desktop:
      the create job.
    * `turn_on`, `restart_server`: the power job. `delete_server`: the delete
      job.
    * `cancel`, by what the screen showed: the manual code it offered to
      cancel is withdrawn; a create that runs is cancelled and, once its run
      has stopped, what it made is deleted; a server standing is deleted.
    * `own_server`: a manual code (`HomeMove.enroll_open/2`).
    * `back_up_now` and `check_again`: run here, or on a linked desktop sent
      as `home.snapshots.run` and `home.move.readiness`.
    * `move_now`, `try_again`: the server a move goes to is the engine's
      own rule (`HomeSummary.target/1`). Here the review runs at the press
      unless a ready one under 15 minutes old is kept (`Move.review/3`); a
      block refuses with its sentence, and a warning the confirm did not name
      moves the confirm and the key, so it answers `changed`; then
      `HomeMove.move_start/3` checks or sets the recovery passphrase and
      restarts the engine. On a linked desktop, `home.move.start` is sent
      with `keep_as_desktop` false, refused only by the server's own blocks,
      and this desktop records the replace's move once the server answered
      (`Provision.move_forwarded/3`); during a move back, the server it goes
      to is this desktop's own candidate, and the start is recorded in the
      return's record (`Home.Return`), never as a replace.
    * `move_back` (Always On's move back, its design §9): on a linked
      desktop, the server opens a copied code for it (`home.enroll.open`,
      which names this desktop), this desktop's candidate for the home is
      written beside the moved home (`Home.Candidate.prepare_return/3`,
      refused as it refuses: an engine that would not start again by itself
      among them), the return's record with the server's name, the ledger's
      server and the epoch the link reached, and the candidate's subtree
      starts beside the link (`Home.Link`'s `start_return/1`; one that does
      not start leaves neither file). Refused while the server reports a
      move of its own.
    * `cancel` during a move back (offered until the server started the
      move, and again once it undid it): the candidate's subtree stops, the
      server's copied code is closed (`home.enroll.withdraw {kind: manual}`;
      one the server cannot be asked to close lapses by itself), and the
      candidate and the record go.
    * `restore_here` (design §8): the newest copy of the server's snapshots
      this desktop keeps that the recovery passphrase opens
      (`Home.LocalReturn.choose/2`; none is the wrong passphrase, before
      anything else), the request in the return's record, then one job that
      deletes the server first and restores the copy
      (`Provision.start_return_restore/2`, `Home.LocalReturn.restore/3`); the
      derived key lives only in that job.

  Every action the summary offers is one of `acts/0`, or one a surface opens
  itself (`learn_more`, `open_console`, `update`), refused as
  `invalid_params` on `action`.

  A step that starts a job names it in the ledger first
  (`Provision.put_action/2`), so the summary the act answers already says
  the step runs; a start refused after that clears it again, and the job's
  end clears it otherwise. The job family's busy rule stays the second
  guard: an act that meets a running read of the provider is refused in
  words.

  Refusals, each with a sentence: `changed` (its sentence alone),
  `invalid_params` (a missing or bad input, a passphrase that is not the one
  set, an action a surface opens itself), `unavailable` with capability
  `home` (busy, a block, nothing to move to), the settings write's
  `external_change` and `config_unreadable` (a recovery key that could not be
  kept), and a step sent to the server answered as the server answered it
  (`primary_unreachable` and `unconfirmed` among them).

  Nothing of the input reaches a log line or telemetry: an act logs its
  action and who asked (`:actor`: nil from `daemon.sock`, `:setup_page`) and
  emits no event of its own; a job keeps its own bookends.

  Seams in `opts`, passed as they are to `Management.Home`,
  `Management.Provision` and `Management.HomeMove`: `:home`,
  `:engine_role`, `:now`, `:providers`, `:provider_opts`, `:jobs`,
  `:link_status`, `:config`, `:scheduler`, `:save_recipient`, `:restart`,
  `:open_enrollment`, `:withdraw_enrollment` (a 1-arity stand-in for the
  rail's, given the window's kind) and the review's; for a move back,
  `Home.Candidate.prepare_return/3`'s `:role` and `:restarts_itself?`,
  `:start_return` and `:stop_return` (in place of the rail's), and
  `:local_return` (a 2-arity stand-in for `Home.LocalReturn.restore/3`,
  given the home and the copy); and `:serializer` (the name of this
  process), `:actor` and `:primary_forward`.
  """

  use GenServer

  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Link
  alias FermixCore.Home.LocalReturn
  alias FermixCore.Home.Move
  alias FermixCore.Home.Provision.Registry
  alias FermixCore.Home.Return
  alias FermixCore.Management.AlwaysOn.Input
  alias FermixCore.Management.Copy
  alias FermixCore.Management.Home
  alias FermixCore.Management.HomeMove
  alias FermixCore.Management.HomeSummary
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Provision
  alias FermixCore.Setup.ConfigStore

  require Logger

  @capability "home"
  @acts ~w(paste_token create_server cancel move_now try_again turn_on restart_server
           start_again create_in back_up_now replace_server check_again own_server delete_server
           move_back restore_here)
  @opened ~w(learn_more open_console update)
  # Every client allows `home.act` this long: a token check takes up to about
  # 45 s and a review sent to the server up to 60 s.
  @deadline_ms 90_000
  # A summary's key is a short digest; the bound only refuses junk.
  @max_key_bytes 64

  @changed_sentence "Always On changed since this was shown, so look at it again."
  @busy_step_sentence "Fermix is already working on your server, so try again once that is " <>
                        "done."
  @busy_backup_sentence "A backup is already running, and it finishes by itself."
  @opened_sentence "This one opens a page of its own; Fermix takes no step for it."
  @unknown_sentence "Name one of the steps Always On offers."
  @key_sentence "Send the key the action came with."
  @nothing_to_move_sentence "There is no server to move to yet."
  @not_running_sentence "Always On's steps run inside Fermix, and it is not running here."
  @late_sentence "Fermix took too long to get to this step, so it did not run it. Look at " <>
                   "Always On again."
  @review_sentence "The review of the move could not be read. See the daemon log."
  @external_sentence "The settings file changed outside Fermix, so look at it and try again."
  @server_moving_sentence "Your server is moving Fermix right now, so move back once that is " <>
                            "done."
  @not_receiving_sentence "Fermix could not start receiving the move back here, so nothing " <>
                            "was kept; Fermix's log says why."
  @no_copy_sentence "There is no backup on this computer to restore."
  # A move the server reports, from its request to its undoing.
  @server_moves ~w(requested streaming committing aborting committed undoing)

  @typedoc "One step a surface asks for: an action, the key it was drawn with, and its input."
  @type request :: %{action: String.t(), key: String.t(), input: Input.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts),
    do: GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Every action `act/2` runs, in the protocol's order."
  @spec acts() :: [String.t()]
  def acts, do: @acts

  @doc "How long every client allows `home.act`, in milliseconds."
  @spec deadline_ms() :: pos_integer()
  def deadline_ms, do: @deadline_ms

  @doc "Every sentence an act's own refusal says, for the copy rules."
  @spec sentences() :: [String.t()]
  def sentences do
    [
      @changed_sentence,
      @busy_step_sentence,
      @busy_backup_sentence,
      @opened_sentence,
      @unknown_sentence,
      @key_sentence,
      @nothing_to_move_sentence,
      @not_running_sentence,
      @late_sentence,
      @review_sentence,
      @external_sentence,
      @server_moving_sentence,
      @not_receiving_sentence,
      @no_copy_sentence
    ]
  end

  @doc """
  `home.act`'s params as the router received them (`action`, `key`, and
  `input`, decoded into `AlwaysOn.Input`): the request `act/2` takes, or the
  field refused with its sentence.
  """
  @spec decode(map()) :: {:ok, request()} | {:error, {:invalid_params, String.t(), String.t()}}
  def decode(params) when is_map(params) do
    with {:ok, action} <- action_param(Map.get(params, "action")),
         {:ok, key} <- key_param(Map.get(params, "key")),
         {:ok, input} <- Input.decode(Map.get(params, "input")),
         do: {:ok, %{action: action, key: key, input: input}}
  end

  defp action_param(action) when action in @acts, do: {:ok, action}
  defp action_param(action) when action in @opened, do: invalid("action", @opened_sentence)
  defp action_param(_action), do: invalid("action", @unknown_sentence)

  defp key_param(key)
       when is_binary(key) and byte_size(key) > 0 and byte_size(key) <= @max_key_bytes,
       do: {:ok, key}

  defp key_param(_key), do: invalid("key", @key_sentence)

  defp invalid(field, sentence), do: {:error, {:invalid_params, field, sentence}}

  @doc "Runs one step, as the moduledoc says, in this engine's serializer."
  @spec act(request(), keyword()) :: Protocol.route_result()
  def act(%{action: action, key: key, input: %Input{}} = request, opts)
      when action in @acts and is_binary(key) and is_list(opts) do
    server = Keyword.get(opts, :serializer, __MODULE__)
    deadline = System.monotonic_time(:millisecond) + @deadline_ms

    if GenServer.whereis(server),
      do: GenServer.call(server, {:act, request, opts, deadline}, @deadline_ms),
      else: unavailable(@not_running_sentence)
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:act, request, opts, deadline}, _from, state),
    do: {:reply, run(request, opts, deadline), state}

  # -- the key rule ----------------------------------------------------------

  defp run(request, opts, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      facts = Home.summary_facts(opts)
      seen = %{facts: facts, summary: HomeSummary.summary(facts)}

      offered(
        HomeSummary.find_action(seen.summary, request.action, request.key),
        request,
        seen,
        opts
      )
    else
      Logger.warning("always on: #{request.action} waited past its deadline and did not run")
      unavailable(@late_sentence)
    end
  end

  # `seen`: the facts the screen was drawn from, and the screen.
  defp offered(:error, _request, _seen, _opts), do: changed()

  defp offered({:ok, _action}, request, seen, opts) do
    Logger.info("always on: #{request.action}, asked by #{inspect(Keyword.get(opts, :actor))}")

    request
    |> step(seen, opts)
    |> answer(opts)
  end

  defp answer({:ok, result}, opts), do: {:ok, %{"summary" => summary(opts), "result" => result}}
  defp answer({:error, code, details}, _opts) when is_atom(code), do: {:error, code, details}
  defp answer({:error, reason}, _opts), do: refusal(reason)

  defp changed, do: {:error, :changed, %{"sentence" => @changed_sentence}}

  defp summary(opts), do: opts |> Home.summary_facts() |> HomeSummary.summary()

  # -- the steps -------------------------------------------------------------

  defp step(%{action: "paste_token", input: input}, _seen, opts) do
    params = %{"provider" => input.provider || only_provider(opts), "token" => input.token}
    with {:ok, _view} <- Provision.connect(params, opts), do: {:ok, nil}
  end

  defp step(%{action: action, input: input}, _seen, opts)
       when action in ["create_server", "replace_server"] do
    choice = %{type: input.type, location: input.location, replace: action == "replace_server"}
    job("create", fn -> Provision.start_create(choice, opts) end, opts)
  end

  defp step(%{action: "create_in"}, %{facts: %{provision: %{failure: failure}}}, opts) do
    choice = %{type: failure.type, location: failure.next_location, replace: desktop?(opts)}
    job("create", fn -> Provision.start_create(choice, opts) end, opts)
  end

  defp step(%{action: "start_again", input: input}, _seen, opts) do
    again = %{replace: desktop?(opts), type: input.type, location: input.location}
    job("create", fn -> Provision.start_again(again, opts) end, opts)
  end

  defp step(%{action: "turn_on"}, _seen, opts),
    do: job("power_on", fn -> Provision.power(%{"action" => "on"}, opts) end, opts)

  defp step(%{action: "restart_server"}, _seen, opts),
    do: job("power_reset", fn -> Provision.power(%{"action" => "reset"}, opts) end, opts)

  defp step(%{action: "delete_server"}, _seen, opts), do: delete_job(opts)
  defp step(%{action: "move_back"}, seen, opts), do: move_back(seen, opts)

  defp step(%{action: "restore_here", input: input}, seen, opts),
    do: restore_here(input.recovery_passphrase, seen, opts)

  defp step(%{action: "cancel"}, seen, opts), do: cancel(seen, opts)
  defp step(%{action: "own_server"}, _seen, opts), do: own_server(opts)

  defp step(%{action: "back_up_now"}, _seen, opts),
    do: on_server("home.snapshots.run", %{}, fn -> Home.snapshots_run(opts) end, opts)

  defp step(%{action: "check_again"}, seen, opts) do
    id = candidate_id(HomeSummary.target(seen.facts))

    on_server(
      "home.move.readiness",
      %{"candidate_id" => id},
      fn -> HomeMove.move_readiness(id, opts) end,
      opts
    )
  end

  defp step(%{action: action} = request, seen, opts) when action in ["move_now", "try_again"] do
    case HomeSummary.target(seen.facts) do
      %{"candidate_id" => id} -> move(id, request, seen, opts)
      nil -> unavailable(@nothing_to_move_sentence)
    end
  end

  # A step's job: named in the ledger first, so the summary says it runs; a
  # start refused after that leaves no step behind.
  defp job(kind, start, opts) do
    with :ok <- Provision.put_action(kind, opts) do
      case start.() do
        {:ok, _job} -> {:ok, nil}
        {:error, _reason} = refused -> unstarted(refused, opts)
      end
    end
  end

  defp unstarted(refused, opts) do
    case Provision.clear_action(opts) do
      :ok ->
        refused

      {:error, reason} ->
        Logger.error("always on: a refused step's name stays in the ledger: #{inspect(reason)}")
        refused
    end
  end

  defp delete_job(opts), do: job("delete", fn -> Provision.delete(opts) end, opts)

  # By what the screen showed: a move back's, on the token screen the code
  # of a server of the owner's own, while a create runs that create,
  # otherwise the server that stands.
  defp cancel(%{facts: facts} = seen, opts) do
    if returning?(facts), do: cancel_return(opts), else: cancel_step(seen, opts)
  end

  # A move back's screen: its candidate, or its started record alone.
  defp returning?(%{role: :device, returning: returning}) when returning != nil, do: true

  defp returning?(%{role: :device, return: %{move_started_at: %DateTime{}} = record}),
    do: not Map.has_key?(record, :moved_at)

  defp returning?(_facts), do: false

  defp cancel_step(%{summary: %{"state" => "connect"}}, opts), do: withdraw_code(opts)

  defp cancel_step(%{facts: %{provision: %{action: %{kind: "create"}}}}, opts) do
    with :ok <- Provision.stop_step(opts),
         :ok <- Provision.clear_action(opts),
         {:ok, holding?} <- Provision.holding(opts) do
      if holding?, do: delete_job(opts), else: {:ok, nil}
    end
  end

  defp cancel_step(_seen, opts), do: delete_job(opts)

  defp withdraw_code(opts) do
    withdraw =
      Keyword.get(opts, :withdraw_enrollment, fn kind -> Link.impl().withdraw_enrollment(kind) end)

    case withdraw.(:manual) do
      :ok -> {:ok, nil}
      {:error, {:unavailable, sentence}} when is_binary(sentence) -> unavailable(sentence)
    end
  end

  defp own_server(opts) do
    with {:ok, %{"code" => code, "expires_at" => at}} <- HomeMove.enroll_open(nil, opts),
         do: {:ok, %{"code" => code, "expires_at" => at, "command" => Copy.own_server_command()}}
  end

  # A step the server takes: here, or over the link on a linked desktop.
  defp on_server(method, params, local, opts) do
    answered =
      case Keyword.fetch(opts, :primary_forward) do
        {:ok, forward} -> forward.(server_request(method, params), [])
        :error -> local.()
      end

    case answered do
      {:ok, _answer} -> {:ok, nil}
      refused -> refused
    end
  end

  # -- the move --------------------------------------------------------------

  defp move(candidate_id, request, seen, opts) do
    case Keyword.fetch(opts, :primary_forward) do
      {:ok, forward} -> forwarded_move(candidate_id, request.input, forward, seen, opts)
      :error -> local_move(candidate_id, request, opts)
    end
  end

  defp local_move(candidate_id, request, opts) do
    with :ok <- reviewed(candidate_id, opts),
         :ok <- still_offered(request, opts),
         {:ok, started} <-
           HomeMove.move_start(candidate_id, request.input.recovery_passphrase, opts),
         do: {:ok, %{"move_id" => started["move_id"]}}
  end

  # The review the owner was shown under 15 minutes ago, else one now, kept
  # so the summary's confirm says any warning it found.
  defp reviewed(candidate_id, opts) do
    case Move.review(home(opts), candidate_id, now(opts)) do
      {:ok, _report} ->
        :ok

      :none ->
        fresh_review(candidate_id, opts)

      {:error, reason} ->
        Logger.error(
          "always on: the kept review of the move could not be read: #{inspect(reason)}"
        )

        unavailable(@review_sentence)
    end
  end

  defp fresh_review(candidate_id, opts) do
    with {:ok, %{"ready" => ready, "items" => items}} <-
           HomeMove.move_readiness(candidate_id, opts) do
      if ready,
        do: :ok,
        else: unavailable(Move.error_sentence({:not_ready, blocks(items)}))
    end
  end

  defp blocks(items), do: for(%{"status" => "block", "sentence" => said} <- items, do: said)

  defp still_offered(%{action: action, key: key}, opts) do
    case HomeSummary.find_action(summary(opts), action, key) do
      {:ok, _action} -> :ok
      :error -> changed()
    end
  end

  # A replace's move: the server checks the passphrase against its own key
  # and refuses on its own blocks; this desktop keeps that it started the
  # move once the server answered. A move back's start is kept before the
  # request leaves (`return_start_ahead/2`), since the server restarts into
  # the move as it answers, and settled by the answer (`return_answered/3`).
  defp forwarded_move(candidate_id, input, forward, %{facts: facts}, opts) do
    params = %{
      "candidate_id" => candidate_id,
      "recovery_passphrase" => input.recovery_passphrase,
      "keep_as_desktop" => false
    }

    with :ok <- start_ahead(facts, candidate_id, opts) do
      answer = forward.(server_request("home.move.start", params), [])
      _kept = keep_move(facts, candidate_id, answer, opts)

      case answer do
        {:ok, %{"move_id" => move_id}} -> {:ok, %{"move_id" => move_id}}
        {:error, _code, _details} = refused -> refused
      end
    end
  end

  defp start_ahead(%{returning: %{"kind" => "return"}}, candidate_id, opts),
    do: return_start_ahead(candidate_id, opts)

  defp start_ahead(_facts, _candidate_id, _opts), do: :ok

  defp keep_move(%{returning: %{"kind" => "return"}}, _candidate_id, answer, opts),
    do: return_answered(answer, home(opts), opts)

  defp keep_move(_facts, candidate_id, answer, opts),
    do: Provision.move_forwarded(%{"candidate_id" => candidate_id}, answer, opts)

  # Move now on a move back (the move back's TLA spec, finding HR-1): the
  # start is in the return's record before the request leaves, so no stop of
  # this engine after the server took it leaves a screen that offers Cancel
  # while the server moves. One that cannot be kept sends nothing.
  defp return_start_ahead(candidate_id, opts) do
    home = home(opts)
    fields = %{move_started_at: now(opts), candidate_id: candidate_id}

    with {:ok, record} <- Return.read(home),
         :ok <- Return.write(home, record |> Map.drop([:move_id]) |> Map.merge(fields)) do
      :ok
    else
      unkept -> not_kept(unkept)
    end
  end

  # The server's answer settles the start: its move id kept; an answer lost
  # (`unconfirmed`) keeps the start, as a replace's is kept; a request that
  # never left (no link) or one the server refused takes it back.
  defp return_answered({:ok, %{"move_id" => move_id}}, home, _opts),
    do: update_return(home, &Map.put(&1, :move_id, move_id))

  defp return_answered({:error, :unconfirmed, _details}, _home, _opts), do: :kept

  defp return_answered({:error, _refused, _details}, home, _opts),
    do: update_return(home, &Map.drop(&1, [:move_started_at, :candidate_id, :move_id]))

  defp update_return(home, change) do
    with {:ok, record} <- Return.read(home),
         :ok <- Return.write(home, change.(record)) do
      :recorded
    else
      unkept ->
        Logger.error("always on: the move back's start was not settled: #{inspect(unkept)}")
        unkept
    end
  end

  # -- moving back -------------------------------------------------------------

  # Move back (design §9, M0): the server opens a copied code that names this
  # desktop, the candidate and the return's record are written beside the
  # moved home, and the candidate's subtree starts beside the link.
  defp move_back(%{facts: facts}, opts) do
    with :ok <- server_still(facts),
         {:ok, code} <- return_code(Keyword.fetch!(opts, :primary_forward)),
         {:ok, state} <- prepared(code, opts),
         :ok <- keep_record(home(opts), return_record(facts, state, opts)),
         do: receiving(opts)
  end

  defp server_still(facts) do
    if get_in(facts, [:primary_home, "move", "phase"]) in @server_moves,
      do: unavailable(@server_moving_sentence),
      else: :ok
  end

  defp return_code(forward) do
    case forward.(server_request("home.enroll.open", %{}), []) do
      {:ok, %{"code" => code}} when is_binary(code) -> {:ok, code}
      {:error, _code, _details} = refused -> refused
    end
  end

  defp prepared(code, opts) do
    prepare = [now: now(opts)] ++ Keyword.take(opts, [:role, :restarts_itself?])

    case Candidate.prepare_return(home(opts), {:return, code}, prepare) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> unavailable(Candidate.error_sentence(reason))
    end
  end

  # The server's name as its code gave it, the server the ledger holds (none
  # for a server of the owner's own) and the epoch the link reached.
  defp return_record(facts, state, opts) do
    %{
      from: get_in(state, ["primary", "name"]),
      started_at: now(opts),
      provider_server: get_in(facts, [:provision, :server, :id]),
      primary_epoch: get_in(facts, [:link, :primary, :epoch])
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp keep_record(home, record) do
    case Return.write(home, record) do
      :ok -> :ok
      {:error, reason} -> not_kept(reason)
    end
  end

  # One that does not start keeps nothing behind: the next Move back writes
  # both again.
  defp receiving(opts) do
    home = home(opts)

    start = Keyword.get(opts, :start_return, fn home -> Link.impl().start_return(home) end)

    case start.(home) do
      :ok ->
        {:ok, nil}

      {:error, reason} ->
        Logger.error("always on: receiving the move back did not start: #{inspect(reason)}")
        _forgot = forget_return(home)
        unavailable(@not_receiving_sentence)
    end
  end

  defp cancel_return(opts) do
    :ok = Keyword.get(opts, :stop_return, fn -> Link.impl().stop_return() end).()
    :ok = close_return_code(opts)

    case forget_return(home(opts)) do
      :ok -> {:ok, nil}
      {:error, reason} -> not_kept(reason)
    end
  end

  # The server's copied code for this desktop; one it cannot be asked to
  # close (no link runs here, or the server did not answer) lapses by
  # itself within its half hour.
  defp close_return_code(opts) do
    request = server_request("home.enroll.withdraw", %{"kind" => "manual"})

    case Keyword.fetch(opts, :primary_forward) do
      {:ok, forward} -> closed(forward.(request, []))
      :error -> Logger.warning("always on: no link runs here to close the move back's code")
    end
  end

  defp closed({:ok, _withdrawn}), do: :ok

  defp closed({:error, code, _details}),
    do: Logger.warning("always on: the server did not close the move back's code (#{code})")

  # The record first: a stop before the candidate goes leaves a candidate
  # alone, which the screen offers to Cancel, never a started record alone
  # (the move back's TLA spec, HR-2).
  defp forget_return(home) do
    with :ok <- Return.remove(home), do: Candidate.remove(home)
  end

  defp not_kept(reason) do
    Logger.error("always on: the move back's files could not be kept: #{inspect(reason)}")
    unavailable(@not_receiving_sentence)
  end

  # Restore here (design §8): the copy is chosen before anything else, so a
  # passphrase that opens none deletes nothing; then the request is kept and
  # one job deletes the server and restores the copy.
  defp restore_here(passphrase, %{facts: facts}, opts) do
    home = home(opts)

    with {:ok, copy} <- chosen(LocalReturn.choose(home, passphrase)),
         :ok <- keep_record(home, restore_record(facts, copy, opts)) do
      copy = Map.put(copy, :from, server_name(facts))
      restore = Keyword.get(opts, :local_return, &LocalReturn.restore(&1, &2, restore_opts(opts)))
      run = fn _report -> restore.(home, copy) end
      job("delete", fn -> Provision.start_return_restore(run, opts) end, opts)
    end
  end

  defp chosen({:ok, copy}), do: {:ok, copy}
  defp chosen({:error, :no_copy}), do: unavailable(@no_copy_sentence)
  defp chosen({:error, reason}), do: Home.recovery_result({:error, reason})

  # The request in the return's record: a record of its own when none was
  # kept, the server the ledger holds named, the copy to restore asked for.
  defp restore_record(facts, copy, opts) do
    kept = facts.return || %{from: server_name(facts), started_at: now(opts)}

    kept
    |> Map.put(:fence_requested, copy.name)
    |> maybe_put(:provider_server, get_in(facts, [:provision, :server, :id]))
  end

  defp server_name(%{provision: %{server: %{name: name}}}) when is_binary(name), do: name
  defp server_name(%{link: %{primary: %{name: name}}}) when is_binary(name), do: name
  defp server_name(%{moved: %{to: to}}), do: to

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put_new(map, key, value)

  defp restore_opts(opts),
    do:
      [now: now(opts)] ++ Keyword.take(opts, [:role, :restarts_itself?, :restart, :restore_opts])

  # -- refusals and seams ----------------------------------------------------

  defp refusal({:busy, "home.snapshots.run"}), do: unavailable(@busy_backup_sentence)
  defp refusal({:busy, _operation}), do: unavailable(@busy_step_sentence)

  defp refusal({:unavailable, capability, sentence}),
    do: {:error, :unavailable, %{"capability" => capability, "sentence" => sentence}}

  defp refusal({:invalid_params, field, sentence}),
    do: {:error, :invalid_params, %{"field" => field, "sentence" => sentence}}

  defp refusal({:external_change, sections}),
    do:
      {:error, :external_change,
       %{"section" => List.first(sections) || "settings", "sentence" => @external_sentence}}

  defp refusal({:config_unreadable, sentence}),
    do: {:error, :config_unreadable, %{"sentence" => sentence}}

  defp unavailable(sentence),
    do: {:error, :unavailable, %{"capability" => @capability, "sentence" => sentence}}

  defp server_request(method, params) do
    %{
      request_id: "always-on-" <> method,
      protocol_version: Protocol.protocol_version(),
      method: method,
      params: params
    }
  end

  defp only_provider(opts) do
    case Keyword.get_lazy(opts, :providers, &Registry.all/0) do
      [provider] -> provider.id()
      _several -> nil
    end
  end

  defp candidate_id(%{"candidate_id" => id}), do: id
  defp candidate_id(nil), do: nil

  defp desktop?(opts), do: Keyword.has_key?(opts, :primary_forward)
  defp home(opts), do: Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)
  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
end
