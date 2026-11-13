defmodule FermixChannels.Mobile.WebPush.Payload do
  @moduledoc """
  The plaintext of one Web Push to a phone. Pure.

  Compact JSON with its keys always in this order:

      {"v":1,"kind":"message","profile_id":"main","server_seq":42,"preview_text":"…"}

  `kind` is `message` (a row Fermix wrote into the phone's chat) or `approval`
  (one is waiting). `server_seq` and `preview_text` are JSON `null` when absent,
  and an approval carries neither: one that arrives with either is refused, so
  an approval's text can never reach Google, sealed or not.

  The result always fits one Web Push record: at most 2,047 bytes, one less
  than `Encryption.padded_size/0` for the delimiter. When the JSON would be
  longer, `preview_text` is cut at a grapheme boundary and ends with "…". The
  cut is measured on the JSON as written, escapes included, and walks the text
  only as far as the room left for it.
  """

  alias FermixChannels.Mobile.WebPush.Encryption

  @version 1
  @max_bytes Encryption.padded_size() - 1
  @ellipsis "…"
  @max_profile_id_bytes 128
  # The phone protocol's row numbers are unsigned 64-bit (priv/mobile/protocol.schema.json).
  @max_server_seq 18_446_744_073_709_551_615
  @fields [:kind, :profile_id, :server_seq, :preview_text]
  @kinds [:message, :approval]

  @type fields :: %{
          kind: :message | :approval,
          profile_id: String.t(),
          server_seq: pos_integer() | nil,
          preview_text: String.t() | nil
        }

  @type error ::
          {:invalid_field, :kind | :profile_id | :server_seq | :preview_text}
          | {:unknown_fields, [term()]}
          | :approval_with_content

  @doc "The JSON plaintext for `fields`, cut to fit one record."
  @spec encode(fields()) :: {:ok, binary()} | {:error, error()}
  def encode(
        %{kind: _kind, profile_id: _profile_id, server_seq: _seq, preview_text: _text} = fields
      ) do
    with :ok <- known_fields(fields),
         :ok <- valid_kind(fields.kind),
         :ok <- valid_profile_id(fields.profile_id),
         :ok <- valid_server_seq(fields.server_seq),
         :ok <- valid_preview(fields.preview_text),
         :ok <- approval_without_content(fields) do
      fit(fields)
    end
  end

  defp known_fields(fields) do
    case Map.keys(fields) -- @fields do
      [] -> :ok
      unknown -> {:error, {:unknown_fields, Enum.sort(unknown)}}
    end
  end

  defp valid_kind(kind) when kind in @kinds, do: :ok
  defp valid_kind(_kind), do: {:error, {:invalid_field, :kind}}

  defp valid_profile_id(id)
       when is_binary(id) and byte_size(id) in 1..@max_profile_id_bytes do
    if String.valid?(id), do: :ok, else: {:error, {:invalid_field, :profile_id}}
  end

  defp valid_profile_id(_id), do: {:error, {:invalid_field, :profile_id}}

  defp valid_server_seq(nil), do: :ok

  defp valid_server_seq(seq) when is_integer(seq) and seq >= 1 and seq <= @max_server_seq,
    do: :ok

  defp valid_server_seq(_seq), do: {:error, {:invalid_field, :server_seq}}

  defp valid_preview(nil), do: :ok

  defp valid_preview(text) when is_binary(text) do
    if String.valid?(text), do: :ok, else: {:error, {:invalid_field, :preview_text}}
  end

  defp valid_preview(_text), do: {:error, {:invalid_field, :preview_text}}

  defp approval_without_content(%{kind: :approval, server_seq: nil, preview_text: nil}), do: :ok
  defp approval_without_content(%{kind: :approval}), do: {:error, :approval_with_content}
  defp approval_without_content(%{kind: :message}), do: :ok

  defp fit(fields) do
    json = json(fields, fields.preview_text)

    if byte_size(json) <= @max_bytes,
      do: {:ok, json},
      else: {:ok, cut(fields)}
  end

  # The room the preview has is what is left once the JSON holds an empty one
  # and the ellipsis; the kept prefix is measured escaped, as written.
  defp cut(fields) do
    room = @max_bytes - byte_size(json(fields, "")) - escaped_size(@ellipsis)
    kept = prefix_within(fields.preview_text, room)
    json = json(fields, kept <> @ellipsis)
    true = byte_size(json) <= @max_bytes
    json
  end

  # Each step keeps one grapheme, and every grapheme takes at least one byte of
  # room, so the walk ends within `room` steps however long the text is.
  defp prefix_within(text, room), do: prefix_within(text, room, [])

  defp prefix_within(text, room, kept) do
    with {grapheme, rest} <- String.next_grapheme(text),
         size when size <= room <- escaped_size(grapheme) do
      prefix_within(rest, room - size, [kept, grapheme])
    else
      _end_or_no_room -> IO.iodata_to_binary(kept)
    end
  end

  defp escaped_size(text), do: byte_size(Jason.encode!(text)) - 2

  defp json(fields, preview_text) do
    Jason.encode!(
      Jason.OrderedObject.new([
        {"v", @version},
        {"kind", Atom.to_string(fields.kind)},
        {"profile_id", fields.profile_id},
        {"server_seq", fields.server_seq},
        {"preview_text", preview_text}
      ])
    )
  end
end
