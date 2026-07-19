defmodule Fermix.CLI.VersionSkew do
  @moduledoc """
  Detects a running daemon whose version differs from this CLI binary's.

  A package-manager upgrade (`brew upgrade fermix`) swaps the binary on
  disk but never touches the launchd/systemd service, so the daemon keeps
  running the old release until it is restarted. `fermix status` and
  `fermix doctor`'s daemon-socket check surface that skew via `note/2`.
  """

  @spec note(String.t() | nil, String.t()) :: String.t() | nil
  def note(daemon_version, binary_version \\ current_version())

  def note(daemon_version, binary_version) when daemon_version in [nil, binary_version] do
    nil
  end

  def note(daemon_version, binary_version) when is_binary(daemon_version) do
    "daemon is running #{daemon_version} but the installed binary is " <>
      "#{binary_version} — run `fermix restart` to load it"
  end

  defp current_version do
    case Application.spec(:fermix_core, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end
end
