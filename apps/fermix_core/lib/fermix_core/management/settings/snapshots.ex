defmodule FermixCore.Management.Settings.Snapshots do
  @moduledoc """
  The `snapshots` section (M75 §8, ALWAYS_ON_PANE §3.12, S1, S7): Backup
  settings, under the `always_on` pane, with one row, how often an Always On
  server backs up (`snapshots_interval_hours`, "Back up every"). It projects
  `[fermix_core.snapshots]` (`Home.Snapshot.Config`) and writes through
  `Home.Snapshot.Settings.save/2`.

  **Only on an Always On server** (D18): listed and owned, so read and
  written, only where this primary is an Always On server's
  (`Home.ServerPrimary.check/2` is `:server`). A Mac that never moved, or any
  home that never moved, keeps no S3 backup and lists no backup settings. A
  linked desktop shows the server's own section: it is no machine section
  (`Management.Placement`), so the server answers it. `server_primary?:` in
  `opts` says which for a test; `macos?:` names the host for the check.

  Whether the recovery passphrase is set is the summary's (`detail.backup`,
  `Management.HomeSummary`), the one place it is said, and it changes only
  through `home.snapshots.passphrase`; the recovery key is never shown. No app
  sets any part of S3 (D7): an Always On server's bucket comes from its
  infrastructure, through first boot and the move's activation, and another
  S3 service is set on the server itself, in `config.toml` with its keys
  through `secret.set`. The last attempt, the last verified point and the
  next run are runtime facts, published by `home.snapshots.status` rather
  than as rows.
  """

  alias FermixCore.Home.ServerPrimary
  alias FermixCore.Home.Snapshot.Config
  alias FermixCore.Management.Settings.Row
  alias FermixCore.Management.Settings.Source
  alias FermixCore.Setup.ConfigStore

  @section %{id: "snapshots", pane: "always_on", title: "Backup settings"}

  @doc "The one section this module owns, on an Always On server's primary; none elsewhere."
  @spec sections(keyword()) :: [%{id: String.t(), pane: String.t(), title: String.t()}]
  def sections(opts \\ []) when is_list(opts),
    do: if(server_primary?(opts), do: [@section], else: [])

  @doc "Whether this module owns the named section here."
  @spec owns?(String.t(), keyword()) :: boolean()
  def owns?(section, opts \\ []) when is_binary(section) and is_list(opts),
    do: section == @section.id and server_primary?(opts)

  @doc "The rows of the owned section."
  @spec rows(String.t(), Source.snapshot()) :: [Row.t()]
  def rows("snapshots", snapshot) when is_map(snapshot) do
    block = Config.normalize(Source.core(snapshot, :snapshots))

    [
      Row.new("snapshots_interval_hours", :number, "Back up every",
        value: Config.interval_hours(block),
        min: 1,
        max: 168,
        step: 1,
        format: :hours,
        restart: Row.restart?(:snapshots)
      )
    ]
  end

  defp server_primary?(opts) do
    Keyword.get_lazy(opts, :server_primary?, fn ->
      ServerPrimary.check(ConfigStore.fermix_home(), Keyword.take(opts, [:macos?])) == :server
    end)
  end
end
