defmodule Fermix.CLI.Service.Binding do
  @moduledoc """
  The CLI-owned record of which home this machine's user service runs (M38 §4.7).

  `$XDG_CONFIG_HOME/fermix/service.json`, with the standard `~/.config` default,
  holding one absolute path and no credentials:

      {"schema_version": 1, "home": "/home/operator/.fermix"}

  It is a **location** binding, not a second copy of configuration. The systemd
  vendor unit starts `fermix service run`, which resolves this file before any
  configuration is read, so disabling the service and reopening the desktop
  client still finds the same home. `service uninstall` preserves it.

  Three outcomes, deliberately distinct: a missing file is first run, an
  unreadable or malformed one is Recovery with a sentence an operator can act
  on, and a valid one is the home. A malformed binding is **never** an
  instruction to guess the default home.

  The home is JSON data, so spaces and percent characters round-trip untouched;
  what is refused is a relative path, a control character, and a home so deep
  that `daemon.sock` under it would not fit the OS socket address.
  """

  alias FermixCore.SocketPath

  @schema_version 1
  @dir_name "fermix"
  @file_name "service.json"
  @dir_mode 0o700
  @file_mode 0o600

  @type binding :: %{home: Path.t()}
  @type invalid :: {:invalid, String.t()}

  @doc """
  The binding file's path.

  `:root` replaces the whole config root (tests and the packaged verifier);
  `:config_home` replaces only the `XDG_CONFIG_HOME` reading.
  """
  @spec path(keyword()) :: Path.t()
  def path(opts \\ []) when is_list(opts) do
    Path.join([root(opts), @dir_name, @file_name])
  end

  @doc "Reads the binding, distinguishing a first run from a broken one."
  @spec read(keyword()) :: {:ok, binding()} | {:error, :missing} | {:error, invalid()}
  def read(opts \\ []) when is_list(opts) do
    file = path(opts)

    case File.read(file) do
      {:ok, contents} -> decode(contents, file)
      {:error, :enoent} -> {:error, :missing}
      {:error, reason} -> invalid("The service binding at #{file} could not be read (#{reason}).")
    end
  end

  @doc """
  Writes the binding atomically: a sibling temporary file, tightened to 0600,
  renamed over the target inside a 0700 directory.

  An invalid home is refused before any directory or file is created.
  """
  @spec write(Path.t(), keyword()) ::
          :ok | {:error, invalid()} | {:error, {:binding_write_failed, term()}}
  def write(home, opts \\ []) when is_list(opts) do
    with :ok <- validate(home) do
      file = path(opts)
      temporary = file <> ".tmp-#{System.unique_integer([:positive, :monotonic])}"
      publish(file, temporary, payload(home))
    end
  end

  @doc "Whether `home` can be a service home on this OS."
  @spec validate(term()) :: :ok | {:error, invalid()}
  def validate(home) when is_binary(home) do
    with :ok <- absolute(home),
         :ok <- printable(home) do
      socket_fits(home)
    end
  end

  def validate(_home), do: invalid("The service home must be a path, written as text.")

  defp publish(file, temporary, contents) do
    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.chmod(Path.dirname(file), @dir_mode),
         :ok <- File.write(temporary, contents),
         :ok <- File.chmod(temporary, @file_mode),
         :ok <- File.rename(temporary, file) do
      :ok
    else
      {:error, reason} ->
        # The temporary file is this function's to own on every path: a failed
        # rename must not leave a half-written binding beside the real one.
        _ = File.rm(temporary)
        {:error, {:binding_write_failed, reason}}
    end
  end

  defp payload(home) do
    Jason.encode!(%{"schema_version" => @schema_version, "home" => home})
  end

  defp decode(contents, file) do
    case Jason.decode(contents) do
      {:ok, %{"schema_version" => @schema_version, "home" => home}} -> decoded(home)
      {:ok, %{"schema_version" => other}} -> unknown_version(other, file)
      {:ok, _shape} -> invalid("The service binding at #{file} does not name a home.")
      {:error, _reason} -> invalid("The service binding at #{file} could not be read as JSON.")
    end
  end

  defp decoded(home) do
    with :ok <- validate(home), do: {:ok, %{home: home}}
  end

  defp unknown_version(version, file) do
    invalid(
      "The service binding at #{file} is written in schema version #{inspect(version)}, " <>
        "which this Fermix does not read."
    )
  end

  defp absolute(home) do
    if home != "" and Path.type(home) == :absolute,
      do: :ok,
      else: invalid("The service home must be an absolute path, and #{inspect(home)} is not.")
  end

  # Control characters cannot appear in a path the kernel will accept, and a
  # newline in particular is what turns a serialized value into a second line.
  defp printable(home) do
    if String.match?(home, ~r/[\x00-\x1f\x7f]/),
      do: invalid("The service home contains a control character, which a path cannot carry."),
      else: :ok
  end

  defp socket_fits(home) do
    limit = SocketPath.max_bytes()
    bytes = byte_size(Path.join(home, "daemon.sock"))

    if bytes > limit do
      invalid(
        "The daemon.sock path under that home is #{bytes} bytes, over the #{limit}-byte " <>
          "limit this OS allows for a unix socket address. Choose a shorter home."
      )
    else
      :ok
    end
  end

  defp root(opts) do
    case Keyword.fetch(opts, :root) do
      {:ok, root} when is_binary(root) and root != "" -> root
      _absent -> config_home(opts)
    end
  end

  defp config_home(opts) do
    value =
      if Keyword.has_key?(opts, :config_home),
        do: Keyword.get(opts, :config_home),
        else: System.get_env("XDG_CONFIG_HOME")

    case value do
      home when is_binary(home) and home != "" -> home
      _unset_or_blank -> Path.join(System.user_home!(), ".config")
    end
  end

  defp invalid(sentence), do: {:error, {:invalid, sentence}}
end
