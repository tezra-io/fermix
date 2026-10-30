defmodule FermixChannels.Desktop.Executor do
  @moduledoc """
  A desktop's runner for the actions its primary asks of it (M75 §11, B11),
  in the device role. The desktop relay calls `handle/3` for each `invoke` it
  receives and sends back what `answer/2` lists; it answers each
  `invoke_status` with `receipts/2`.

  The primary asks; this machine decides, under its own policy and never the
  primary's:

    * **its switch**: nothing runs while this machine's `[fermix_core.engine]
      executor` is false (`FermixCore.Home.Role.executor?/1`, default true);
    * **the deadline**: an invocation that reached it past its `deadline_s`
      is refused without running;
    * **once**: an invocation it already holds a receipt for is refused, never
      run a second time;
    * `notify {title, body}`: through this engine's own notifications
      (`FermixCore.Native.Notifications`, the `computer` delivery channel's),
      refused by name where this build shows none;
    * `open_url {url}`: http or https only, through the platform's opener
      (`/usr/bin/open` through the `disclaim` exec shim on macOS, as every
      child is, so the opener is its own TCC responsible process;
      `xdg-open` on Linux), never a fallback opener;
    * `read_file {path}` and `list_directory {path}`: only what this machine's
      sandbox lets a file tool read (`FermixCore.Sandbox.read_path/3`: its roots
      and its protected paths, so Fermix's token file, secrets, identity and
      `device/` stay unreadable whatever the primary asks) and the folders the
      owner granted the primary to read (`FermixCore.Home.ReadGrants`, read
      anew for every request, so a grant the owner removed holds for the
      next one), a file of at
      most the session's `max_media_bytes`, at most 500 entries. A file is
      copied once into `<home>/device/media-send` (`:send_staging`) as it is
      hashed, so its hash and the bytes the relay streams from that copy are
      the same, and memory never holds it whole;
    * `run_command {command, cwd?}`: through this machine's own confined shell
      and grants (`Sandbox.shell_plan/3`, `Sandbox.confine/4`), its output cut
      at 64 KiB and its run bounded by what is left of the deadline. This
      machine shows a notification as it starts one for the primary, so a
      command the server runs here is never silent;
    * `grant_read {path}`: the owner approved this folder on a `device` card on
      the primary; it is recorded in this machine's own read grants
      (`FermixCore.Home.ReadGrants`) if it is a folder this machine's sandbox
      would ever let be granted (never `/`, the home folder itself, Fermix's
      home or a protected path), and shown here as a notification the moment
      it is recorded, naming the folder and the server, so a grant is never
      silent either. The owner sees and removes this machine's grants here
      (`device.grants.list`, `device.grants.remove`).

  Every decided invocation, run or refused, leaves a receipt
  (`Desktop.Receipts`), which holds hashes, never the arguments or the output.
  The result carries back the correlation id the primary sent (the asking
  turn's session id), which the log line names too.
  """

  require Logger

  alias FermixChannels.Desktop.Receipts
  alias FermixCore.CommandRunner
  alias FermixCore.Home.ReadGrants
  alias FermixCore.Home.Role
  alias FermixCore.Native.Notifications
  alias FermixCore.Sandbox
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Sandbox.ConfigMutation
  alias FermixCore.Sandbox.OsSandbox
  alias FermixCore.Sandbox.PathPolicy
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @actions ~w(notify open_url read_file list_directory run_command grant_read)
  @max_listed 500
  @max_output_bytes 64 * 1_024
  @max_url_bytes 2_048
  @max_title_bytes 256
  @max_body_bytes 4_096
  @opener_timeout_ms 10_000
  # What a command's run leaves of the deadline for its answer to travel back.
  @answer_margin_ms 5_000
  @min_command_ms 1_000
  @mac_opener "/usr/bin/open"
  @copy_chunk_bytes 64 * 1_024

  @typedoc """
  A `read_file`'s bytes: a private copy of the file the relay streams and then
  deletes, with its size.
  """
  @type blob :: {:file, Path.t(), non_neg_integer()}

  @typedoc "How an invocation ended, its result map, and a `read_file`'s bytes."
  @type outcome :: {:ok | :refused | :failed, map(), blob() | nil}

  @typedoc """
  What `handle/3` runs with. Required: `:receipts` (the `Desktop.Receipts`
  writer), `:received_at_ms` (monotonic milliseconds when the `invoke` arrived),
  `:max_media_bytes` (the session's `caps.max_media_bytes`) and
  `:send_staging` (the private folder a file's copy is staged in). Optional:
  `:primary_name` (the server's name, for the command notification), and the
  seams `:home` (this engine's home), `:now_ms` and `:utc_now` (clocks),
  `:engine` (this machine's `[fermix_core.engine]` section, the running one by
  default), `:sandbox_config` and `:os_sandbox` (the sandbox's),
  `:notifications` (`Native.Notifications` options), `:os_type`, `:shim_path`
  and `:find_executable` (the opener's), and `:run` (`CommandRunner.run/3`'s
  place).
  """
  @type context :: %{required(atom()) => term()}

  @doc "The actions this runner knows."
  @spec actions() :: [String.t()]
  def actions, do: @actions

  @doc """
  Decides and runs one `invoke`: its header fields (`invocation_id`, `action`,
  `deadline_s`) and its arguments JSON. Always answers, and always leaves a
  receipt for what it decided unless one was already held.
  """
  @spec handle(map(), binary(), context()) :: outcome()
  def handle(
        %{"invocation_id" => id, "action" => action, "deadline_s" => deadline_s},
        payload,
        context
      )
      when is_binary(id) and is_binary(action) and is_integer(deadline_s) and
             is_binary(payload) and is_map(context) do
    case Receipts.lookup(Map.fetch!(context, :receipts), [id]) do
      [receipt] -> already_handled(receipt)
      [] -> decide(id, action, deadline_s, payload, context)
    end
  end

  @doc """
  What the relay sends back for `outcome`, in order: the `read_file`'s bytes as
  `invoke_blob` first (the staged copy, `{:file, path, size}`, which the relay
  streams and then deletes), then `invoke_result` with the result JSON. Each
  is `{type, fields, payload}`; the rail chunks them (`index`, `last`).
  """
  @spec answer(String.t(), outcome()) :: [{String.t(), map(), binary() | blob()}]
  def answer(invocation_id, {status, result, blob}) when is_binary(invocation_id) do
    result_event =
      {"invoke_result", %{"invocation_id" => invocation_id, "status" => Atom.to_string(status)},
       Jason.encode!(result)}

    case blob do
      nil -> [result_event]
      bytes -> [{"invoke_blob", %{"invocation_id" => invocation_id}, bytes}, result_event]
    end
  end

  @doc """
  The `invoke_receipts` answer to an `invoke_status`: each named invocation
  this machine holds a receipt for, as `{invocation_id, status, finished_at}`.
  """
  @spec receipts(GenServer.server(), [String.t()]) :: [map()]
  def receipts(server, invocation_ids) when is_list(invocation_ids) do
    server
    |> Receipts.lookup(invocation_ids)
    |> Enum.map(&Map.take(&1, ["invocation_id", "status", "finished_at"]))
  end

  # --- deciding ------------------------------------------------------------

  defp already_handled(receipt) do
    refused(
      "already_handled",
      "it already ran here (#{receipt["status"]} at #{receipt["finished_at"]}) and is not " <>
        "run twice."
    )
  end

  defp decide(id, action, deadline_s, payload, context) do
    {correlation_id, outcome} = run(id, action, deadline_s, payload, context)
    {status, result, blob} = outcome
    result = Map.put(result, "correlation_id", correlation_id)
    :ok = record(id, action, status, payload, result, context)

    Logger.info(
      "desktop executor: #{action} #{id} #{status} (correlation #{correlation_id})" <>
        reason_note(result)
    )

    {status, result, blob}
  end

  defp run(id, action, deadline_s, payload, context) do
    case decode(payload) do
      {:ok, args, correlation_id} ->
        {correlation_id, checked_run(id, action, deadline_s, args, context)}

      {:error, outcome} ->
        {"none", outcome}
    end
  end

  defp checked_run(id, action, deadline_s, args, context) do
    with :ok <- executor_on(context),
         {:ok, left_ms} <- before_deadline(deadline_s, context),
         :ok <- known(action) do
      act(action, args, Map.merge(context, %{invocation_id: id, left_ms: left_ms}))
    end
  end

  defp decode(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = args} ->
        {correlation_id, args} = Map.pop(args, "correlation_id")
        {:ok, args, correlation(correlation_id)}

      _not_an_object ->
        {:error, refused("invalid_arguments", "its arguments are not a JSON object.")}
    end
  end

  defp correlation(id) when is_binary(id) and id != "" and byte_size(id) <= 256, do: id
  defp correlation(_none), do: "none"

  defp executor_on(context) do
    engine =
      Map.get_lazy(context, :engine, fn -> Application.get_env(:fermix_core, :engine, []) end)

    if Role.executor?(engine),
      do: :ok,
      else:
        refused(
          "executor_off",
          "actions are turned off on this computer ([fermix_core.engine] executor = false)."
        )
  end

  defp before_deadline(deadline_s, context) do
    now = Map.get(context, :now_ms, fn -> System.monotonic_time(:millisecond) end).()
    left = deadline_s * 1_000 - (now - Map.fetch!(context, :received_at_ms))

    if left > 0,
      do: {:ok, left},
      else: refused("deadline_passed", "it reached this computer after its deadline.")
  end

  defp known(action) when action in @actions, do: :ok
  defp known(action), do: refused("unknown_action", "this computer does not know #{action}.")

  # --- the actions ---------------------------------------------------------

  defp act("notify", %{"title" => title, "body" => body}, context)
       when is_binary(title) and title != "" and byte_size(title) <= @max_title_bytes and
              is_binary(body) and byte_size(body) <= @max_body_bytes do
    opts = Map.get(context, :notifications, [])

    case Notifications.post(%{title: title, body: body, sound: false}, opts) do
      {:ok, _id} -> ok(%{})
      {:error, :not_offered} -> not_offered(opts)
      {:error, reason} -> failed("not_shown", notify_sentence(reason))
    end
  end

  defp act("open_url", %{"url" => url}, context) when is_binary(url) do
    with :ok <- web_url(url),
         {:ok, {executable, args}} <- opener(url, context) do
      case run_fun(context).(executable, args, timeout_ms: @opener_timeout_ms) do
        {:ok, %{exit: 0}} -> ok(%{"url" => url})
        {:ok, %{exit: code, stdout: out}} -> failed("opener_failed", opener_sentence(code, out))
        {:error, reason} -> failed("opener_failed", "the opener did not run: #{inspect(reason)}")
      end
    end
  end

  defp act("read_file", %{"path" => path}, context) when is_binary(path) and path != "" do
    with {:ok, resolved} <- readable(path, :device_read_file, context),
         {:ok, size} <- regular_file(resolved),
         :ok <- within_media(size, context),
         {:ok, staged, copied, hash} <- stage_copy(resolved, context) do
      ok(
        %{
          "path" => resolved,
          "name" => Path.basename(resolved),
          "size_bytes" => copied,
          "sha256" => hash
        },
        {:file, staged, copied}
      )
    end
  end

  defp act("list_directory", %{"path" => path}, context) when is_binary(path) and path != "" do
    with {:ok, resolved} <- readable(path, :device_list_directory, context),
         :ok <- directory(resolved),
         {:ok, names} <- list(resolved) do
      shown = names |> Enum.sort() |> Enum.take(@max_listed)

      ok(%{
        "path" => resolved,
        "entries" => Enum.map(shown, &entry(resolved, &1)),
        "total" => length(names),
        "truncated" => length(names) > @max_listed
      })
    end
  end

  defp act("run_command", %{"command" => command} = args, context)
       when is_binary(command) and command != "" do
    with {:ok, cwd} <- optional_path(args, "cwd"),
         {:ok, timeout_ms} <- command_time(context),
         sandbox = sandbox_context(context),
         {:ok, plan} <- shell_plan(command, cwd, sandbox),
         {:ok, spawn} <- confine(command, sandbox, plan) do
      :ok = announce_command(command, context)
      run_shell(spawn, plan, timeout_ms, context)
    end
  end

  defp act("grant_read", %{"path" => path}, context) when is_binary(path) and path != "" do
    with {:ok, folder} <- grantable(expand_home(path), context),
         :ok <- directory(folder) do
      record_grant(folder, context)
    end
  end

  defp act(action, _args, _context),
    do: refused("invalid_arguments", "the arguments of #{action} are missing or invalid.")

  # --- notify --------------------------------------------------------------

  defp not_offered(opts) do
    case Notifications.resolve(opts) do
      {:error, sentence} -> refused("not_offered", sentence <> ".")
      {:ok, _resolution} -> refused("not_offered", "this build shows no notifications.")
    end
  end

  defp notify_sentence(:backend_missing), do: "busctl is not installed on this computer."
  defp notify_sentence(:no_server), do: "no notification server runs in this session."
  defp notify_sentence(:host_unavailable), do: "the Fermix app is not running."

  defp notify_sentence(:not_authorized),
    do: "the Fermix app is not allowed to show notifications (System Settings > Notifications)."

  defp notify_sentence(:timeout), do: "the notification service did not answer in time."

  defp notify_sentence({:failed, evidence}),
    do: "the notification service refused it: #{evidence}"

  # --- open_url ------------------------------------------------------------

  defp web_url(url) do
    with true <- byte_size(url) <= @max_url_bytes,
         false <- String.match?(url, ~r/[\s\x00-\x1f\x7f]/),
         {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] <- URI.new(url),
         true <- is_binary(host) and host != "" do
      :ok
    else
      _not_web -> refused("not_a_web_url", "only an http or https web address is opened here.")
    end
  end

  # One configuration per system: through the disclaim shim on macOS (a
  # missing shim refuses; there is no undisclaimed spawn), xdg-open on Linux.
  defp opener(url, context) do
    case Map.get_lazy(context, :os_type, &:os.type/0) do
      {:unix, :darwin} ->
        mac_opener(url, Map.get_lazy(context, :shim_path, &shim_path/0))

      {:unix, :linux} ->
        linux_opener(url, Map.get(context, :find_executable, &System.find_executable/1))

      other ->
        refused("no_opener", "this computer's system (#{inspect(other)}) has no opener.")
    end
  end

  defp mac_opener(_url, nil) do
    refused(
      "no_opener",
      "Fermix's macOS disclaim shim is not built on this computer; rebuild or reinstall Fermix."
    )
  end

  defp mac_opener(url, shim), do: {:ok, {shim, [@mac_opener, url]}}

  defp linux_opener(url, find) do
    case find.("xdg-open") do
      nil -> refused("no_opener", "xdg-open is not installed on this computer.")
      path -> {:ok, {path, [url]}}
    end
  end

  defp shim_path do
    path = Application.app_dir(:fermix_nif, "priv/disclaim")
    if File.regular?(path), do: path, else: nil
  end

  defp opener_sentence(code, out),
    do: "the opener exited #{code}: #{out |> String.trim() |> String.slice(0, 300)}"

  # --- files ---------------------------------------------------------------

  # The sandbox's own read scope, and the folders the owner granted the
  # primary to read here; its protected paths stay closed inside both.
  defp readable(path, operation, context) do
    with {:ok, scope} <- read_scope(context) do
      case Sandbox.read_path(expand_home(path), operation, scope) do
        {:ok, resolved} -> {:ok, resolved}
        {:error, reason} -> sandbox_refusal(reason)
      end
    end
  end

  defp read_scope(context) do
    case ReadGrants.folders(home(context)) do
      {:ok, folders} ->
        config = sandbox_config(context)
        granted = %{config | allowed_roots: Enum.uniq(config.allowed_roots ++ folders)}
        {:ok, Map.put(sandbox_context(context), :sandbox_config, granted)}

      {:error, reason} ->
        failed("read_grants", "this computer's read grants could not be read: #{inspect(reason)}")
    end
  end

  # Copied in bounded pieces while it is hashed, so the hash names exactly the
  # bytes that are sent, and a file that grew past the bound since it was
  # measured is refused rather than read on.
  defp stage_copy(source, context) do
    staged = Path.join(Map.fetch!(context, :send_staging), Map.fetch!(context, :invocation_id))
    max = Map.fetch!(context, :max_media_bytes)

    result =
      with {:ok, {copied, hash}} <- open_copy(source, staged, max) do
        {:ok, staged, copied, hash}
      end

    unless match?({:ok, _staged, _copied, _hash}, result), do: _ = File.rm(staged)
    result
  end

  defp open_copy(source, staged, max) do
    case File.open(source, [:read, :binary], fn input -> write_copy(input, staged, max) end) do
      {:ok, {:ok, _copied_hash} = done} -> done
      {:ok, refusal} -> refusal
      {:error, reason} -> failed("unreadable", "#{source}: #{:file.format_error(reason)}.")
    end
  end

  defp write_copy(input, staged, max) do
    with :ok <- File.write(staged, <<>>),
         :ok <- File.chmod(staged, 0o600),
         {:ok, result} <-
           File.open(staged, [:write, :binary], &copy_pieces(input, &1, 0, hash_init(), max)) do
      result
    else
      {:error, reason} ->
        failed("not_staged", "the file could not be staged to send: #{inspect(reason)}")
    end
  end

  defp copy_pieces(input, output, copied, hash, max) do
    case IO.binread(input, @copy_chunk_bytes) do
      :eof ->
        {:ok, {copied, hash |> :crypto.hash_final() |> Base.encode16(case: :lower)}}

      {:error, reason} ->
        failed("unreadable", "the file could not be read: #{inspect(reason)}")

      bytes when copied + byte_size(bytes) > max ->
        refused("too_large", "the file grew past the #{max}-byte limit while it was read.")

      bytes ->
        :ok = IO.binwrite(output, bytes)

        copy_pieces(
          input,
          output,
          copied + byte_size(bytes),
          :crypto.hash_update(hash, bytes),
          max
        )
    end
  end

  defp hash_init, do: :crypto.hash_init(:sha256)

  # --- grant_read ----------------------------------------------------------

  # A folder this machine's sandbox would let be granted at all: never `/`, the
  # home folder itself, Fermix's home or a protected path.
  defp grantable(path, context) do
    case Path.type(path) do
      :absolute -> unsafe_check(path, context)
      _relative -> refused("invalid_arguments", "#{path} is not a full path on this computer.")
    end
  end

  defp unsafe_check(path, context) do
    case ConfigMutation.add_allowed_root(sandbox_config(context), path) do
      {:ok, _config} -> {:ok, PathPolicy.canonical_path(path)}
      {:error, {:unsafe_root, root}} -> refused("unsafe_root", unsafe_sentence(root))
    end
  end

  defp unsafe_sentence(root) do
    "#{root} is never granted on this computer (the whole disk, the home folder itself, " <>
      "Fermix's own folder or a path Fermix keeps private); grant a folder inside it."
  end

  defp record_grant(folder, context) do
    case ReadGrants.add(home(context), folder, utc_now(context)) do
      :ok ->
        :ok = announce_grant(folder, context)
        ok(%{"path" => folder})

      {:error, :too_many_grants} ->
        refused(
          "too_many_grants",
          "this computer already holds #{ReadGrants.max_grants()} read grants."
        )

      {:error, reason} ->
        failed("not_recorded", "the read grant could not be recorded: #{inspect(reason)}")
    end
  end

  defp regular_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, size}
      {:ok, %File.Stat{type: :directory}} -> refused("not_a_file", "#{path} is a folder.")
      {:ok, %File.Stat{type: type}} -> refused("not_a_file", "#{path} is a #{type}, not a file.")
      {:error, :enoent} -> failed("not_found", "there is no file at #{path}.")
      {:error, reason} -> failed("unreadable", "#{path}: #{:file.format_error(reason)}.")
    end
  end

  defp directory(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{}} -> refused("not_a_folder", "#{path} is not a folder.")
      {:error, :enoent} -> failed("not_found", "there is no folder at #{path}.")
      {:error, reason} -> failed("unreadable", "#{path}: #{:file.format_error(reason)}.")
    end
  end

  defp within_media(size, context) do
    max = Map.fetch!(context, :max_media_bytes)

    if size <= max,
      do: :ok,
      else: refused("too_large", "the file is #{size} bytes, over the #{max}-byte limit.")
  end

  defp list(path) do
    case File.ls(path) do
      {:ok, names} -> {:ok, names}
      {:error, reason} -> failed("unreadable", "#{path}: #{:file.format_error(reason)}.")
    end
  end

  # An entry as it is, never following a link.
  defp entry(dir, name) do
    case File.lstat(Path.join(dir, name)) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        %{"name" => name, "type" => "file", "size_bytes" => size}

      {:ok, %File.Stat{type: :directory}} ->
        %{"name" => name, "type" => "directory"}

      {:ok, %File.Stat{type: :symlink}} ->
        %{"name" => name, "type" => "link"}

      {:ok, %File.Stat{}} ->
        %{"name" => name, "type" => "other"}

      {:error, _reason} ->
        %{"name" => name, "type" => "unreadable"}
    end
  end

  # `~` is this computer's home: the path is the owner's own words about it.
  defp expand_home("~"), do: Path.expand("~")
  defp expand_home("~/" <> _rest = path), do: Path.expand(path)
  defp expand_home(path), do: path

  defp optional_path(args, key) do
    case Map.get(args, key) do
      nil -> {:ok, nil}
      path when is_binary(path) and path != "" -> {:ok, expand_home(path)}
      _invalid -> refused("invalid_arguments", "#{key} is not a path.")
    end
  end

  defp sandbox_refusal({:protected_path, path}) do
    refused(
      "protected_path",
      "#{path} is one Fermix keeps private on this computer, so it is never read here."
    )
  end

  defp sandbox_refusal({:outside_root, path}) do
    refused(
      "outside_sandbox",
      "#{path} is outside what Fermix may read on this computer; ask for read access to its " <>
        "folder (grant_read), which the owner approves."
    )
  end

  defp sandbox_refusal({:blocked_root, path}),
    do: refused("blocked_path", "#{path} is blocked in this computer's sandbox.")

  defp sandbox_refusal({:hardline, reason}),
    do: refused("hardline", "this computer's sandbox never runs it (#{reason}).")

  defp sandbox_refusal({:missing_working_dir, dir}),
    do: failed("not_found", "there is no folder at #{dir}.")

  defp sandbox_refusal({:os_sandbox_unavailable, sentence}),
    do: refused("os_sandbox", sentence)

  defp sandbox_refusal(reason),
    do: refused("sandbox_denied", "this computer's sandbox refused it (#{inspect(reason)}).")

  # --- commands ------------------------------------------------------------

  defp command_time(context) do
    left = Map.fetch!(context, :left_ms) - @answer_margin_ms

    if left >= @min_command_ms,
      do: {:ok, left},
      else: refused("deadline_passed", "too little of its deadline was left to run it.")
  end

  defp shell_plan(command, cwd, sandbox) do
    case Sandbox.shell_plan(command, cwd, sandbox) do
      {:ok, plan} -> {:ok, plan}
      {:error, reason} -> sandbox_refusal(reason)
    end
  end

  defp confine(command, sandbox, plan) do
    case Sandbox.confine(shell(), ["-c", command], sandbox, plan.roots) do
      {:ok, spawn} -> {:ok, spawn}
      {:error, reason} -> sandbox_refusal(reason)
    end
  end

  defp shell, do: System.find_executable("sh") || "/bin/sh"

  # A command the server runs here is shown on this computer as it starts, and
  # a folder the server may now read here the moment its grant is recorded. A
  # notification that cannot be shown is logged: the owner approved the action
  # on the server's card, the grant can be seen and removed here
  # (`device.grants.list`), and the action goes on.
  defp announce_command(command, context) do
    announce("Fermix on #{server(context)} is running a command here", command, context)
  end

  defp announce_grant(folder, context) do
    announce(
      "Fermix on #{server(context)} can now read a folder here",
      "#{folder}. If you did not allow this, remove it in Fermix on this computer.",
      context
    )
  end

  defp server(context), do: Map.get(context, :primary_name) || "your server"

  defp announce(title, body, context) do
    opts = Map.get(context, :notifications, [])
    note = %{title: title, body: String.slice(body, 0, @max_body_bytes), sound: false}

    case Notifications.post(note, opts) do
      {:ok, _id} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "desktop executor: the notification for invocation " <>
            "#{Map.get(context, :invocation_id)} was not shown: #{inspect(reason)}"
        )
    end
  end

  defp run_shell({executable, args}, plan, timeout_ms, context) do
    opts = [
      cwd: plan.working_dir,
      timeout_ms: timeout_ms,
      env: plan.env,
      env_mode: :replace,
      max_output_bytes: @max_output_bytes
    ]

    case run_fun(context).(executable, args, opts) do
      {:ok, %{truncated?: true, stdout: out}} ->
        output_too_long(out, plan)

      {:ok, %{exit: 0} = run} ->
        ok(command_result(run, plan))

      {:ok, %{exit: code, stdout: out} = run} ->
        exited(code, out, command_result(run, plan))

      {:error, {:timeout, ms}} ->
        failed("timeout", "the command did not finish within #{ms} ms and was stopped.")

      {:error, reason} ->
        failed("not_run", "the command could not start: #{inspect(reason)}")
    end
  end

  # The runner stops a command at the output bound, so it never finished: its
  # first 64 KiB go back, and it is not reported as having exited.
  defp output_too_long(out, plan) do
    {:failed,
     %{
       "reason" => "output_too_long",
       "message" => "the command printed more than 64 KiB and was stopped there.",
       "output" => redact(out, plan.redact_values),
       "truncated" => true
     }, nil}
  end

  # `sandbox-exec` (or the Landlock shim) failing to start the command is not
  # the command failing.
  defp exited(code, out, result) do
    case OsSandbox.refusal(code, out) do
      nil ->
        {:failed,
         Map.merge(result, %{
           "reason" => "exit_nonzero",
           "message" => "the command exited #{code}."
         }), nil}

      sentence ->
        refused("os_sandbox", sentence)
    end
  end

  # The allowed variables' values are scrubbed from the output before it leaves
  # this machine, as the shell tool scrubs them before the model reads them.
  defp command_result(%{exit: code, stdout: out} = run, plan) do
    %{
      "exit_code" => code,
      "output" => redact(out, plan.redact_values),
      "truncated" => Map.get(run, :truncated?, false)
    }
  end

  defp redact(text, []), do: text
  defp redact(text, values), do: ToolTelemetry.redact(text, values)

  defp sandbox_context(context) do
    %{
      agent_name: "desktop_executor",
      conversation_key: {:desktop_invocation, Map.get(context, :invocation_id)},
      cwd: nil
    }
    |> Map.merge(Map.take(context, [:sandbox_config, :os_sandbox]))
  end

  defp run_fun(context), do: Map.get(context, :run, &CommandRunner.run/3)

  defp sandbox_config(context),
    do: SandboxConfig.normalize(Map.get_lazy(context, :sandbox_config, &SandboxConfig.current/0))

  defp home(context), do: Map.get_lazy(context, :home, &ConfigStore.fermix_home/0)
  defp utc_now(context), do: Map.get(context, :utc_now, &DateTime.utc_now/0).()

  # --- answers and receipts -------------------------------------------------

  defp ok(result, blob \\ nil), do: {:ok, result, blob}
  defp failed(reason, message), do: {:failed, %{"reason" => reason, "message" => message}, nil}

  defp refused(reason, message),
    do: {:refused, %{"reason" => reason, "message" => message}, nil}

  defp reason_note(%{"reason" => reason}), do: ": " <> reason
  defp reason_note(_result), do: ""

  defp record(id, action, status, payload, result, context) do
    receipt = %{
      "invocation_id" => id,
      "action" => action,
      "status" => Atom.to_string(status),
      "finished_at" => finished_at(context),
      "args_sha256" => sha256(payload),
      "result_sha256" => sha256(Jason.encode!(result))
    }

    case Receipts.record(Map.fetch!(context, :receipts), receipt) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "desktop executor: no receipt written for #{id} (#{inspect(reason)}); the primary " <>
            "will report it uncertain if its result is lost"
        )

        :ok
    end
  end

  defp finished_at(context) do
    context
    |> Map.get(:utc_now, &DateTime.utc_now/0)
    |> then(& &1.())
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
