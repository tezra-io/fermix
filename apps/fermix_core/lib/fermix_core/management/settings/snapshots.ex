defmodule FermixCore.Management.Settings.Snapshots do
  @moduledoc """
  The `snapshots` section (M75 §8): where and how often the primary keeps its
  encrypted snapshots, under the `always_on` pane. Every row is a projection
  of `[fermix_core.snapshots]` (`Home.Snapshot.Config`), and every write goes
  through `Home.Snapshot.Settings.save/2`.

  The recovery key is shown and never written here: it is derived from the
  recovery passphrase by `home.snapshots.passphrase`, which never stores the
  passphrase. The S3 access keys are secret rows, stored with `secret.set`
  under `snapshot_s3_access_key_id` and `snapshot_s3_secret_access_key`.
  The last attempt, the last verified point and the next run are runtime
  facts, published by `home.snapshots.status` rather than as rows.
  """

  alias FermixCore.Home.Snapshot.Config
  alias FermixCore.Management.Settings.Row
  alias FermixCore.Management.Settings.Source

  @section %{id: "snapshots", pane: "always_on", title: "Recovery snapshots"}

  @recipient_info "Every snapshot is encrypted to this key. Restoring one needs the recovery " <>
                    "passphrase it came from, and Fermix never stores that passphrase."

  @doc "The one section this module owns."
  @spec sections() :: [%{id: String.t(), pane: String.t(), title: String.t()}]
  def sections, do: [@section]

  @doc "Whether this module owns the named section."
  @spec owns?(String.t()) :: boolean()
  def owns?(section) when is_binary(section), do: section == @section.id

  @doc "The rows of the owned section."
  @spec rows(String.t(), Source.snapshot()) :: [Row.t()]
  def rows("snapshots", snapshot) when is_map(snapshot) do
    block = Config.normalize(Source.core(snapshot, :snapshots))
    restart = Row.restart?(:snapshots)

    [
      Row.new("snapshots_recipient", :text, "Recovery key",
        footer: "Fermix makes it from the recovery passphrase you set in Always On.",
        info: @recipient_info,
        value: Source.string(block, :recipient),
        read_only: true,
        restart: restart
      ),
      Row.new("snapshots_interval_hours", :number, "Take a snapshot every",
        value: Config.interval_hours(block),
        min: 1,
        max: 168,
        step: 1,
        format: :hours,
        restart: restart
      ),
      Row.new("snapshots_s3_bucket", :text, "S3 bucket",
        footer: "Snapshots are kept here, and nothing is kept until it is set.",
        example: "fermix-snapshots",
        value: Source.string(block, :s3_bucket),
        restart: restart
      ),
      Row.new("snapshots_s3_region", :text, "Region",
        example: "eu-west-1",
        value: Source.string(block, :s3_region),
        restart: restart
      ),
      Row.new("snapshot_s3_access_key_id", :secret, "Access key ID",
        present: Source.secret_present?(snapshot, :snapshot_s3_access_key_id),
        restart: restart
      ),
      Row.new("snapshot_s3_secret_access_key", :secret, "Secret access key",
        present: Source.secret_present?(snapshot, :snapshot_s3_secret_access_key),
        restart: restart
      ),
      Row.new("snapshots_s3_prefix", :text, "Folder in the bucket",
        footer: "Each profile keeps its snapshots in a folder of its own beneath it.",
        example: "fermix",
        value: Source.string(block, :s3_prefix),
        restart: restart,
        advanced: true
      ),
      Row.new("snapshots_s3_endpoint", :text, "Storage address",
        footer: "Only for a storage service that speaks S3. Leave it empty for AWS.",
        example: "https://s3.example.net",
        value: Source.string(block, :s3_endpoint),
        restart: restart,
        advanced: true
      )
    ]
  end
end
