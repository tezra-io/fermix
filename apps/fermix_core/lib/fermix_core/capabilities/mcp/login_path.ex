defmodule FermixCore.Capabilities.MCP.LoginPath do
  @moduledoc """
  The `PATH` of every operator stdio MCP server, and the one resolver of the
  program a server's `command` names (M74 E3).

  The daemon's own `PATH` is launchd's baseline plus `Boot.PathBaseline`, which
  holds Homebrew's folder but none of what an owner's shell adds: an nvm, fnm,
  asdf or mise `node`, a `uv` in `~/.cargo/bin`. `npx` is `#!/usr/bin/env node`,
  so finding `npx` is not enough either: the server finds `node` through its
  own `PATH`. So the `PATH` the owner's interactive login shell sets is read
  once per daemon start, the first time a server needs it, and every operator
  stdio server runs with it.

  If the shell cannot be read (no `SHELL`, a timeout, no `PATH` in what it
  printed), one warning says why and the daemon's own `PATH` is used: that is
  what really exists, and a program it cannot find is reported as not found,
  which tells the owner to give the full path.

  `config.toml` keeps the command as typed. `resolve/3` turns it into the
  absolute program at every start, so a Node or uv upgrade that moves the
  program does not break the server. A command without a slash is looked up on
  this `PATH`; one with a slash is a path, read relative to the server's `cwd`,
  else the home folder.

  The shell is read in a task of its own, so the owner keeps answering while
  it runs: a start waits for the `PATH` (`path/1`, `resolve/3`), and a row
  never does. `known/3` resolves from the `PATH` already read and answers `nil`
  for a command without a slash before the first reading finishes, so a list
  of servers never waits up to the shell's time limit. A draft is the moment
  the owner adds a local server, so `await_read/1` starts the reading and waits
  for it, but only briefly: a draft answers well inside a client's request
  budget, and the next draft finds the `PATH` read.

  The reading is injected (`:read`), and a test shortens a draft's wait
  (`:draft_wait_ms`); the daemon's reading comes from
  `config :fermix_core, :mcp_login_shell` (default `LoginPath.Shell`), so a
  test never runs the real login shell.
  """

  use GenServer

  require Logger

  @callback read() :: {:ok, String.t()} | {:error, term()}

  # How long a draft waits for the first reading before it answers without it.
  @draft_wait_ms 3_000

  @type resolution :: {:ok, Path.t()} | {:error, {:command_not_found, String.t()}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  The `PATH` an operator stdio server runs with, read from the login shell the
  first time it is asked for, which then waits for the reading.
  """
  @spec path(GenServer.server()) :: String.t()
  def path(server) do
    GenServer.call(server, :path, __MODULE__.Shell.timeout_ms() + 5_000)
  end

  @doc """
  The absolute program `command` names, or `{:error, {:command_not_found,
  command}}`. `cwd` is the server's working folder, or `nil`.
  """
  @spec resolve(GenServer.server(), String.t(), String.t() | nil) :: resolution()
  def resolve(server, command, cwd)
      when is_binary(command) and command != "" and (is_binary(cwd) or is_nil(cwd)) do
    found =
      if String.contains?(command, "/"),
        do: find_path(command, cwd),
        else: find_on(command, path(server))

    resolution(command, found)
  end

  @doc """
  What `resolve/3` answers, without waiting for the login shell: a command
  with a slash is resolved as `resolve/3` resolves it, one without only on a
  `PATH` already read, and `nil` before then. It never starts the reading.
  """
  @spec known(GenServer.server(), String.t(), String.t() | nil) :: resolution() | nil
  def known(server, command, cwd)
      when is_binary(command) and command != "" and (is_binary(cwd) or is_nil(cwd)) do
    if String.contains?(command, "/"),
      do: resolution(command, find_path(command, cwd)),
      else: known_on(command, GenServer.call(server, :known_path))
  end

  @doc """
  Starts reading the login shell's `PATH` if no reading has run, and waits for
  it at most #{@draft_wait_ms} ms: `:ok` once the `PATH` is read, `:timeout`
  past the wait, the reading going on. A draft asks once, then resolves each of
  its commands with `known/3`, so a paste of many servers waits once.
  """
  @spec await_read(GenServer.server()) :: :ok | :timeout
  def await_read(server), do: GenServer.call(server, :await_read)

  defp known_on(_command, nil), do: nil
  defp known_on(command, path), do: resolution(command, find_on(command, path))

  defp resolution(command, nil), do: {:error, {:command_not_found, command}}
  defp resolution(_command, program), do: {:ok, program}

  defp find_path(command, cwd) do
    command
    |> Path.expand(cwd || System.user_home!())
    |> String.to_charlist()
    |> :os.find_executable()
    |> found()
  end

  defp find_on(command, path) do
    command
    |> String.to_charlist()
    |> :os.find_executable(String.to_charlist(path))
    |> found()
  end

  defp found(false), do: nil
  defp found(program), do: List.to_string(program)

  @impl true
  def init(opts) do
    read = Keyword.get_lazy(opts, :read, &configured_read/0)
    draft_wait_ms = Keyword.get(opts, :draft_wait_ms, @draft_wait_ms)
    {:ok, %{read: read, draft_wait_ms: draft_wait_ms, path: nil, reading: nil, waiting: []}}
  end

  defp configured_read do
    module = Application.get_env(:fermix_core, :mcp_login_shell, __MODULE__.Shell)
    &module.read/0
  end

  @impl true
  def handle_call(:path, from, %{path: nil} = state),
    do: {:noreply, await_reading(state, {:path, from})}

  def handle_call(:path, _from, state), do: {:reply, state.path, state}
  def handle_call(:known_path, _from, state), do: {:reply, state.path, state}

  def handle_call(:await_read, from, %{path: nil} = state) do
    Process.send_after(self(), {:waited, from}, state.draft_wait_ms)
    {:noreply, await_reading(state, {:read, from})}
  end

  def handle_call(:await_read, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({ref, path}, %{reading: ref} = state) do
    Process.demonitor(ref, [:flush])
    Enum.each(state.waiting, &answer(&1, path))
    {:noreply, %{state | path: path, reading: nil, waiting: []}}
  end

  # A draft's wait ended before the reading did: it answers without the PATH,
  # and the reading goes on for the next caller.
  def handle_info({:waited, from}, state) do
    if {:read, from} in state.waiting do
      GenServer.reply(from, :timeout)
      {:noreply, %{state | waiting: List.delete(state.waiting, {:read, from})}}
    else
      {:noreply, state}
    end
  end

  # The first caller starts the one reading; every caller until it finishes
  # waits for the same answer. The task is linked, as the reading inside a
  # call was: a reading that crashes takes the owner with it, and its
  # supervisor starts a fresh one.
  defp await_reading(%{reading: nil} = state, waiter) do
    task = Task.async(fn -> read_once(state.read) end)
    %{state | reading: task.ref, waiting: [waiter]}
  end

  defp await_reading(state, waiter), do: %{state | waiting: [waiter | state.waiting]}

  defp answer({:path, from}, path), do: GenServer.reply(from, path)
  defp answer({:read, from}, _path), do: GenServer.reply(from, :ok)

  defp read_once(read) do
    case read.() do
      {:ok, path} ->
        path

      {:error, reason} ->
        Logger.warning(
          "MCP servers run with the daemon's PATH: the login shell's PATH could not be " <>
            "read (#{inspect(reason)})"
        )

        System.get_env("PATH", "")
    end
  end
end

defmodule FermixCore.Capabilities.MCP.LoginPath.Shell do
  @moduledoc """
  Reads the `PATH` the owner's login shell sets: `$SHELL -ilc`, interactive
  because nvm-style setups live in `.zshrc`, with the value printed between two
  markers so a banner or a prompt the rc files print around it is not taken
  for it, inside a time limit.

  `read/1` takes `:run` (`fn shell, args -> {:ok, output} | {:error, reason}
  end`) and `:shell` for tests; the daemon's runs the shell through
  `CommandRunner`, which kills it at the limit.
  """

  @behaviour FermixCore.Capabilities.MCP.LoginPath

  alias FermixCore.CommandRunner

  @marker "__FERMIX_LOGIN_PATH__"
  @timeout_ms 10_000

  @doc "How long the login shell may take."
  @spec timeout_ms() :: pos_integer()
  def timeout_ms, do: @timeout_ms

  @impl true
  def read, do: read([])

  @spec read(keyword()) :: {:ok, String.t()} | {:error, term()}
  def read(opts) when is_list(opts) do
    run = Keyword.get(opts, :run, &run/2)
    shell = Keyword.get_lazy(opts, :shell, fn -> System.get_env("SHELL") end)
    script = ~s(printf '%s' "#{@marker}$PATH#{@marker}")

    with :ok <- absolute(shell),
         {:ok, output} <- run.(shell, ["-ilc", script]) do
      marked(output)
    end
  end

  defp absolute(shell) when is_binary(shell) do
    if Path.type(shell) == :absolute, do: :ok, else: {:error, {:shell_not_absolute, shell}}
  end

  defp absolute(nil), do: {:error, :no_shell}

  # The value is what sits between the two markers; what the rc files print
  # before or after it is not.
  defp marked(output) do
    case String.split(output, @marker) do
      [_before, path, _after] when path != "" -> {:ok, path}
      _no_value -> {:error, :no_path_printed}
    end
  end

  defp run(shell, args) do
    case CommandRunner.run(shell, args, timeout_ms: @timeout_ms) do
      {:ok, %{stdout: output}} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end
end
