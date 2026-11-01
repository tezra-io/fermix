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
  with the summary as it is now and a sentence, and nothing is done. That
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
      (`Provision.move_forwarded/3`).

  Every action the summary offers is one of `acts/0`, or one a surface opens
  itself (`learn_more`, `open_console`, `update`), refused as
  `invalid_params` on `action`.

  A step that starts a job names it in the ledger first
  (`Provision.put_action/2`), so the summary the act answers already says
  the step runs; a start refused after that clears it again, and the job's
  end clears it otherwise. The job family's busy rule stays the second
  guard: an act that meets a running read of the provider is refused in
  words.

  Refusals, each with a sentence: `changed` (the summary now),
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
  rail's, given the window's kind) and the review's; and `:serializer` (the
  name of this process), `:actor` and `:primary_forward`.
  """

  use GenServer

  alias FermixCore.Home.Link
  alias FermixCore.Home.Move
  alias FermixCore.Home.Provision.Registry
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
           start_again create_in back_up_now replace_server check_again own_server delete_server)
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
      @external_sentence
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
  defp offered(:error, _request, seen, _opts), do: changed(seen.summary)

  defp offered({:ok, _action}, request, seen, opts) do
    Logger.info("always on: #{request.action}, asked by #{inspect(Keyword.get(opts, :actor))}")

    request
    |> step(seen, opts)
    |> answer(opts)
  end

  defp answer({:ok, result}, opts), do: {:ok, %{"summary" => summary(opts), "result" => result}}
  defp answer({:error, code, details}, _opts) when is_atom(code), do: {:error, code, details}
  defp answer({:error, reason}, _opts), do: refusal(reason)

  defp changed(summary),
    do: {:error, :changed, %{"summary" => summary, "sentence" => @changed_sentence}}

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

  defp step(%{action: "start_again"}, _seen, opts),
    do: job("create", fn -> Provision.start_again(%{replace: desktop?(opts)}, opts) end, opts)

  defp step(%{action: "turn_on"}, _seen, opts),
    do: job("power_on", fn -> Provision.power(%{"action" => "on"}, opts) end, opts)

  defp step(%{action: "restart_server"}, _seen, opts),
    do: job("power_reset", fn -> Provision.power(%{"action" => "reset"}, opts) end, opts)

  defp step(%{action: "delete_server"}, _seen, opts), do: delete_job(opts)
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
      %{"candidate_id" => id} -> move(id, request, opts)
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

  # By what the screen showed: on the token screen the code of a server of
  # the owner's own, while a create runs that create, otherwise the server
  # that stands.
  defp cancel(%{summary: %{"state" => "connect"}}, opts), do: withdraw_code(opts)

  defp cancel(%{facts: %{provision: %{action: %{kind: "create"}}}}, opts) do
    with :ok <- Provision.stop_step(opts),
         :ok <- Provision.clear_action(opts),
         {:ok, holding?} <- Provision.holding(opts) do
      if holding?, do: delete_job(opts), else: {:ok, nil}
    end
  end

  defp cancel(_seen, opts), do: delete_job(opts)

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

  defp move(candidate_id, request, opts) do
    case Keyword.fetch(opts, :primary_forward) do
      {:ok, forward} -> forwarded_move(candidate_id, request.input, forward, opts)
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
    summary = summary(opts)

    case HomeSummary.find_action(summary, action, key) do
      {:ok, _action} -> :ok
      :error -> changed(summary)
    end
  end

  # A replace's move: the server checks the passphrase against its own key
  # and refuses on its own blocks; this desktop keeps that it started the
  # move once the server answered.
  defp forwarded_move(candidate_id, input, forward, opts) do
    params = %{
      "candidate_id" => candidate_id,
      "recovery_passphrase" => input.recovery_passphrase,
      "keep_as_desktop" => false
    }

    answer = forward.(server_request("home.move.start", params), [])
    _kept = Provision.move_forwarded(%{"candidate_id" => candidate_id}, answer, opts)

    case answer do
      {:ok, %{"move_id" => move_id}} -> {:ok, %{"move_id" => move_id}}
      {:error, _code, _details} = refused -> refused
    end
  end

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
