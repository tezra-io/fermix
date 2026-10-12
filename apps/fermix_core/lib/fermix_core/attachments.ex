defmodule FermixCore.Attachments do
  @moduledoc """
  An inbound attachment as the turn receives it (M67).

  A channel declares what the platform gave it (`t:declared/0`): its own ids and
  fields, nothing guessed. The gateway pipeline
  (`FermixChannels.Gateway.Attachments`) downloads it, names its kind from the
  bytes (`FermixCore.Attachments.Kind`), applies the caps and renders it into
  this struct. The turn then turns each one into a manifest line in the user
  text (`FermixCore.Attachments.Manifest`, persisted) and, for what a model can
  take inline, a neutral content part (`parts/1`, turn-local, never persisted).

  `status` says how the attachment reached the model:

    * `:ready` — its bytes ride the turn: a picture, a PDF, the still of a GIF or
      video (`poster`), or a text file inlined under the manifest;
    * `:transcribed` — its sound became the transcript composed into the text
      (a voice note, a Telegram video note);
    * `{:unusable, reason}` — nothing of it reached the model, and the manifest
      or the gateway's reply names it with the one sentence its reason has.

  Bytes are turn-local and never reach a log or a trace: `inspect/1` shows only
  the fields that describe the attachment.
  """

  @type kind :: :still | :animation | :video | :audio | :document | :text | :unknown

  @typedoc "The platform's own object type, the classifier's last resort."
  @type hint ::
          :photo
          | :voice
          | :audio
          | :video_note
          | :animation
          | :video
          | :sticker
          | :document

  @typedoc """
  What a channel declares for one attachment: the platform's own fields, no I/O
  and no guess. `file_id` or `url` (or `data`, for the CLI) is what the
  channel's `download_attachment/2` fetches; `poster` is a still the platform or
  the phone made for a GIF or video, declared the same way.
  """
  @type declared :: %{
          optional(:file_id) => term(),
          optional(:url) => String.t() | nil,
          optional(:data) => binary(),
          optional(:mime_type) => String.t() | nil,
          optional(:size_bytes) => non_neg_integer() | nil,
          optional(:file_name) => String.t() | nil,
          optional(:hint) => hint() | nil,
          optional(:poster) => map() | nil,
          optional(:duration_s) => non_neg_integer() | nil
        }

  @typedoc "Why nothing of an attachment reached the model; each has one sentence."
  @type unusable ::
          {:too_large, pos_integer(), pos_integer()}
          | {:too_many, pos_integer()}
          | {:turn_full, pos_integer()}
          | {:needs_ffmpeg, :animation | :video}
          | {:no_still, String.t()}
          | {:poster_unavailable, :animation | :video, term()}
          | {:still_unsupported, String.t()}
          | {:unknown_type, String.t()}
          | {:not_as_declared, String.t()}
          | {:download_failed, term()}
          | {:channel_cannot_fetch, String.t()}

  @type status :: :ready | :transcribed | {:unusable, unusable()}

  @type still :: %{mime_type: String.t(), bytes: binary()}

  @type t :: %__MODULE__{
          kind: kind(),
          mime_type: String.t(),
          name: String.t() | nil,
          size_bytes: non_neg_integer() | nil,
          duration_s: non_neg_integer() | nil,
          hint: hint() | nil,
          bytes: binary() | nil,
          poster: still() | nil,
          status: status()
        }

  @derive {Inspect, only: [:kind, :mime_type, :name, :size_bytes, :status]}
  @enforce_keys [:kind, :mime_type]
  defstruct [
    :kind,
    :mime_type,
    :name,
    :size_bytes,
    :duration_s,
    :hint,
    bytes: nil,
    poster: nil,
    status: :ready
  ]

  # The text one message inlines under its manifest, all its text files
  # together: about 8k tokens, persisted with the turn and replayed with it.
  @max_text_inline_bytes 32 * 1024

  @doc "How many bytes of text files one message inlines, all of them together."
  @spec max_text_inline_bytes() :: pos_integer()
  def max_text_inline_bytes, do: @max_text_inline_bytes

  @doc """
  The neutral content parts a turn's attachments put on the user message, in
  attachment order: a picture as `:image`, a GIF or video by its still as
  `:image`, a PDF as `:document`. A text file rides the manifest instead and a
  transcript the text, so neither has a part; nothing unusable has one.
  """
  @spec parts([t()]) :: [FermixCore.Providers.Adapter.content_part()]
  def parts(attachments) when is_list(attachments) do
    Enum.flat_map(attachments, &part/1)
  end

  defp part(%__MODULE__{status: :ready, kind: :still} = att),
    do: [%{type: :image, mime_type: att.mime_type, data: att.bytes}]

  defp part(%__MODULE__{status: :ready, kind: kind, poster: %{} = still})
       when kind in [:animation, :video],
       do: [%{type: :image, mime_type: still.mime_type, data: still.bytes}]

  defp part(%__MODULE__{status: :ready, kind: :document} = att),
    do: [%{type: :document, mime_type: att.mime_type, data: att.bytes, name: document_name(att)}]

  defp part(%__MODULE__{}), do: []

  defp document_name(%__MODULE__{name: name}) when is_binary(name) and name != "", do: name
  defp document_name(%__MODULE__{}), do: "document.pdf"
end
