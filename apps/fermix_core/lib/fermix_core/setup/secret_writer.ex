defmodule FermixCore.Setup.SecretWriter do
  @moduledoc """
  Facade for setup-managed OS secret storage.
  """

  alias FermixCore.Setup.SecretPaths

  @sentinel "@keyring"
  @type secret_key :: atom()
  @type writer_error :: {:error, term()}

  @callback put(secret_key(), String.t(), keyword()) :: :ok | writer_error()
  @callback get(secret_key(), keyword()) :: {:ok, String.t()} | writer_error()
  @callback available?(keyword()) :: boolean()
  @callback command_source(secret_key(), keyword()) :: map()

  @spec sentinel() :: String.t()
  def sentinel, do: @sentinel

  @spec put(secret_key(), String.t(), keyword()) :: :ok | writer_error()
  def put(key, value, opts \\ []) when is_atom(key) and is_binary(value) do
    impl(opts).put(key, value, opts)
  end

  @spec get(secret_key(), keyword()) :: {:ok, String.t()} | writer_error()
  def get(key, opts \\ []) when is_atom(key), do: impl(opts).get(key, opts)

  @spec get!(secret_key(), keyword()) :: String.t()
  def get!(key, opts \\ []) when is_atom(key) do
    case get(key, opts) do
      {:ok, value} -> value
      {:error, reason} -> raise ArgumentError, format_error(key, reason)
    end
  end

  @spec available?(keyword()) :: boolean()
  def available?(opts \\ []), do: impl(opts).available?(opts)

  @spec command_source(secret_key()) :: map()
  def command_source(key) when is_atom(key), do: impl([]).command_source(key, [])

  @spec command_source(secret_key(), keyword()) :: map()
  def command_source(key, opts) when is_atom(key) and is_list(opts),
    do: impl(opts).command_source(key, opts)

  @spec format_error(secret_key(), term()) :: String.t()
  def format_error(key, reason) when is_atom(key) do
    secret = SecretPaths.fetch!(key)
    "#{secret.env} could not be resolved from @keyring: #{format_reason(reason)}"
  end

  @spec format_store_error(secret_key(), term()) :: String.t()
  def format_store_error(key, reason) when is_atom(key) do
    secret = SecretPaths.fetch!(key)
    "#{secret.env} could not be stored in the OS keyring: #{format_reason(reason)}"
  end

  defp impl(opts) do
    Keyword.get(opts, :impl) ||
      Application.get_env(:fermix_core, :secret_writer, __MODULE__.Auto)
  end

  defp format_reason({:helper_timeout, command, timeout}) do
    "#{command} timed out after #{timeout}ms. Unlock your login Keychain or reconfigure the secret."
  end

  defp format_reason({:helper_failed, command, code, output}) do
    "#{command} exited #{code}: #{output}"
  end

  defp format_reason(:unavailable), do: "no supported OS secret helper is available"
  defp format_reason(reason), do: inspect(reason)
end

defmodule FermixCore.Setup.SecretWriter.Auto do
  @moduledoc false

  @behaviour FermixCore.Setup.SecretWriter

  alias FermixCore.Setup.SecretWriter

  @default_candidates [
    SecretWriter.MacOS,
    SecretWriter.SecretTool
  ]

  @impl true
  def available?(opts \\ []), do: selected(opts).available?(opts)

  @impl true
  def put(key, value, opts \\ []) when is_atom(key) and is_binary(value) do
    selected(opts).put(key, value, opts)
  end

  @impl true
  def get(key, opts \\ []) when is_atom(key), do: selected(opts).get(key, opts)

  @impl true
  def command_source(key, opts \\ []) when is_atom(key) do
    selected(opts).command_source(key, opts)
  end

  defp selected(opts) do
    opts
    |> candidates()
    |> Enum.find(SecretWriter.None, & &1.available?(opts))
  end

  defp candidates(opts) do
    Keyword.get(opts, :candidates) ||
      Application.get_env(:fermix_core, :secret_writer_candidates, @default_candidates)
  end
