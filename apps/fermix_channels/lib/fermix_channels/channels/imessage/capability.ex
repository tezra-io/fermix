defmodule FermixChannels.Channels.IMessage.Capability do
  @moduledoc """
  `imessage` (M97 §6.4): the iMessage channel carried through a Mac's
  Messages for its server. The server runs the listener and the adapter,
  which make turns; the Mac runs the helper (`IMessage.Bridge`) and nothing
  that makes one. This module is both ends' contract: the server sends
  through it (`IMessage.ComputerHelper`), the Mac runs it
  (`FermixChannels.Desktop.Invoke`).

  Three operations, each carrying the helper's own request and answer
  unchanged (`{"method", "params", "timeout_ms"}` in, `{"result"}` or the
  helper's typed `{"error"}` out):

    * `imessage.call`: a read the link may run again after a lost answer
      (`probe`, `policy.get`, `watch.subscribe`, `watch.unsubscribe`,
      `messages.after`, `attachment.fetch`);
    * `imessage.send`: `send.text` and `send.file`, an effect the link never
      sends twice; the helper's own idempotency key stays in the params, so
      a delivery the gateway retries is answered from its ledger;
    * `imessage.watch`: long-lived (`deadline_ms` 0), the helper's
      notifications as they come (`IMessage.Watch`).

  Two calls are split where the callback can only say "effect" by operation:
  a send is an effect, every other call a read (`effect?/1`).

  **Never from the server**: `policy.set` (who Fermix may write to is
  confirmed on this Mac's screen and nowhere else, §7.2), `grant`,
  `initialize` and `shutdown`. `validate/2` refuses each by name on both
  ends.

  **Files stay on the Mac.** `send.file` arrives with its bytes as the
  invocation's part (at most 20 MiB) and a file name; the Mac stages it in
  the helper's outbox and fills `path` itself. `attachment.fetch` answers the
  file's name, type and size, with its bytes as the part, and the copy in the
  helper's inbox is removed once read. No path of the Mac's leaves it.

  **Admission**: the `imessage` switch and the epoch are Admission's; the
  origin is this module's. A send serves unattended turns, a reply to a
  message nobody watches and a reminder at its hour, so every turn's origin
  may send except a delegated worker's, whose reply goes through the turn
  that started it: a worker's send is a bug on the server, refused. Who may
  be written to is bounded by the recipient policy confirmed on this Mac,
  not by the origin.
  """

  @behaviour FermixCore.Computers.Capability

  alias FermixChannels.Channels.IMessage.Protocol
  alias FermixChannels.Channels.IMessage.Watch
  alias FermixCore.Computers.Offers.IMessage, as: IMessageOffer
  alias FermixCore.Computers.Outcome

  @reads ~w(probe policy.get watch.subscribe watch.unsubscribe messages.after attachment.fetch)
  @sends ~w(send.text send.file)
  @never ~w(policy.set grant initialize shutdown)
  @max_timeout_ms 180_000
  @max_part_bytes 20 * 1_024 * 1_024
  @max_name_bytes 128
  # The link's own allowance over the helper's budget.
  @deadline_margin_ms 5_000
  @policy_sentence "Who Fermix may write to is confirmed on the Mac that carries Messages; " <>
                     "the server cannot change it."

  @impl true
  def id, do: :imessage

  @impl true
  def offer, do: :imessage

  @impl true
  def ops, do: ["imessage.call", "imessage.send", "imessage.watch"]

  @impl true
  def label, do: IMessageOffer.label()

  @impl true
  def op_label("imessage.call"), do: "read Messages"
  def op_label("imessage.send"), do: "send a message"
  def op_label("imessage.watch"), do: "watch for new messages"

  @impl true
  def effect?("imessage.send"), do: true
  def effect?(_read_or_watch), do: false

  @impl true
  def long_lived?("imessage.watch"), do: true
  def long_lived?(_op), do: false

  @doc "The helper methods each operation carries."
  @spec methods(String.t()) :: [String.t()]
  def methods("imessage.call"), do: @reads
  def methods("imessage.send"), do: @sends
  def methods("imessage.watch"), do: []

  @doc "The sentence `policy.set` is refused with, on either end."
  @spec policy_sentence() :: String.t()
  def policy_sentence, do: @policy_sentence

  @doc "The most bytes a file carries either way."
  @spec max_part_bytes() :: pos_integer()
  def max_part_bytes, do: @max_part_bytes

  @impl true
  def validate("imessage.watch", %{"after" => after_seq, "boot" => boot} = args)
      when map_size(args) == 2 and (is_nil(after_seq) or is_integer(after_seq)) and
             (is_nil(boot) or is_binary(boot)),
      do: :ok

  def validate("imessage.watch", _args),
    do: {:error, "The watch takes the last event it was given and the watch it came from."}

  def validate(op, %{"method" => method} = args) when op in ["imessage.call", "imessage.send"] do
    cond do
      method == "policy.set" -> {:error, @policy_sentence}
      method in @never or method not in methods(op) -> {:error, unknown_method(method)}
      true -> valid_request(args)
    end
  end

  def validate(_op, _args), do: {:error, "A Messages request names its helper method."}

  defp valid_request(%{"params" => params, "timeout_ms" => timeout} = args)
       when is_map(params) and is_integer(timeout) and timeout in 1..@max_timeout_ms do
    case Map.drop(args, ["method", "params", "timeout_ms"]) do
      empty when map_size(empty) == 0 -> :ok
      %{"file_name" => name} = rest when map_size(rest) == 1 -> valid_name(name)
      _other -> {:error, "A Messages request carries its method, its params and its timeout."}
    end
  end

  defp valid_request(_args),
    do: {:error, "A Messages request carries its params and a timeout of at most 180 s."}

  defp valid_name(name) when is_binary(name) and byte_size(name) in 1..@max_name_bytes do
    if Path.basename(name) == name and name not in [".", ".."] and String.valid?(name),
      do: :ok,
      else: {:error, "A file's name is one name, not a path."}
  end

  defp valid_name(_name), do: {:error, "A file's name is one name, not a path."}

  defp unknown_method(method),
    do: "The server may not ask Messages on the Mac for #{inspect(method)}."

  @impl true
  def bounds("imessage.call"),
    do: %{result_bytes: Outcome.max_result_bytes(), part_bytes: @max_part_bytes}

  def bounds("imessage.send"), do: %{result_bytes: 64 * 1_024, part_bytes: 0}
  def bounds("imessage.watch"), do: %{result_bytes: Outcome.max_result_bytes(), part_bytes: 0}

  @impl true
  def deadline_ms("imessage.watch", _args), do: 0

  def deadline_ms(_op, %{"timeout_ms" => timeout}) when is_integer(timeout),
    do: timeout + @deadline_margin_ms

  @impl true
  def admit("imessage.send", _args, %{origin: :worker}),
    do:
      {:refused, :unavailable,
       "A delegated worker does not send iMessages; its reply goes through the turn that " <>
         "started it."}

  def admit(_op, _args, _context), do: :ok

  @impl true
  def run("imessage.watch", %{"after" => after_seq, "boot" => boot}, nil, _context) do
    case Watch.next(Watch, after_seq, boot) do
      {:ok, answer} -> {:ok, answer, nil}
      {:error, sentence} -> {:refused, :unavailable, sentence}
    end
  end

  def run(op, %{"method" => method, "params" => params} = args, part, _context)
      when op in ["imessage.call", "imessage.send"] do
    case Watch.request(Watch, method, params, part, args) do
      {:ok, result, answer_part} ->
        {:ok, %{"result" => result}, answer_part}

      {:error, {kind, message, data}} ->
        error = %{"kind" => Atom.to_string(kind), "message" => message, "data" => data}
        {:failed, "#{kind}: #{bounded(message)}", %{"error" => error}, nil}

      {:unavailable, sentence} ->
        {:refused, :unavailable, sentence}
    end
  end

  def run(_op, _args, _part, _context), do: {:failed, "Messages takes no file for that request."}

  @impl true
  def target("imessage.watch", _args), do: "imessage.watch"

  def target(_op, %{"method" => method, "params" => %{"to" => to}})
      when is_binary(method) and is_binary(to),
      do: "#{method} to #{Protocol.redact_handle(to)}"

  def target(_op, %{"method" => method}) when is_binary(method), do: method
  def target(op, _args), do: op

  defp bounded(message) when is_binary(message), do: String.slice(message, 0, 200)
end
