defmodule FermixCore.ComputerUse.ServerControl do
  @moduledoc """
  When Fermix on this computer's server worked this computer itself (M97
  §8.7), so the computer-history recorder on this computer can mark those
  stretches as Fermix's own and its summarizer stops reporting the agent's
  clicks as the owner's. Two records under this computer's home, of one
  shape, each with one writer, and one reader for both (`stretches/1`, the
  recorder's read):

    * `device/screen_control.jsonl`: one line when its server took the
      screen and one when it let go. `ComputerUse.Seat` writes it.
    * `device/browser_control.jsonl`: one line when a turn on its server
      began using this computer's browser while none did, and one when the
      last such turn ended, however it ended (`browser_started/2`,
      `browser_ended/3`). `Browser.HeldTurnListener` writes it; its seat is
      always `browser`.

  A line of either:

      {"v":1,"e":"started","at":"2026-11-09T21:14:03Z","seat":"cua_x1"}
      {"v":1,"e":"ended","at":"2026-11-09T21:16:40Z","seat":"cua_x1","why":"closed"}

  `why` is one of `closed` (the server let go, or the last turn using the
  browser ended), `stopped` (the person at this computer pressed Stop),
  `switched_off` (its master, screen or browser switch went off), `idle`
  (nothing came for a while) and `helper_exited`.

  Only times, the server's session id or the word `browser`, and a closed
  word, never anything on the screen or in a page. Each file is mode 0600 in a
  0700 folder, under `device/`, which the sandbox protects and which never
  travels with the home. Each keeps at most #{2_000} lines: past that, it is
  cut to its newest #{1_000}.
  """

  require Logger

  @version 1
  @screen_file "screen_control.jsonl"
  @browser_file "browser_control.jsonl"
  @browser_seat "browser"
  @max_lines 2_000
  @kept_lines 1_000
  @whys ~w(closed stopped switched_off idle helper_exited)a
  @browser_whys [:closed, :switched_off]

  @typedoc "Why the server let go of the screen, or its turns of the browser."
  @type why :: :closed | :stopped | :switched_off | :idle | :helper_exited

  @typedoc """
  One stretch: when it started and, once it did, when it ended and why. A
  browser stretch's seat is `"browser"`.
  """
  @type stretch :: %{
          seat: String.t(),
          started_at: DateTime.t(),
          ended_at: DateTime.t() | nil,
          why: why() | nil
        }

  @doc "The screen's record under `home`."
  @spec path(Path.t()) :: Path.t()
  def path(home) when is_binary(home), do: Path.join([home, "device", @screen_file])

  @doc "The browser's record under `home`."
  @spec browser_path(Path.t()) :: Path.t()
  def browser_path(home) when is_binary(home), do: Path.join([home, "device", @browser_file])

  @doc "Records that the server took the screen for `seat` at `at`."
  @spec started(Path.t(), String.t(), DateTime.t()) :: :ok | {:error, term()}
  def started(home, seat, %DateTime{} = at) when is_binary(home) and is_binary(seat),
    do: append(path(home), started_line(seat, at))

  @doc "Records that the server let go of the screen for `seat` at `at`, and why."
  @spec ended(Path.t(), String.t(), DateTime.t(), why()) :: :ok | {:error, term()}
  def ended(home, seat, %DateTime{} = at, why)
      when is_binary(home) and is_binary(seat) and why in @whys,
      do: append(path(home), ended_line(seat, at, why))

  @doc "Records that a turn on the server began using this computer's browser at `at`."
  @spec browser_started(Path.t(), DateTime.t()) :: :ok | {:error, term()}
  def browser_started(home, %DateTime{} = at) when is_binary(home),
    do: append(browser_path(home), started_line(@browser_seat, at))

  @doc """
  Records that the last turn on the server using this computer's browser
  ended at `at`: `closed` however the turn ended, `switched_off` when this
  computer's switch ended it.
  """
  @spec browser_ended(Path.t(), DateTime.t(), :closed | :switched_off) :: :ok | {:error, term()}
  def browser_ended(home, %DateTime{} = at, why)
      when is_binary(home) and why in @browser_whys,
      do: append(browser_path(home), ended_line(@browser_seat, at, why))

  @doc """
  Every stretch recorded under `home`, the screen's and the browser's, oldest
  first; one still open has no `ended_at`. A line that cannot be read is
  skipped and logged; a record that cannot be read is an error.
  """
  @spec stretches(Path.t()) :: {:ok, [stretch()]} | {:error, term()}
  def stretches(home) when is_binary(home) do
    with {:ok, screen} <- read(path(home)),
         {:ok, browser} <- read(browser_path(home)) do
      {:ok, Enum.sort_by(screen ++ browser, &DateTime.to_unix(&1.started_at, :microsecond))}
    end
  end

  @doc "Whether the browser's record ends with a stretch still open."
  @spec browser_open?(Path.t()) :: {:ok, boolean()} | {:error, term()}
  def browser_open?(home) when is_binary(home) do
    with {:ok, stretches} <- read(browser_path(home)),
         do: {:ok, Enum.any?(stretches, &is_nil(&1.ended_at))}
  end

  defp read(file) do
    case File.read(file) do
      {:ok, contents} -> {:ok, contents |> String.split("\n", trim: true) |> joined()}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp started_line(seat, at),
    do: %{"v" => @version, "e" => "started", "at" => iso(at), "seat" => seat}

  defp ended_line(seat, at, why) do
    %{
      "v" => @version,
      "e" => "ended",
      "at" => iso(at),
      "seat" => seat,
      "why" => Atom.to_string(why)
    }
  end

  defp joined(lines) do
    {done, open} =
      Enum.reduce(lines, {[], %{}}, fn line, {done, open} -> take(decode(line), done, open) end)

    done ++ Map.values(open)
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
        Logger.warning("a line of the server control record could not be read; it is skipped")
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

  defp append(file, record) do
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
