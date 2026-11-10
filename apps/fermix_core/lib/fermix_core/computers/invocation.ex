defmodule FermixCore.Computers.Invocation do
  @moduledoc """
  One invocation of a computer's capability from the server (M97 §6.1,
  §6.3), as `FermixCore.Computers.call/6` runs it in the caller's process.

  **Before anything is sent** it refuses at once, with the sentence the
  model reads, a computer that is not connected ("asleep or offline", D5),
  one whose offer for the capability is off or unavailable (in that
  offer's own words), and one that has said nothing of what it offers. Args
  the capability refuses are `failed` with its sentence, and args over
  #{1_024} KiB are refused before the codec would be.

  **Then** it mints the invocation's id (`inv-` and 26 base32 characters,
  never reused), registers it with `Computers.Calls`, sends `invoke_open`
  and its part through the transport, and waits for `invoke_result` and any
  part it announces (the two may cross lanes), at most `deadline_ms` and
  #{2_000} ms more for the link. A computer that names no deadline
  (`deadline_ms` 0, a long-lived op) is waited on until it answers or is
  cancelled (`Computers.cancel/2`).

  **An effect is never sent twice by the link.** When the session ends and
  comes back, the family asks the computer for each invocation still waited
  on (`invoke_status`); its answer arrives here as any other. An answer
  that says the outcome is not known (`unknown`), or that holds only the
  journal's receipt, ends an effect there: the model is told the outcome is
  not known. A read (`effect?/1` false) is asked once more under a new id
  with the time left. When no answer comes before the wait ends, an effect
  is `unknown` and a read `timed_out`, and the computer is told to cancel
  it, best-effort.

  Seams in `opts` (beside `deadline_ms`, `part` and `on_part`): `:calls`
  (the `Calls` server), `:transport` (`{module, opts}`), `:computers`
  (options for `FermixCore.Computers.get/2`), `:epoch` (this primary's
  epoch, else read from `:home`'s), `:grace_ms` (the link's allowance) and
  `:clock` (0-arity wall clock).
  """

  require Logger

  alias FermixCore.Computers
  alias FermixCore.Computers.Calls
  alias FermixCore.Computers.Capability
  alias FermixCore.Computers.Computer
  alias FermixCore.Computers.Origin
  alias FermixCore.Computers.Outcome
  alias FermixCore.Computers.Transport
  alias FermixCore.Home.Epoch
  alias FermixCore.Setup.ConfigStore

  @default_deadline_ms 30_000
  @max_deadline_ms 900_000
  @grace_ms 2_000
  @max_args_bytes 1_024 * 1_024
  # A read asked again needs at least this much of its deadline left.
  @min_retry_ms 1_000
  @default_mime "application/octet-stream"

  @doc "Runs the invocation (the moduledoc)."
  @spec call(Computer.t() | String.t(), module(), String.t(), map(), map(), keyword()) ::
          {:ok, Outcome.t()} | {:error, Outcome.t()}
  def call(computer, module, op, args, context, opts)
      when is_atom(module) and is_binary(op) and is_map(args) and is_map(context) and
             is_list(opts) do
    unless Capability.runs?(module, op),
      do: raise(ArgumentError, "#{inspect(module)} has no op #{inspect(op)}")

    with {:ok, computer} <- computer(computer, opts),
         :ok <- reachable(computer, module),
         {:ok, request} <- request(computer, module, op, args, context, opts) do
      request |> invoke(opts, false) |> answer()
    else
      {:refused, %Outcome{} = outcome} -> {:error, outcome}
    end
  end

  @doc "Cancels the invocation `id` on its computer; its answer comes to its caller."
  @spec cancel(String.t(), keyword()) :: :ok | {:error, :not_found | term()}
  def cancel(id, opts) when is_binary(id) and is_list(opts),
    do: Calls.cancel(Keyword.get(opts, :calls, Calls), id)

  defp answer(%Outcome{status: :ok} = outcome), do: {:ok, outcome}
  defp answer(%Outcome{} = outcome), do: {:error, outcome}

  # -- before anything is sent ---------------------------------------------------

  defp computer(%Computer{} = computer, _opts), do: {:ok, computer}

  defp computer(name, opts) when is_binary(name) do
    case Computers.get(name, Keyword.get(opts, :computers, [])) do
      {:ok, computer} -> {:ok, computer}
      {:error, :not_found} -> refuse(:unavailable, "Your Fermix has no such computer.")
    end
  end

  defp reachable(%Computer{connected: false, name: name}, _module),
    do: refuse(:unavailable, "#{name} is asleep or offline, so Fermix cannot reach it now.")

  defp reachable(%Computer{offers: []} = computer, _module),
    do: refuse(:unavailable, "#{computer.name} has not said yet what Fermix may use there.")

  defp reachable(%Computer{}, _module), do: :ok

  defp refuse(refusal, sentence), do: {:refused, Outcome.refused(refusal, sentence)}

  defp request(computer, module, op, args, context, opts) do
    deadline = deadline(module, op, opts)
    origin = Origin.of(context)

    with :ok <- refuse_offer(computer, module),
         :ok <- valid_args(module, op, args),
         {:ok, payload} <- encoded(args),
         {:ok, part} <- part(Keyword.get(opts, :part)) do
      {:ok,
       %{
         computer: computer,
         module: module,
         capability: Capability.wire_id(module),
         op: op,
         payload: payload,
         effect?: module.effect?(op),
         deadline_ms: deadline,
         epoch: epoch(opts),
         origin: origin,
         turn: turn(origin, context),
         target: Capability.bounded_target(module.target(op, args)),
         part: part
       }}
    end
  end

  # The offer the capability is, as the computer last said it.
  defp refuse_offer(%Computer{} = computer, module) do
    with id when is_atom(id) and not is_nil(id) <- module.offer(),
         wanted = Atom.to_string(id),
         offer <- Enum.find(computer.offers, &(&1.id == wanted)),
         false <- match?(%{state: :on}, offer) do
      offer_refusal(offer, computer, module)
    else
      _on_or_master_only -> :ok
    end
  end

  defp offer_refusal(%{state: :off, sentence: sentence}, _computer, module),
    do: {:refused, %{Outcome.refused(:off, sentence) | capability: Capability.wire_id(module)}}

  defp offer_refusal(%{state: :unavailable, sentence: sentence}, _computer, _module),
    do: refuse(:unavailable, sentence)

  defp offer_refusal(nil, computer, _module),
    do: refuse(:unavailable, "#{computer.name} has not said yet what Fermix may use there.")

  defp valid_args(module, op, args) do
    case module.validate(op, args) do
      :ok -> :ok
      {:error, sentence} -> {:refused, %Outcome{status: :failed, message: sentence}}
    end
  end

  defp encoded(args) do
    payload = Jason.encode!(args)

    if byte_size(payload) <= @max_args_bytes,
      do: {:ok, payload},
      else: {:refused, %Outcome{status: :failed, message: "The request is larger than 1 MiB."}}
  end

  defp part(nil), do: {:ok, nil}
  defp part(bytes) when is_binary(bytes), do: part({bytes, @default_mime})

  defp part({bytes, mime}) when is_binary(bytes) and is_binary(mime) do
    if byte_size(bytes) in 1..Outcome.max_part_bytes() do
      sha = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
      {:ok, %{bytes: bytes, announce: %{size_bytes: byte_size(bytes), sha256: sha, mime: mime}}}
    else
      {:refused, %Outcome{status: :failed, message: "The file is larger than 20 MiB."}}
    end
  end

  defp deadline(module, op, opts) do
    case Keyword.get(opts, :deadline_ms, @default_deadline_ms) do
      0 ->
        unless module.long_lived?(op),
          do: raise(ArgumentError, "#{op} is not long-lived, so it needs a deadline")

        0

      ms when is_integer(ms) and ms in 1..@max_deadline_ms ->
        ms
    end
  end

  defp epoch(opts) do
    Keyword.get_lazy(opts, :epoch, fn ->
      home = Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)
      {:ok, epoch} = Epoch.read(home)
      epoch
    end)
  end

  # A turn names itself; the tool call's id where the loop gave one, else
  # the invocation's own (`header/1`).
  defp turn(origin, context) do
    if Origin.turn?(origin) do
      session = Map.get(context, :session_id)

      unless is_binary(session) and session != "",
        do: raise(ArgumentError, "a turn's invocation needs the turn's session_id")

      %{session_id: session, tool_call_id: Map.get(context, :tool_call_id)}
    end
  end

  # -- sending and waiting ------------------------------------------------------

  defp invoke(request, opts, retried?) do
    id = mint_id()
    calls = Keyword.get(opts, :calls, Calls)
    {transport, transport_opts} = Keyword.get_lazy(opts, :transport, &Transport.impl/0)
    device = request.computer.device_id
    now = clock(opts)

    :ok =
      Calls.register(calls, %{
        id: id,
        device_id: device,
        caller: self(),
        effect?: request.effect?,
        started_at: now,
        deadline_at: deadline_at(now, request.deadline_ms),
        transport: {transport, transport_opts}
      })

    started = System.monotonic_time(:millisecond)

    sent =
      transport.open(
        device,
        header(request, id),
        request.payload,
        part_bytes(request),
        transport_opts
      )

    outcome = sent(sent, request, id, started, opts)
    :ok = Calls.forget(calls, id)
    :ok = flush(id)

    outcome |> finished(request, id) |> again(request, opts, retried?, started)
  end

  defp sent(:ok, request, id, started, opts),
    do: await(request, id, started, %{result: nil, part: nil}, opts)

  defp sent({:error, {:part, reason}}, request, id, started, opts) do
    Logger.warning("invocation #{id}: its file was not sent whole: #{inspect(reason)}")
    await(request, id, started, %{result: nil, part: nil}, opts)
  end

  defp sent({:error, :not_connected}, request, _id, _started, _opts),
    do: Outcome.refused(:unavailable, away(request.computer))

  defp sent({:error, reason}, request, id, _started, _opts) do
    Logger.error("invocation #{id} was not sent to #{request.computer.name}: #{inspect(reason)}")
    Outcome.refused(:unavailable, "#{request.computer.name} could not be sent the request.")
  end

  defp away(computer), do: "#{computer.name} is asleep or offline, so Fermix cannot reach it now."

  defp await(request, id, started, state, opts) do
    receive do
      {:computer_invoke, ^id, message} ->
        state = take(message, state, opts)

        case complete(state, request) do
          {:done, outcome} -> outcome
          :more -> await(request, id, started, state, opts)
        end
    after
      wait_left(request, started, opts) -> gave_up(request, id, state, opts)
    end
  end

  defp wait_left(%{deadline_ms: 0}, _started, _opts), do: :infinity

  defp wait_left(request, started, opts) do
    grace = Keyword.get(opts, :grace_ms, @grace_ms)
    max(started + request.deadline_ms + grace - System.monotonic_time(:millisecond), 0)
  end

  # A result that came twice (asked again after a reconnect) is taken once.
  defp take({:result, _fields, _payload}, %{result: %Outcome{}} = state, _opts), do: state

  defp take({:result, fields, payload}, state, _opts) do
    case Outcome.from_wire(fields, payload) do
      {:ok, outcome} ->
        %{state | result: outcome}

      {:error, reason} ->
        Logger.warning("an invocation's answer was refused: #{inspect(reason)}")

        %{
          state
          | result: %Outcome{status: :failed, message: "The computer's answer could not be read."}
        }
    end
  end

  defp take({:part, {:progress, received, size}}, state, opts) do
    case Keyword.get(opts, :on_part) do
      nil ->
        state

      on_part ->
        _said = on_part.(%{received_bytes: received, size_bytes: size})
        state
    end
  end

  defp take({:part, {:done, bytes}}, %{part: nil} = state, _opts),
    do: %{state | part: {:ok, bytes}}

  defp take({:part, {:error, sentence}}, %{part: nil} = state, _opts),
    do: %{state | part: {:error, sentence}}

  defp take({:part, _late}, state, _opts), do: state

  defp complete(%{result: nil}, _request), do: :more
  defp complete(%{result: %Outcome{part: nil} = outcome}, _request), do: {:done, outcome}
  defp complete(%{part: nil}, _request), do: :more

  defp complete(%{result: outcome, part: {:ok, bytes}}, request) do
    %{size_bytes: size, sha256: sha} = outcome.part
    whole? = byte_size(bytes) == size and sha256(bytes) == sha

    if whole?,
      do: {:done, %{outcome | part_bytes: bytes}},
      else: {:done, part_lost(outcome, request, "The answer's file did not arrive whole.")}
  end

  defp complete(%{result: outcome, part: {:error, sentence}}, request),
    do: {:done, part_lost(outcome, request, sentence)}

  # An effect that ran stays done without its file; a read fails, and is asked
  # again by the model if it wants.
  defp part_lost(outcome, %{effect?: true}, _sentence), do: outcome
  defp part_lost(_outcome, _request, sentence), do: %Outcome{status: :failed, message: sentence}

  defp gave_up(request, id, state, opts) do
    {transport, transport_opts} = Keyword.get_lazy(opts, :transport, &Transport.impl/0)

    case state.result do
      %Outcome{} = outcome ->
        part_lost(outcome, request, "The answer's file did not arrive in time.")

      nil ->
        _cancelled = cancel_sent(transport, request.computer.device_id, id, transport_opts)
        if request.effect?, do: %Outcome{status: :unknown}, else: %Outcome{status: :timed_out}
    end
  end

  defp cancel_sent(transport, device, id, opts) do
    case transport.cancel(device, id, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("invocation #{id} was not cancelled on its computer: #{inspect(reason)}")
    end
  end

  defp finished(%Outcome{} = outcome, request, id) do
    %{
      outcome
      | invocation: id,
        computer: request.computer.device_id,
        capability: outcome.capability || request.capability,
        target: request.target,
        deadline_ms: request.deadline_ms
    }
  end

  # An answer that says the outcome is not known ends an effect; a read is
  # asked once more under a new id, with the time it has left.
  defp again(outcome, request, opts, false, started) do
    left = time_left(request, started)

    if not request.effect? and lost?(outcome) and left != :none,
      do: invoke(%{request | deadline_ms: left}, opts, true),
      else: outcome
  end

  defp again(outcome, _request, _opts, true, _started), do: outcome

  defp lost?(%Outcome{status: :unknown}), do: true
  defp lost?(%Outcome{receipt_only: true}), do: true
  defp lost?(_outcome), do: false

  defp time_left(%{deadline_ms: 0}, _started), do: 0

  defp time_left(request, started) do
    left = started + request.deadline_ms - System.monotonic_time(:millisecond)
    if left >= @min_retry_ms, do: left, else: :none
  end

  defp header(request, id) do
    %{
      "id" => id,
      "capability" => request.capability,
      "op" => request.op,
      "deadline_ms" => request.deadline_ms,
      "epoch" => request.epoch,
      "origin" => Atom.to_string(request.origin)
    }
    |> put_turn(request.turn, id)
    |> put_part(request.part)
  end

  defp put_turn(header, nil, _id), do: header

  defp put_turn(header, %{session_id: session, tool_call_id: call}, id),
    do: Map.put(header, "turn", %{"session_id" => session, "tool_call_id" => call || id})

  defp put_part(header, nil), do: header

  defp put_part(header, %{announce: announce}),
    do: Map.put(header, "part", Outcome.wire_part(announce))

  defp part_bytes(%{part: nil}), do: nil
  defp part_bytes(%{part: %{bytes: bytes}}), do: bytes

  # Words for an invocation that came after its caller let go are dropped.
  defp flush(id) do
    receive do
      {:computer_invoke, ^id, _late} -> flush(id)
    after
      0 -> :ok
    end
  end

  defp mint_id,
    do: "inv-" <> Base.encode32(:crypto.strong_rand_bytes(16), case: :lower, padding: false)

  defp deadline_at(_now, 0), do: nil
  defp deadline_at(now, deadline_ms), do: DateTime.add(now, deadline_ms, :millisecond)

  defp clock(opts), do: Keyword.get(opts, :clock, &DateTime.utc_now/0).()

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
