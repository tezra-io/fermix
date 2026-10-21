defmodule FermixChannels.LinkPreviews do
  @moduledoc """
  A timeline row's link previews: once a row is durable, the pages its links
  name are read, each preview is stored on the row, and then announced, the
  phones hearing the card (`link_preview`) and the Mac that the row changed
  (`row_updated`), each wire only its own event.

  The links are the caller's, read by `FermixCore.ReplyBlocks.links/2`: a
  reply's, less the ones its blocks draw (M72), or a phone user's own
  message's. Every row of the one timeline is previewed the same way, whether
  or not a phone is paired: the bounded task supervisor resolutions run under
  starts with the channels application, a launch past its bound is refused
  and logged, never queued, and one resolution has one deadline. A preview's
  picture is a blob in `FermixChannels.Mobile.MediaStore`, the timeline's
  media store, served by `media_fetch` only through the preview on its row.

  An injected `:resolver` is called as `resolver.(links, store_thumbnail)`,
  the shape `FermixChannels.Mobile.Unfurl.resolve/2` receives.
  """

  require Logger

  alias FermixChannels.Companion.Fanout
  alias FermixChannels.Companion.Output
  alias FermixChannels.Mobile.MediaStore
  alias FermixChannels.Mobile.Unfurl
  alias FermixCore.Companion.Timeline
  alias FermixCore.Text

  # One resolution fetches up to four pages, their redirects and thumbnails,
  # each read chunk by chunk: the whole of it has one deadline, and only so
  # many run at once (SEC-11).
  @deadline_ms 20_000
  @max_concurrent 4
  @supervisor FermixChannels.LinkPreviews.Supervisor
  # A link preview card's bounds, in bytes (D7).
  @max_url_bytes 2_048
  @max_site_bytes 120
  @max_title_bytes 300
  @max_description_bytes 600

  @doc """
  Resolve the previews of `links` for the row at `server_seq` asynchronously,
  store each on the row, then announce it. A row that names no link asks for
  nothing.
  """
  @spec schedule(String.t(), pos_integer(), [String.t()], keyword()) :: :ok
  def schedule(profile_id, server_seq, links, opts \\ [])

  def schedule(_profile_id, _server_seq, [], _opts), do: :ok

  def schedule(profile_id, server_seq, links, opts)
      when is_binary(profile_id) and is_integer(server_seq) and server_seq > 0 and
             is_list(links) and is_list(opts) do
    launch(fn -> resolve(profile_id, server_seq, links, opts) end, opts)
  end

  @doc "How many link-preview resolutions run at once."
  @spec max_concurrent() :: pos_integer()
  def max_concurrent, do: @max_concurrent

  @doc """
  The bounded task supervisor link previews resolve under, which the channels
  application starts: past `max_children` a launch is refused.
  """
  @spec supervisor_spec(atom(), pos_integer()) :: Supervisor.child_spec()
  def supervisor_spec(name \\ @supervisor, max_children \\ @max_concurrent)
      when is_atom(name) and is_integer(max_children) and max_children > 0 do
    Supervisor.child_spec({Task.Supervisor, name: name, max_children: max_children}, id: name)
  end

  defp launch(task, opts) do
    supervisor = Keyword.get(opts, :supervisor, @supervisor)

    launcher =
      Keyword.get(opts, :launcher) ||
        Application.get_env(:fermix_channels, :link_preview_launcher) ||
        (&default_launcher(&1, supervisor))

    case launcher.(task) do
      :ok -> :ok
      {:ok, _pid} -> :ok
      {:error, reason} -> log_error(:launch_failed, reason)
      other -> log_error(:invalid_launcher_result, other)
    end
  end

  # Past the bound a launch is refused (`:max_children`), never queued; a
  # tree that never started the supervisor (a test's) previews nothing.
  defp default_launcher(task, supervisor) do
    case GenServer.whereis(supervisor) do
      nil -> {:error, {:link_preview_supervisor_not_running, supervisor}}
      pid -> Task.Supervisor.start_child(pid, task)
    end
  end

  defp resolve(profile_id, server_seq, links, opts) do
    deadline_ms = Keyword.get(opts, :deadline_ms, @deadline_ms)

    links
    |> resolution(opts)
    |> within_deadline(deadline_ms)
    |> handle_result(profile_id, server_seq, opts)
  end

  # Both seams are looked up here, in the calling process, so a mis-shaped
  # injection raises where it was made.
  defp resolution(links, opts) do
    store_thumbnail = thumbnail_writer(opts)

    case resolver(opts) do
      nil -> fn -> Unfurl.resolve(links, store_thumbnail: store_thumbnail) end
      resolver -> fn -> resolver.(links, store_thumbnail) end
    end
  end

  # A resolution past its deadline is killed along with the fetch it holds.
  defp within_deadline(resolution, deadline_ms) do
    task = Task.async(resolution)

    case Task.yield(task, deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:resolution_exit, reason}}
      nil -> {:error, {:resolution_deadline, deadline_ms}}
    end
  end

  defp resolver(opts) do
    override =
      Keyword.get(opts, :resolver) ||
        Application.get_env(:fermix_channels, :link_preview_resolver)

    injected(override, 2, :link_preview_resolver)
  end

  defp handle_result({:ok, previews, warnings}, profile_id, server_seq, opts)
       when is_list(previews) and is_list(warnings) do
    Enum.each(previews, &publish(profile_id, server_seq, &1, opts))
    Enum.each(warnings, &log_error(:resolution_warning, &1))
    :ok
  end

  defp handle_result({:error, reason}, _profile_id, _server_seq, _opts),
    do: log_error(:resolution_failed, reason)

  defp handle_result(other, _profile_id, _server_seq, _opts),
    do: log_error(:invalid_resolver_result, other)

  # The card is stored on its row before anyone hears of it: history rebuilds
  # it from there, and `media_fetch` serves its image only through it.
  defp publish(profile_id, server_seq, preview, opts) do
    with {:ok, card} <- card(preview),
         {:ok, _row} <- attach(profile_id, server_seq, card, opts),
         :ok <- emit(profile_id, phone_event(server_seq, card), opts),
         :ok <- emit(profile_id, Output.row_updated(profile_id, server_seq), opts) do
      :ok
    else
      {:error, reason} -> log_error(:preview_failed, reason)
    end
  end

  # Text is cut to its bound on a UTF-8 boundary; an address cannot be cut
  # into a working link, so one past its bound is no preview at all. `link`
  # is the address the row wrote, which a client pairs the card with; `url`
  # is where its page answered from.
  defp card(preview) do
    with {:ok, link} <- address(value(preview, :link)),
         {:ok, url} <- address(value(preview, :url)) do
      {:ok,
       %{
         "link" => link,
         "url" => url,
         "site" => bounded_text(value(preview, :site), @max_site_bytes),
         "title" => bounded_text(value(preview, :title), @max_title_bytes)
       }
       |> maybe_put(
         "description",
         bounded_text(value(preview, :description), @max_description_bytes)
       )
       |> maybe_put("image", image(value(preview, :image)))}
    end
  end

  defp address(url) when is_binary(url) and byte_size(url) <= @max_url_bytes, do: {:ok, url}

  defp address(url) when is_binary(url),
    do: {:error, {:link_preview_url_too_long, byte_size(url), @max_url_bytes}}

  defp address(url), do: {:error, {:invalid_link_preview_url, url}}

  defp bounded_text(text, max_bytes) when is_binary(text), do: Text.truncate_utf8(text, max_bytes)
  defp bounded_text(other, _max_bytes), do: other

  defp image(nil), do: nil

  defp image(image) when is_map(image) do
    ref = value(image, :ref)

    %{
      "ref" => ref,
      "sha256" => ref,
      "kind" => "image",
      "mime" => value(image, :mime),
      "size_bytes" => value(image, :size_bytes)
    }
  end

  # The phones' own event for a stored card (mobile protocol); the Mac reads
  # the row again instead.
  defp phone_event(server_seq, card) do
    %{
      "t" => "link_preview",
      "in_reply_to" => server_seq,
      "url" => card["url"],
      "site" => card["site"],
      "title" => card["title"]
    }
    |> maybe_put("description", card["description"])
    |> maybe_put("image_ref", get_in(card, ["image", "ref"]))
  end

  defp emit(profile_id, event, opts) do
    case Keyword.get(opts, :event_sink) do
      sink when is_function(sink, 2) -> sink.({:profile, profile_id}, event)
      nil -> Fanout.announce(profile_id, event)
    end
  end

  defp thumbnail_writer(opts) do
    override = injected(Keyword.get(opts, :thumbnail_store), 2, :thumbnail_store)

    override || (&store_thumbnail/2)
  end

  defp attach(profile_id, server_seq, card, opts) do
    store = Keyword.get(opts, :store, Timeline)

    store.attach_link_preview(profile_id, server_seq, card, Keyword.get(opts, :store_opts, []))
  end

  defp store_thumbnail(bytes, mime) do
    MediaStore.put_bytes(MediaStore, bytes, %{kind: :image, mime_type: mime})
  end

  defp injected(nil, _arity, _name), do: nil
  defp injected(fun, arity, _name) when is_function(fun, arity), do: fun

  defp injected(other, arity, name) do
    raise ArgumentError,
          "#{name} override must be a function of arity #{arity}, got: #{inspect(other)}"
  end

  defp log_error(stage, reason) do
    Logger.warning("link preview #{stage}: #{inspect(reason)}")
    :ok
  end

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
