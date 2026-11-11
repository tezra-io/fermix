defmodule FermixCore.Browser.ComputerRoute do
  @moduledoc """
  The server's half of a `browser` call that runs on one of the home's
  computers (M97 §6.4): the route `FermixCore.Browser.execute/2` hands each
  of the call's requests to, in place of one of its own profiles, once
  `Computers.Choice` chose a computer.

  Each request is one invocation of `Computers.Capabilities.Browser` (its op
  by action, `op/2`), naming the profile the call named, if any, and the
  conversation it belongs to (its pane key here, which is how the computer
  keeps the conversation's own tab), and the computer serves it through its
  own browser. Everything the tool keeps above a profile stays here, so a
  sign-in's two requests are two invocations with the owner asked in the
  chat between them, and a fill that submits is the fill and then the submit.

  **Nothing crosses as a path.** A screenshot's, a PDF's or a download's
  bytes come back as the answer's part and are kept in this server's own
  browser folder (`artifacts/<scope>/<kind>/`, `downloads/<scope>/`), where
  this server's browser keeps its own, and the result's `path` is that copy;
  an upload's `path` is a file in this server's workspace, confined as an
  upload here is (`Browser.Upload`), whose bytes go to the computer with the
  request. A file is at most 20 MiB either way.

  **Every result names the computer**: a result carries `computer`, and an
  error starts "On <name>:". An answer the link lost or the computer refused
  is the browser's error in `Computers.Outcome`'s sentence (`outcome_unknown`
  for an effect whose outcome is not known, never sent twice). An effect
  whose file was lost on the way (`part_lost`) ran: its result says so, and
  where the computer keeps the file for a day.

  Each invocation records the turn's use of the computer
  (`Browser.ComputerTurn`), so a later call that names none carries on there
  and the computer hears when the turn ends, and tells the call its exec
  metadata (`served/1`): the computer, the last invocation and how it ended,
  and the browser that served it there.
  """

  alias FermixCore.Browser.ComputerTurn
  alias FermixCore.Browser.Error
  alias FermixCore.Browser.Upload
  alias FermixCore.Computers.Capabilities.Browser, as: BrowserCapability
  alias FermixCore.Computers.Computer
  alias FermixCore.Computers.Outcome
  alias FermixCore.Computers.Remote
  alias FermixCore.Setup.ConfigStore

  @max_bytes 20 * 1_024 * 1_024
  @mime "application/octet-stream"
  @name ~r/\A[A-Za-z0-9._-]{1,128}\z/

  @typedoc "The browser's request (`FermixCore.Browser`) and its answer."
  @type route :: (map() -> {:ok, map()} | {:error, Error.t()})

  @doc """
  The route of a call on `computer`: `profile` as the call named it (nil for
  the computer's default), `keys` the call's scope and pane keys here, and
  `call` the reference `served/1` collects the call's metadata by.
  """
  @spec route(
          Computer.t(),
          String.t() | nil,
          %{owner: String.t(), pane: String.t()},
          map(),
          reference()
        ) ::
          route()
  def route(%Computer{} = computer, profile, %{owner: _, pane: _} = keys, context, call)
      when (is_nil(profile) or is_binary(profile)) and is_map(context) and is_reference(call) do
    fn %{action: action, args: args} ->
      send_request(action, args, computer, profile, keys, context, call)
    end
  end

  @doc """
  What the call's one exec event carries of the computer: its device id and,
  after the last invocation the call made, that invocation, how it ended and
  the computer's browser that served it (`cdp` or `fermix_app`). The route
  told it to this process as each invocation ended.
  """
  @spec served(Computer.t(), reference()) :: {:computer, String.t() | nil, map()}
  def served(%Computer{device_id: device}, call) when is_reference(call),
    do: collect(call, {:computer, nil, %{computer: device}})

  defp collect(call, last) do
    receive do
      {^call, backend, metadata} -> collect(call, {:computer, backend, metadata})
    after
      0 -> last
    end
  end

  # -- one request ---------------------------------------------------------------------

  defp send_request(action, args, computer, profile, keys, context, call) do
    turn = ComputerTurn.turn(context)
    :ok = ComputerTurn.used(BrowserCapability.turn_seams(context), turn, computer, context)

    with {:ok, wire_args, part} <- outgoing(action, args) do
      request = %{
        "action" => action,
        "args" => wire_args,
        "profile" => profile,
        "conversation" => keys.pane
      }

      op = BrowserCapability.op(action, args)
      {_ended, outcome} = Remote.invoke(BrowserCapability, op, request, context, part_opts(part))
      backend = backend(outcome)
      send(self(), {call, backend, Outcome.exec_metadata(outcome)})
      answer(outcome, action, computer, keys.owner)
    end
  end

  # An upload's file is this server's, confined as an upload here is; its
  # bytes go with the request and the computer keeps them for its page.
  defp outgoing("upload", args) do
    with {:ok, path} <- Upload.confined_path(args["path"]),
         {:ok, bytes} <- upload_bytes(path) do
      {:ok, args |> Map.delete("path") |> Map.put("upload_name", Path.basename(path)),
       {bytes, @mime}}
    end
  end

  defp outgoing(_action, args), do: {:ok, args, nil}

  defp upload_bytes(path) do
    case File.stat(path) do
      {:ok, %{size: 0}} ->
        {:error, Error.new("upload_empty", "The file is empty, so there is nothing to upload.")}

      {:ok, %{size: size}} when size > @max_bytes ->
        {:error,
         Error.new(
           "upload_too_large",
           "The file is #{size} bytes; a computer takes at most 20 MiB at once."
         )}

      {:ok, _stat} ->
        read_upload(path)

      {:error, reason} ->
        {:error, Error.new("upload_not_found", "Upload file was not found (#{reason})")}
    end
  end

  defp read_upload(path) do
    case File.read(path) do
      {:ok, bytes} when byte_size(bytes) in 1..@max_bytes ->
        {:ok, bytes}

      {:ok, _changed} ->
        {:error, Error.new("upload_changed", "The file changed while it was read; try again.")}

      {:error, reason} ->
        {:error, Error.new("upload_not_found", "Upload file was not found (#{reason})")}
    end
  end

  defp part_opts(nil), do: []
  defp part_opts(part), do: [part: part]

  # -- the answer ----------------------------------------------------------------------

  defp answer(%Outcome{status: :ok, receipt_only: true} = outcome, _action, computer, _owner) do
    {:ok,
     %{
       "ok" => true,
       "page" => "unobserved",
       "computer" => computer.name,
       "note" => Outcome.sentence(outcome, computer.name)
     }}
  end

  # It ran, and its file was lost on the way: said so, never a failure that
  # would have it done again, with where the computer keeps the file.
  defp answer(%Outcome{status: :ok, part_lost: true} = outcome, _action, computer, _owner) do
    {:ok,
     %{
       "ok" => true,
       "page" => "unobserved",
       "computer" => computer.name,
       "note" => lost_note(outcome, computer)
     }}
  end

  defp answer(%Outcome{status: :ok, result: said} = outcome, _action, computer, owner) do
    with {:ok, result} <- result(said, outcome.part_bytes, computer),
         {:ok, result} <- landed(result, said["artifact"], outcome.part_bytes, computer, owner) do
      {:ok, Map.put(result, "computer", computer.name)}
    end
  end

  defp answer(%Outcome{status: :failed, result: %{"error" => said}}, _action, computer, _owner)
       when is_map(said),
       do: {:error, said_error(said, computer)}

  defp answer(%Outcome{} = outcome, _action, computer, _owner),
    do: {:error, Error.new(code(outcome), Outcome.sentence(outcome, computer.name))}

  defp result(%{"result" => result}, _part, _computer) when is_map(result), do: {:ok, result}

  defp result(%{"result_part" => true}, json, computer) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, result} when is_map(result) -> {:ok, result}
      _not_a_result -> not_a_result(computer)
    end
  end

  defp result(_said, _part, computer), do: not_a_result(computer)

  defp not_a_result(computer),
    do:
      {:error,
       Error.new(
         "computer_failed",
         "On #{computer.name}: the browser's answer could not be read."
       )}

  # The computer's file, kept in this server's browser folder; the result's
  # path is this copy.
  defp landed(result, nil, _part, _computer, _owner), do: {:ok, result}

  defp landed(result, %{"kind" => kind, "name" => name}, bytes, computer, owner)
       when kind in ["screenshots", "pdf", "downloads"] and is_binary(bytes) and is_binary(name) do
    dir = artifact_dir(kind, owner)
    path = Path.join(dir, file_name(kind, name))

    with :ok <- File.mkdir_p(dir), :ok <- File.write(path, bytes) do
      {:ok, Map.put(result, "path", path)}
    else
      {:error, reason} ->
        {:error,
         Error.new(
           "artifact_write_failed",
           "The file from #{computer.name} could not be kept on this server: #{inspect(reason)}"
         )}
    end
  end

  defp landed(_result, _artifact, _part, computer, _owner), do: not_a_result(computer)

  # The computer keeps a file it sent for a day (`kept`, its own path there).
  defp lost_note(%Outcome{result: %{"artifact" => %{"kept" => kept}}} = outcome, computer)
       when is_binary(kept),
       do:
         Outcome.sentence(outcome, computer.name) <>
           " It stays on #{computer.name} for a day, at #{kept}."

  defp lost_note(outcome, computer), do: Outcome.sentence(outcome, computer.name)

  defp artifact_dir("downloads", owner),
    do: Path.join([ConfigStore.workspace_paths().browser, "downloads", owner])

  defp artifact_dir(kind, owner),
    do: Path.join([ConfigStore.workspace_paths().browser, "artifacts", owner, kind])

  # A download keeps the name the computer's browser gave it (its own unique
  # one); a capture is named as this server's own are.
  defp file_name("downloads", name) do
    if Regex.match?(@name, name) and name not in [".", ".."],
      do: name,
      else: "#{System.unique_integer([:positive, :monotonic])}"
  end

  defp file_name(_kind, name) do
    extension = name |> Path.extname() |> String.replace(~r/[^A-Za-z0-9.]/, "")
    "#{System.unique_integer([:positive, :monotonic])}#{extension}"
  end

  defp said_error(%{"code" => code, "message" => message} = said, computer)
       when is_binary(code) and is_binary(message) do
    details = if is_map(said["details"]), do: said["details"], else: %{}
    Error.new(code, "On #{computer.name}: " <> message, details)
  end

  defp said_error(_said, computer),
    do:
      Error.new("computer_failed", "On #{computer.name}: the browser's error could not be read.")

  defp code(%Outcome{status: :unknown}), do: "outcome_unknown"
  defp code(%Outcome{status: :refused}), do: "computer_refused"
  defp code(%Outcome{status: :timed_out}), do: "computer_timed_out"
  defp code(%Outcome{status: :cancelled}), do: "computer_cancelled"
  defp code(%Outcome{}), do: "computer_failed"

  defp backend(%Outcome{result: %{"backend" => backend}}) when backend in ["cdp", "fermix_app"],
    do: backend

  defp backend(_outcome), do: nil
end
