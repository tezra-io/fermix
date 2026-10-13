defmodule FermixCore.Attachments.Workspace do
  @moduledoc """
  Keeps an operator turn's inbound attachments in the workspace (M67 D1), so a
  later turn can open one after the channel's link has expired.

  Every attachment that was downloaded, an unreadable one included, is written
  under the sandbox `workspace_root` at
  `media/inbound/<YYYY-MM-DD>/<stem>-<token><ext>`, where a later turn opens it
  with `view_image`, `file_read` or a program already installed. What the model
  saw of a GIF or a video goes beside it, `-still<ext>` or `-frame<N>.jpg`, so
  `view_image` reopens exactly that. Each attachment's `saved` says where it went
  and the manifest names the path. A voice note is not kept: its transcript is
  the text, and the manifest never lists it. Which turns save is the caller's
  decision (an operator's chat turn; never a guest's, never a Live call's
  screen frame).

  The folder is bounded to 14 days and 1 GiB: before a turn writes, every file
  older than that goes, then the oldest until what stays and what the turn
  writes fit. The prune looks at no more than 10,000 entries, oldest folder
  first (a larger folder is trimmed over several turns), and deletes only
  regular files strictly inside the real `media/inbound`: that folder's own path
  is resolved first, a symbolic link inside it is never followed or deleted, and
  nothing deeper than a day's folder is looked at. The workspace is writable by
  the agent's own commands, so right before each delete the prune checks again,
  by device and inode, that `media/inbound`, the day's folder and the file are
  the ones it walked; anything swapped stops the prune.

  A failure (the sandbox refuses the folder, a write or a prune fails, the
  folder changed under the prune) is a sentence in `saved`, which the manifest
  names and the save event traces; the sentence names folders, never a sender's
  file name. No attachment is dropped and the turn runs.
  """

  require Logger

  alias FermixCore.Attachments
  alias FermixCore.Attachments.Telemetry, as: AttachmentTelemetry
  alias FermixCore.Sandbox
  alias FermixCore.Telemetry
  alias FermixCore.Tools.Media.Support

  @max_age_days 14
  @max_age_s @max_age_days * 24 * 60 * 60
  @max_bytes 1024 * 1024 * 1024
  @max_scan 10_000
  @max_stem 40
  @action :save_attachment

  @extensions %{
    "image/jpeg" => ".jpg",
    "image/png" => ".png",
    "image/gif" => ".gif",
    "image/webp" => ".webp",
    "image/heic" => ".heic",
    "image/avif" => ".avif",
    "video/mp4" => ".mp4",
    "video/quicktime" => ".mov",
    "video/webm" => ".webm",
    "video/3gpp" => ".3gp",
    "audio/ogg" => ".ogg",
    "audio/mpeg" => ".mp3",
    "audio/mp4" => ".m4a",
    "audio/wav" => ".wav",
    "audio/flac" => ".flac",
    "audio/amr" => ".amr",
    "audio/webm" => ".webm",
    "application/pdf" => ".pdf",
    "text/plain" => ".txt"
  }

  @type opt ::
          {:channel, String.t()}
          | {:session_id, String.t() | nil}
          | {:now, integer()}
          | {:before_delete, (String.t() -> term())}

  @doc """
  `attachments` with `saved` set on each one kept, in the workspace of the
  sandbox config `context` names. `channel:` and `session_id:` ride the save
  event; `now:` (POSIX seconds) dates the folder and ages the prune.
  `before_delete:` is called with each path just before the prune checks and
  deletes it: the test seam for a folder that changes mid-prune.
  """
  @spec save([Attachments.t()], map(), [opt()]) :: [Attachments.t()]
  def save(attachments, context, opts)
      when is_list(attachments) and is_map(context) and is_list(opts) do
    if Enum.any?(attachments, &kept?/1),
      do: save_kept(attachments, context, opts),
      else: attachments
  end

  defp save_kept(attachments, context, opts) do
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)
    room = attachments |> Enum.filter(&kept?/1) |> Enum.map(&written_bytes/1) |> Enum.sum()

    before_delete = Keyword.get(opts, :before_delete, fn _path -> :ok end)

    {{saved, pruned}, duration_us} =
      Telemetry.timed_us(fn -> write_all(attachments, context, {room, now, before_delete}) end)

    AttachmentTelemetry.emit_save(
      Keyword.fetch!(opts, :channel),
      Keyword.get(opts, :session_id),
      stats(saved, pruned),
      duration_us
    )

    saved
  end

  defp stats(attachments, pruned) do
    saved = Enum.filter(attachments, &match?(%Attachments{saved: {:saved, _path, _seen}}, &1))
    failures = for %Attachments{saved: {:not_saved, sentence}} <- attachments, do: sentence

    %{
      saved: length(saved),
      failed: length(failures),
      files:
        saved
        |> Enum.map(fn %{saved: {:saved, _path, seen}} -> 1 + length(seen) end)
        |> Enum.sum(),
      bytes: saved |> Enum.map(&written_bytes/1) |> Enum.sum(),
      pruned_files: pruned.files,
      pruned_bytes: pruned.bytes,
      first_failure: List.first(failures)
    }
  end

  defp write_all(attachments, context, prune) do
    case prepare(context, prune) do
      {:ok, dir, pruned} ->
        {Enum.map(attachments, &write_one(&1, dir, context)), pruned}

      {:error, sentence} ->
        {Enum.map(attachments, &not_saved(&1, sentence)), %{files: 0, bytes: 0}}
    end
  end

  defp prepare(context, {room, now, before_delete}) do
    with {:ok, root} <- inbound_root(context),
         {:ok, pruned} <- prune(root, room, now, before_delete) do
      {:ok, Path.join(root, day(now)), pruned}
    end
  end

  # The real `media/inbound`: the sandbox resolves every symbolic link on the
  # way and refuses a folder outside the roots or under a protected path.
  defp inbound_root(context) do
    path = Path.join([Sandbox.workspace_root(context), "media", "inbound"])

    case Sandbox.write_path(path, @action, context) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, reason} -> {:error, Support.sandbox_error(reason)}
    end
  end

  defp kept?(%Attachments{status: :transcribed}), do: false
  defp kept?(%Attachments{bytes: bytes}), do: is_binary(bytes)

  defp not_saved(%Attachments{} = att, sentence) do
    if kept?(att), do: %{att | saved: {:not_saved, sentence}}, else: att
  end

  # --- Writing ---

  defp write_one(%Attachments{} = att, dir, context) do
    if kept?(att), do: %{att | saved: write_files(files(att), dir, context)}, else: att
  end

  defp files(%Attachments{} = att) do
    base = stem(att) <> "-" <> token()
    [{base <> extension(att.mime_type, att.name), att.bytes} | seen(att, base)]
  end

  # What the model saw of a GIF or a video: its frames, or its one still.
  defp seen(%Attachments{status: :ready, frames: [_ | _] = frames}, base) do
    for {frame, number} <- Enum.with_index(frames, 1),
        do: {"#{base}-frame#{number}#{extension(frame.mime_type, nil)}", frame.bytes}
  end

  defp seen(%Attachments{status: :ready, poster: %{mime_type: mime, bytes: bytes}}, base),
    do: [{base <> "-still" <> extension(mime, nil), bytes}]

  defp seen(%Attachments{}, _base), do: []

  # All of an attachment's files or none: a write that fails removes the ones
  # this attachment already wrote. The failure names no file: the name is the
  # sender's, and the sentence reaches the trace.
  defp write_files(files, dir, context) do
    files
    |> Enum.reduce_while({:ok, []}, fn {name, bytes}, {:ok, written} ->
      case Support.write_bytes(Path.join(dir, name), bytes, context, action: @action) do
        {:ok, path} -> {:cont, {:ok, [path | written]}}
        {:error, sentence} -> {:halt, {:error, String.replace(sentence, name, "…"), written}}
      end
    end)
    |> written_files()
  end

  defp written_files({:ok, written}) do
    [path | seen] = Enum.reverse(written)
    {:saved, path, seen}
  end

  defp written_files({:error, sentence, written}) do
    Enum.each(written, &remove_written/1)
    {:not_saved, sentence}
  end

  defp remove_written(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Inbound save cleanup failed: #{path} - #{inspect(reason)}")
    end
  end

  defp written_bytes(%Attachments{bytes: bytes} = att) do
    seen = att |> seen("") |> Enum.map(fn {_name, still} -> byte_size(still) end)
    Enum.sum([byte_size(bytes) | seen])
  end

  # --- Names ---

  defp day(now) do
    {{year, month, day}, _time} = :calendar.system_time_to_local_time(now, :second)
    year |> Date.new!(month, day) |> Date.to_iso8601()
  end

  defp token, do: 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  # The sender's file name, reduced to letters, digits, `_` and `-`, so the
  # path is safe in any tool and any shell; with nothing left, the kind.
  defp stem(%Attachments{name: name} = att) when is_binary(name) do
    stem =
      name
      |> Path.basename()
      |> Path.rootname()
      |> String.replace(~r/[^A-Za-z0-9_-]+/, "-")
      |> String.slice(0, @max_stem)
      |> String.trim("-")

    if stem == "", do: kind_word(att.kind), else: stem
  end

  defp stem(%Attachments{kind: kind}), do: kind_word(kind)

  defp kind_word(:still), do: "image"
  defp kind_word(:unknown), do: "file"
  defp kind_word(kind), do: Atom.to_string(kind)

  # The extension of the type the bytes were classified as; for a type the
  # table does not know, the sender's own (a `.docx` stays a `.docx`).
  defp extension(mime, name) do
    Map.get_lazy(@extensions, mime, fn -> sender_extension(name) end)
  end

  defp sender_extension(name) when is_binary(name) do
    extension = Path.extname(name)
    if extension =~ ~r/\A\.[A-Za-z0-9]{1,8}\z/, do: String.downcase(extension), else: ".bin"
  end

  defp sender_extension(nil), do: ".bin"

  # --- Pruning ---

  # The daemon deletes here with its own rights, and the workspace is writable
  # by the agent's commands, so every folder the walk trusted is checked again,
  # by device and inode, right before each delete. The sandbox resolved `root`
  # to a real path, so each of its folders, from `/` down, must still be the
  # directory it was: a link swapped in anywhere on the way is a change.
  defp prune(root, room, now, before_delete) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory}} -> prune_root(root, room, now, before_delete)
      {:ok, %File.Stat{}} -> {:error, failure("list", root, :enotdir)}
      {:error, :enoent} -> {:ok, %{files: 0, bytes: 0}}
      {:error, reason} -> {:error, failure("read", root, reason)}
    end
  end

  defp prune_root(root, room, now, before_delete) do
    case root_guards(root) do
      {:ok, guards} -> prune_folder(guards, room, now, before_delete)
      :changed -> {:error, changed(root)}
    end
  end

  defp root_guards(root) do
    root
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.reduce_while({:ok, []}, fn folder, {:ok, guards} ->
      case File.lstat(folder) do
        {:ok, %File.Stat{type: :directory} = stat} ->
          {:cont, {:ok, guards ++ [{folder, identity(stat)}]}}

        _link_or_gone ->
          {:halt, :changed}
      end
    end)
  end

  defp prune_folder(guards, room, now, before_delete) do
    with {:ok, files, _left} <- walk(guards, :root, @max_scan) do
      files |> doomed(room, now) |> delete_all(before_delete)
    end
  end

  # Oldest first: every file past the age, then as many of the rest as keep
  # what stays and what this turn writes over the cap.
  defp doomed(files, room, now) do
    {old, young} =
      files
      |> Enum.sort_by(& &1.mtime)
      |> Enum.split_with(&(now - &1.mtime > @max_age_s))

    total = young |> Enum.map(& &1.size) |> Enum.sum()

    {over, _sum} =
      Enum.flat_map_reduce(young, total + room, fn file, sum ->
        if sum > @max_bytes, do: {[file], sum - file.size}, else: {:halt, sum}
      end)

    old ++ over
  end

  defp delete_all(files, before_delete) do
    Enum.reduce_while(files, {:ok, %{files: 0, bytes: 0}}, fn file, {:ok, pruned} ->
      before_delete.(file.path)
      delete_one(file, pruned)
    end)
  end

  defp delete_one(file, pruned) do
    case unchanged(file) do
      :ok -> remove(file, pruned)
      :gone -> {:cont, {:ok, pruned}}
      :changed -> {:halt, {:error, changed(file.folder)}}
    end
  end

  defp remove(file, pruned) do
    case File.rm(file.path) do
      :ok -> {:cont, {:ok, %{files: pruned.files + 1, bytes: pruned.bytes + file.size}}}
      {:error, :enoent} -> {:cont, {:ok, pruned}}
      {:error, reason} -> {:halt, {:error, failure("delete a file in", file.folder, reason)}}
    end
  end

  # Every folder on the way is still the directory the walk saw, and the file
  # still the regular file it saw: a link swapped in, at any depth, is a change.
  defp unchanged(file) do
    if Enum.all?(file.guards, &same_folder?/1), do: file_state(file), else: :changed
  end

  defp same_folder?({folder, id}) do
    case File.lstat(folder) do
      {:ok, %File.Stat{type: :directory} = stat} -> identity(stat) == id
      _changed_or_gone -> false
    end
  end

  defp file_state(file) do
    case File.lstat(file.path) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        if identity(stat) == file.id, do: :ok, else: :changed

      {:error, :enoent} ->
        :gone

      _changed ->
        :changed
    end
  end

  defp changed(folder) do
    Logger.warning(
      "Inbound attachments prune stopped: #{folder} changed while it was being pruned"
    )

    "the inbound attachments folder changed while it was being pruned (#{folder}), " <>
      "so pruning stopped"
  end

  defp identity(%File.Stat{major_device: device, inode: inode}), do: {device, inode}

  # `guards` are the folders from `/` down to the one being read, each with the
  # identity the walk saw. `level` is `:root` for `media/inbound` itself and
  # `:day` for a day's folder; nothing deeper is read. `budget` caps how many
  # entries one prune looks at, names in order, so the oldest day comes first.
  defp walk(guards, level, budget) do
    {dir, _id} = List.last(guards)

    with {:ok, names} <- list(dir) do
      names
      |> Enum.sort()
      |> Enum.reduce_while({:ok, [], budget}, &visit({guards, level, dir}, &1, &2))
    end
  end

  defp list(dir) do
    case File.ls(dir) do
      {:ok, names} -> {:ok, names}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, failure("list", dir, reason)}
    end
  end

  defp visit(_where, _name, {:ok, files, 0}), do: {:halt, {:ok, files, 0}}

  defp visit({guards, level, dir}, name, {:ok, files, left}) do
    path = Path.join(dir, name)

    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        {:cont, {:ok, [seen_file(guards, dir, path, stat) | files], left - 1}}

      {:ok, %File.Stat{type: :directory} = stat} when level == :root ->
        descend(guards ++ [{path, identity(stat)}], files, left - 1)

      {:ok, %File.Stat{}} ->
        {:cont, {:ok, files, left - 1}}

      {:error, :enoent} ->
        {:cont, {:ok, files, left - 1}}

      {:error, reason} ->
        {:halt, {:error, failure("read an entry in", dir, reason)}}
    end
  end

  defp seen_file(guards, dir, path, %File.Stat{} = stat) do
    %{
      path: path,
      folder: dir,
      size: stat.size,
      mtime: stat.mtime,
      id: identity(stat),
      guards: guards
    }
  end

  defp descend(guards, files, left) do
    case walk(guards, :day, left) do
      {:ok, day_files, left} -> {:cont, {:ok, day_files ++ files, left}}
      {:error, _sentence} = error -> {:halt, error}
    end
  end

  # A folder, never a file: a file's name is the sender's, and the sentence
  # reaches the trace.
  defp failure(verb, folder, reason),
    do:
      "the inbound attachments folder could not be pruned: " <>
        "#{:file.format_error(reason)} (could not #{verb} #{folder})"
end
