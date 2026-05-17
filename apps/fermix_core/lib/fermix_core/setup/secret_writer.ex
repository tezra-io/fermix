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

  @spec format_error(secret_key(), term()) :: String.t()
  def format_error(key, reason) when is_atom(key) do
    secret = SecretPaths.fetch!(key)
    "#{secret.env} could not be resolved from @keyring: #{format_reason(reason)}"
  end

  defp impl(opts) do
    Keyword.get(opts, :impl) ||
      Application.get_env(:fermix_core, :secret_writer, __MODULE__.MacOS)
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

defmodule FermixCore.Setup.SecretWriter.MacOS do
  @moduledoc false

  @behaviour FermixCore.Setup.SecretWriter

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

  defp run(binary, args, timeout_ms) do
    command = Enum.join([binary | args_without_secret(args)], " ")
    task = Task.async(fn -> System.cmd(binary, args, stderr_to_stdout: true) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, code}} -> {:error, {:helper_failed, command, code, String.slice(output, 0, 200)}}
      nil -> {:error, {:helper_timeout, command, timeout_ms}}
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
