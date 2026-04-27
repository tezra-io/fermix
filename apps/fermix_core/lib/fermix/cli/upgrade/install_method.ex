defmodule Fermix.CLI.Upgrade.InstallMethod do
  @moduledoc """
  Detects how the running `fermix` binary was installed.

  We refuse to overwrite package-manager-owned binaries — Homebrew
  cellar paths, dpkg-managed `/usr/bin` files, and so on — because
  silently mutating them desynchronizes the package database from
  reality. For those cases we return `{:managed, name, hint}` so the
  caller can print the right `brew upgrade` / `apt upgrade` command
  and exit without touching disk.
  """

  @type method ::
          {:managed, :homebrew, String.t()}
          | {:managed, :dpkg, String.t()}
          | {:unmanaged, Path.t()}
          | {:error, term()}

  @spec detect(Path.t() | nil) :: method()
  def detect(binary_path \\ nil) do
    path = binary_path || System.find_executable("fermix")

    cond do
      is_nil(path) -> {:error, :fermix_not_on_path}
      homebrew_owned?(path) -> {:managed, :homebrew, "brew upgrade fermix"}
      dpkg_owned?(path) -> {:managed, :dpkg, "sudo apt update && sudo apt upgrade fermix"}
      true -> {:unmanaged, path}
    end
  end

  defp homebrew_owned?(path) do
    String.contains?(path, "/Cellar/") or String.contains?(path, "/homebrew/")
  end

  defp dpkg_owned?(path) do
    case System.find_executable("dpkg") do
      nil ->
        false

      dpkg ->
        case System.cmd(dpkg, ["-S", path], stderr_to_stdout: true) do
          {_out, 0} -> true
          _ -> false
        end
    end
  end
end
