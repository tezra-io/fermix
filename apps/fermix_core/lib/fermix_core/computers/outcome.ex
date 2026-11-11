defmodule FermixCore.Computers.Outcome do
  @moduledoc """
  How an invocation on a computer ended (M97 §6.1, §6.3): one status from a
  closed set, and with it what the computer answered.

  | Status | Means |
  |---|---|
  | `ok` | it ran; `result` is its answer |
  | `failed` | it ran and failed; `message` is the capability's own words, and a tool that failed with a result of its own carries it in `result` (and its part) as well |
  | `refused` | it never ran; `refusal` says why, `message` in the computer's words |
  | `timed_out` | it did not finish within its deadline |
  | `cancelled` | it was cancelled before it finished |
  | `unknown` | whether it ran is not known: its answer was lost |

  A refusal is one of `off` (switched off on that computer), `unavailable`
  (it cannot run there, in the computer's words), `outside_sandbox`,
  `not_attended` (it runs only while the owner is in the conversation),
  `stopped_here` (the person at the computer stopped it), `busy` and
  `stale_epoch` (the request came from an older copy of the home). The
  home's own refusals before anything is sent (a computer that is away, a
  name no computer has) are not in this set: they never reach the wire.

  A `receipt` is the computer's record that it took the request: when, and
  what it acted on (`target`, a path, a host or an action; never content).
  An answer that says only what the computer's journal recorded, its result
  no longer held there (`receipt_only`), carries no result. An effect whose
  answer arrived and whose file (its part) did not is `part_lost`, the
  server's own word, never on the wire: it ran, and its output was lost on
  the way.

  On the wire an outcome is the `invoke_result` event (`to_wire/1`,
  `from_wire/2`): its header and its result JSON. `sentence/2` is what the
  model is told, naming the computer; each sentence obeys
  `Management.Copy`'s rules (`sentences/0`). `exec_metadata/1` is what the
  server's one tool exec row carries: ids and closed words, never content.
  Pure.
  """

  alias FermixCore.Computers.Offers

  @statuses [:ok, :failed, :refused, :timed_out, :cancelled, :unknown]
  @refusals [
    :off,
    :unavailable,
    :outside_sandbox,
    :not_attended,
    :stopped_here,
    :busy,
    :stale_epoch
  ]
  @status_words Map.new(@statuses, &{Atom.to_string(&1), &1})
  @refusal_words Map.new(@refusals, &{Atom.to_string(&1), &1})
  # A message rides for these alone: the capability's error, the refusal's
  # sentence, or why an answer is not known.
  @with_message [:failed, :refused, :unknown]
  @max_message_bytes 512
  @max_result_bytes 4 * 1_024 * 1_024
  @max_part_bytes 20 * 1_024 * 1_024
  @receipt_only ~s({"receipt_only":true})
  @controls ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u
  @sha256 ~r/\A[0-9a-f]{64}\z/
  @max_mime_bytes 127

  @typedoc "How an invocation ended."
  @type status :: :ok | :failed | :refused | :timed_out | :cancelled | :unknown

  @typedoc "Why a computer refused an invocation."
  @type refusal ::
          :off
          | :unavailable
          | :outside_sandbox
          | :not_attended
          | :stopped_here
          | :busy
          | :stale_epoch

  @typedoc "A part the answer announces: its size, its SHA-256 and its type."
  @type part :: %{size_bytes: pos_integer(), sha256: String.t(), mime: String.t()}

  @typedoc "The computer's record that it took the request."
  @type receipt :: %{at: DateTime.t(), target: String.t()}

  @enforce_keys [:status]
  defstruct status: nil,
            refusal: nil,
            message: nil,
            receipt: nil,
            result: %{},
            part: nil,
            part_bytes: nil,
            duration_ms: 0,
            receipt_only: false,
            part_lost: false,
            invocation: nil,
            computer: nil,
            capability: nil,
            target: nil,
            deadline_ms: nil

  @type t :: %__MODULE__{
          status: status(),
          refusal: refusal() | nil,
          message: String.t() | nil,
          receipt: receipt() | nil,
          result: map(),
          part: part() | nil,
          part_bytes: binary() | nil,
          duration_ms: non_neg_integer(),
          receipt_only: boolean(),
          part_lost: boolean(),
          invocation: String.t() | nil,
          computer: String.t() | nil,
          capability: String.t() | nil,
          target: String.t() | nil,
          deadline_ms: non_neg_integer() | nil
        }

  @doc "Every status, in the order the table lists them."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Every refusal, in the order the moduledoc lists them."
  @spec refusals() :: [refusal()]
  def refusals, do: @refusals

  @doc "The most bytes a result's JSON carries on the wire."
  @spec max_result_bytes() :: pos_integer()
  def max_result_bytes, do: @max_result_bytes

  @doc "The most bytes one part carries, either way."
  @spec max_part_bytes() :: pos_integer()
  def max_part_bytes, do: @max_part_bytes

  @doc "The payload of an answer that holds only the journal's receipt."
  @spec receipt_only_payload() :: String.t()
  def receipt_only_payload, do: @receipt_only

  @doc "A refusal with the computer's sentence."
  @spec refused(refusal(), String.t()) :: t()
  def refused(refusal, message) when refusal in @refusals and is_binary(message),
    do: %__MODULE__{status: :refused, refusal: refusal, message: message}

  @doc "Whether the outcome is an error a caller hears as `{:error, outcome}`."
  @spec error?(t()) :: boolean()
  def error?(%__MODULE__{status: status}), do: status != :ok

  # -- the wire --------------------------------------------------------------

  @doc """
  The outcome an `invoke_result` carries: its header `fields` and its result
  JSON. Refuses what the closed sets do not hold, a refusal on another status,
  a message where none rides, a part or a receipt of the wrong shape, and a
  result that is not a JSON object.
  """
  @spec from_wire(map(), binary()) :: {:ok, t()} | {:error, term()}
  def from_wire(fields, payload) when is_map(fields) and is_binary(payload) do
    with {:ok, status} <- word(@status_words, fields["status"], "status"),
         {:ok, refusal} <- refusal(status, fields["refusal"]),
         {:ok, message} <- message(status, fields["message"]),
         {:ok, receipt} <- receipt(fields["receipt"]),
         {:ok, part} <- part(fields["part"]),
         {:ok, duration} <- duration(fields["duration_ms"]),
         {:ok, result, receipt_only} <- result(payload) do
      {:ok,
       %__MODULE__{
         status: status,
         refusal: refusal,
         message: message,
         receipt: receipt,
         part: part,
         duration_ms: duration,
         result: result,
         receipt_only: receipt_only,
         invocation: fields["id"]
       }}
    end
  end

  @doc """
  The `invoke_result` of `outcome`: its header (`id` and the fields the
  moduledoc names; `t`, `index` and `last` are the sender's) and its result
  JSON. A message is made one line of at most #{@max_message_bytes} bytes.
  """
  @spec to_wire(t()) :: {map(), binary()}
  def to_wire(%__MODULE__{invocation: id, status: status} = outcome)
      when is_binary(id) and status in @statuses do
    header =
      %{"id" => id, "status" => Atom.to_string(status), "duration_ms" => outcome.duration_ms}
      |> put_some("refusal", outcome.refusal && Atom.to_string(outcome.refusal))
      |> put_some("message", wire_message(status, outcome.message))
      |> put_some("receipt", wire_receipt(outcome.receipt))
      |> put_some("part", wire_part(outcome.part))

    payload = if outcome.receipt_only, do: @receipt_only, else: Jason.encode!(outcome.result)
    {header, payload}
  end

  @doc "A part's announcement as the wire carries it."
  @spec wire_part(part() | nil) :: map() | nil
  def wire_part(nil), do: nil

  def wire_part(%{size_bytes: size, sha256: sha, mime: mime}),
    do: %{"size_bytes" => size, "sha256" => sha, "mime" => mime}

  @doc "A part's announcement read from the wire, or why it is refused."
  @spec part(map() | nil) :: {:ok, part() | nil} | {:error, term()}
  def part(nil), do: {:ok, nil}

  def part(%{"size_bytes" => size, "sha256" => sha, "mime" => mime})
      when is_integer(size) and size in 1..@max_part_bytes and is_binary(sha) and is_binary(mime) do
    if Regex.match?(@sha256, sha) and printable?(mime, @max_mime_bytes),
      do: {:ok, %{size_bytes: size, sha256: sha, mime: mime}},
      else: {:error, {:invalid_field, "part"}}
  end

  def part(_other), do: {:error, {:invalid_field, "part"}}

  defp word(words, value, field) do
    case Map.fetch(words, value) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:invalid_field, field}}
    end
  end

  defp refusal(:refused, value), do: word(@refusal_words, value, "refusal")
  defp refusal(_status, nil), do: {:ok, nil}
  defp refusal(_status, _value), do: {:error, {:invalid_field, "refusal"}}

  defp message(status, nil) when status in [:failed, :refused],
    do: {:error, {:missing_field, "message"}}

  defp message(status, nil) when status not in @with_message, do: {:ok, nil}
  defp message(:unknown, nil), do: {:ok, nil}

  defp message(status, value) when status in @with_message do
    if printable?(value, @max_message_bytes),
      do: {:ok, value},
      else: {:error, {:invalid_field, "message"}}
  end

  defp message(_status, _value), do: {:error, {:invalid_field, "message"}}

  defp receipt(nil), do: {:ok, nil}

  defp receipt(%{"at" => at, "target" => target}) when is_binary(at) and is_binary(target) do
    with {:ok, at, 0} <- DateTime.from_iso8601(at),
         true <- printable?(target, 256) do
      {:ok, %{at: at, target: target}}
    else
      _invalid -> {:error, {:invalid_field, "receipt"}}
    end
  end

  defp receipt(_other), do: {:error, {:invalid_field, "receipt"}}

  defp duration(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp duration(_value), do: {:error, {:invalid_field, "duration_ms"}}

  defp result(@receipt_only), do: {:ok, %{}, true}

  defp result(payload) when byte_size(payload) <= @max_result_bytes do
    case Jason.decode(payload) do
      {:ok, %{} = result} -> {:ok, result, false}
      _other -> {:error, {:invalid_result, "the result is not a JSON object"}}
    end
  end

  defp result(payload),
    do: {:error, {:invalid_result, "the result is #{byte_size(payload)} bytes"}}

  defp wire_message(status, message) when status in @with_message and is_binary(message),
    do: one_line(message)

  defp wire_message(_status, _message), do: nil

  defp wire_receipt(nil), do: nil

  defp wire_receipt(%{at: %DateTime{} = at, target: target}) when is_binary(target),
    do: %{
      "at" => at |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
      "target" => target
    }

  # The capability's own words on one line, cut on a character boundary.
  defp one_line(text) do
    line = text |> String.replace_invalid() |> String.replace(@controls, " ") |> String.trim()
    line = if line == "", do: "It failed and said nothing more.", else: line
    cut(line, @max_message_bytes)
  end

  defp cut(text, max) when byte_size(text) <= max, do: text

  defp cut(text, max) do
    text
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, acc ->
      if byte_size(acc) + byte_size(grapheme) <= max,
        do: {:cont, acc <> grapheme},
        else: {:halt, acc}
    end)
  end

  defp printable?(value, max) when is_binary(value),
    do: byte_size(value) in 1..max and String.valid?(value) and not Regex.match?(@controls, value)

  defp printable?(_value, _max), do: false

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  # -- what the model is told ----------------------------------------------------

  @doc """
  What the model is told of `outcome` on the computer called `name`, in a
  sentence of its own for each status and refusal (M97 §6.3): an answer
  that was lost says the outcome is not known.
  """
  @spec sentence(t(), String.t()) :: String.t()
  def sentence(%__MODULE__{status: :ok, receipt_only: true}, name),
    do: "#{name} did it, but its answer was lost on the way back."

  def sentence(%__MODULE__{status: :ok, part_lost: true}, name),
    do: "#{name} ran it, but its output was lost on the way back, so it is not run again."

  def sentence(%__MODULE__{status: :ok}, name), do: "Done on #{name}."

  def sentence(%__MODULE__{status: :failed, part_lost: true, message: message}, name),
    do:
      "#{name}: #{message} The rest of its output was lost on the way back, so it is not " <>
        "run again."

  def sentence(%__MODULE__{status: :failed, message: message}, name), do: "#{name}: #{message}"

  def sentence(%__MODULE__{status: :refused} = outcome, name),
    do: refusal_sentence(outcome.refusal, outcome, name)

  def sentence(%__MODULE__{status: :timed_out, deadline_ms: deadline}, name)
      when is_integer(deadline) and deadline > 0,
      do: "#{name} did not finish within #{seconds(deadline)}."

  def sentence(%__MODULE__{status: :timed_out}, name), do: "#{name} did not finish in time."
  def sentence(%__MODULE__{status: :cancelled}, name), do: "Cancelled before #{name} finished it."

  def sentence(%__MODULE__{status: :unknown, target: target}, name) do
    what = if is_binary(target) and target != "", do: target, else: "it"

    "Fermix lost #{name}'s answer, so whether #{what} happened is not known. " <>
      "Check before doing it again."
  end

  defp refusal_sentence(:off, outcome, name) do
    case label(outcome.capability) do
      nil ->
        "#{name} has everything Fermix on your server may use switched off. Only someone at " <>
          "#{name} can switch it on."

      label ->
        "#{name} has #{label} switched off. Only someone at #{name} can switch it on."
    end
  end

  defp refusal_sentence(:outside_sandbox, %{target: target}, name) do
    what = if is_binary(target) and target != "", do: target, else: "That"

    "#{what} is outside what #{name}'s sandbox allows. Someone at #{name} can allow the folder."
  end

  defp refusal_sentence(:not_attended, _outcome, name),
    do: "This runs on #{name} only while you are in the conversation."

  defp refusal_sentence(:stopped_here, _outcome, name), do: "The person at #{name} stopped it."

  defp refusal_sentence(:busy, _outcome, name),
    do: "#{name} is running as much as it allows right now. Try again in a moment."

  defp refusal_sentence(:stale_epoch, _outcome, name),
    do: "#{name} refused a request from an older copy of this Fermix."

  defp refusal_sentence(:unavailable, %{message: message}, _name) when is_binary(message),
    do: message

  defp refusal_sentence(:unavailable, _outcome, name), do: "#{name} cannot do that now."

  defp seconds(deadline_ms) do
    case div(deadline_ms + 999, 1_000) do
      1 -> "1 second"
      n -> "#{n} seconds"
    end
  end

  # The words an offer goes by, for the capability that is that offer; none
  # for one gated by the master switch alone.
  defp label(capability) when is_binary(capability) do
    Enum.find_value(Offers.core_modules(), fn module ->
      if Atom.to_string(module.id()) == capability, do: module.label()
    end)
  end

  defp label(_capability), do: nil

  @doc """
  Every sentence `sentence/2` says, for the copy rules, on a computer called
  "studio Mac" with the target "notes" and a refusal of the browser.
  """
  @spec sentences() :: [String.t()]
  def sentences do
    base = %__MODULE__{status: :ok, capability: "browser", target: "notes"}

    [
      %{base | status: :ok},
      %{base | status: :ok, receipt_only: true},
      %{base | status: :ok, part_lost: true},
      %{base | status: :failed, message: "No such file."},
      %{base | status: :failed, message: "Command failed (exit code 2):", part_lost: true},
      %{base | status: :timed_out, deadline_ms: 20_000},
      %{base | status: :timed_out, deadline_ms: 1_000},
      %{base | status: :timed_out},
      %{base | status: :cancelled},
      %{base | status: :unknown},
      %{base | status: :unknown, target: nil},
      %{refused(:off, "Switched off.") | capability: "system"}
    ]
    |> Enum.concat(for refusal <- @refusals, do: %{base | status: :refused, refusal: refusal})
    |> Enum.map(&sentence(&1, "studio Mac"))
  end

  # -- what the server's exec row carries -------------------------------------

  @doc """
  What the server's one tool exec row for this invocation carries, beside
  the tool's own: the computer's device id, the invocation's id, its status
  and its refusal. Ids and closed words, never content; absent when unset.
  """
  @spec exec_metadata(t()) :: map()
  def exec_metadata(%__MODULE__{} = outcome) do
    %{
      computer: outcome.computer,
      invocation: outcome.invocation,
      invoke_status: outcome.status,
      refusal: outcome.refusal
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end
end
