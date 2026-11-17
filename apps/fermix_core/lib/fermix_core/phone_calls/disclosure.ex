defmodule FermixCore.PhoneCalls.Disclosure do
  @moduledoc """
  The check a phone call's backend reply passes before it leaves for the
  voice session (M94 §11: "Backend replies are checked for permitted
  disclosure before going to Live"). Pure and deterministic: the same reply,
  brief and call always give the same answer, and no model is asked.

  What the person called may hear is what the brief lets the call share (its
  shareable facts, M94 §06) and what was already said on the call. The turn
  that wrote the reply holds nothing else of the owner's: no memory, persona
  or chat, and the brief's rendering leaves out the number dialed, the caller
  number and where the number came from (`BriefText`). So the check holds the
  reply to that, in what code can recognise exactly. A reply is withheld
  (`{:withheld, why}`) when it:

    * runs past `max_reply_bytes/0` (`:too_long`), the bound that keeps it
      within the voice session's 500-token append limit whatever its script;
    * carries the untrusted-content frame or a model control-token marker
      (`:protocol_text`), which would hand the voice model a frame or a token
      as if they were the backend's words;
    * holds a number of seven or more digits, the shape of a phone, card or
      account number (an ISO date aside), that no shareable fact holds and
      nobody said on the call (`:unshared_number`), compared digits only, so
      `555-0142` matches `+1 (503) 555-0142`;
    * holds an email address no shareable fact holds and nobody said on the
      call (`:unshared_email`);
    * repeats eight consecutive words of the turn's own instructions that are
      not also in the brief, a shareable fact or the call (`:instructions_text`),
      the sign of a prompt being read out.

  A withheld reply is never sent: the turn fails with
  `{:reply_withheld, why}`, and the call's worker speaks its own honest
  limitation in its place (`PhoneCalls.Delegate`).

  What it cannot catch: a disclosure in other words (a limit or a fact the
  brief does not share, paraphrased; a number spelled out as words or split
  below seven digits; anything inferred), a run of instructions shorter than
  eight words, and anything the voice model itself says, which reaches the
  person with no Fermix check before it is heard. Content the brief shares or
  the call already heard passes by design.
  """

  alias FermixCore.PhoneCalls.Brief
  alias FermixCore.PhoneCalls.Transcript

  # About 300 tokens of English, and under the vendor's 500-token append limit
  # for a script at two or three bytes a token.
  @max_reply_bytes 1_200
  @shingle_words 8
  @number ~r/\+?\d(?:[\s().\-]?\d){6,}/u
  @iso_date ~r/\A\d{4}-\d{2}-\d{2}\z/
  @email ~r/[\p{L}\p{N}._%+\-]+@[\p{L}\p{N}\-]+(?:\.[\p{L}\p{N}\-]+)+/u
  @protocol_markers ["untrusted_tool_result", "<|", "|>"]

  @type why ::
          :too_long | :protocol_text | :unshared_number | :unshared_email | :instructions_text

  @typedoc """
  What a reply is checked against: the call's `brief`, the turn's own
  `instructions` (its whole system text), the brief as that text renders it
  (`mandate`, `BriefText.block/2`) and the transcript `window` the turn read.
  """
  @type inputs :: %{
          brief: Brief.t(),
          instructions: String.t(),
          mandate: String.t(),
          window: String.t()
        }

  @doc "The byte bound on a reply."
  @spec max_reply_bytes() :: pos_integer()
  def max_reply_bytes, do: @max_reply_bytes

  @doc "`:ok` when `reply` may go to the voice session, else why it is withheld."
  @spec check(String.t(), inputs()) :: :ok | {:withheld, why()}
  def check(reply, %{
        brief: %Brief{} = brief,
        instructions: text,
        mandate: mandate,
        window: window
      })
      when is_binary(reply) and is_binary(text) and is_binary(mandate) and is_binary(window) do
    shared = shared_text(brief, window)

    # In order; the first rule a reply breaks is why it is withheld.
    rules = [
      too_long: fn -> byte_size(reply) > @max_reply_bytes end,
      protocol_text: fn -> protocol_text?(reply) end,
      unshared_number: fn -> unshared?(numbers(reply), numbers(shared)) end,
      unshared_email: fn -> unshared?(emails(reply), emails(shared)) end,
      instructions_text: fn -> instructions_text?(reply, text, mandate <> "\n" <> shared) end
    ]

    case Enum.find(rules, fn {_why, broken?} -> broken?.() end) do
      nil -> :ok
      {why, _broken?} -> {:withheld, why}
    end
  end

  # What the person called may hear: the brief's shareable facts and the call.
  defp shared_text(%Brief{shareable_facts: facts}, window) do
    facts
    |> Enum.map(&(&1.label <> ": " <> &1.value))
    |> Enum.concat([window])
    |> Enum.join("\n")
  end

  defp protocol_text?(reply) do
    lowered = String.downcase(reply)
    Enum.any?(@protocol_markers, &String.contains?(lowered, &1))
  end

  defp numbers(text) do
    @number
    |> Regex.scan(text)
    |> Enum.map(fn [match] -> String.trim(match) end)
    |> Enum.reject(&Regex.match?(@iso_date, &1))
    |> Enum.map(&String.replace(&1, ~r/\D/u, ""))
  end

  defp emails(text) do
    @email |> Regex.scan(text) |> Enum.map(fn [match] -> String.downcase(match) end)
  end

  # Every value in `found` must sit inside a value of `allowed`.
  defp unshared?(found, allowed),
    do: Enum.any?(found, fn value -> not Enum.any?(allowed, &String.contains?(&1, value)) end)

  defp instructions_text?(reply, instructions, allowed) do
    protected = MapSet.difference(shingles(instructions), shingles(allowed))
    not MapSet.disjoint?(shingles(reply), protected)
  end

  defp shingles(text) do
    words = Transcript.words(text)

    words
    |> Enum.chunk_every(@shingle_words, 1, :discard)
    |> MapSet.new(&Enum.join(&1, " "))
  end
end
