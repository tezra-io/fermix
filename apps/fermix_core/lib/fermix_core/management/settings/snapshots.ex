defmodule FermixCore.Management.Settings.Snapshots do
  @moduledoc """
  The `snapshots` section (M75 §8, ALWAYS_ON_PANE §3.12): how often the
  primary keeps its encrypted snapshots, and whether the recovery passphrase
  is set, under the `always_on` pane. The interval is a projection of
  `[fermix_core.snapshots]` (`Home.Snapshot.Config`), written through
  `Home.Snapshot.Settings.save/2`.

  No app sets any part of S3 (D7): an Always On server's bucket comes from its
  infrastructure, through first boot and the move's activation, and another
  S3 service is set on the server itself, in `config.toml` with its keys
  through `secret.set`. The recovery passphrase is shown as set or not, and
  never written here: `home.snapshots.passphrase` derives the recovery key
  from it and never stores the passphrase; the key itself is never shown. The
  last attempt, the last verified point and the next run are runtime facts,
  published by `home.snapshots.status` rather than as rows.
  """

  alias FermixCore.Home.Snapshot.Config
  alias FermixCore.Management.Settings.Row
  alias FermixCore.Management.Settings.Source

  @section %{id: "snapshots", pane: "always_on", title: "Recovery snapshots"}

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
      Row.new("snapshots_passphrase", :text, "Recovery passphrase",
        footer: "Every backup is encrypted to it, and Fermix never stores it.",
        value: if(Config.recipient?(block), do: "Set", else: "Not set"),
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
      )
    ]
  end
end
