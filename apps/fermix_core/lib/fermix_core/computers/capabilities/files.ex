defmodule FermixCore.Computers.Capabilities.Files do
  @moduledoc """
  `files` (M97 §6.4): reading, writing, editing and searching files, looking
  at images and sending a file, on a computer of the home, inside that
  computer's sandbox roots. Its `files` switch gates it, at that computer.

  Each op runs the tool's own code (`perform/2`) under that computer's
  sandbox (`Computers.Capabilities.Local`); there is no second implementation
  of any of them:

  | op | tool | changes something |
  |---|---|---|
  | `file.read` | `file_read` | no |
  | `file.write` | `file_write` | yes |
  | `file.edit` | `file_edit` | yes |
  | `file.glob` | `glob_search` | no |
  | `file.search` | `content_search` | no |
  | `image.view` | `view_image` | no |
  | `file.send` | `send_attachment` | no |

  `file.send` only reads: the computer answers the file's bytes, and the
  server sends them to the chat once, after the answer arrived, so a lost
  answer is read again and nothing reaches the chat twice. A file it will
  not send is a failed invocation, as every tool's own failure is
  (`Local.ran/1`).

  Before anything runs, a path outside the computer's roots is refused
  `outside_sandbox` (`admit/3`); a protected or blocked path is the tool's to
  refuse, in its own words, as it is here. Bounds are the tools' own (100 KB
  a read, 10 MiB an image); a text or file above 256 KiB rides the part, and
  so does content above that written to a file (`content_part`).
  """

  @behaviour FermixCore.Computers.Capability

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Computers.Capabilities.Local
  alias FermixCore.Tools.ContentSearch
  alias FermixCore.Tools.FileEdit
  alias FermixCore.Tools.FileRead
  alias FermixCore.Tools.FileWrite
  alias FermixCore.Tools.GlobSearch
  alias FermixCore.Tools.SendAttachment
  alias FermixCore.Tools.ViewImage

  @ops %{
    "file.read" => FileRead,
    "file.write" => FileWrite,
    "file.edit" => FileEdit,
    "file.glob" => GlobSearch,
    "file.search" => ContentSearch,
    "image.view" => ViewImage,
    "file.send" => SendAttachment
  }
  @effects ["file.write", "file.edit"]
  @max_part_bytes 20 * 1_024 * 1_024
  @result_bytes 256 * 1_024 + 16 * 1_024
  # A read is 100 KB at most and its marker; a write's or an edit's answer is
  # one sentence. Searches, images and a sent file ride the part up to its
  # most.
  @part_bytes %{
    "file.read" => 128 * 1_024,
    "file.write" => 64 * 1_024,
    "file.edit" => 64 * 1_024
  }
  @default_deadline_ms 30_000
  @transfer_deadline_ms 120_000
  # Searching names its own timeout, at most 120 s; the sandbox's own checks
  # take the rest.
  @search_slack_ms 5_000

  @impl true
  def id, do: :files

  @impl true
  def offer, do: :files

  @impl true
  def ops, do: @ops |> Map.keys() |> Enum.sort()

  @impl true
  def effect?(op) when is_map_key(@ops, op), do: op in @effects

  @impl true
  def long_lived?(op) when is_map_key(@ops, op), do: false

  @impl true
  def here?(context) when is_map(context), do: true

  @impl true
  def validate("file.write", %{"content_part" => true} = args) do
    if Map.has_key?(args, "content"),
      do: {:error, "Send the content inline or as the request's file, not both."},
      else: :ok
  end

  def validate(op, args) when is_map_key(@ops, op) and is_map(args), do: :ok

  @impl true
  def bounds(op) when is_map_key(@ops, op),
    do: %{result_bytes: @result_bytes, part_bytes: Map.get(@part_bytes, op, @max_part_bytes)}

  @impl true
  def deadline_ms("file.search", args) do
    case Map.get(args, "timeout_ms") do
      ms when is_integer(ms) -> min(max(ms, 1), 120_000) + @search_slack_ms
      _default -> @default_deadline_ms + @search_slack_ms
    end
  end

  def deadline_ms(op, _args) when op in ["image.view", "file.send"], do: @transfer_deadline_ms
  def deadline_ms(op, _args) when is_map_key(@ops, op), do: @default_deadline_ms

  @impl true
  def admit(op, args, context) when op in ["file.read", "file.send"],
    do: Local.admit_path(args["path"], :read, operation(op), context)

  def admit(op, args, context) when op in ["file.write", "file.edit"],
    do: Local.admit_path(args["path"], :write, operation(op), context)

  def admit(op, args, context) when op in ["file.glob", "file.search"],
    do: Local.admit_path(Map.get(args, "path", File.cwd!()), :read, operation(op), context)

  def admit("image.view", args, context),
    do: Local.admit_paths(args["paths"], :read, :view_image, context)

  @impl true
  def run("file.write", %{"content_part" => true} = args, part, context) when is_binary(part),
    do:
      perform(FileWrite, args |> Map.delete("content_part") |> Map.put("content", part), context)

  def run("file.write", %{"content_part" => true}, nil, _context),
    do: {:failed, "The content to write did not come with the request."}

  def run("file.send", args, nil, context), do: read_to_send(args, Local.tool_context(context))
  def run(op, args, nil, context), do: perform(Map.fetch!(@ops, op), args, context)
  def run(_op, _args, _part, _context), do: {:failed, "This takes no file."}

  @impl true
  def target("file.glob", args),
    do: Path.join(text(args["path"], "."), text(args["pattern"], "*"))

  def target("file.search", args), do: text(args["path"], ".")

  def target("image.view", %{"paths" => paths}) when is_list(paths),
    do: paths |> Enum.filter(&is_binary/1) |> Enum.join(", ") |> text("image.view")

  def target(op, args) when is_map_key(@ops, op), do: text(args["path"], op)

  @doc """
  A file write's arguments with its content taken out, to ride as the
  request's part (`content_part`): the server's half of a write above what
  the request carries inline.
  """
  @spec without_content(map()) :: map()
  def without_content(args) when is_map(args),
    do: args |> Map.delete("content") |> Map.put("content_part", true)

  defp perform(module, args, context),
    do: Local.ran(module.perform(args, Local.tool_context(context)))

  # The file is checked by `send_attachment`'s own rules here, then its bytes
  # are the answer's part; the server sends them on.
  defp read_to_send(args, tool_context) do
    case SendAttachment.attachment(args, tool_context) do
      {:ok, part} -> with_bytes(part)
      {:error, reason} -> not_sent(SendAttachment.error_text(reason))
    end
  end

  defp with_bytes(%{path: path} = part) do
    case File.stat(path) do
      {:ok, %{size: 0}} ->
        not_sent("The file is empty, so there is nothing to send.")

      {:ok, %{size: size}} when size > @max_part_bytes ->
        not_sent("The file is #{size} bytes; a computer sends at most 20 MiB at once.")

      {:ok, _stat} ->
        read_bytes(part)

      {:error, reason} ->
        not_sent("The file could not be read: #{:file.format_error(reason)}.")
    end
  end

  defp read_bytes(part) do
    case File.read(part.path) do
      {:ok, bytes} when byte_size(bytes) in 1..@max_part_bytes ->
        {:ok, sent(part), bytes}

      {:ok, _grown_or_emptied} ->
        not_sent("The file changed while it was read; try again.")

      {:error, reason} ->
        not_sent("The file could not be read: #{:file.format_error(reason)}.")
    end
  end

  defp sent(part) do
    %{"success" => true, "filename" => part.filename, "kind" => Atom.to_string(part.kind)}
    |> put_some("caption", Map.get(part, :caption))
    |> put_some("mime_type", Map.get(part, :mime_type))
  end

  # The send tool's own refusal: a failed invocation that carries it whole.
  defp not_sent(error), do: Local.ran({:ok, Tool.error(error)})

  defp operation("file.read"), do: :file_read
  defp operation("file.send"), do: :send_attachment
  defp operation("file.write"), do: :file_write
  defp operation("file.edit"), do: :file_edit
  defp operation("file.glob"), do: :glob_search
  defp operation("file.search"), do: :content_search

  defp text(value, _default) when is_binary(value) and value != "", do: value
  defp text(_value, default), do: default

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)
end
