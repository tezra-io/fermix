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

  # Brew links binaries from the Cellar into a `bin/` directory, so the
  # path operators actually invoke (e.g. `/usr/local/bin/fermix`) is
  # often a symlink. We have to inspect both the symlink path AND the
  # resolved target — checking only the link path would miss every
  # Homebrew install on Intel macOS and every classic linuxbrew setup.
  defp homebrew_owned?(path) do
    looks_like_brew?(path) or looks_like_brew?(resolve_symlink(path)) or
      under_brew_prefix?(path)
  end

  defp looks_like_brew?(nil), do: false

  defp looks_like_brew?(path) do
    String.contains?(path, "/Cellar/") or String.contains?(path, "/homebrew/")
  end

  defp resolve_symlink(path) do
    case File.read_link(path) do
      {:ok, target} -> Path.expand(target, Path.dirname(path))
      {:error, _} -> nil
    end
  end

  defp under_brew_prefix?(path) do
    case System.find_executable("brew") do
      nil ->
        false

      brew ->
        case System.cmd(brew, ["--prefix"], stderr_to_stdout: true) do
          {out, 0} ->
            prefix = String.trim(out)
            prefix != "" and String.starts_with?(path, prefix <> "/")

          _ ->
            false
        end
    end
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
