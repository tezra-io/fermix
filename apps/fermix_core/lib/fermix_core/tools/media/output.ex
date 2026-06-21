defmodule FermixCore.Tools.Media.Output do
  @moduledoc """
  The single fused-egress seam for generated media: write the artifact bytes
  under the workspace sandbox, then deliver them through the channel `reply_fn`.

  This is `send_attachment`'s build-`media_part`-then-deliver factored out so
  "generate and send" is one call. When the run has no channel `reply_fn` (a
  subagent or scheduled job — §8.3), `emit/3` writes the file and reports it as
  not-delivered; that is a *different valid configuration* (file-only vs
  channel-delivered), not a Rule #12 fallback.
  """

  alias FermixCore.Reply
  alias FermixCore.Tools.Media.Support

  @type modality :: :image | :audio | :video

  @type emit_result :: %{path: String.t(), delivered?: boolean()}

  @doc """
  Writes `artifact` under `workspace/media/<modality>-<token>.<ext>` and delivers
  it via `context.reply_fn` when present. Returns the absolute path plus whether
  it reached a channel; `{:error, reason}` if the write or the channel delivery
  failed.
  """
  @spec emit(map(), map(), map()) :: {:ok, emit_result()} | {:error, String.t()}
  def emit(%{bytes: bytes, mime: mime, ext: ext}, %{modality: modality} = args, context)
      when modality in [:image, :audio, :video] and is_binary(bytes) and is_binary(mime) and
             is_binary(ext) and is_map(context) do
    rel = Path.join("media", "#{modality}-#{Support.token()}.#{ext}")

    with {:ok, abs} <- Support.write_bytes(rel, bytes, context) do
      deliver(abs, mime, modality, args, context)
    end
  end

  defp deliver(abs, mime, modality, args, context) do
    case Map.get(context, :reply_fn) do
      reply_fn when is_function(reply_fn, 1) ->
        send_media(reply_fn, media_part(abs, mime, modality, args))

      _absent ->
        {:ok, %{path: abs, delivered?: false}}
    end
  end

  defp send_media(reply_fn, part) do
    case reply_fn.({:media, part}) do
      :ok -> {:ok, %{path: part.path, delivered?: true}}
      {:error, reason} -> {:error, Reply.format_delivery_error(reason)}
      other -> {:error, "channel returned an invalid reply result: #{inspect(other)}"}
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
