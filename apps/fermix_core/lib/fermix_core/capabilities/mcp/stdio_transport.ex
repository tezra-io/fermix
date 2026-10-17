defmodule FermixCore.Capabilities.MCP.StdioTransport do
  @moduledoc """
  Fermix's stdio transport for an operator MCP server (M74 E3): the process
  that owns the server's program and the port it talks over, passed to
  `Anubis.Client` as its `layer` in place of `Anubis.Transport.STDIO`.

  **Secrets.** The spec it is started with names the values a server declares
  and never carries one. The values (`env_secrets` through
  `Capabilities.MCP.Secrets`, `pass_env` through `[sandbox.env]`) are read here,
  after `init/1`, put in the program's environment and dropped: they are in no
  child spec, in no state this process keeps, in no log line, and
  `format_status/1` prints only the fields below. Reading them after `init/1`
  keeps a slow Keychain from holding the MCP supervisor's start, as
  `Remote.Owner` connects after its own.

  **Environment.** `Port.open`'s `env:` extends the daemon's environment, so
  every inherited name is unset except the base the MCP SDKs' stdio clients
  pass (`HOME`, `LOGNAME`, `SHELL`, `TERM`, `USER`), `PATH` is the owner's login
  shell's (`LoginPath`), and the declared names are added on top: literal `env`,
  `pass_env`, `env_secrets`, one declaration per name (`MCP.Config`). The
  program is the absolute path `LoginPath.resolve/3` answers, run in `cwd`.

  **Stderr.** A port gives one stream back, and stdout is the protocol's, so
  the program is started by `/bin/sh` with its stderr appended to a file of its
  own under the logs folder, emptied at each start. That shell sets `PWD` and
  `SHLVL` for the program as it starts it. Every 30 s the file's size is
  checked; past 1 MB its last lines are carried in this process and the file
  is emptied, so a server that talks for days holds the disk to about that
  size. When the program exits, the carry and what the file holds then,
  bounded in lines and bytes, go into its status.

  **Status.** This process holds the program, so it is the source's
  `RuntimeStatus` owner, as `Remote.Owner` is for a remote source: registering
  writes `connecting`, and it writes the terminal classes only it can see (a
  program not found, a missing folder, a variable it could not read, the
  program's exit with its last lines). `MCP.Server` pins this generation and
  writes `ready` with the tool count, or `retries_exhausted`.

  A start that cannot run the program ends `:normal`, which is terminal for the
  subtree; the program exiting ends it abnormally, so the subtree starts it
  again within its restart budget, and the last exit is what stays visible.
  """

  @behaviour Anubis.Transport
  @behaviour Anubis.Transport.Behaviour

  use GenServer

  require Logger

  alias Anubis.Transport.STDIO
  alias FermixCore.Capabilities.MCP.LoginPath
  alias FermixCore.Capabilities.MCP.RuntimeStatus
  alias FermixCore.Capabilities.MCP.Secrets, as: McpSecrets
  alias FermixCore.CommandRunner
  alias FermixCore.ProcessGroup
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Sandbox.Env, as: SandboxEnv
  alias FermixCore.Setup.ConfigStore

  @base_env ~w(HOME LOGNAME SHELL TERM USER)
  @shell "/bin/sh"
  # Appended, so emptying the file under a running program leaves its next
  # write at the new end instead of at the old offset.
  @launch ~s(stderr_file=$1; shift; exec "$@" 2>>"$stderr_file")
  @tail_bytes 4_096
  @tail_lines 20
  @stop_grace_ms 2_000
  @stderr_check_ms 30_000
  @stderr_cap_bytes 1_048_576

  @typedoc "What the transport needs of the server's spec: names and the command, no value."
  @type spec :: %{
          required(:source_id) => RuntimeStatus.source_id(),
          required(:name) => String.t(),
          required(:command) => String.t(),
          required(:args) => [String.t()],
          required(:cwd) => String.t() | nil,
          required(:env) => %{String.t() => String.t()},
          required(:env_secrets) => [String.t()],
          required(:pass_env) => [String.t()]
        }

  @type opt ::
          {:name, GenServer.name()}
          | {:client, GenServer.server()}
          | {:spec, spec()}
          | {:runtime_status, GenServer.server() | nil}
          | {:login_path, GenServer.server()}
          | {:stderr_dir, Path.t()}
          # Test seams for the stderr bound; the daemon keeps the defaults.
          | {:stderr_check_ms, pos_integer()}
          | {:stderr_cap_bytes, pos_integer()}

  # --- the line framing the client parses replies with: Anubis's own ---------

  @impl Anubis.Transport
  defdelegate transport_init(opts \\ []), to: STDIO

  @impl Anubis.Transport
  defdelegate parse(raw, state), to: STDIO

  @impl Anubis.Transport
  defdelegate encode(message, state), to: STDIO

  @impl Anubis.Transport
  defdelegate extract_metadata(raw, state), to: STDIO

  # --- Anubis.Transport.Behaviour -------------------------------------------

  @impl Anubis.Transport.Behaviour
  @spec start_link([opt()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @impl Anubis.Transport.Behaviour
  def send_message(transport, message, opts) when is_binary(message) and is_list(opts) do
    GenServer.call(transport, {:send, message}, Keyword.get(opts, :timeout, 5_000))
  end

  @impl Anubis.Transport.Behaviour
  def shutdown(transport), do: GenServer.cast(transport, :close)

  @impl Anubis.Transport.Behaviour
  def supported_protocol_versions, do: :all

  @doc """
  The last lines of the stderr file at `path`: read from its last
  #{@tail_bytes} bytes, the first line dropped when the read began inside it,
  blank lines left out, invalid UTF-8 replaced, at most #{@tail_lines} lines.
  A file that cannot be read has no lines, and says why in the log.
  """
  @spec tail(Path.t()) :: [String.t()]
  def tail(path) when is_binary(path) do
    case read_end(path) do
      {:ok, bytes, whole?} ->
        last_lines(bytes, whole?)

      {:error, reason} ->
        Logger.warning("MCP server stderr at #{path} could not be read: #{inspect(reason)}")
        []
    end
  end

  defp read_end(path) do
    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
      offset = max(size - @tail_bytes, 0)

      try do
        read_from(file, offset)
      after
        File.close(file)
      end
    end
  end

  defp read_from(file, offset) do
    case :file.pread(file, offset, @tail_bytes) do
      {:ok, bytes} -> {:ok, bytes, offset == 0}
      :eof -> {:ok, "", true}
      {:error, reason} -> {:error, reason}
    end
  end

  defp last_lines(bytes, whole?) do
    lines = String.split(bytes, ["\r\n", "\n"])
    lines = if whole?, do: lines, else: Enum.drop(lines, 1)

    lines
    |> Enum.map(&(&1 |> String.replace_invalid() |> String.trim_trailing()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(-@tail_lines)
  end

  # --- GenServer -------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    # Trapped so `terminate/2` runs on the supervisor's shutdown and ends the
    # program with the process that owns it.
    Process.flag(:trap_exit, true)

    spec = Keyword.fetch!(opts, :spec)
    {kind, name} = Map.fetch!(spec, :source_id)
    runtime_status = Keyword.get(opts, :runtime_status)
    stderr_dir = Keyword.get_lazy(opts, :stderr_dir, &default_stderr_dir/0)

    state = %{
      source_id: {kind, name},
      client: Keyword.fetch!(opts, :client),
      runtime_status: runtime_status,
      generation: register(runtime_status, {kind, name}),
      login_path: Keyword.get(opts, :login_path, LoginPath),
      stderr_file: Path.join(stderr_dir, "#{kind}-#{name}.stderr"),
      stderr_carry: [],
      stderr_check_ms: Keyword.get(opts, :stderr_check_ms, @stderr_check_ms),
      stderr_cap_bytes: Keyword.get(opts, :stderr_cap_bytes, @stderr_cap_bytes),
      port: nil,
      os_pid: nil
    }

    {:ok, state, {:continue, {:start, spec}}}
  end

  defp default_stderr_dir, do: Path.join(ConfigStore.workspace_paths().logs, "mcp")

  defp register(nil, _source_id), do: nil

  defp register(server, source_id) do
    {:ok, generation} = RuntimeStatus.register_owner(server, source_id, self())
    generation
  end

  @impl GenServer
  def handle_continue({:start, spec}, state) do
    with {:ok, program} <- LoginPath.resolve(state.login_path, spec.command, spec.cwd),
         :ok <- folder(spec.cwd),
         {:ok, env} <- environment(spec, state.login_path),
         {:ok, port} <- open(program, spec, env, state.stderr_file) do
      GenServer.cast(state.client, :initialize)
      :ok = check_stderr_later(state)
      {:noreply, %{state | port: port, os_pid: os_pid(port)}}
    else
      {:error, reason} -> refuse(state, reason)
    end
  end

  @impl GenServer
  def handle_call({:send, message}, _from, %{port: port} = state) when is_port(port) do
    {:reply, command(port, message), state}
  end

  def handle_call({:send, _message}, _from, state) do
    {:reply, {:error, :port_not_connected}, state}
  end

  # `MCP.Supervisor.stop_server/3` asks a source's owner for an orderly stop
  # before it terminates the subtree. For a program that is ending it, so the
  # exit that follows is not mistaken for a crash.
  def handle_call(:teardown, _from, state), do: {:reply, :ok, stop_program(state)}

  # The client closes its transport as it ends, and whatever ends the client
  # ends this subtree: the program stops here and this process is left to its
  # supervisor. Ending `:normal` here would end the subtree instead of letting
  # it restart the client.
  @impl GenServer
  def handle_cast(:close, state), do: {:noreply, stop_program(state)}

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    GenServer.cast(state.client, {:response, data})
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    lines = last_of(state.stderr_carry ++ tail(state.stderr_file))
    # What the program left behind in its group (the `node` an `npx` started).
    signal(state.os_pid, :sigkill)
    _ = put_exited(state, lines)
    {:stop, {:mcp_server_exited, status}, %{state | port: nil, os_pid: nil}}
  end

  def handle_info(:check_stderr, %{port: nil} = state), do: {:noreply, state}

  def handle_info(:check_stderr, state) do
    state = bound_stderr(state)
    :ok = check_stderr_later(state)
    {:noreply, state}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    {:stop, {:mcp_port_closed, class(reason)}, %{state | port: nil, os_pid: nil}}
  end

  # What a program this process already ended still had in flight.
  def handle_info({port, _message}, state) when is_port(port), do: {:noreply, state}
  def handle_info({:EXIT, port, _reason}, state) when is_port(port), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    _ = stop_program(state)
    :ok
  end

  # Only these fields print, in a crash report or `:sys.get_status/1`, and a
  # message is printed as its kind: a request carries a tool's arguments and a
  # port message the program's output.
  @impl GenServer
  def format_status(status) do
    status
    |> Map.replace_lazy(:state, &printable/1)
    |> Map.replace_lazy(:message, &kind/1)
  end

  defp printable(state) when is_map(state) do
    Map.take(state, [:source_id, :client, :os_pid, :stderr_file])
  end

  defp printable(_state), do: :redacted

  defp kind(message) when is_tuple(message) and tuple_size(message) > 0 do
    case elem(message, 0) do
      tag when is_atom(tag) -> tag
      _port_or_pid -> :message
    end
  end

  defp kind(message) when is_atom(message), do: message
  defp kind(_message), do: :message

  # --- starting --------------------------------------------------------------

  defp folder(nil), do: :ok

  defp folder(cwd) do
    if File.dir?(cwd), do: :ok, else: {:error, {:cwd_not_found, cwd}}
  end

  defp environment(spec, login_path) do
    with {:ok, passed} <- passed(spec.pass_env),
         {:ok, secrets} <- secrets(spec) do
      base = System.get_env() |> Map.take(@base_env) |> Map.reject(&function_value?/1)

      {:ok,
       base
       |> Map.put("PATH", LoginPath.path(login_path))
       |> Map.merge(passed)
       |> Map.merge(spec.env)
       |> Map.merge(secrets)}
    end
  end

  # A shell function exported into the daemon's environment is not passed on,
  # as the SDKs' own stdio clients refuse it.
  defp function_value?({_name, value}), do: String.starts_with?(value, "()")

  defp passed([]), do: {:ok, %{}}

  defp passed(names) do
    case SandboxEnv.build_command(SandboxConfig.current(), names) do
      {:ok, env} ->
        {:ok, env |> Map.new() |> Map.take(names)}

      {:error, reason} ->
        Logger.warning("MCP pass_env: #{SandboxEnv.format_error(reason)}")
        {:error, {:env_unavailable, :pass_env}}
    end
  end

  defp secrets(spec) do
    Enum.reduce_while(spec.env_secrets, {:ok, %{}}, fn var, {:ok, acc} ->
      case McpSecrets.fetch(spec.name, {:env, var}) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, var, value)}}
        {:error, _reason} -> {:halt, {:error, {:env_unavailable, var}}}
      end
    end)
  end

  # The port is opened here and only here. A failed open raises with its
  # arguments in the stack trace, the environment among them, so the failure
  # is returned as its class instead.
  defp open(program, spec, env, stderr_file) do
    :ok = empty_file(stderr_file)

    options =
      [
        :binary,
        :exit_status,
        :hide,
        args: ["-c", @launch, "fermix-mcp", stderr_file, program | spec.args],
        env: CommandRunner.replacement_env(Map.to_list(env))
      ] ++ cd(spec.cwd)

    {:ok, Port.open({:spawn_executable, @shell}, options)}
  rescue
    error in [ArgumentError, ErlangError] -> {:error, {:spawn_failed, spawn_class(error)}}
  end

  defp spawn_class(%ErlangError{original: original}) when is_atom(original), do: original
  defp spawn_class(_error), do: :badarg

  defp cd(nil), do: []
  defp cd(cwd), do: [cd: String.to_charlist(cwd)]

  # Emptied at each start, and readable by the owner alone: what a program
  # prints there is its own business.
  defp empty_file(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
    File.chmod!(path, 0o600)
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  end

  # A program that exits between a request and its write closes the port under
  # it; the exit already waiting in the mailbox is what the status reports.
  defp command(port, message) do
    true = Port.command(port, message)
    :ok
  rescue
    ArgumentError -> {:error, :port_closed}
  end

  # Every reason here names a program, a folder or a variable, never a value.
  defp refuse(state, reason) do
    {status, detail, _subject} = RuntimeStatus.classify(reason)
    _ = put(state, status, detail)
    Logger.warning("MCP server #{inspect(state.source_id)} did not start: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  # --- the stderr bound --------------------------------------------------------

  defp check_stderr_later(state) do
    _timer = Process.send_after(self(), :check_stderr, state.stderr_check_ms)
    :ok
  end

  # Past the cap, the file's last lines move into the carry and the file is
  # emptied. A line written between the read and the emptying is lost, which
  # the exit sentence can spare: it holds the last lines, not every line.
  defp bound_stderr(state) do
    case File.stat(state.stderr_file) do
      {:ok, %File.Stat{size: size}} when size > state.stderr_cap_bytes ->
        carry = last_of(state.stderr_carry ++ tail(state.stderr_file))
        :ok = empty_stderr(state.stderr_file)
        %{state | stderr_carry: carry}

      {:ok, %File.Stat{}} ->
        state

      {:error, reason} ->
        Logger.warning(
          "MCP server stderr at #{state.stderr_file} is unreadable: #{inspect(reason)}"
        )

        state
    end
  end

  defp empty_stderr(path) do
    case File.write(path, "") do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("MCP server stderr at #{path} could not be emptied: #{inspect(reason)}")
        :ok
    end
  end

  # The exit sentence's bound, over the carry and the file together: the last
  # `@tail_lines` lines, and of those the last that fit in `@tail_bytes` bytes.
  defp last_of(lines), do: lines |> Enum.take(-@tail_lines) |> within_bytes()

  defp within_bytes([_dropped | rest] = lines) do
    if Enum.sum_by(lines, &byte_size/1) > @tail_bytes, do: within_bytes(rest), else: lines
  end

  defp within_bytes([]), do: []

  # --- ending ----------------------------------------------------------------

  # TERM to the program's process group (an `npx` and the `node` it started),
  # then KILL once the grace is spent. The port's child leads its own group.
  defp stop_program(%{port: nil} = state), do: state

  defp stop_program(%{port: port, os_pid: os_pid} = state) do
    signal(os_pid, :sigterm)

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      @stop_grace_ms -> signal(os_pid, :sigkill)
    end

    if Port.info(port) != nil, do: Port.close(port)
    %{state | port: nil, os_pid: nil}
  end

  defp signal(nil, _signal), do: :ok
  defp signal(os_pid, signal), do: ProcessGroup.signal(os_pid, signal)

  defp class(reason) when is_atom(reason), do: reason
  defp class(reason) when is_tuple(reason) and is_atom(elem(reason, 0)), do: elem(reason, 0)
  defp class(_reason), do: :unclassified

  # --- status ----------------------------------------------------------------

  defp put(%{generation: nil}, _status, _detail), do: :no_status_sink

  defp put(state, status, detail) do
    RuntimeStatus.put(state.runtime_status, state.source_id, state.generation, status, detail)
  end

  defp put_exited(%{generation: nil}, _lines), do: :no_status_sink

  defp put_exited(state, lines) do
    RuntimeStatus.put_exited(state.runtime_status, state.source_id, state.generation, lines)
  end
end
