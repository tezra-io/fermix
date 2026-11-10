defmodule FermixCore.Home.Readable do
  @moduledoc """
  The one rule for whether this engine can read a home another engine wrote
  (M97 §3.4): a home a newer engine wrote may hold settings and data this
  engine does not know, so it is refused by name rather than run
  half-understood, as is one whose engine version does not parse.

  Its callers: a restore (`Home.Archive`, before it writes anything), a
  move's review (`Home.MoveReadiness`: a server this computer could not read
  back), and Always On's screen on a computer (`Management.HomeSummary`:
  Move back and Restore here say "Update Fermix on this computer first").

  The rule compares engine versions today. Whether a restore should refuse
  by a home format number instead is undecided (D16); deciding it would
  change this module, `Home.Releases.eligible/3`, the archive manifest and
  the site's parser, and nothing else.
  """

  @doc """
  Whether an engine running `ours` reads the home `written` describes
  (`engine_version`, the engine that wrote it): `:ok`, or
  `{:error, {:newer_engine, theirs, ours}}`.
  """
  @spec readable?(
          %{required(:engine_version) => String.t() | nil, optional(any()) => any()},
          String.t()
        ) ::
          :ok | {:error, {:newer_engine, String.t() | nil, String.t()}}
  def readable?(%{engine_version: theirs}, ours) when is_binary(ours) do
    ours_parsed = Version.parse!(ours)

    with true <- is_binary(theirs),
         {:ok, parsed} <- Version.parse(theirs),
         true <- Version.compare(parsed, ours_parsed) != :gt do
      :ok
    else
      _newer_or_unreadable -> {:error, {:newer_engine, theirs, ours}}
    end
  end
end
