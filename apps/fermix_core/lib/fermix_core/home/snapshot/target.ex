defmodule FermixCore.Home.Snapshot.Target do
  @moduledoc """
  Where a primary keeps its snapshots (M75 §8): the S3 target
  (`FermixCore.Home.Snapshot.S3`), and the connected desktops over the rail
  (`FermixChannels.Desktop.SnapshotTarget`, which `fermix_core` reaches only
  through `config :fermix_core, :snapshot_targets`).

  The scheduler (`FermixCore.Home.Snapshot.Scheduler`) writes one encrypted
  file per run and hands it to every target `configured/1` admits, one after
  another; each answers on its own, and the status (`Snapshot.Status`) records
  each target's last attempt, last verified point and last error separately.

  A target never reads the plaintext and never holds the recovery passphrase:
  it stores, or streams, the encrypted file as it is. "Verified" is the
  target's own proof that the bytes arrived whole: S3 accepting the SHA-256
  checksum, a desktop answering the same SHA-256 (`snapshot_stored`).
  """

  @typedoc "One written snapshot, as a target receives it."
  @type snapshot :: %{
          path: Path.t(),
          name: String.t(),
          sha256: String.t(),
          size: non_neg_integer(),
          epoch: pos_integer(),
          created_at: DateTime.t()
        }

  @typedoc "Where a verified snapshot now is, in words an owner reads (`s3://bucket/key`)."
  @type stored :: %{location: String.t()}

  @doc "The target's id in the status file and on the management wire (`s3`)."
  @callback id() :: String.t()

  @doc "The target's name in a sentence (`S3`)."
  @callback label() :: String.t()

  @doc """
  The target's settings from `[fermix_core.snapshots]`, or `:not_configured`
  when the section does not turn it on.
  """
  @callback configured(config :: keyword()) :: {:ok, settings :: term()} | :not_configured

  @doc "Where the target puts snapshots, for the status (`s3://bucket/prefix/profile/`)."
  @callback destination(settings :: term(), opts :: keyword()) :: String.t()

  @doc """
  Stores `snapshot` and answers once the target verified it. `opts` carries the
  caller's facts: `:profile`, `:now` (a 0-arity clock) and the target's own
  test seams. `{:waiting, reason}` is a target that cannot take it now and will
  at a later run, which is no failure (a desktop asleep or offline): the
  status records it as `waiting`.
  """
  @callback store(snapshot(), settings :: term(), opts :: keyword()) ::
              {:ok, stored()} | {:waiting, term()} | {:error, term()}

  @doc """
  The one sentence an owner is shown for a `store/3` failure or wait, carrying
  the vendor's own words where it gave any.
  """
  @callback sentence(reason :: term()) :: String.t()
end
