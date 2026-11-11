defmodule FermixCore.ComputerUse.ServerControl do
  @moduledoc """
  When Fermix on this computer's server drove this computer's screen (M97
  §8.7): one line when its server took the screen and one when it let go,
  in `device/screen_control.jsonl` under this computer's home, so the
  computer-history recorder on this computer can mark that stretch as
  Fermix's own and its summarizer stops reporting the agent's clicks as the
  owner's. `ComputerUse.Seat` is its one writer; `stretches/2` is the
  recorder's read.

      {"v":1,"e":"started","at":"2026-11-09T21:14:03Z","seat":"cua_x1"}
      {"v":1,"e":"ended","at":"2026-11-09T21:16:40Z","seat":"cua_x1","why":"closed"}

  `why` is one of `closed` (the server let go), `stopped` (the person at
  this computer pressed Stop), `switched_off` (its master or screen switch
  went off), `idle` (nothing came for a while) and `helper_exited`.

  Only times, the server's session id and a closed word, never anything on
  the screen. The file is mode 0600 in a 0700 folder, under `device/`, which
  the sandbox protects and which never travels with the home. It keeps at
  most #{2_000} lines: past that, it is cut to its newest #{1_000}.
  """

  require Logger

  @version 1
  @file_name "screen_control.jsonl"
  @max_lines 2_000
  @kept_lines 1_000
  @whys ~w(closed stopped switched_off idle helper_exited)a

  @typedoc "Why the server let go of the screen."
  @type why :: :closed | :stopped | :switched_off | :idle | :helper_exited

  @typedoc "One stretch: when it started and, once it did, when it ended and why."
  @type stretch :: %{
          seat: String.t(),
          started_at: DateTime.t(),
          ended_at: DateTime.t() | nil,
          why: why() | nil
        }

  @doc "The file under `home`."
  @spec path(Path.t()) :: Path.t()
  def path(home) when is_binary(home), do: Path.join([home, "device", @file_name])

  @doc "Records that the server took the screen for `seat` at `at`."
  @spec started(Path.t(), String.t(), DateTime.t()) :: :ok | {:error, term()}
  def started(home, seat, %DateTime{} = at) when is_binary(home) and is_binary(seat),
    do: append(home, %{"v" => @version, "e" => "started", "at" => iso(at), "seat" => seat})

  @doc "Records that the server let go of the screen for `seat` at `at`, and why."
  @spec ended(Path.t(), String.t(), DateTime.t(), why()) :: :ok | {:error, term()}
  def ended(home, seat, %DateTime{} = at, why)
      when is_binary(home) and is_binary(seat) and why in @whys do
    record = %{
      "v" => @version,
      "e" => "ended",
      "at" => iso(at),
      "seat" => seat,
      "why" => Atom.to_string(why)
    }

    append(home, record)
  end

  @doc """
  The stretches recorded under `home`, oldest first; one still open has no
  `ended_at`. A line that cannot be read is skipped and logged.
  """
  @spec stretches(Path.t()) :: {:ok, [stretch()]} | {:error, term()}
  def stretches(home) when is_binary(home) do
    case File.read(path(home)) do
      {:ok, contents} -> {:ok, contents |> String.split("\n", trim: true) |> joined()}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp joined(lines) do
    {done, open} =
      Enum.reduce(lines, {[], %{}}, fn line, {done, open} -> take(decode(line), done, open) end)

    (done ++ Map.values(open)) |> Enum.sort_by(&DateTime.to_unix(&1.started_at, :microsecond))
  end

  defp take({:started, seat, at}, done, open),
    do: {done, Map.put(open, seat, %{seat: seat, started_at: at, ended_at: nil, why: nil})}

  defp take({:ended, seat, at, why}, done, open) do
    case Map.pop(open, seat) do
      {nil, open} -> {done, open}
      {stretch, open} -> {[%{stretch | ended_at: at, why: why} | done], open}
    end
  end

  defp take(:skip, done, open), do: {done, open}

  defp decode(line) do
    with {:ok, %{"v" => @version, "e" => e, "at" => at, "seat" => seat} = record}
         when is_binary(seat) <- Jason.decode(line),
         {:ok, at, _offset} <- DateTime.from_iso8601(at) do
      event(e, seat, at, record["why"])
    else
      _unreadable ->
        Logger.warning("a line of the screen control record could not be read; it is skipped")
        :skip
    end
  end

  defp event("started", seat, at, _why), do: {:started, seat, at}

  defp event("ended", seat, at, why) when is_binary(why) do
    case Enum.find(@whys, &(Atom.to_string(&1) == why)) do
      nil -> :skip
      atom -> {:ended, seat, at, atom}
    end
  end

  defp event(_e, _seat, _at, _why), do: :skip

  defp append(home, record) do
    file = path(home)
    dir = Path.dirname(file)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- write_line(file, Jason.encode!(record) <> "\n"),
         :ok <- File.chmod(file, 0o600) do
      bounded(file)
    end
  end

  defp write_line(file, line) do
    case File.open(file, [:append, :binary]) do
      {:ok, io} ->
        try do
          IO.binwrite(io, line)
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Past the most lines, the newest are kept: a temporary file, then a rename.
  defp bounded(file) do
    with {:ok, contents} <- File.read(file),
         lines = String.split(contents, "\n", trim: true),
         true <- length(lines) > @max_lines do
      tmp = "#{file}.#{System.unique_integer([:positive])}.tmp"
      kept = lines |> Enum.take(-@kept_lines) |> Enum.map_join(&(&1 <> "\n"))

      with :ok <- File.write(tmp, kept),
           :ok <- File.chmod(tmp, 0o600),
           :ok <- File.rename(tmp, file) do
        :ok
      else
        {:error, _reason} = error ->
          _ = File.rm(tmp)
          error
      end
    else
      false -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