end

defmodule FermixCore.Setup.SecretWriter.None do
  @moduledoc """
  No-op writer returned when candidate auto-selection finds nothing available.
  Reports unavailable and refuses reads/writes so callers degrade cleanly.
  """

  @behaviour FermixCore.Setup.SecretWriter

  @impl true
  def available?(_opts \\ []), do: false

  @impl true
  def put(_key, _value, _opts \\ []), do: {:error, :unavailable}

  @impl true
  def get(_key, _opts \\ []), do: {:error, :unavailable}

  @impl true
  def command_source(_key, _opts \\ []), do: %{source: :command, command: "", args: []}
end

defmodule FermixCore.Setup.SecretWriter.SecretTool do
  @moduledoc false

  @behaviour FermixCore.Setup.SecretWriter

  alias FermixCore.CommandRunner
  alias FermixCore.Setup.SecretPaths

  @account "fermix"
  @service "fermix"
  @label "Fermix"
  @default_timeout_ms 3_000

  @impl true
  def available?(_opts \\ []), do: not is_nil(secret_tool_binary()) and not is_nil(shell_binary())

  @impl true
  def put(key, value, opts \\ []) when is_atom(key) and is_binary(value) do
    with {:ok, binary} <- fetch_secret_tool_binary(),
         {:ok, shell} <- fetch_shell_binary() do
      with_temp_secret(value, fn secret_file ->
        run_with_stdin(shell, secret_file, binary, put_args(key), timeout(opts))
      end)
    end
  end

  @impl true
  def get(key, opts \\ []) when is_atom(key) do
    with {:ok, binary} <- fetch_secret_tool_binary(),
         {:ok, output} <- run(binary, lookup_args(key), timeout(opts)) do
      output
      |> String.trim_trailing("\n")
      |> case do
        "" -> {:error, :missing_secret}
        value -> {:ok, value}
      end
    end
  end

  @impl true
  def command_source(key, _opts \\ []) when is_atom(key) do
    %{
      source: :command,
      command: secret_tool_binary() || "secret-tool",
      args: lookup_args(key),
      timeout_ms: @default_timeout_ms
    }
  end

  defp put_args(key) do
    ["store", "--label", @label | attributes(key)]
  end

  defp lookup_args(key), do: ["lookup" | attributes(key)]

  defp attributes(key) do
    secret = SecretPaths.fetch!(key)
    ["service", @service, "account", @account, "env", secret.env]
  end

  defp fetch_secret_tool_binary do
    case secret_tool_binary() do
      nil -> {:error, :unavailable}
      binary -> {:ok, binary}
    end
  end

  defp fetch_shell_binary do
    case shell_binary() do
      nil -> {:error, :unavailable}
      binary -> {:ok, binary}
    end
  end

  defp secret_tool_binary, do: System.find_executable("secret-tool")

  defp shell_binary do
    System.find_executable("sh") ||
      if File.exists?("/bin/sh"), do: "/bin/sh"
  end

  defp timeout(opts), do: Keyword.get(opts, :timeout_ms, @default_timeout_ms)

  defp with_temp_secret(value, fun) do
    case write_temp_secret(value) do
      {:ok, path} ->
        try do
          fun.(path)
        after
          cleanup_temp_secret(path)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_temp_secret(value) do
    dir = Path.join(System.tmp_dir!(), "fermix-secret-#{System.unique_integer([:positive])}")
    path = Path.join(dir, "secret")

    with :ok <- File.mkdir(dir),
         :ok <- File.write(path, value, [:binary]),
         :ok <- File.chmod(path, 0o600) do
      {:ok, path}
    else
      {:error, reason} -> {:error, {:temp_secret_failed, reason}}
    end
  end

  defp cleanup_temp_secret(path) do
    _ = File.rm(path)
    _ = File.rmdir(Path.dirname(path))
    :ok
  end

  defp run_with_stdin(shell, secret_file, binary, args, timeout_ms) do
    script = ~s(secret_file=$1; shift; exec "$@" < "$secret_file")
    run(shell, ["-c", script, "fermix-secret", secret_file, binary | args], timeout_ms)
  end

  defp run(binary, args, timeout_ms) do
    command = Enum.join([binary | args], " ")

    case CommandRunner.run(binary, args, timeout_ms: timeout_ms) do
      {:ok, %{exit: 0, stdout: output, truncated?: false}} ->
        {:ok, output}

      {:ok, %{exit: code, stdout: output}} ->
        {:error, {:helper_failed, command, code, String.slice(output, 0, 200)}}

      {:error, {:timeout, ^timeout_ms}} ->
        {:error, {:helper_timeout, command, timeout_ms}}

      {:error, {:executable_not_found, _path}} ->
        {:error, :unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule FermixCore.Setup.SecretWriter.MacOS do
  @moduledoc false

  @behaviour FermixCore.Setup.SecretWriter

  alias FermixCore.CommandRunner
  alias FermixCore.Setup.SecretPaths

  @account "fermix"
  @default_timeout_ms 3_000

  @impl true
  def available?(_opts \\ []), do: not is_nil(security_binary())

  @impl true
  def put(key, value, opts \\ []) when is_atom(key) and is_binary(value) do
    with {:ok, binary} <- fetch_security_binary(),
         {:ok, _output} <- run(binary, put_args(key, value), timeout(opts)) do
      :ok
    end
  end

  @impl true
  def get(key, opts \\ []) when is_atom(key) do
    with {:ok, binary} <- fetch_security_binary(),
         {:ok, output} <- run(binary, get_args(key), timeout(opts)) do
      output
      |> String.trim_trailing("\n")
      |> case do
        "" -> {:error, :missing_secret}
        value -> {:ok, value}
      end
    end
  end

  @impl true
  @spec command_source(atom(), keyword()) :: map()
  def command_source(key, _opts \\ []) when is_atom(key) do
    %{
      source: :command,
      command: security_binary() || "/usr/bin/security",
      args: get_args(key),
      timeout_ms: @default_timeout_ms
    }
  end

  defp put_args(key, value) do
    ["add-generic-password", "-a", @account, "-s", service(key), "-w", value, "-U"]
  end

  defp get_args(key) do
    ["find-generic-password", "-a", @account, "-s", service(key), "-w"]
  end

  defp service(key) do
    secret = SecretPaths.fetch!(key)
    "fermix:#{secret.env}"
  end

  defp fetch_security_binary do
    case security_binary() do
      nil -> {:error, :unavailable}
      binary -> {:ok, binary}
    end
  end

  defp security_binary do
    System.find_executable("security") ||
      if File.exists?("/usr/bin/security"), do: "/usr/bin/security"
  end

  defp timeout(opts), do: Keyword.get(opts, :timeout_ms, @default_timeout_ms)

  # CommandRunner kills the OS child on timeout — the prior Task.async +
  # System.cmd pattern only ended the BEAM task and left `security` running
  # (e.g. hung on a locked keychain).
  defp run(binary, args, timeout_ms) do
    command = Enum.join([binary | args_without_secret(args)], " ")

    case CommandRunner.run(binary, args, timeout_ms: timeout_ms) do
      {:ok, %{exit: 0, stdout: output, truncated?: false}} ->
        {:ok, output}

      {:ok, %{exit: code, stdout: output}} ->
        {:error, {:helper_failed, command, code, String.slice(output, 0, 200)}}

      {:error, {:timeout, ^timeout_ms}} ->
        {:error, {:helper_timeout, command, timeout_ms}}

      {:error, {:executable_not_found, _path}} ->
        {:error, :unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp args_without_secret(["add-generic-password" | rest]) do
    rest
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn
      ["-w", _value] -> ["-w", "<redacted>"]
      pair -> pair
    end)
    |> then(&["add-generic-password" | &1])
  end

  defp args_without_secret(args), do: args
end
