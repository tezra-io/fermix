defmodule FermixCore.Attachments.Kind do
  @moduledoc """
  Names an attachment's kind and mime (M67): from its bytes first, the mime the
  platform declared second, the platform's own object type (`hint`) last.

  A platform's mime can lie (a Telegram photo is always called JPEG) and a CLI
  file declares none, so a signature in the leading bytes wins. Without one the
  declared mime decides; without a telling mime, text is recognised as UTF-8
  with no NUL; the hint names what is left. What none of them names is
  `:unknown`, under its declared mime.

  The platform's word refines what the bytes cannot tell apart: Telegram sends
  a GIF as a silent MP4 (`animation`), whose container reads as a video, so a
  video the platform calls an animation is an animation; and an MP4 or 3GP
  container the platform calls audio (a phone's voice recording) is audio.

  A declared picture or PDF format that has a signature (PNG, JPEG, GIF, WebP,
  PDF) is believed only with it: without the signature the file is `:unknown`
  under that mime (`signed?/1`), because what arrived is not what was declared
  (a channel without file access answers with a web page).

  A file is `:text` only when every byte the manifest inlines
  (`Attachments.max_text_inline_bytes/0`) is UTF-8 with no NUL, so no turn ever
  carries bytes its JSON wire cannot encode.
  """

  alias FermixCore.Attachments
  alias FermixCore.Attachments.GifFrame

  @octet_stream "application/octet-stream"
  @text_mimes ~w(application/json application/xml application/yaml application/x-yaml
                 application/toml application/x-toml application/x-ndjson)
  @heic_brands ~w(heic heix heim heis hevc hevx mif1 msf1)
  @signed_mimes ~w(image/png image/jpeg image/jpg image/gif image/webp application/pdf)

  @doc """
  The kind and mime of downloaded `bytes`, declared as `declared` (its
  `:mime_type` and `:hint` are read). The mime is never nil:
  `application/octet-stream` names a file nothing identified.
  """
  @spec classify(map(), binary()) :: {Attachments.kind(), String.t()}
  def classify(declared, bytes) when is_map(declared) and is_binary(bytes) do
    mime = declared_mime(declared)
    hint = Map.get(declared, :hint)

    bytes
    |> signature(mime, hint)
    |> or_else(fn -> by_mime(mime, bytes) end)
    |> or_else(fn -> by_text(bytes) end)
    |> or_else(fn -> by_hint(hint, mime) end)
    |> or_else(fn -> {:unknown, mime || @octet_stream} end)
    |> refine(hint)
  end

  @doc """
  The kind and mime of an attachment no byte of which arrived, from its
  declared mime and hint alone, so a reply can still name what it was.
  """
  @spec declared(map()) :: {Attachments.kind(), String.t()}
  def declared(declared) when is_map(declared) do
    mime = declared_mime(declared)
    hint = Map.get(declared, :hint)

    mime
    |> by_declared_mime()
    |> or_else(fn -> by_hint(hint, mime) end)
    |> or_else(fn -> {:unknown, mime || @octet_stream} end)
    |> refine(hint)
  end

  @doc "Whether `mime` names a format Fermix knows by its signature."
  @spec signed?(String.t()) :: boolean()
  def signed?(mime) when is_binary(mime), do: mime in @signed_mimes

  defp or_else(nil, next), do: next.()
  defp or_else(found, _next), do: found

  defp refine({:video, mime}, :animation), do: {:animation, mime}
  defp refine(kind_and_mime, _hint), do: kind_and_mime

  # --- Signatures in the leading bytes ---

  defp signature(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>>, _mime, _hint),
    do: {:still, "image/png"}

  defp signature(<<0xFF, 0xD8, 0xFF, _rest::binary>>, _mime, _hint), do: {:still, "image/jpeg"}

  defp signature(<<"GIF8", version, "a", _rest::binary>> = bytes, _mime, _hint)
       when version in [?7, ?9] do
    if GifFrame.animated?(bytes), do: {:animation, "image/gif"}, else: {:still, "image/gif"}
  end

  defp signature(<<"RIFF", _size::binary-size(4), "WEBP", chunk::binary>>, _mime, _hint),
    do: webp(chunk)

  defp signature(<<"RIFF", _size::binary-size(4), "WAVE", _rest::binary>>, _mime, _hint),
    do: {:audio, "audio/wav"}

  # ISO media (MP4, M4A, 3GP, HEIC) and Matroska (WebM) carry sound or pictures
  # alike; a container the platform calls audio is audio.
  defp signature(
         <<_size::binary-size(4), "ftyp", brand::binary-size(4), _rest::binary>>,
         mime,
         hint
       ),
       do: brand |> iso_media() |> sound_if_declared(mime, hint)

  defp signature(<<0x1A, 0x45, 0xDF, 0xA3, _rest::binary>>, mime, hint),
    do: sound_if_declared({:video, "video/webm"}, mime, hint)

  defp signature(<<"%PDF-", _rest::binary>>, _mime, _hint), do: {:document, "application/pdf"}
  defp signature(<<"OggS", _rest::binary>>, _mime, _hint), do: {:audio, "audio/ogg"}
  defp signature(<<"ID3", _rest::binary>>, _mime, _hint), do: {:audio, "audio/mpeg"}
  defp signature(<<"fLaC", _rest::binary>>, _mime, _hint), do: {:audio, "audio/flac"}
  defp signature(<<"#!AMR", _rest::binary>>, _mime, _hint), do: {:audio, "audio/amr"}
  defp signature(_bytes, _mime, _hint), do: nil

  defp sound_if_declared({:video, _container}, "audio/" <> _ = mime, _hint), do: {:audio, mime}

  defp sound_if_declared({:video, "video/webm"}, _mime, hint) when hint in [:voice, :audio],
    do: {:audio, "audio/webm"}

  defp sound_if_declared({:video, _container}, _mime, hint) when hint in [:voice, :audio],
    do: {:audio, "audio/mp4"}

  defp sound_if_declared(kind_and_mime, _mime, _hint), do: kind_and_mime

  # An extended (VP8X) WebP sets bit 1 of its flags when it is animated.
  defp webp(<<"VP8X", _size::binary-size(4), flags, _rest::binary>>)
       when Bitwise.band(flags, 0x02) != 0,
       do: {:animation, "image/webp"}

  defp webp(_chunk), do: {:still, "image/webp"}

  defp iso_media(brand) when brand in @heic_brands, do: {:still, "image/heic"}
  defp iso_media(brand) when brand in ["avif", "avis"], do: {:still, "image/avif"}
  defp iso_media(brand) when brand in ["M4A ", "M4B "], do: {:audio, "audio/mp4"}
  defp iso_media("qt  "), do: {:video, "video/quicktime"}
  defp iso_media("3g" <> _rest), do: {:video, "video/3gpp"}
  defp iso_media(_brand), do: {:video, "video/mp4"}

  # --- The declared mime ---

  defp declared_mime(declared) do
    case Map.get(declared, :mime_type) do
      mime when is_binary(mime) -> essence(mime)
      _none -> nil
    end
  end

  # `text/plain; charset=utf-8` is `text/plain`; an octet stream tells nothing.
  defp essence(mime) do
    case mime |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase() do
      "" -> nil
      @octet_stream -> nil
      "binary/octet-stream" -> nil
      essence -> essence
    end
  end

  # A signed format that reached here has no signature: not what was declared.
  defp by_mime(nil, _bytes), do: nil
  defp by_mime(mime, _bytes) when mime in @signed_mimes, do: {:unknown, mime}
  defp by_mime("text/" <> _ = mime, bytes), do: text_if_text(mime, bytes)
  defp by_mime(mime, bytes) when mime in @text_mimes, do: text_if_text(mime, bytes)
  defp by_mime(mime, _bytes), do: by_declared_mime(mime)

  defp by_declared_mime(nil), do: nil
  defp by_declared_mime("image/" <> _ = mime), do: {:still, mime}
  defp by_declared_mime("video/" <> _ = mime), do: {:video, mime}
  defp by_declared_mime("audio/" <> _ = mime), do: {:audio, mime}
  defp by_declared_mime("application/pdf"), do: {:document, "application/pdf"}
  defp by_declared_mime("text/" <> _ = mime), do: {:text, mime}
  defp by_declared_mime(mime) when mime in @text_mimes, do: {:text, mime}
  defp by_declared_mime(_mime), do: nil

  defp text_if_text(mime, bytes), do: if(text?(bytes), do: {:text, mime})

  # --- Text and the hint ---

  defp by_text(bytes), do: if(text?(bytes), do: {:text, "text/plain"})

  # Every byte the manifest can inline must be UTF-8 with no NUL. A file longer
  # than that may cut a character in two at the limit; one that ends inside it
  # must be whole.
  defp text?(""), do: false

  defp text?(bytes) do
    limit = Attachments.max_text_inline_bytes()
    probe = binary_part(bytes, 0, min(byte_size(bytes), limit))
    not String.contains?(probe, <<0>>) and utf8?(probe, byte_size(bytes) > limit)
  end

  defp utf8?(probe, cut?) do
    case :unicode.characters_to_binary(probe, :utf8, :utf8) do
      text when is_binary(text) -> true
      {:incomplete, _text, _tail} -> cut?
      {:error, _text, _rest} -> false
    end
  end

  defp by_hint(:photo, mime), do: {:still, mime || "image/jpeg"}
  defp by_hint(:sticker, mime), do: {:animation, mime || @octet_stream}
  defp by_hint(:animation, mime), do: {:animation, mime || "video/mp4"}
  defp by_hint(hint, mime) when hint in [:video, :video_note], do: {:video, mime || "video/mp4"}
  defp by_hint(hint, mime) when hint in [:voice, :audio], do: {:audio, mime || @octet_stream}
  defp by_hint(_hint, _mime), do: nil
end
