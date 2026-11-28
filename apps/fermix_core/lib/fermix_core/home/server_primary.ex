defmodule FermixCore.Home.ServerPrimary do
  @moduledoc """
  Whether this primary is an Always On server's (ALWAYS_ON_PANE §3.12, D18):
  the one place S3 backups and their scheduler are admitted
  (`Snapshot.Scheduler.targets/0`), and what `fermix doctor` reads to say a
  primary's S3 backups stopped.

  **The fact.** A move writes the computer's own desktop row (`kind:
  :desktop`) into the home's device list before it captures, and the row
  travels to the server: a home holding one is a server's, a home that never
  moved holds none. It is the fact `HomeSummary` already draws the server's
  `primary` by (`of/2`, the one decision, which `HomeSummary.gather/5` gives
  the rail's rows), read here from the file (`Home.Link.home_desktops/1`) so
  it holds before the channels' store starts. A move back and Restore here
  drop every desktop row (`Candidate.Return`, M102 D6), and a desktop row is
  never revoked (`devices.revoke` refuses one), so a server keeps its fact
  for as long as it is the primary.

  **macOS is refused outright**, whatever the list holds: an Always On server
  is Linux, and a Mac that took the home back before a move back dropped
  every computer's row can still hold one (M102 N2).

  `opts` (the tests' seams): `:macos?` and `:desktop_rows` (a 1-arity reader
  of a home's rows, `Home.Link`'s in its place).
  """

  alias FermixCore.Home.Link

  require Logger

  @type os :: :macos | :linux
  @type reason :: :macos | :no_desktop | {:device_list, term()}
  @type answer :: :server | {:not_server, reason()}

  @doc "Whether the primary serving `home` is an Always On server's."
  @spec check(Path.t(), keyword()) :: answer()
  def check(home, opts \\ []) when is_binary(home) and is_list(opts) do
    if macos?(opts), do: of(:macos, []), else: rows(home, opts)
  end

  @doc """
  The decision itself, by the host's system `os` and the home's desktop
  `rows`: a server only off macOS and with a row.
  """
  @spec of(os(), [map()]) :: answer()
  def of(:macos, rows) when is_list(rows), do: {:not_server, :macos}
  def of(:linux, [_ | _]), do: :server
  def of(:linux, []), do: {:not_server, :no_desktop}

  @doc "The sentence a primary that is no Always On server's is told, by why."
  @spec sentence(reason()) :: String.t()
  def sentence(:macos),
    do: "Fermix keeps S3 backups only on an Always On server, and this Mac is not one."

  def sentence(:no_desktop),
    do:
      "Fermix keeps S3 backups only on an Always On server, and this computer is not one: " <>
        "no desktop moved its home here."

  def sentence({:device_list, reason}),
    do:
      "Fermix could not read this home's device list (#{describe(reason)}), so it cannot " <>
        "tell whether this is an Always On server, and keeps no S3 backup."

  defp macos?(opts),
    do: Keyword.get_lazy(opts, :macos?, fn -> match?({:unix, :darwin}, :os.type()) end)

  defp rows(home, opts) do
    reader = Keyword.get(opts, :desktop_rows, &link_rows/1)

    case reader.(home) do
      {:ok, rows} ->
        of(:linux, rows)

      {:error, reason} ->
        Logger.error("server primary: the device list could not be read: #{inspect(reason)}")
        {:not_server, {:device_list, reason}}
    end
  end

  defp link_rows(home), do: Link.impl().home_desktops(home)

  defp describe(reason) when is_atom(reason) do
    case :file.format_error(reason) do
      ~c"unknown POSIX error" ++ _rest -> "`#{reason}`"
      words -> List.to_string(words)
    end
  end

  defp describe(reason), do: inspect(reason)
end
