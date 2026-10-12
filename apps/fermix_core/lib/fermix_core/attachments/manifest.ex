defmodule FermixCore.Attachments.Manifest do
  @moduledoc """
  The words for a turn's attachments (M67): the `[attachments]` manifest the
  turn composes into the user text, and the reply the gateway sends when
  nothing in a message is usable (D4).

  The manifest is persisted as part of the user message, so history and
  compaction know what was attached and what could not be read. It lists each
  attachment's name, kind and size and what reached the model, or why nothing
  did. Text files are inlined under it, all of them together cut at
  `FermixCore.Attachments.max_text_inline_bytes/0`, on a character boundary. A
  voice note is not listed: its transcript already stands in the text (M21), so
  a voice-note turn reads as it always has. A turn with no attachments is left
  byte-identical.

  Every unusable reason has exactly one sentence, shared by both: a reason
  without a clause here does not match, and fails loud.
  """

  alias FermixCore.Attachments

  @mib 1024 * 1024

  @type opt :: {:os, :macos | :linux | :other}

  @doc """
  `content` with the manifest of `attachments` under it. Text-only (`[]`) and
  voice-note-only turns come back unchanged. `os:` picks the ffmpeg install
  hint; it defaults to the machine's own.
  """
  @spec compose(String.t(), [Attachments.t()], [opt()]) :: String.t()
  def compose(content, attachments, opts \\ [])
      when is_binary(content) and is_list(attachments) and is_list(opts) do
    case Enum.reject(attachments, &(&1.status == :transcribed)) do
      [] ->
        content

      listed ->
        texts = inline_texts(listed)
        join([content, manifest(listed, texts, opts) | text_blocks(listed, texts)])
    end
  end

  @doc """
  The gateway's reply when a message carried attachments and none of them is
  usable (D4): one sentence per attachment, each naming it and its reason. No
  turn runs, so it never says the message looks empty.
  """
  @spec unusable_reply([Attachments.t(), ...], [opt()]) :: String.t()
  def unusable_reply([_ | _] = attachments, opts \\ []) when is_list(opts) do
    lines = Enum.map(attachments, &"#{label(&1)}: #{reason_of(&1, opts)}.")

    case lines do
      [line] -> "I couldn't read #{line}"
      lines -> Enum.join(["I couldn't read anything you attached:" | lines], "\n- ")
    end
  end

  defp manifest(attachments, texts, opts) do
    {lines, _counters} =
      attachments
      |> Enum.zip(texts)
      |> Enum.with_index(1)
      |> Enum.map_reduce(%{image: 0, document: 0}, &line(&1, &2, opts))

    Enum.join(["[attachments]" | lines], "\n")
  end

  defp line({{%Attachments{} = att, text}, index}, counters, opts) do
    {outcome, counters} = outcome(att, text, counters, opts)
    facts = [name(att), kind_label(att), duration(att), size(att.size_bytes), outcome]
    {"#{index}. " <> (facts |> Enum.reject(&is_nil/1) |> Enum.join(" · ")), counters}
  end

  defp outcome(%Attachments{status: {:unusable, reason}}, _text, counters, opts),
    do: {"not readable: " <> reason(reason, opts), counters}

  defp outcome(%Attachments{kind: :still}, _text, counters, _opts),
    do: numbered(counters, :image, &"attached as image #{&1}")

  defp outcome(%Attachments{kind: kind}, _text, counters, _opts)
       when kind in [:animation, :video],
       do: numbered(counters, :image, &"one still frame of it attached as image #{&1}")

  defp outcome(%Attachments{kind: :document}, _text, counters, _opts),
    do: numbered(counters, :document, &"attached as document #{&1}")

  defp outcome(%Attachments{kind: :text} = att, text, counters, _opts),
    do: {text_outcome(att.bytes, text), counters}

  defp numbered(counters, part, sentence) do
    number = Map.fetch!(counters, part) + 1
    {sentence.(number), Map.put(counters, part, number)}
  end

  defp text_outcome(bytes, bytes), do: "inlined below"

  defp text_outcome(_bytes, ""),
    do:
      "not inlined: the text files before it already fill the " <>
        "#{div(Attachments.max_text_inline_bytes(), 1024)} KB one message inlines; " <>
        "send it in its own message"

  defp text_outcome(_bytes, text),
    do: "the first #{size(byte_size(text))} inlined below; the rest is cut"

  # One budget for every text file of the message, spent in attachment order.
  defp inline_texts(attachments) do
    {texts, _left} =
      Enum.map_reduce(attachments, Attachments.max_text_inline_bytes(), &inline_text/2)

    texts
  end

  defp inline_text(%Attachments{kind: :text, status: :ready, bytes: bytes}, left) do
    text = cut_text(bytes, left)
    {text, left - byte_size(text)}
  end

  defp inline_text(%Attachments{}, left), do: {nil, left}

  defp text_blocks(attachments, texts) do
    for {%Attachments{} = att, text} <- Enum.zip(attachments, texts), text not in [nil, ""] do
      "[#{name(att) || "text file"}]\n" <> text
    end
  end

  # Cut on a character boundary, so the inlined text stays valid UTF-8; `Kind`
  # admitted the file as text only if these bytes are UTF-8.
  defp cut_text(bytes, limit) when byte_size(bytes) <= limit, do: bytes

  defp cut_text(bytes, limit) do
    case :unicode.characters_to_binary(binary_part(bytes, 0, limit), :utf8, :utf8) do
      text when is_binary(text) -> text
      {:incomplete, text, _tail} -> text
    end
  end

  defp join(parts), do: parts |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")

  defp label(%Attachments{} = att), do: name(att) || "the #{kind_label(att)} you sent"

  # A sender's file name, on one line and bounded, so it cannot break the list.
  defp name(%Attachments{name: name}) when is_binary(name) do
    case name
         |> String.replace(~r/[[:cntrl:]]+/u, " ")
         |> String.trim()
         |> String.slice(0, 120) do
      "" -> nil
      line -> line
    end
  end

  defp name(%Attachments{}), do: nil

  defp kind_label(%Attachments{kind: :still}), do: "image"
  defp kind_label(%Attachments{kind: :document}), do: "PDF"
  defp kind_label(%Attachments{kind: :unknown}), do: "file"
  defp kind_label(%Attachments{kind: kind}), do: Atom.to_string(kind)

  defp duration(%Attachments{duration_s: seconds}) when is_integer(seconds) and seconds > 0,
    do: "#{seconds} s"

  defp duration(%Attachments{}), do: nil

  defp size(bytes) when is_integer(bytes) and bytes >= @mib, do: "#{mb(bytes)} MB"
  defp size(bytes) when is_integer(bytes) and bytes >= 1024, do: "#{div(bytes, 1024)} KB"
  defp size(bytes) when is_integer(bytes), do: "#{bytes} bytes"
  defp size(_unknown), do: nil

  defp mb(bytes), do: Float.round(bytes / @mib, 1)

  defp reason_of(%Attachments{status: {:unusable, reason}}, opts), do: reason(reason, opts)

  defp reason({:too_large, bytes, cap}, _opts),
    do: "it is #{mb(bytes)} MB, over the #{div(cap, @mib)} MB limit"

  defp reason({:too_many, max}, _opts),
    do: "only the first #{max} attachments of a message are read; send it in its own message"

  defp reason({:turn_full, cap}, _opts),
    do:
      "it would take what one message carries past #{div(cap, @mib)} MB; send it in its " <>
        "own message"

  defp reason({:no_still, mime}, _opts),
    do: "it is an animated picture (#{mime}) with no still to read; send a screenshot of it"

  defp reason({:poster_unavailable, kind, _why}, _opts),
    do:
      "it is #{article(kind)} #{kind}, and the still the channel made of it could not be " <>
        "fetched or read; send a screenshot of it"

  defp reason({:not_as_declared, mime}, _opts),
    do:
      "the channel called it #{mime}, but what arrived is not one (a channel without " <>
        "access to the file sends a web page instead)"

  defp reason({:channel_cannot_fetch, channel}, _opts),
    do: "the #{channel} channel gives Fermix no way to fetch attachments"

  defp reason({:needs_ffmpeg, kind}, opts),
    do:
      "it is #{article(kind)} #{kind} with no still to read; reading its frames takes " <>
        "ffmpeg (#{install_hint(os(opts))}), or send a screenshot of it"

  defp reason({:still_unsupported, mime}, _opts),
    do: "it is a #{mime} picture, which the models do not take; send it as a JPEG or PNG"

  defp reason({:unknown_type, mime}, _opts),
    do:
      "Fermix can't read this type of file (#{mime}); send it as a PDF, a picture or " <>
        "plain text"

  defp reason({:download_failed, _why}, _opts),
    do: "the download from the channel failed; send it again"

  defp article(:animation), do: "an"
  defp article(:video), do: "a"

  defp install_hint(:macos), do: "install it with brew install ffmpeg"

  defp install_hint(:linux),
    do: "install the ffmpeg package (for example sudo apt install ffmpeg)"

  defp install_hint(:other), do: "install ffmpeg"

  defp os(opts), do: Keyword.get_lazy(opts, :os, &host_os/0)

  # The one place the install hint learns the machine it runs on.
  defp host_os do
    case :os.type() do
      {:unix, :darwin} -> :macos
      {:unix, :linux} -> :linux
      _other -> :other
    end
  end
end
