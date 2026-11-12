defmodule FermixCore.Harness.SignIn do
  @moduledoc """
  The one place for a coding agent's sign-in state on this machine (M98 D10).

  Fermix reads whether an agent's sign-in file is there (`Harness.Vendors`)
  and never asks the vendor, so a sign-in the vendor no longer accepts still
  reads as found until a run fails on it. A run whose own words say it could
  not sign in is classified `signed_out` (`Harness.Run`, from the adapter's
  pinned words), and its agent is marked signed out in this machine's coding
  store (`Harness.MachineStore`), with the stat of its sign-in file (size,
  mtime, inode; never its bytes).

  A mark clears when a run of that agent completes here, when its sign-in
  file changed since the mark (it appeared, vanished or was rewritten: the
  owner signed in again), or on the owner's word (`coding_agents.check`). An
  agent with no file Fermix reads (Claude Code on a Mac, in the Keychain)
  keeps its mark until one of the other two. Every reader applies the same
  rule (`marks/1` leaves out a mark whose file changed), so doctor, the setup
  page and `setup.detect` agree before the store has deleted it; the Manager
  deletes such marks when it starts (`check_all/1`).

  The states and their words, the one source for doctor and the setup page:
  `:sign_in_found` ("sign-in found": the file is there, the vendor never
  asked), `:not_verified` (the agent's folder only, a Mac's Keychain),
  `:not_signed_in` and `:signed_out` (a run failed to sign in).

  Options: `:store` (the store process, `MachineStore` by default) for the
  rail's own writes, `:path` (the store's file) for reads and the owner's
  clear on any machine, `:vendor_opts` (`Vendors.sign_in_file/2`'s), `:stat`
  (a file's stat, a test's seam), `:now`, and `:machine`, `:macos?`,
  `:server?` for the machine's name (`machine_word/1`).
  """

  require Logger

  alias FermixCore.Harness.MachineStore
  alias FermixCore.Harness.Vendors
  alias FermixCore.Home.Candidate
  alias FermixCore.Setup.ConfigStore

  @vendors ~w(codex claude)
  @names %{"codex" => "Codex", "claude" => "Claude Code"}
  @logins %{"codex" => "codex login", "claude" => "claude"}
  @machines ["this Mac", "this server", "this computer"]

  @type state :: :sign_in_found | :not_verified | :not_signed_in | :signed_out

  # --- the state ---------------------------------------------------------------------

  @doc "An agent's state from its sign-in file's state and its mark (pure)."
  @spec view(Vendors.auth_state(), map() | nil) :: state()
  def view(:absent, _mark), do: :not_signed_in
  def view(auth, %{}) when auth in [:authenticated, :unverified], do: :signed_out
  def view(:authenticated, nil), do: :sign_in_found
  def view(:unverified, nil), do: :not_verified

  @doc "The owner's word for a state, in doctor and on the setup page."
  @spec word(state()) :: String.t()
  def word(:sign_in_found), do: "sign-in found"
  def word(:not_verified), do: "sign-in not verified"
  def word(:not_signed_in), do: "not signed in"
  def word(:signed_out), do: "signed out (a run failed to sign in)"

  # --- the sentences -----------------------------------------------------------------

  @doc """
  The sentence a run that failed to sign in carries after the vendor's own
  words (D10). It says the run stopped, never that it did nothing: a sign-in
  can expire mid-run, after the agent changed files.
  """
  @spec sentence(String.t(), String.t()) :: String.t()
  def sentence(vendor, machine) when vendor in @vendors and machine in @machines do
    name = Map.fetch!(@names, vendor)

    "#{name} is signed out on #{machine}, so the run stopped. Sign in to #{name} on " <>
      "#{machine} (run #{Map.fetch!(@logins, vendor)} in a terminal), then tell me."
  end

  @doc "The sentence for a marked agent, where its state is shown or a follow-up waits on it."
  @spec marked_sentence(String.t(), String.t()) :: String.t()
  def marked_sentence(vendor, machine) when vendor in @vendors and machine in @machines do
    "#{Map.fetch!(@names, vendor)} failed to sign in on its last run on #{machine}. Sign in " <>
      "again (run #{Map.fetch!(@logins, vendor)} in a terminal); the next run that works " <>
      "clears this."
  end

  @doc "Every sentence this module can say, for `Management.CopyTest`."
  @spec sentences() :: [String.t()]
  def sentences do
    for vendor <- @vendors,
        machine <- @machines,
        say <- [&sentence/2, &marked_sentence/2],
        do: say.(vendor, machine)
  end

  @doc """
  `sentence/2` for a run `row` that failed to sign in, else "". The machine is
  `opts[:machine]`, else this one (`machine_word/1`).
  """
  @spec run_note(map(), keyword()) :: String.t()
  def run_note(%{reason: "signed_out", vendor: vendor}, opts)
      when vendor in @vendors and is_list(opts),
      do: sentence(vendor, machine_word(opts))

  def run_note(row, opts) when is_map(row) and is_list(opts), do: ""

  @doc """
  What the owner calls this machine: "this Mac", "this server" (an Always On
  server, `Home.Candidate.server?/1`) or "this computer". `:machine` names it
  outright; `:macos?` and `:server?` stand in for the host.
  """
  @spec machine_word(keyword()) :: String.t()
  def machine_word(opts) when is_list(opts) do
    case Keyword.fetch(opts, :machine) do
      {:ok, machine} when machine in @machines -> machine
      :error -> host_word(opts)
    end
  end

  defp host_word(opts) do
    cond do
      Keyword.get_lazy(opts, :macos?, fn -> :os.type() == {:unix, :darwin} end) -> "this Mac"
      Keyword.get_lazy(opts, :server?, &server?/0) -> "this server"
      true -> "this computer"
    end
  end

  defp server?, do: Candidate.server?(ConfigStore.fermix_home())

  # --- the marks ---------------------------------------------------------------------

  @doc """
  This machine's marks, keyed by agent, leaving out any whose sign-in file
  changed since it was marked. Read on a connection of its own, so any engine
  can read them, its rail running or not. No store is no mark.
  """
  @spec marks(keyword()) :: {:ok, %{String.t() => MachineStore.mark()}} | {:error, term()}
  def marks(opts) when is_list(opts) do
    with {:ok, marks} <- MachineStore.marks_at(store_path(opts)) do
      {:ok, Map.filter(marks, fn {_vendor, mark} -> current?(mark, opts) end)}
    end
  end

  @doc """
  After a run's terminal write (`Harness.Manager`): a run whose reason is
  `signed_out` marks its agent, and a completed run clears its agent's mark.
  A store that cannot keep it is logged, never raised.
  """
  @spec record_outcome(map(), keyword()) :: :ok
  def record_outcome(%{vendor: vendor, id: run_id} = row, opts)
      when vendor in @vendors and is_list(opts) do
    case row do
      %{reason: "signed_out"} -> mark(vendor, run_id, opts)
      %{status: "completed"} -> unmark(vendor, "cleared", opts)
      _other -> :ok
    end
  end

  def record_outcome(row, opts) when is_map(row) and is_list(opts), do: :ok

  @doc """
  Deletes every mark whose sign-in file changed since it was marked (the
  Manager, when it starts). Errors are logged.
  """
  @spec check_all(keyword()) :: :ok
  def check_all(opts) when is_list(opts) do
    case MachineStore.marks(server: store(opts)) do
      {:ok, marks} ->
        for {vendor, mark} <- marks, not current?(mark, opts), do: unmark(vendor, "checked", opts)
        :ok

      {:error, reason} ->
        Logger.warning("coding agents: sign-in marks could not be read: #{inspect(reason)}")
    end
  end

  @doc "The owner's word that `vendors` are signed in again: their marks are deleted."
  @spec clear([String.t()], keyword()) :: :ok | {:error, term()}
  def clear(vendors, opts) when is_list(vendors) and is_list(opts) do
    true = Enum.all?(vendors, &(&1 in @vendors))
    MachineStore.delete_marks_at(store_path(opts), vendors)
  end

  defp mark(vendor, run_id, opts) do
    file = Vendors.sign_in_file(vendor, Keyword.get(opts, :vendor_opts, []))

    mark = %{
      marked_at: Keyword.get(opts, :now, &DateTime.utc_now/0).(),
      run_id: run_id,
      sign_in_file: file,
      file_stat: file_stat(file, opts)
    }

    vendor |> MachineStore.put_mark(mark, server: store(opts)) |> logged(vendor, "kept")
  end

  defp unmark(vendor, done, opts),
    do: vendor |> MachineStore.delete_mark(server: store(opts)) |> logged(vendor, done)

  defp logged(:ok, _vendor, _done), do: :ok

  defp logged({:error, reason}, vendor, done) do
    Logger.warning("coding agents: #{vendor}'s sign-in mark was not #{done}: #{inspect(reason)}")
  end

  # The mark is current while the agent's sign-in file is as it was when it
  # was marked: the same file (or still none) with the same stat.
  defp current?(%{vendor: vendor} = mark, opts) do
    file = Vendors.sign_in_file(vendor, Keyword.get(opts, :vendor_opts, []))
    {file, file_stat(file, opts)} == {mark.sign_in_file, mark.file_stat}
  end

  # A file that vanished between finding it and reading its stat has no stat,
  # which differs from any mark that recorded one: it changed.
  defp file_stat(nil, _opts), do: nil

  defp file_stat(file, opts) do
    case Keyword.get(opts, :stat, &stat/1).(file) do
      {:ok, stat} -> stat
      {:error, _vanished} -> nil
    end
  end

  defp stat(file) do
    with {:ok, %File.Stat{size: size, mtime: mtime, inode: inode}} <-
           File.stat(file, time: :posix),
         do: {:ok, %{"size" => size, "mtime" => mtime, "inode" => inode}}
  end

  defp store(opts), do: Keyword.get(opts, :store, MachineStore)

  defp store_path(opts),
    do: Keyword.get_lazy(opts, :path, fn -> MachineStore.path(ConfigStore.fermix_home()) end)
end
