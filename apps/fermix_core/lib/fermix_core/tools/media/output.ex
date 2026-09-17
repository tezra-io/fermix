defmodule FermixCore.Tools.Media.Output do
  @moduledoc """
  The single fused-egress seam for generated media: write the artifact bytes
  under the workspace sandbox, then deliver them through the channel `reply_fn`
  when the resolved delivery mode says to.

  This is `send_attachment`'s build-`media_part`-then-deliver factored out so
  "generate and send" is one call. The mode is an explicit input (M46 §6.1), not
  something inferred here: `:save` never delivers, `:send` requires the caller to
  have already proved a reply path exists, and `:default` keeps the
  context-driven behaviour — send when a channel `reply_fn` is present, write the
  file and report it not-delivered otherwise (a subagent, or a scheduled job with
  no media route). That last one is a *different valid configuration*, not a
  Rule #12 fallback.
  """

  alias FermixCore.Reply
  alias FermixCore.Tools.Media.Support

  @type modality :: :image | :audio | :video

  @type delivery :: :save | :send | :default

  @type emit_result :: %{path: String.t(), delivered?: boolean()}

  @typedoc """
  A failure carries the artifact path whenever one was written, so a failed send
  never costs the caller the file it already paid to generate.
  """
  @type emit_error :: %{required(:reason) => String.t(), optional(:path) => String.t()}

  @doc """
  Writes `artifact` under `workspace/media/<modality>-<token>.<ext>` and delivers
  it via `context.reply_fn` when `args.delivery` resolves to a send. Returns the
  absolute path plus whether it reached a channel; `{:error, emit_error()}` if
  the write or the channel delivery failed.
  """
  @spec emit(map(), map(), map()) :: {:ok, emit_result()} | {:error, emit_error()}
  def emit(
        %{bytes: bytes, mime: mime, ext: ext},
        %{modality: modality, delivery: delivery} = args,
        context
      )
      when modality in [:image, :audio, :video] and delivery in [:save, :send, :default] and
             is_binary(bytes) and is_binary(mime) and is_binary(ext) and is_map(context) do
    rel = Path.join("media", "#{modality}-#{Support.token()}.#{ext}")

    case Support.write_bytes(rel, bytes, context) do
      {:ok, abs} -> deliver(abs, mime, modality, args, context)
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  defp deliver(abs, _mime, _modality, %{delivery: :save}, _context),
    do: {:ok, %{path: abs, delivered?: false}}

  defp deliver(abs, mime, modality, %{delivery: :send} = args, context) do
    case Map.get(context, :reply_fn) do
      reply_fn when is_function(reply_fn, 1) ->
        send_media(reply_fn, media_part(abs, mime, modality, args))

      _absent ->
        # An assertion, not a fallback: the caller gates an explicit send before
        # any provider work, so reaching here means that gate was bypassed.
        {:error, %{path: abs, reason: "no channel reply context is available to send the media"}}
    end
  end

  defp deliver(abs, mime, modality, %{delivery: :default} = args, context) do
    case Map.get(context, :reply_fn) do
      reply_fn when is_function(reply_fn, 1) ->
        send_media(reply_fn, media_part(abs, mime, modality, args))

      _absent ->
        {:ok, %{path: abs, delivered?: false}}
    end
  end

  defp send_media(reply_fn, part) do
    case reply_fn.({:media, part}) do
      :ok ->
        {:ok, %{path: part.path, delivered?: true}}

      {:error, reason} ->
        {:error, %{path: part.path, reason: Reply.format_delivery_error(reason)}}

      other ->
        {:error,
         %{path: part.path, reason: "channel returned an invalid reply result: #{inspect(other)}"}}
    end
  end

  defp media_part(abs, mime, modality, args) do
    %{kind: kind_for(modality), path: abs, filename: Path.basename(abs), mime_type: mime}
    |> maybe_put(:caption, Map.get(args, :caption))
  end

  defp kind_for(:image), do: :image
  defp kind_for(:audio), do: :audio
  defp kind_for(:video), do: :video

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
