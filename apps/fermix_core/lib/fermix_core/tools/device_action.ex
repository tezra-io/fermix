defmodule FermixCore.Tools.DeviceAction do
  @moduledoc """
  Do one bounded thing on the owner's own desktop (M75 §11, B11): show a
  notification, open a web page, read a file, list a folder, run a command, or
  ask for read access to a folder, on a Mac or Linux desktop whose engine runs
  in the device role and keeps a session to this primary.

  The primary asks; the desktop decides. Each call becomes one invocation with
  its own id, deadline and the turn's correlation id (`FermixCore.DeviceActions`,
  implemented on the channels side), and the desktop runs it only under its own
  policy: its `[fermix_core.engine] executor` switch, its own sandbox read scope
  and confined shell, and its own refusals. A result lost in a reconnect is
  reconciled from the desktop's receipt; one it holds no receipt for is
  reported as uncertain, and nothing is ever sent twice.

  Rules, each one place:

    * **Offered** only on the primary, only on a turn the owner asked in or
      scheduled (`Temporal.Access.operator_read_turn?/1`, never a run a cue
      woke), and only while some desktop row lets actions run (`executor` on).
      `execute/2` repeats every check.
    * **Which desktop.** `device` names one by its name; it is needed only when
      the primary holds more than one desktop row.
    * **Unavailable is a refusal.** A desktop that is not connected answers
      `Your <name> is unavailable; nothing was run.` Nothing is queued.
    * **Commands and read grants need the owner.** `run_command` and
      `grant_read` meet `Capabilities.AccessGate` (`owner_approval?`): while
      their desktop is connected, the owner approves the exact command, or the
      exact folder, on that exact desktop with a card of kind `device`
      (`approval_request/2`) that waits as long as the action's deadline, and
      only the confirmed call runs (`execute/2` checks the confirmation's
      digest too). Once it ran, the request that asked is asked again and the
      same call there gets the confirmed call's result back: the model reads
      the command's output, or reads in the folder it was granted.
    * **A read grant is the desktop's own.** `grant_read {path}` records the
      folder in that desktop's own read grants (`device/read_grants.json`
      there), so `read_file` and `list_directory` may read in it; the
      desktop's sandbox, protected paths and refusals still decide.
    * **A file reaches the model as an attachment.** `read_file`'s bytes go
      through the engine's inbound attachment pipeline on the channels side,
      and come back as the `[attachments]` manifest and its content parts
      (`FermixCore.Attachments`): a PDF as a document, a picture as an image,
      a text file inlined; never as raw bytes in the text.

  Telemetry: one `[:fermix, :tool, :exec]` event per call through
  `Tools.Telemetry.exec/5`, with the action, the device id, the invocation id
  and the outcome; the file's bytes and the content parts never reach it.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Attachments
  alias FermixCore.Attachments.Manifest
  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.DeviceActions
  alias FermixCore.Home.Role
  alias FermixCore.Temporal.Access
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @name "device_action"
  @actions ~w(notify open_url read_file list_directory run_command grant_read)
  # The actions the owner approves one by one.
  @approved ~w(run_command grant_read)
  # How long the desktop may take to start each action and the primary waits
  # for it, in seconds (the wire's `deadline_s`, 1 to 600). An approved
  # action's card waits as long.
  @deadlines %{
    "notify" => 30,
    "open_url" => 30,
    "list_directory" => 60,
    "read_file" => 120,
    "run_command" => 120,
    "grant_read" => 120
  }
  @max_title_bytes 256
  @max_body_bytes 4_096
  @max_url_bytes 2_048
  @max_path_bytes 4_096
  # `Capabilities.AccessGate` refuses to park a command it cannot show whole.
  @max_command_chars 2_000
  @max_device_bytes 128
  @max_listed 500

  @impl true
  @spec name() :: String.t()
  def name, do: @name

  @doc "The actions a desktop runs."
  @spec actions() :: [String.t()]
  def actions, do: @actions

  @impl true
  @spec description() :: String.t()
  def description do
    "Do one thing on the owner's own desktop computer (a Mac or Linux desktop paired with " <>
      "this Fermix), not here: show a notification, open a web page, read a file, list a " <>
      "folder, run a command, or ask for read access to a folder (the owner approves each " <>
      "command and each read grant first). Paths are that computer's own, and its own " <>
      "sandbox decides what may be read."
  end

  @impl true
  @spec parameters() :: map()
  def parameters, do: parameters_with(device_schema([]))

  @doc "Per-turn schema: `device` is an enum of the desktop rows' names."
  @spec dynamic_parameters(map()) :: map()
  def dynamic_parameters(context) when is_map(context),
    do: parameters_with(device_schema(Enum.map(desktops(), & &1.name)))

  @doc """
  Offered only on the primary, on a turn the owner asked in or scheduled (not
  a run a cue woke), while some desktop row lets actions run.
  """
  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context),
    do: primary?(context) and owner_turn?(context) and Enum.any?(desktops(), & &1.executor)

  @impl true
  def when_to_use do
    "When the owner asks for something on their own computer rather than here: a file in " <>
      "their Mac's Downloads, what is in a folder there, a page to open or a notification to " <>
      "show there, or a command to run there. A path such as ~/Documents means this machine " <>
      "unless the owner names their computer; ask when it is unclear. When reading a file or " <>
      "listing a folder there is refused as outside that computer's sandbox, ask for read " <>
      "access to its folder with grant_read, then read. Never fill in a file's contents or a " <>
      "folder's listing yourself when the computer could not be reached."
  end

  @impl true
  def examples do
    [
      %{
        args: %{"action" => "list_directory", "path" => "~/Downloads"},
        note: "what is in the Downloads folder on the owner's Mac"
      },
      %{
        args: %{"action" => "read_file", "path" => "~/Downloads/lease.pdf"},
        note: "read a PDF on the owner's Mac"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "unavailable", description: "the desktop is not connected; nothing was run"},
      %{tag: "turned_off", description: "actions on that desktop are turned off"},
      %{tag: "ambiguous_device", description: "more than one desktop and none was named"},
      %{tag: "refused", description: "the desktop's own policy refused it; its words are given"},
      %{tag: "failed", description: "it ran and failed on the desktop"},
      %{tag: "uncertain", description: "no result and no receipt: whether it ran is unknown"},
      %{
        tag: "needs_approval",
        description: "a command or a read grant waits for the owner's approval"
      }
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :system

  @doc """
  Whether `Capabilities.AccessGate` must hold this call for the owner: a
  `run_command` or a `grant_read` for a desktop that is connected and lets
  actions run. Any other call, or one its desktop cannot take, runs to its own
  answer without asking (an unavailable desktop runs nothing). `execute/2`
  never runs either without the confirmation, so a desktop that connects in
  between is refused.
  """
  @spec approval_required?(map(), map()) :: boolean()
  def approval_required?(%{"action" => action} = args, context)
      when action in @approved and is_map(context) do
    with {:ok, ^action, _fields} <- parse(args),
         {:ok, %{executor: true, connected: true}} <- resolve_desktop(args, desktops()) do
      true
    else
      _invalid_unavailable_off_or_unresolved -> false
    end
  end

  def approval_required?(args, context) when is_map(args) and is_map(context), do: false

  @doc """
  What the owner is asked about an approved action the gate holds: the card's
  kind (`:device`), its head, the exact lines it will act on (the computer and
  the command, or the computer and the folder), each one value the gate shows
  verbatim (redacted and escaped), and how long the card waits (`ttl_s`, the
  action's deadline).
  """
  @spec approval_request(map(), map()) :: %{
          card: :device,
          head: String.t(),
          lines: [{String.t(), String.t()}],
          ttl_s: pos_integer()
        }
  def approval_request(%{"action" => "run_command", "command" => command} = args, context)
      when is_binary(command) and is_map(context) do
    name = desktop_name(args)

    %{
      card: :device,
      head:
        "Run this command on your #{name}? It runs there, inside that computer's own sandbox.",
      lines:
        [{"Computer", name}, {"Command", command}] ++
          folder_line(Map.get(args, "cwd")),
      ttl_s: Map.fetch!(@deadlines, "run_command")
    }
  end

  def approval_request(%{"action" => "grant_read", "path" => path} = args, context)
      when is_binary(path) and is_map(context) do
    name = desktop_name(args)

    %{
      card: :device,
      head:
        "Let Fermix read this folder on your #{name}? It can then read the files in it " <>
          "there; nothing else changes on that computer.",
      lines: [{"Computer", name}, {"Folder", path}],
      ttl_s: Map.fetch!(@deadlines, "grant_read")
    }
  end

  defp desktop_name(args) do
    case resolve_desktop(args, desktops()) do
      {:ok, desktop} -> desktop.name
      {:error, _reason} -> Map.get(args, "device") || "desktop"
    end
  end

  defp folder_line(cwd) when is_binary(cwd) and cwd != "", do: [{"Folder", cwd}]
  defp folder_line(_none), do: []

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    start = System.monotonic_time(:millisecond)
    {result, metadata} = run(args, context)
    duration = System.monotonic_time(:millisecond) - start

    # The images (a PDF, a picture) never reach a trace: the event previews the
    # result without its content parts.
    ToolTelemetry.exec(@name, context, match?({:ok, %{success: true}}, result), duration,
      metadata: metadata,
      input: args,
      result: without_parts(result)
    )

    result
  end

  defp run(args, context) do
    with :ok <- check_turn(context),
         {:ok, action, fields} <- parse(args),
         {:ok, desktop} <- resolve_desktop(args, desktops()),
         :ok <- check_desktop(desktop),
         :ok <- check_confirmed(action, args, context) do
      invoke(desktop, action, fields, context)
    else
      {:error, reason} -> refusal(reason, Map.get(args, "action"))
    end
  end

  # --- who and what --------------------------------------------------------

  defp check_turn(context) do
    cond do
      not primary?(context) -> {:error, :not_primary}
      not owner_turn?(context) -> {:error, :not_owner_turn}
      true -> :ok
    end
  end

  # The role this engine booted in; `:engine_role` stands in for that record in
  # a test, as `Role.booted/0` would return it.
  defp primary?(context),
    do: match?(%{role: :primary}, Map.get_lazy(context, :engine_role, &Role.booted/0))

  # The owner's own turn or a run they scheduled; a run a cue woke read what an
  # outsider wrote, and never reaches the owner's computer.
  defp owner_turn?(context),
    do: Access.operator_read_turn?(context) and Map.get(context, :trigger) != "cue"

  defp parse(%{"action" => action} = args) when action in @actions do
    with {:ok, fields} <- fields(action, args), do: {:ok, action, fields}
  end

  defp parse(%{"action" => action}) when is_binary(action),
    do: {:error, {:unknown_action, action}}

  defp parse(_args), do: {:error, {:invalid_param, "action"}}

  defp fields("notify", args) do
    with {:ok, title} <- text(args, "title", @max_title_bytes),
         {:ok, body} <- text(args, "body", @max_body_bytes),
         do: {:ok, %{"title" => title, "body" => body}}
  end

  defp fields("open_url", args) do
    with {:ok, url} <- text(args, "url", @max_url_bytes),
         :ok <- web_url(url),
         do: {:ok, %{"url" => url}}
  end

  defp fields(action, args) when action in ["read_file", "list_directory", "grant_read"] do
    with {:ok, path} <- text(args, "path", @max_path_bytes), do: {:ok, %{"path" => path}}
  end

  defp fields("run_command", args) do
    with {:ok, command} <- command(args),
         {:ok, cwd} <- optional_text(args, "cwd", @max_path_bytes) do
      {:ok, if(cwd, do: %{"command" => command, "cwd" => cwd}, else: %{"command" => command})}
    end
  end

  defp text(args, key, max) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" and byte_size(value) <= max -> {:ok, value}
      _missing_or_invalid -> {:error, {:invalid_param, key}}
    end
  end

  defp optional_text(args, key, max) do
    if Map.has_key?(args, key), do: text(args, key, max), else: {:ok, nil}
  end

  defp command(args) do
    case Map.get(args, "command") do
      command when is_binary(command) and command != "" ->
        if String.length(command) <= @max_command_chars,
          do: {:ok, command},
          else: {:error, :command_too_long}

      _missing ->
        {:error, {:invalid_param, "command"}}
    end
  end

  # The primary refuses what it can tell is not a web page; the desktop checks
  # again for itself.
  defp web_url(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        :ok

      _not_web ->
        {:error, :not_a_web_url}
    end
  end

  # --- which desktop -------------------------------------------------------

  defp desktops do
    case DeviceActions.impl() do
      nil -> []
      module -> module.desktops()
    end
  end

  defp resolve_desktop(args, desktops) do
    case Map.get(args, "device") do
      nil -> only_desktop(desktops)
      name when is_binary(name) and byte_size(name) <= @max_device_bytes -> named(name, desktops)
      _invalid -> {:error, {:invalid_param, "device"}}
    end
  end

  defp only_desktop([desktop]), do: {:ok, desktop}
  defp only_desktop([]), do: {:error, :no_desktop}
  defp only_desktop(desktops), do: {:error, {:ambiguous_device, names(desktops)}}

  defp named(name, desktops) do
    wanted = fold(name)

    case Enum.filter(desktops, &(fold(&1.name) == wanted)) do
      [desktop] -> {:ok, desktop}
      [] -> {:error, {:unknown_device, name, names(desktops)}}
      _same_name -> {:error, {:ambiguous_device, names(desktops)}}
    end
  end

  defp fold(name), do: name |> String.trim() |> String.downcase()
  defp names(desktops), do: Enum.map(desktops, & &1.name)

  defp check_desktop(%{executor: false} = desktop), do: {:error, {:turned_off, desktop.name}}

  defp check_desktop(%{connected: false} = desktop),
    do: {:error, {:unavailable, desktop.name}}

  defp check_desktop(%{executor: true, connected: true}), do: :ok

  # The gate holds every command and read grant a connected desktop could take,
  # and runs only the confirmed call; this repeats it, so a desktop that
  # connected between the gate's check and this one is refused rather than run
  # unasked.
  defp check_confirmed(action, args, context) when action in @approved do
    if Map.get(context, :access_confirmed) == AccessGate.digest(@name, args),
      do: :ok,
      else: {:error, :needs_approval}
  end

  defp check_confirmed(_action, _args, _context), do: :ok

  # --- the invocation ------------------------------------------------------

  defp invoke(desktop, action, fields, context) do
    opts = [deadline_s: Map.fetch!(@deadlines, action), correlation_id: correlation_id(context)]
    module = DeviceActions.impl()

    case module.invoke(desktop.device_id, action, fields, opts) do
      {:ok, outcome} ->
        {render(outcome, action, desktop, fields), metadata(desktop, action, outcome)}

      {:error, reason} ->
        {result, _metadata} = refusal(error_reason(reason, desktop), action)
        {result, Map.merge(base_metadata(desktop, action), %{outcome: outcome_word(reason)})}
    end
  end

  defp correlation_id(context) do
    case Map.get(context, :session_id) do
      session_id when is_binary(session_id) and session_id != "" -> session_id
      _none -> "none"
    end
  end

  defp error_reason(:not_connected, desktop), do: {:unavailable, desktop.name}
  defp error_reason({:busy, max}, desktop), do: {:busy, desktop.name, max}
  defp error_reason({:attachment, reason}, desktop), do: {:attachment, desktop.name, reason}

  defp outcome_word(:not_connected), do: "unavailable"
  defp outcome_word({:busy, _max}), do: "busy"
  defp outcome_word({:attachment, _reason}), do: "attachment_failed"

  # --- what the model reads ------------------------------------------------

  defp render(%{kind: :result, status: :ok} = outcome, action, desktop, fields),
    do: ok(action, desktop, fields, outcome)

  defp render(%{kind: :result, status: :refused, result: result}, action, desktop, _fields) do
    error("Your #{desktop.name} refused to #{verb(action)}: #{message(result)} Nothing was run.")
  end

  defp render(%{kind: :result, status: :failed, result: result}, action, desktop, _fields),
    do: error(failed_text(action, desktop, result))

  defp render(%{kind: :reconciled, status: status, finished_at: at}, action, desktop, _fields) do
    text =
      "This #{action} reached your #{desktop.name} and finished there (#{status}) at #{at}, " <>
        "but its result was lost when the connection dropped. It was not run again, and " <>
        "its output is not available."

    if status == :ok, do: {:ok, Tool.success(text)}, else: error(text)
  end

  defp render(%{kind: :uncertain}, action, desktop, _fields) do
    error(
      "Whether this #{action} ran on your #{desktop.name} is unknown: no result arrived and " <>
        "the computer holds no record of it. It was not sent again; check on the computer " <>
        "before asking for it again."
    )
  end

  defp ok("notify", desktop, _fields, _outcome),
    do: {:ok, Tool.success("Showed the notification on your #{desktop.name}.")}

  defp ok("open_url", desktop, %{"url" => url}, _outcome),
    do: {:ok, Tool.success("Opened #{url} on your #{desktop.name}.")}

  defp ok("list_directory", desktop, %{"path" => path}, %{result: result}),
    do: {:ok, Tool.success(listing(result, path, desktop))}

  defp ok("run_command", desktop, _fields, %{result: result}) do
    {:ok,
     Tool.success(
       "Ran on your #{desktop.name} (exit #{Map.get(result, "exit_code", 0)}):\n" <>
         output_text(result)
     )}
  end

  defp ok("grant_read", desktop, %{"path" => path}, %{result: result}) do
    shown = Map.get(result, "path", path)

    {:ok,
     Tool.success(
       "Your #{desktop.name} now lets Fermix read #{shown}: read_file and list_directory " <>
         "can read there."
     )}
  end

  defp ok("read_file", desktop, %{"path" => path}, %{attachment: %Attachments{} = attachment}) do
    text = Manifest.compose("Read #{path} from your #{desktop.name}.", [attachment])

    case Attachments.parts([attachment]) do
      [] -> {:ok, Tool.success(text)}
      parts -> {:ok, Tool.success_with_images(text, parts)}
    end
  end

  defp listing(result, path, desktop) do
    entries = Map.get(result, "entries", [])
    total = Map.get(result, "total", length(entries))
    shown = Map.get(result, "path", path)

    head =
      if Map.get(result, "truncated") == true,
        do: "#{shown} on your #{desktop.name} holds #{total} entries; the first #{@max_listed}:",
        else: "#{shown} on your #{desktop.name} holds #{total} entries:"

    lines = Enum.map(entries, &entry_line/1)
    Enum.join([head | lines], "\n")
  end

  defp entry_line(%{"name" => name, "type" => "directory"}), do: "- #{name}/"

  defp entry_line(%{"name" => name, "type" => "file", "size_bytes" => size})
       when is_integer(size),
       do: "- #{name} (#{size} bytes)"

  defp entry_line(%{"name" => name, "type" => type}), do: "- #{name} (#{type})"

  defp failed_text("run_command", desktop, %{"reason" => "output_too_long"} = result) do
    "The command printed more than 64 KB on your #{desktop.name} and was stopped there; " <>
      "what it printed first:\n" <> Map.get(result, "output", "")
  end

  defp failed_text("run_command", desktop, %{"exit_code" => code} = result)
       when is_integer(code) do
    "The command failed on your #{desktop.name} (exit #{code}):\n" <> output_text(result)
  end

  defp failed_text(action, desktop, result),
    do: "Could not #{verb(action)} on your #{desktop.name}: #{message(result)}"

  defp output_text(result), do: Map.get(result, "output", "")

  defp message(%{"message" => message}) when is_binary(message) and message != "", do: message
  defp message(_result), do: "it gave no reason."

  defp verb("notify"), do: "show the notification"
  defp verb("open_url"), do: "open the page"
  defp verb("read_file"), do: "read the file"
  defp verb("list_directory"), do: "list the folder"
  defp verb("run_command"), do: "run the command"
  defp verb("grant_read"), do: "grant read access to the folder"
  defp verb(_unknown), do: "do that"

  # --- refusals ------------------------------------------------------------

  defp refusal(reason, action) do
    {error(refusal_text(reason)), %{outcome: refusal_word(reason), action: action_label(action)}}
  end

  defp action_label(action) when action in @actions, do: action
  defp action_label(_other), do: "invalid"

  defp refusal_text(:not_primary),
    do: "device_action runs only on the primary; this engine is not it. Nothing was run."

  defp refusal_text(:not_owner_turn) do
    "device_action runs only on a turn the owner asked for or a job they scheduled; a guest, " <>
      "a delegated worker or a task woken by a cue cannot reach the owner's computer. " <>
      "Nothing was run."
  end

  defp refusal_text({:unknown_action, action}) do
    "Unknown action #{inspect(action)}: use one of #{Enum.join(@actions, ", ")}."
  end

  defp refusal_text({:invalid_param, key}), do: "Missing or invalid parameter: #{key}."

  defp refusal_text(:command_too_long) do
    "The command is longer than #{@max_command_chars} characters, too long for the owner to " <>
      "approve safely. Nothing was run; use a shorter command."
  end

  defp refusal_text(:not_a_web_url),
    do: "Only an http or https web address can be opened. Nothing was run."

  defp refusal_text(:no_desktop),
    do: "No desktop is paired with this Fermix, so nothing was run."

  defp refusal_text({:ambiguous_device, names}) do
    "More than one desktop is paired (#{Enum.join(names, ", ")}); name one in `device`, or ask " <>
      "the owner which. Nothing was run."
  end

  defp refusal_text({:unknown_device, name, names}) do
    "No desktop named #{inspect(name)} is paired; the desktops are #{Enum.join(names, ", ")}. " <>
      "Nothing was run."
  end

  defp refusal_text({:turned_off, name}) do
    "Actions on your #{name} are turned off in this Fermix's device settings; nothing was run."
  end

  defp refusal_text({:unavailable, name}), do: "Your #{name} is unavailable; nothing was run."

  defp refusal_text({:busy, name, max}) do
    "Your #{name} already has #{max} actions in progress; nothing was run. Try again when " <>
      "they finish."
  end

  defp refusal_text({:attachment, name, reason}) do
    "The file arrived from your #{name} but could not be prepared for reading " <>
      "(#{format_reason(reason)})."
  end

  defp refusal_text(:needs_approval) do
    "A command or a read grant on the owner's computer runs only once the owner approves it, " <>
      "and this one was not approved. Nothing was run."
  end

  defp refusal_word({kind, _detail}) when is_atom(kind), do: Atom.to_string(kind)
  defp refusal_word({kind, _name, _detail}) when is_atom(kind), do: Atom.to_string(kind)
  defp refusal_word(kind) when is_atom(kind), do: Atom.to_string(kind)

  defp format_reason({:transcription_failed, reason}),
    do: "its audio could not be transcribed: #{inspect(reason)}"

  defp format_reason(reason), do: inspect(reason)

  defp error(text), do: {:ok, Tool.error(text)}

  # --- trace ---------------------------------------------------------------

  defp base_metadata(desktop, action), do: %{action: action, device_id: desktop.device_id}

  defp metadata(desktop, action, outcome) do
    desktop
    |> base_metadata(action)
    |> Map.put(:invocation_id, outcome.invocation_id)
    |> Map.put(:outcome, outcome_label(outcome))
  end

  defp outcome_label(%{kind: :result, status: status}), do: Atom.to_string(status)
  defp outcome_label(%{kind: :reconciled}), do: "reconciled"
  defp outcome_label(%{kind: :uncertain}), do: "uncertain"

  defp without_parts({:ok, result}), do: {:ok, Map.delete(result, :images)}

  # --- schema --------------------------------------------------------------

  defp parameters_with(device) do
    %{
      type: "object",
      required: ["action"],
      properties: %{
        action: %{
          type: "string",
          enum: @actions,
          description:
            "notify (title, body), open_url (url), read_file (path), list_directory (path), " <>
              "run_command (command, cwd) or grant_read (path, a folder)."
        },
        device: device,
        title: %{type: "string", maxLength: @max_title_bytes, description: "notify: the title."},
        body: %{type: "string", maxLength: @max_body_bytes, description: "notify: the text."},
        url: %{type: "string", description: "open_url: an http or https address."},
        path: %{
          type: "string",
          description:
            "read_file, list_directory, grant_read: a path on that computer (~ is its home " <>
              "folder); for grant_read, the folder to be allowed to read."
        },
        command: %{
          type: "string",
          description: "run_command: the shell command, run on that computer after approval."
        },
        cwd: %{type: "string", description: "run_command: the folder to run it in (optional)."}
      }
    }
  end

  defp device_schema([]) do
    %{
      type: "string",
      description: "The desktop's name; needed only when more than one desktop is paired."
    }
  end

  defp device_schema(names) do
    %{
      type: "string",
      enum: names,
      description: "The desktop to use; needed only when more than one desktop is paired."
    }
  end
end
