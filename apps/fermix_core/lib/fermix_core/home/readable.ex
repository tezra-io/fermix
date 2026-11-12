defmodule FermixCore.Home.Readable do
  @moduledoc """
  The one rule for whether an engine reads a home another engine wrote (M97
  §3.4, D16): by the home's format, never by the engine that wrote it, so a
  release that changes nothing an older engine reads still restores on an
  older app.

  **The home format.** `home_format/0` is one whole number: the newest form
  of a home this engine reads, and the one it writes. It rides in every
  archive's, snapshot's and move stream's manifest (`Archive.Manifest`,
  `home_format`), in this engine's `home.status`, in a candidate's
  `enroll_request`, and in the release table fermix.ai serves
  (`Home.Releases`). An engine reads every home at or below its own format
  (its migrations carry an older one forward at its first boot) and refuses
  one above it by name before anything is written,
  `{:newer_home_format, theirs, ours}`, with `refusal_sentence/0`.

  **When to raise it.** By one, in the change that makes this engine write
  what an engine at the current format cannot read: a `memory.db` migration
  that renames, drops or retypes something an older engine's queries use, or
  adds a constraint its writes break; a manifest key an older engine must
  understand to restore the home correctly; a file of the home whose shape
  changes so that an older engine misreads it; a setting an older engine
  refuses to load. Never for what an older engine reads past (a new table, a
  new optional column, a file it never opens, a setting it ignores): that
  keeps the format, and the release restores on an older app. A raise ships
  with a `home_format` row for its release in the release table, which the
  site's pin script writes. `readable_test.exs` lists every migration and
  manifest key decided under the current format and fails on one added
  without that decision.

  **A home that names no format.** The engines before home formats wrote
  none; the manifest's `engine_version` names such an engine, and every one
  of them is older than the first engine that writes a format. Each wrote a
  home that engine reads, so a home with no format is format 1 (`format/1`),
  the oldest there is, and no engine version is compared.

  **An engine that names no format.** An engine from before home formats
  says none: a candidate whose `enroll_request` has no `home_format`, a
  release the release table gives no `home_format` row. Its own code
  compares engine versions, so it reads only a home its own version or an
  older one wrote, and refuses one whose version it cannot read
  (`reads?/2`). That is what that engine does, not a second rule here: an
  engine that names a format is never judged by its version.

  **Not the version window.** Whether a computer is served chat, tool
  requests and history is `Computers.Versions` (D14: the server leads, up to
  two minor versions behind), a question about the wire. Whether an engine
  can take a home into its keeping is this module's, a question about the
  home: a restore and Restore here, a move's and a move back's staging
  (`Archive.install/5`, the one path they share), a move's review
  (`Home.MoveReadiness`: whether the server reads this home and this
  computer could read the server's back), Move back and Restore here on a
  computer (`Management.HomeSummary`: "Update Fermix on this computer
  first"), and the update gate (`Home.Releases.eligible/3`: a release is
  eligible once a published app for each system that keeps backups reads
  the home it writes). A computer can be inside the window and unable to
  read the server's home, or past it and able to.
  """

  @home_format 1
  # What a home that names no format is (the moduledoc).
  @unformatted 1

  @typedoc """
  A home, or an engine as a reader of one: the format it names (nil when it
  names none) and the engine version it names.
  """
  @type engine :: %{
          required(:home_format) => pos_integer() | nil,
          required(:engine_version) => String.t() | nil,
          optional(any()) => any()
        }

  @doc "This engine's home format: the newest it reads, and the one it writes."
  @spec home_format() :: pos_integer()
  def home_format, do: @home_format

  @doc "The format of the home `written` describes: its own, or 1 when it names none."
  @spec format(%{required(:home_format) => pos_integer() | nil, optional(any()) => any()}) ::
          pos_integer()
  def format(%{home_format: nil}), do: @unformatted
  def format(%{home_format: format}) when is_integer(format) and format >= 1, do: format

  @doc """
  Whether an engine at format `ours` (this engine's by default) reads the home
  `written` describes: `:ok`, or `{:error, {:newer_home_format, theirs, ours}}`.
  """
  @spec readable?(%{required(:home_format) => pos_integer() | nil, optional(any()) => any()}) ::
          :ok | {:error, {:newer_home_format, pos_integer(), pos_integer()}}
  @spec readable?(
          %{required(:home_format) => pos_integer() | nil, optional(any()) => any()},
          pos_integer()
        ) :: :ok | {:error, {:newer_home_format, pos_integer(), pos_integer()}}
  def readable?(written, ours \\ @home_format) when is_integer(ours) and ours >= 1 do
    case format(written) do
      theirs when theirs <= ours -> :ok
      theirs -> {:error, {:newer_home_format, theirs, ours}}
    end
  end

  @doc """
  Whether the engine `reader` reads the home `written` describes: by its
  format when it names one, else as its own code decides, by engine version
  (the moduledoc).
  """
  @spec reads?(engine(), engine()) :: boolean()
  def reads?(%{home_format: ours}, written) when is_integer(ours),
    do: readable?(written, ours) == :ok

  def reads?(%{home_format: nil, engine_version: reader}, %{engine_version: writer}) do
    with true <- is_binary(reader) and is_binary(writer),
         {:ok, reader} <- Version.parse(reader),
         {:ok, writer} <- Version.parse(writer) do
      Version.compare(writer, reader) != :gt
    else
      _unreadable -> false
    end
  end

  @doc """
  What the owner reads where this engine refused a home in a newer format: what
  to do, and no version.
  """
  @spec refusal_sentence() :: String.t()
  def refusal_sentence,
    do:
      "A newer Fermix wrote this home in a form this one cannot read. Update Fermix on " <>
        "this computer first, then try again."
end
