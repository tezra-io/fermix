defmodule Fermix.CLI.Upgrade.InstallMethod do
  @moduledoc """
  Detects how the running `fermix` binary was installed.

  We refuse to overwrite package-manager-owned binaries — Homebrew
  cellar paths, dpkg-managed `/usr/bin` files, and so on — because
  silently mutating them desynchronizes the package database from
  reality. For those cases we return `{:managed, name, hint}` so the
  caller can print the right `brew upgrade` / `apt upgrade` command
  and exit without touching disk.

  Two ordered guards answer two different questions, which is why they are not
  a fallback chain (M38 §9.3):

    1. **Distribution identity.** A `linux_package` engine was built as a
       package by this project, and it refuses to self-update before it looks
       at a path at all. That is the only guard that is right by construction
       rather than by query, and it is the only one that works on a host where
       the ownership tool is not installed.
    2. **Host package-database ownership.** `dpkg -S`, `rpm -qf` and
       `pacman -Qo` answer whether *this host's* database owns the file, which
       is a different question with a different answer for a binary this
       project did not package — a community `fermix-bin` rebuild of the
       standalone artifact is exactly that case.

  One repository serves dnf and zypper hosts alike, so the rpm hint carries
  both spellings rather than probing which front end is installed; the pacman
  hint names the AUR package and the operator's own helper, because
  `pacman -Syu` does not upgrade an AUR package.

  Every ownership query runs through `opts[:cmd]` and every tool lookup through
  `opts[:find_executable]`, so a test answers for a host it does not have.
  """

  alias FermixCore.BuildInfo

  @linux_package_hint "sudo apt update && sudo apt upgrade fermix " <>
                        "(Fedora and RHEL: sudo dnf upgrade fermix; " <>
                        "openSUSE: sudo zypper update fermix)"
  @dpkg_hint "sudo apt update && sudo apt upgrade fermix"
  @rpm_hint "sudo dnf upgrade fermix (openSUSE: sudo zypper update fermix)"
  @pacman_hint "update the AUR package fermix-bin with your AUR helper " <>
                 "(for example, yay -Syu fermix-bin)"

  @ownership [
    {:dpkg, "dpkg", ["-S"], @dpkg_hint},
    {:rpm, "rpm", ["-qf"], @rpm_hint},
    {:pacman, "pacman", ["-Qo"], @pacman_hint}
  ]

  @type name :: :linux_package | :homebrew | :dpkg | :rpm | :pacman

  @type method ::
          {:managed, name(), String.t()}
          | {:unmanaged, Path.t()}
          | {:error, term()}

  @spec detect(Path.t() | nil, keyword()) :: method()
  def detect(binary_path \\ nil, opts \\ []) when is_list(opts) do
    build_info = Keyword.get(opts, :build_info, BuildInfo)

    if build_info.linux_package?() do
      {:managed, :linux_package, @linux_package_hint}
    else
      detect_by_ownership(binary_path, opts)
    end
  end

  defp detect_by_ownership(binary_path, opts) do
    path = binary_path || resolve_self(opts).()

    cond do
      is_nil(path) -> {:error, :fermix_not_on_path}
      homebrew_owned?(path, opts) -> {:managed, :homebrew, "brew upgrade fermix"}
      true -> database_owner(path, opts)
    end
  end

  defp database_owner(path, opts) do
    Enum.find_value(@ownership, {:unmanaged, path}, fn {name, tool, args, hint} ->
      if owned?(tool, args ++ [path], opts), do: {:managed, name, hint}
    end)
  end

  defp owned?(tool, args, opts) do
    case run(tool, args, opts) do
      {_output, 0} -> true
      _absent_or_unowned -> false
    end
  end

  # Brew links binaries from the Cellar into a `bin/` directory, so the
  # path operators actually invoke (e.g. `/usr/local/bin/fermix`) is
  # often a symlink. We have to inspect both the symlink path AND the
  # resolved target — checking only the link path would miss every
  # Homebrew install on Intel macOS and every classic linuxbrew setup.
  defp homebrew_owned?(path, opts) do
    looks_like_brew?(path) or looks_like_brew?(resolve_symlink(path)) or
      under_brew_prefix?(path, opts)
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

  defp under_brew_prefix?(path, opts) do
    case run("brew", ["--prefix"], opts) do
      {out, 0} ->
        prefix = String.trim(out)
        prefix != "" and String.starts_with?(path, prefix <> "/")

      _absent_or_failed ->
        false
    end
  end

  # `System.cmd/3` raises on a missing executable, so the lookup is the guard:
  # a tool this host does not have answers `:absent` rather than crashing a
  # refusal whose only job is to print a sentence.
  defp run(tool, args, opts) do
    case find_executable(opts).(tool) do
      nil -> :absent
      executable -> cmd(opts).(executable, args)
    end
  end

  defp find_executable(opts) do
    Keyword.get(opts, :find_executable, &System.find_executable/1)
  end

  defp cmd(opts) do
    Keyword.get(opts, :cmd, fn executable, args ->
      System.cmd(executable, args, stderr_to_stdout: true)
    end)
  end

  defp resolve_self(opts) do
    Keyword.get(opts, :resolve_self, fn -> System.find_executable("fermix") end)
  end
end
