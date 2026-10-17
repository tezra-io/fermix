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
  absolute program at every start, at draft time and on the row, so a Node or
  uv upgrade that moves the program does not break the server. A command
  without a slash is looked up on this `PATH`; one with a slash is a path,
  read relative to the server's `cwd`, else the home folder.

  The reading is injected (`:read`); the daemon's comes from
  `config :fermix_core, :mcp_login_shell` (default `LoginPath.Shell`), so a
  test never runs the real login shell.
  """

  use GenServer

  require Logger

  @callback read() :: {:ok, String.t()} | {:error, term()}

  @type resolution :: {:ok, Path.t()} | {:error, {:command_not_found, String.t()}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The `PATH` an operator stdio server runs with."
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

    case found do
      nil -> {:error, {:command_not_found, command}}
      program -> {:ok, program}
    end
  end

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
    {:ok, %{read: read, path: nil}}
  end

  defp configured_read do
    module = Application.get_env(:fermix_core, :mcp_login_shell, __MODULE__.Shell)
    &module.read/0
  end

  @impl true
  def handle_call(:path, _from, %{path: nil} = state) do
    path = read_once(state.read)
    {:reply, path, %{state | path: path}}
  end

  def handle_call(:path, _from, state), do: {:reply, state.path, state}

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
