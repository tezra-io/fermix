defmodule FermixCore.ComputerUse.ComputerDriver do
  @moduledoc """
  The `Compux.Driver` for a computer's screen (M97 §6.4): each driver call of a
  `ComputerUse.Session` on the server is one invocation to the computer that
  `Computers.Choice` chose, whose own helper runs it
  (`Computers.Capabilities.Screen`, held there by `ComputerUse.Seat`). A step
  is one request out and one reply back, its image (a PNG of at most 1366 by
  768) riding as the invocation's part and handed to the session as the local
  driver hands it, base64 in `data`.

  **Where the session lives.** On the server: the action budget, the images the
  model may still name, the bound window, `/pause` and `/resume`, and one
  screen per conversation are the session's, as they are for this machine's
  own screen, so none of them is built twice. What only the computer can
  decide is decided there: whether the turn is one the owner is in (again),
  its access level from its own sandbox mode, courtesy from its idle signal,
  and whether the person at it stopped the server. A session on a computer's
  screen therefore runs here with courtesy off and its access as the computer
  last said it, which refuses a change under `strict` before anything is sent
  and is checked again there.

  **The person at the computer is in charge.** `start/1` takes the screen
  (`screen.look` of the helper's `hello`, which the computer answers by
  starting its helper and showing its mark, or refusing `busy` or
  `stopped_here`), then holds one long-lived `screen.watch` that the computer
  answers when its hold ends, and renews the hold every #{div(30_000, 1_000)} s
  for as long as the session exists, paused included (`screen.control`
  `keep`), so a gap between steps or a long pause never lets the computer go:
  it lets go only of a screen whose server went quiet. A Stop there, or its
  switch going off, answers `stopped_here`: the session is told as the
  helper's own Stop button tells it (`{:compux_session_event, _,
  operator_stop}` to the process that started this driver), so the model
  hears that the person at the computer stopped it. Any other end (the
  computer let go of a server it no longer heard, its helper ended, its
  engine stopped) ends the session quietly (`SessionManager.end_session/2`).
  `stop/1` ends the watch, which lets go of the computer's screen.

  **Every turn names itself.** The tool puts its turn on each request
  (`with_turn/2`), so each invocation carries that turn's origin and ids and
  the computer checks them; a request the session makes on its own (the
  helper's `probe`, the release of held input) carries the turn that started
  it.

  Its errors are the local driver's where the meaning is the same (the
  helper's refusal, its timeout, its exit, a person at the computer), so the
  session decides what they mean as it always has; a refusal under `strict` is
  `{:refused, :strict_mode}`; the rest is `{:computer, sentence}` or, for a
  stop, `{:computer_stopped, sentence}`, each naming the computer.
  """

  @behaviour Compux.Driver

  require Logger

  alias Compux.Protocol
  alias FermixCore.Computers
  alias FermixCore.Computers.Capabilities.Screen
  alias FermixCore.Computers.Computer
  alias FermixCore.Computers.Outcome
  alias FermixCore.ComputerUse.SessionManager

  @turn_key "fermix_turn"
  # Well inside the computer's lapse (`Seat`, 120 s), so a lost renewal or two
  # never lets the screen go while the session exists.
  @keep_every_ms 30_000
  # What an invocation reads of a turn (`Computers.Origin`, `Computers.Invocation`).
  @turn_keys [
    :session_id,
    :tool_call_id,
    :computer_use_origin,
    :subagent_depth,
    :skill_depth,
    :trigger,
    :harness_continuation_depth,
    :computer_call_opts,
    :computer
  ]

  @doc "The request key a turn rides under, which the session never reads."
  @spec turn_key() :: String.t()
  def turn_key, do: @turn_key

  @doc "What a turn's loop `context` gives the invocations it asks for."
  @spec turn(map()) :: map()
  def turn(context) when is_map(context), do: Map.take(context, @turn_keys)

  @doc "`request` carrying the turn whose loop context is `context` (the moduledoc)."
  @spec with_turn(map(), map()) :: map()
  def with_turn(request, context) when is_map(request) and is_map(context),
    do: Map.put(request, @turn_key, turn(context))

  @doc """
  The driver spec for `computer` from the turn whose loop context is
  `context`: the session adds its id (`session_id`), which is the seat.
  """
  @spec spec(Computer.t(), map()) :: {module(), keyword()}
  def spec(%Computer{} = computer, context) when is_map(context) do
    {__MODULE__,
     [
       computer: computer,
       turn: turn(context),
       conversation_key: Map.fetch!(context, :conversation_key)
     ]}
  end

  @impl true
  def start(opts) do
    state = %{
      computer: Keyword.fetch!(opts, :computer),
      turn: Keyword.fetch!(opts, :turn),
      seat: Keyword.fetch!(opts, :session_id),
      conversation_key: Keyword.fetch!(opts, :conversation_key),
      owner: self(),
      ref: make_ref()
    }

    case call(state, state.turn, "screen.look", %{"action" => "hello"}) do
      {:ok, hello} -> {:ok, state |> Map.put(:hello, hello) |> Map.put(:watch, watch(state))}
      {:error, reason} -> {:error, reason}
    end
  end

  # The helper's identity was read when the screen was taken, as the local
  # transport answers a second `hello` from the one it read at the handshake.
  @impl true
  def execute(state, %{"action" => "hello"} = request) do
    {_turn, _request} = Map.pop(request, @turn_key)
    {:ok, state.hello}
  end

  def execute(state, request) when is_map(request) do
    {turn, request} = Map.pop(request, @turn_key)
    op = if Protocol.read_only?(request["action"]), do: "screen.look", else: "screen.act"
    call(state, turn || state.turn, op, request)
  end

  @impl true
  def control(state, action) when action in [:pause, :resume, :release] do
    args = %{"seat" => state.seat, "control" => Atom.to_string(action)}

    case Computers.call(
           computer(state, state.turn),
           Screen,
           "screen.control",
           args,
           state.turn,
           call_opts(state.turn)
         ) do
      {:ok, %Outcome{result: %{"ack" => ack}}} -> {:ok, ack(ack)}
      {:ok, %Outcome{}} -> {:ok, ack(nil)}
      {:error, outcome} -> {:error, {:computer, sentence(outcome, state)}}
    end
  end

  # Ending the watch lets go of the computer's screen: the server's waiters
  # cancel what a caller that went away was waiting on.
  @impl true
  def stop(%{watch: watch}) when is_pid(watch) do
    Process.exit(watch, :kill)
    :ok
  end

  def stop(_state), do: :ok

  # -- one request ----------------------------------------------------------------

  defp call(state, turn, op, request) do
    args = %{"seat" => state.seat, "request" => request}

    case Computers.call(computer(state, turn), Screen, op, args, turn, call_opts(turn)) do
      {:ok, %Outcome{result: %{"response" => response}} = outcome} when is_map(response) ->
        {:ok, with_image(response, outcome.part_bytes)}

      {:ok, %Outcome{} = outcome} ->
        {:error, {:computer, sentence(outcome, state)}}

      {:error, %Outcome{} = outcome} ->
        {:error, failure(outcome, op, state)}
    end
  end

  # The computer as the turn's choice resolved it, else as the session found it.
  defp computer(_state, %{computer: %Computer{} = computer}), do: computer
  defp computer(state, _turn), do: state.computer

  defp call_opts(turn), do: Map.get(turn, :computer_call_opts, [])

  defp with_image(response, png) when is_binary(png),
    do: Map.put(response, "data", Base.encode64(png))

  defp with_image(response, _none), do: response

  # -- what went wrong ------------------------------------------------------------

  defp failure(%Outcome{status: :failed, result: %{"error" => error}} = outcome, _op, state)
       when is_map(error),
       do: driver_error(error, outcome, state)

  defp failure(%Outcome{status: :refused, refusal: refusal} = outcome, _op, state)
       when refusal in [:stopped_here, :off] do
    stopped(state)
    {:computer_stopped, sentence(outcome, state)}
  end

  defp failure(%Outcome{status: :refused, refusal: :outside_sandbox}, _op, _state),
    do: {:refused, :strict_mode}

  # Whether it reached the screen is not known, as when the local helper went
  # quiet on an action: the session starts over, and the model looks first.
  defp failure(%Outcome{status: status, deadline_ms: deadline}, _op, _state)
       when status in [:unknown, :timed_out],
       do: {:timeout, :cu_sidecar_action, deadline || 0}

  # An action that stopped on the computer without saying how: whether its input
  # went out is not known there either.
  defp failure(%Outcome{status: :failed} = outcome, "screen.act", state),
    do: {:helper_fault, {:computer, sentence(outcome, state)}}

  defp failure(%Outcome{} = outcome, _op, state), do: {:computer, sentence(outcome, state)}

  defp driver_error(%{"kind" => "action_failed", "payload" => payload}, _outcome, _state)
       when is_map(payload),
       do: {:action_failed, payload}

  defp driver_error(%{"kind" => "timeout", "ms" => ms}, _outcome, _state) when is_integer(ms),
    do: {:timeout, :cu_sidecar_action, ms}

  defp driver_error(%{"kind" => "exited", "status" => status}, _outcome, _state)
       when is_integer(status),
       do: {:sidecar_exited, status}

  defp driver_error(%{"kind" => "exited"}, _outcome, _state), do: {:sidecar_exited, :on_computer}
  defp driver_error(%{"kind" => "unavailable"}, _outcome, _state), do: :sidecar_unavailable
  defp driver_error(%{"kind" => "user_active"}, _outcome, _state), do: :user_active

  defp driver_error(%{"kind" => "not_dispatched"}, _outcome, _state),
    do: {:not_dispatched, :helper_on_computer}

  defp driver_error(%{"kind" => "wire", "detail" => detail}, _outcome, _state),
    do: {:protocol_error, detail}

  defp driver_error(_other, outcome, state), do: {:computer, sentence(outcome, state)}

  defp sentence(%Outcome{} = outcome, state), do: Outcome.sentence(outcome, state.computer.name)

  # The acknowledgement a pause reads: whether an action is still under way.
  defp ack(%{"in_flight_request_id" => id}) when is_binary(id), do: %{in_flight_request_id: id}
  defp ack(_none), do: %{in_flight_request_id: nil}

  # The person at the computer stopped it: the session hears it as it hears the
  # helper's own Stop button.
  defp stopped(state) do
    send(
      state.owner,
      {:compux_session_event, state.ref, %{"kind" => "indicator", "event" => "operator_stop"}}
    )

    :ok
  end

  # -- the watch ----------------------------------------------------------------

  # A process of its own, which `stop/1` ends, and which ends with the driver's
  # owner too; the call it waits in is its linked task, so ending it cancels
  # the call and the computer lets go. While it waits it renews the hold.
  defp watch(state) do
    spawn(fn ->
      owner = Process.monitor(state.owner)
      task = Task.async(fn -> watch_call(state) end)
      keep_later()
      watching(state, owner, task)
    end)
  end

  defp watching(state, owner, %Task{ref: task_ref} = task) do
    receive do
      {^task_ref, answer} ->
        Process.demonitor(task_ref, [:flush])
        watched(answer, state)

      {:DOWN, ^owner, :process, _pid, _reason} ->
        Task.shutdown(task, :brutal_kill)

      :keep ->
        :ok = keep(state)
        keep_later()
        watching(state, owner, task)
    end
  end

  defp keep_later, do: Process.send_after(self(), :keep, @keep_every_ms)

  # The session exists, so its hold is renewed; one the computer did not hear
  # is said, and its watch tells the session if the computer let go.
  defp keep(state) do
    args = %{"seat" => state.seat, "control" => "keep"}

    case Computers.call(
           state.computer,
           Screen,
           "screen.control",
           args,
           state.turn,
           call_opts(state.turn)
         ) do
      {:ok, %Outcome{}} ->
        :ok

      {:error, %Outcome{} = outcome} ->
        Logger.info(
          "computer_use: #{state.computer.name} did not hear the hold renewed: " <>
            "#{outcome.status}"
        )
    end
  end

  defp watched({:error, %Outcome{status: :refused, refusal: refusal}}, state)
       when refusal in [:stopped_here, :off],
       do: stopped(state)

  defp watched(answer, state) do
    Logger.info("computer_use: #{state.computer.name} let go of its screen (#{why(answer)})")
    SessionManager.end_session(state.conversation_key, state.seat)
  end

  defp watch_call(state) do
    opts = Keyword.put(call_opts(state.turn), :deadline_ms, 0)
    args = %{"seat" => state.seat}
    Computers.call(state.computer, Screen, "screen.watch", args, state.turn, opts)
  end

  defp why({:ok, %Outcome{result: %{"ended" => why}}}) when is_binary(why), do: why
  defp why({_ok_or_error, %Outcome{status: status}}), do: Atom.to_string(status)
end
