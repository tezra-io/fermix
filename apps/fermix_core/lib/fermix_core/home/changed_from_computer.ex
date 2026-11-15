defmodule FermixCore.Home.ChangedFromComputer do
  @moduledoc """
  What one of its computers changed of the server's own limits (M97 §19.5,
  D28): recorded on the server once the write a computer sent stood and
  moved the value (`record/3`, called by the server's management router), so
  the server's summary tells the newest change once, as a notice
  (`Management.HomeSummary`, `computer_change:<what>:<at>`), for a week
  after, and so does every linked computer's, which reads the changes from
  the server's `home.status` (`computer_changes`, `view/1`).

  A change is `%{at, computer, what, value}`: when, the computer's name, and
  what it set: `:sandbox_mode` to `strict`, `standard` or `open`,
  `:sandbox_profile` (the command profile) to `bare`, `assistant` or
  `extended`, `:sandbox_env_allow` to the names of the environment variables
  commands may get, or `:harness_approved` to whether coding agents may run
  there.

  One record for each `what` (`whats/0`), so a change of one limit never
  takes the place of another's: `<home>/device/changed_from_computer/<what>.json`,
  `0600` under `0700` directories, `{"v": 1, "at": "2031-06-01T09:00:00.000Z",
  "computer": "loft-linux", "what": "sandbox_mode", "value": "open"}`.
  `device/` stays on this machine (`Home.DeviceLocal`). A change replaces the
  record of its own `what`; `at` keeps its milliseconds, so each change's
  notice id is its own.

  Recording tells the Always On watch (`Home.StatusWatch`, `:computers`: a
  computer did it), so the apps hear the notice; `opts`' `:status_changed`
  (0-arity) stands in for it in a test.
  """

  alias FermixCore.Home.StatusWatch
  alias FermixCore.Sandbox.Config, as: SandboxConfig

  @dir "changed_from_computer"
  @version 1
  # In the sandbox section's row order, then the coding approval: the order
  # of one write's changes, which share a time.
  @whats ~w(sandbox_mode sandbox_profile sandbox_env_allow harness_approved)a
  # A computer's name is at most 64 bytes (`Home.ComputerName`); the bounds
  # only refuse junk. A list setting takes at most 200 values
  # (`Settings.AnswerMap`).
  @max_name_bytes 256
  @max_names 200

  @type what :: :sandbox_mode | :sandbox_profile | :sandbox_env_allow | :harness_approved
  @type change :: %{
          at: DateTime.t(),
          computer: String.t(),
          what: what(),
          value: String.t() | boolean() | [String.t()]
        }

  @doc "Every limit a change names, one record each."
  @spec whats() :: [what()]
  def whats, do: @whats

  @doc "Where the record of `what` lives under `home`."
  @spec path(Path.t(), what()) :: Path.t()
  def path(home, what) when is_binary(home) and home != "" and what in @whats,
    do: Path.join([home, "device", @dir, "#{what}.json"])

  @doc """
  Records `change` in place of the one before of its `what`, and tells the
  Always On watch. A change that is not one of the moduledoc's raises
  `ArgumentError`.
  """
  @spec record(Path.t(), change(), keyword()) :: :ok | {:error, term()}
  def record(home, change, opts \\ []) when is_binary(home) and home != "" and is_list(opts) do
    :ok = valid!(change)
    contents = Jason.encode!(Map.put(view(change), "v", @version))

    with :ok <- write(path(home, change.what), contents) do
      :ok = Keyword.get(opts, :status_changed, fn -> StatusWatch.changed(:computers) end).()
    end
  end

  @doc "The change of `what` recorded, `:absent` when none was, or why it cannot be read."
  @spec read(Path.t(), what()) :: {:ok, change()} | :absent | {:error, term()}
  def read(home, what) when is_binary(home) and home != "" and what in @whats do
    file = path(home, what)

    with {:ok, contents} <- File.read(file),
         {:ok, %{"v" => @version} = record} <- Jason.decode(contents),
         {:ok, %{what: ^what} = change} <- from_view(record) do
      {:ok, change}
    else
      {:error, :enoent} -> :absent
      {:error, reason} when is_atom(reason) -> {:error, {:file, file, reason}}
      _not_ours -> {:error, {:invalid_record, file}}
    end
  end

  @doc """
  `changes` newest first, and the changes of one write, which share a time,
  in `whats/0`'s order: the head is the one a summary tells.
  """
  @spec newest_first([change()]) :: [change()]
  def newest_first(changes) when is_list(changes) do
    Enum.sort_by(changes, fn %{at: at, what: what} ->
      {-DateTime.to_unix(at, :microsecond), Enum.find_index(@whats, &(&1 == what))}
    end)
  end

  @doc """
  A change as `home.status` carries it, one of `computer_changes`: `at` to
  the millisecond, always written with its three digits.
  """
  @spec view(change()) :: map()
  def view(%{at: %DateTime{microsecond: {micros, _precision}} = at} = change),
    do: %{
      "at" => DateTime.to_iso8601(%{at | microsecond: {div(micros, 1_000) * 1_000, 3}}),
      "computer" => change.computer,
      "what" => Atom.to_string(change.what),
      "value" => change.value
    }

  @doc """
  A change `view/1` gave, read back (a linked computer reads its server's
  `home.status`): `:error` for anything this engine does not know, a newer
  server's kind of change among them, which is then not drawn.
  """
  @spec from_view(term()) :: {:ok, change()} | :error
  def from_view(%{"at" => at, "computer" => computer, "what" => what, "value" => value})
      when is_binary(at) and is_binary(what) do
    with {:ok, at, _offset} <- DateTime.from_iso8601(at),
         {:ok, what} <- known_what(what),
         change = %{at: at, computer: computer, what: what, value: value},
         true <- valid?(change) do
      {:ok, change}
    else
      _unknown -> :error
    end
  end

  def from_view(_other), do: :error

  defp known_what(what) do
    case Enum.find(@whats, &(Atom.to_string(&1) == what)) do
      nil -> :error
      known -> {:ok, known}
    end
  end

  defp valid!(change) do
    if valid?(change),
      do: :ok,
      else: raise(ArgumentError, "no change from a computer: #{inspect(change)}")
  end

  defp valid?(%{at: %DateTime{}, computer: computer, what: what, value: value})
       when is_binary(computer) and computer != "" and byte_size(computer) <= @max_name_bytes,
       do: valid_value?(what, value)

  defp valid?(_other), do: false

  defp valid_value?(:sandbox_mode, mode) when is_binary(mode),
    do: mode in Enum.map(SandboxConfig.modes(), &Atom.to_string/1)

  defp valid_value?(:sandbox_profile, profile) when is_binary(profile),
    do: profile in Enum.map(SandboxConfig.command_profiles(), &Atom.to_string/1)

  defp valid_value?(:sandbox_env_allow, names) when is_list(names),
    do: length(names) <= @max_names and Enum.all?(names, &is_binary/1)

  defp valid_value?(:harness_approved, approved), do: is_boolean(approved)
  defp valid_value?(_what, _value), do: false

  defp write(file, contents) do
    dir = Path.dirname(file)
    tmp = file <> ".tmp"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(Path.dirname(dir), 0o700),
         :ok <- File.chmod(dir, 0o700),
         :ok <- File.write(tmp, contents),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, file) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, {:file, file, reason}}
    end
  end
end
