defmodule FermixCore.Home.ChangedFromComputer do
  @moduledoc """
  That the server's sandbox or its coding approval was changed from one of
  its computers (M97 §19.5, D28): recorded on the server once the write a
  computer sent succeeded (`record/3`, called by the server's management
  router), so the server's summary tells it once, as a notice
  (`Management.HomeSummary`, `computer_change:<at>`), for a week after, and
  so does every linked computer's, which reads it from the server's
  `home.status` (`computer_change`, `view/1`).

  A change is `%{at, computer, what, value}`: when, the computer's name,
  `:sandbox_mode` with the mode it was set to (`strict`, `standard` or
  `open`), or `:harness_approved` with whether coding agents may run there.

  `<home>/device/changed_from_computer.json`, `0600` under a `0700`
  directory: `{"v": 1, "at": "2031-06-01T09:00:00Z", "computer": "loft-linux",
  "what": "sandbox_mode", "value": "open"}`. `device/` stays on this machine
  (`Home.DeviceLocal`). The newest change only: each record replaces the one
  before, so the notice's id moves once per change.

  Recording tells the Always On watch (`Home.StatusWatch`, `:computers`: a
  computer did it), so the apps hear the notice; `opts`' `:status_changed`
  (0-arity) stands in for it in a test.
  """

  alias FermixCore.Home.StatusWatch
  alias FermixCore.Sandbox.Config, as: SandboxConfig

  @file_name "changed_from_computer.json"
  @version 1
  @whats ~w(sandbox_mode harness_approved)a
  # A computer's name is at most 64 bytes (`Home.ComputerName`); the bound
  # only refuses junk.
  @max_name_bytes 256

  @type what :: :sandbox_mode | :harness_approved
  @type change :: %{
          at: DateTime.t(),
          computer: String.t(),
          what: what(),
          value: String.t() | boolean()
        }

  @doc "Where the record lives under `home`."
  @spec path(Path.t()) :: Path.t()
  def path(home) when is_binary(home) and home != "", do: Path.join([home, "device", @file_name])

  @doc """
  Records `change` in place of the one before and tells the Always On watch.
  A change that is not one of the moduledoc's raises `ArgumentError`.
  """
  @spec record(Path.t(), change(), keyword()) :: :ok | {:error, term()}
  def record(home, change, opts \\ []) when is_binary(home) and home != "" and is_list(opts) do
    :ok = valid!(change)
    contents = Jason.encode!(Map.put(view(change), "v", @version))

    with :ok <- write(path(home), contents) do
      :ok = Keyword.get(opts, :status_changed, fn -> StatusWatch.changed(:computers) end).()
    end
  end

  @doc "The change recorded, `:absent` when none was, or why it cannot be read."
  @spec read(Path.t()) :: {:ok, change()} | :absent | {:error, term()}
  def read(home) when is_binary(home) and home != "" do
    file = path(home)

    with {:ok, contents} <- File.read(file),
         {:ok, %{"v" => @version} = record} <- Jason.decode(contents),
         {:ok, change} <- from_view(record) do
      {:ok, change}
    else
      {:error, :enoent} -> :absent
      {:error, reason} when is_atom(reason) -> {:error, {:file, file, reason}}
      _not_ours -> {:error, {:invalid_record, file}}
    end
  end

  @doc "The change as `home.status` carries it (`computer_change`), or nil for none."
  @spec view(change() | nil) :: map() | nil
  def view(nil), do: nil

  def view(%{at: %DateTime{} = at, computer: computer, what: what, value: value}),
    do: %{
      "at" => at |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "computer" => computer,
      "what" => Atom.to_string(what),
      "value" => value
    }

  @doc """
  A change `view/1` gave, read back (a linked computer reads its server's
  `home.status`): `:error` for anything this engine does not know, a newer
  server's kind of change among them, which is then not drawn.
  """
  @spec from_view(map() | nil) :: {:ok, change()} | :error
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

  defp valid_value?(:harness_approved, approved), do: is_boolean(approved)
  defp valid_value?(_what, _value), do: false

  defp write(file, contents) do
    dir = Path.dirname(file)
    tmp = file <> ".tmp"

    with :ok <- File.mkdir_p(dir),
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
