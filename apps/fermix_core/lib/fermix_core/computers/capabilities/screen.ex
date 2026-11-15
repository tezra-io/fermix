defmodule FermixCore.Computers.Capabilities.Screen do
  @moduledoc """
  `computer_use` (M97 §6.4): the server sees and controls this computer's
  screen. The server's session (`ComputerUse.Session`, its budget, its images,
  its pause) drives it through `ComputerUse.ComputerDriver`, which sends each
  driver call here; this computer's own helper runs it, held for the server by
  `ComputerUse.Seat`. Its `computer_use` switch gates it, at this computer.

  | op | what | changes something |
  |---|---|---|
  | `screen.look` | one read-only request: a screenshot, `elements`, `inspect`, `windows`, a wait, the helper's `hello` and `probe` | no |
  | `screen.act` | one action that sends input: a click, keys, typing, a drag, a scroll, a paste, `set_value`, a verb on a control | yes |
  | `screen.control` | `pause`, `resume` or `release` of the helper's input barrier, or `keep`: the server renews its hold while its session exists, which the journal never records (`recorded?/2`) | no |
  | `screen.watch` | waits, until cancelled, for the server's hold on the screen to end | no |

  An action is never sent twice by the link: a lost answer to `screen.act` is
  not known (`Computers.Outcome`). Args are `{seat, request}` (the server
  session's `cua_` id and the helper request, as `Compux.Protocol` shapes
  it), `{seat, control}` or `{seat}`; a request whose action is not of its op's
  kind is refused before it runs.

  **Here, not on the server**, because the facts are here:

    * the origin: the server's turn must be one the owner is in, a chat or a
      call (`not_attended` otherwise), checked again here;
    * the access level follows this computer's sandbox mode: `strict` refuses
      every action that changes something (`outside_sandbox`), by the rule
      the local session follows (`ComputerUse.Safety.gate/2`);
    * courtesy: before an action that disturbs a person, this computer's idle
      signal decides whether to wait for them or step aside
      (`ComputerUse.Yield`, with this computer's computer use config);
    * one server session holds the screen at a time (`busy`), and a seat the
      person stopped, or whose switch went off, is refused `stopped_here`; a
      seat whose hold ended otherwise (its server went quiet past the
      seat's lapse, or let go) is refused `unavailable`, never taken again.

  The answer of a look or an action is the helper's own reply, its image (a PNG
  of at most #{1366} by #{768}) riding as the part. A step the helper refused,
  courtesy held back, or a helper that stopped answering is `failed`, its result
  the driver's error, which `ComputerDriver` gives the session as the local
  driver would. Nothing typed or read off the screen is ever a target.
  """

  @behaviour FermixCore.Computers.Capability

  alias Compux.Protocol
  alias FermixCore.Computers.Offers.ComputerUse, as: ComputerUseOffer
  alias FermixCore.Computers.Origin
  alias FermixCore.ComputerUse
  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Safety
  alias FermixCore.ComputerUse.Seat
  alias FermixCore.ComputerUse.Yield
  alias FermixCore.Timeouts

  require Logger

  @ops ["screen.act", "screen.control", "screen.look", "screen.watch"]
  @steps ["screen.act", "screen.look"]
  @controls ~w(pause resume release keep)
  @seat ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @result_bytes 1_024 * 1_024
  @part_bytes 16 * 1_024 * 1_024
  @control_deadline_ms 5_000
  # One helper action, the courtesy wait before it, and the courtesy probe.
  @step_slack_ms 2_000
  @max_detail_bytes 300
  # The helper faults after which it is not handed input again.
  @helper_faults ~w(timeout exited unavailable wire)

  @not_attended_sentence "Fermix on your server uses this computer's screen only while you " <>
                           "are in the conversation."
  @strict_sentence "This computer's sandbox is strict, so Fermix on your server may look at " <>
                     "its screen but not act on it. Only someone at this computer can change that."
  @busy_sentence "Fermix on your server is already using this computer's screen in another " <>
                   "conversation."
  @stopped_sentence "The person at this computer stopped it."
  @ended_sentence "Fermix on your server let go of this computer's screen. A new session " <>
                    "takes it again."
  @no_seat_sentence "Fermix on this computer cannot hold its screen for its server now."
  @helper_sentence "The screen helper on this computer did not start. Its log says why."
  @no_file_sentence "This takes no file."

  @impl true
  def id, do: :computer_use

  @impl true
  def offer, do: :computer_use

  @impl true
  def ops, do: @ops

  @impl true
  def label, do: ComputerUseOffer.label()

  @impl true
  def op_label("screen.look"), do: "look at the screen"
  def op_label("screen.act"), do: "use the mouse or keyboard"
  def op_label("screen.control"), do: "pause, resume, keep or let go of the screen"
  def op_label("screen.watch"), do: "hold the screen"

  @impl true
  def effect?("screen.act"), do: true
  def effect?(op) when op in @ops, do: false

  @impl true
  def long_lived?("screen.watch"), do: true
  def long_lived?(op) when op in @ops, do: false

  # The server renewing its hold is no thing Fermix did here: never journaled.
  @impl true
  def recorded?("screen.control", %{"control" => "keep"}), do: false
  def recorded?(_op, _args), do: true

  @doc "Whether this engine's own host can drive its own screen."
  @impl true
  def here?(context) when is_map(context), do: ComputerUse.ready?()

  @impl true
  def deadline_ms(op, _args) when op in @steps,
    do: Timeouts.cu_sidecar_action() + ComputerUse.Courtesy.defer_ms() + @step_slack_ms

  def deadline_ms("screen.control", _args), do: @control_deadline_ms

  @impl true
  def validate(op, args) when op in @ops and is_map(args) do
    with :ok <- seat(args["seat"]), do: shape(op, args)
  end

  @impl true
  def bounds(op) when op in @steps, do: %{result_bytes: @result_bytes, part_bytes: @part_bytes}
  def bounds(op) when op in @ops, do: %{result_bytes: 4_096, part_bytes: 0}

  @impl true
  def admit("screen.act", %{"request" => %{"action" => action}}, context) do
    with :ok <- attended(context) do
      case Safety.gate(action, %Config{access: context.sandbox.mode}) do
        :auto -> :ok
        :refuse -> {:refused, :outside_sandbox, @strict_sentence}
      end
    end
  end

  # Handing the screen back is always allowed: a pause, a release, the end of
  # a hold.
  def admit("screen.control", _args, _context), do: :ok
  def admit(op, _args, context) when op in @ops, do: attended(context)

  # A computer that holds no seat for its server (its helper is not installed,
  # or its engine is stopping) refuses rather than fails.
  @impl true
  def run(op, args, part, context) do
    ran(op, args, part, context)
  catch
    :exit, {:noproc, {GenServer, :call, _args}} -> {:refused, :unavailable, @no_seat_sentence}
  end

  defp ran(op, %{"seat" => seat, "request" => request}, nil, context) when op in @steps do
    server = seats(context)

    case Seat.acquire(server, seat) do
      {:ok, held} -> step(request, held, {server, seat})
      {:error, :stopped} -> {:refused, :stopped_here, @stopped_sentence}
      {:error, :ended} -> {:refused, :unavailable, @ended_sentence}
      {:error, {:busy, _since}} -> {:refused, :busy, @busy_sentence}
      {:error, {:helper, reason}} -> {:failed, helper_sentence(reason)}
    end
  end

  # The server renews its hold, as it does while its session exists.
  defp ran("screen.control", %{"seat" => seat, "control" => "keep"}, nil, context),
    do: {:ok, %{"held" => Seat.keep(seats(context), seat) == :held}, nil}

  defp ran("screen.control", %{"seat" => seat, "control" => control}, nil, context) do
    case Seat.driver(seats(context), seat) do
      {:ok, {mod, state}} -> controlled(mod, state, control)
      :none -> {:ok, %{"ack" => nil}, nil}
    end
  end

  defp ran("screen.watch", %{"seat" => seat}, nil, context) do
    case Seat.watch(seats(context), seat) do
      why when why in [:stopped, :switched_off] -> {:refused, :stopped_here, @stopped_sentence}
      why -> {:ok, %{"ended" => Atom.to_string(why)}, nil}
    end
  end

  defp ran(_op, _args, _part, _context), do: {:failed, @no_file_sentence}

  @doc "Lets go of the screen the watch run `pid` waits on: the server ended its hold."
  @impl true
  def cancel("screen.watch", pid) when is_pid(pid) do
    Seat.close(pid)
  catch
    :exit, {:noproc, _call} -> :ok
  end

  def cancel(op, pid) when op in @ops and is_pid(pid), do: :ok

  @impl true
  def target(op, %{"request" => %{"action" => action}}) when op in @steps and is_binary(action),
    do: "screen " <> action

  def target("screen.control", %{"control" => control}) when control in @controls,
    do: "screen " <> control

  def target(_op, _args), do: "screen"

  @doc "Every sentence this computer says of its screen, for the copy rules."
  @spec sentences() :: [String.t()]
  def sentences,
    do:
      [
        @not_attended_sentence,
        @strict_sentence,
        @busy_sentence,
        @stopped_sentence,
        @ended_sentence,
        @no_seat_sentence,
        @helper_sentence,
        @no_file_sentence
      ] ++
        Enum.map(~w(action_failed user_active not_dispatched timeout exited), &failed_sentence/1)

  # -- the checks --------------------------------------------------------------

  defp seat(seat) when is_binary(seat) do
    if Regex.match?(@seat, seat), do: :ok, else: {:error, "Name the screen's seat."}
  end

  defp seat(_seat), do: {:error, "Name the screen's seat."}

  defp shape("screen.look", %{"request" => %{"action" => action}}) when is_binary(action) do
    if Protocol.read_only?(action), do: :ok, else: {:error, "A look sends no input."}
  end

  defp shape("screen.act", %{"request" => %{"action" => action}}) when is_binary(action) do
    if action in Protocol.actions() and not Protocol.read_only?(action),
      do: :ok,
      else: {:error, "An action sends input."}
  end

  defp shape("screen.control", %{"control" => control}) when control in @controls, do: :ok
  defp shape("screen.watch", %{} = args) when map_size(args) == 1, do: :ok
  defp shape(_op, _args), do: {:error, "The screen does not take that."}

  defp attended(context) do
    if Origin.attended?(context.origin),
      do: :ok,
      else: {:refused, :not_attended, @not_attended_sentence}
  end

  # The seat holder this computer runs; a test names its own.
  defp seats(context), do: Map.get(context, :screen_seat, Seat.name())

  # -- a step ------------------------------------------------------------------

  # A target id rides every request that acts inside a bound window, which is
  # all the courtesy step needs of the session's binding.
  defp step(request, held, seat) do
    facts = %{
      config: held.config,
      capabilities: held.capabilities,
      target_kind: if(is_binary(request["target_id"]), do: :window),
      last_action_at: held.last_action_at
    }

    case Yield.check(request, facts, held.driver) do
      {:proceed, courtesy} -> dispatch(request, held.driver, courtesy, seat)
      {:refuse, :user_active} -> failed(%{"kind" => "user_active"}, seat)
      {:abort, reason} -> failed(%{"kind" => "not_dispatched", "reason" => error(reason)}, seat)
    end
  end

  defp dispatch(request, {mod, state}, courtesy, {server, id} = seat) do
    result = mod.execute(state, request)
    :ok = Seat.acted(server, id, request["action"])

    case result do
      {:ok, response} when is_map(response) -> answered(response, courtesy)
      {:error, reason} -> failed(error(reason), seat)
    end
  end

  # The image rides as the part, its bytes rather than their base64; the rest
  # of the helper's reply is the result.
  defp answered(response, courtesy) do
    result = %{"response" => Map.delete(response, "data"), "courtesy" => Atom.to_string(courtesy)}

    case decoded(response["data"]) do
      {:ok, png} -> {:ok, result, png}
      :none -> {:ok, result, nil}
      :error -> {:ok, Map.put(result, "response", response), nil}
    end
  end

  defp decoded(data) when is_binary(data) do
    case Base.decode64(data) do
      {:ok, bytes} when bytes != "" -> {:ok, bytes}
      _not_base64 -> :error
    end
  end

  defp decoded(_absent), do: :none

  # A step that did not do what was asked: refused by the helper, held back
  # for a person, or a helper that stopped answering, after which this seat
  # hands it no more input. A seat the person stopped meanwhile answers as
  # stopped.
  defp failed(%{"kind" => kind} = error, {server, id}) do
    if kind in @helper_faults or kind == "not_dispatched",
      do: Seat.close(server, id, :helper_exited)

    case Seat.watch_state(server, id) do
      :stopped -> {:refused, :stopped_here, @stopped_sentence}
      _held_or_gone -> {:failed, failed_sentence(kind), %{"error" => error}, nil}
    end
  end

  defp failed_sentence("action_failed"), do: "The helper refused it."
  defp failed_sentence("user_active"), do: "Someone is using this computer, so nothing was sent."

  defp failed_sentence("not_dispatched"),
    do: "The helper stopped answering before anything was sent."

  defp failed_sentence("timeout"), do: "The helper did not answer in time."
  defp failed_sentence(_kind), do: "The helper stopped answering."

  # The driver's error as the wire carries it: the helper's own refusal whole,
  # the faults by kind, anything else by its words.
  defp error({:action_failed, payload}) when is_map(payload),
    do: %{"kind" => "action_failed", "payload" => payload}

  defp error({:timeout, :cu_sidecar_action, ms}) when is_integer(ms),
    do: %{"kind" => "timeout", "ms" => ms}

  defp error({:sidecar_exited, status}) when is_integer(status),
    do: %{"kind" => "exited", "status" => status}

  defp error({:sidecar_exited, status}), do: %{"kind" => "exited", "detail" => detail(status)}
  defp error(:sidecar_unavailable), do: %{"kind" => "unavailable"}

  defp error({family, _detail} = reason)
       when family in [
              :protocol_error,
              :unknown_request_id,
              :stale_generation,
              :malformed_frame,
              :unexpected_frame
            ],
       do: %{"kind" => "wire", "detail" => detail(reason)}

  defp error(reason) when reason in [:sidecar_response_too_large, :request_too_large],
    do: %{"kind" => "wire", "detail" => detail(reason)}

  defp error(reason), do: %{"kind" => "other", "detail" => detail(reason)}

  defp detail(term), do: term |> inspect() |> String.slice(0, @max_detail_bytes)

  defp controlled(mod, state, control) do
    if function_exported?(mod, :control, 2) do
      case mod.control(state, String.to_existing_atom(control)) do
        {:ok, ack} -> {:ok, %{"ack" => ack_view(ack)}, nil}
        {:error, reason} -> {:failed, "The helper did not confirm it: #{detail(reason)}"}
      end
    else
      {:ok, %{"ack" => nil}, nil}
    end
  end

  # The acknowledgement the session reads: whether an action is still under way.
  defp ack_view(ack) when is_map(ack) do
    %{"in_flight_request_id" => ack[:in_flight_request_id] || ack["in_flight_request_id"]}
  end

  defp ack_view(_ack), do: %{"in_flight_request_id" => nil}

  defp helper_sentence(reason) do
    Logger.warning("computer_use: the helper did not start for the server: #{inspect(reason)}")
    @helper_sentence
  end
end
