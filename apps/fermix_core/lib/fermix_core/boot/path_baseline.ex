defmodule FermixCore.Boot.PathBaseline do
  @moduledoc """
  The one ordered list of directories a launchd- or systemd-spawned engine needs
  on `PATH`, with two consumers (M34 native setup §7.9).

  launchd hands a daemon a bare `PATH`, and `cosign`, brew `node` and `python`,
  and the `codex` and `claude` CLIs in `~/.local/bin` are not on it. The service
  unit has always written this list into its own environment; an app-managed
  engine is launched by `SMAppService` instead, inherits that same bare `PATH`,
  and loses every one of those directories. There are 30 `System.find_executable`
  call sites across the tree, so threading a resolver through them is not the fix.

  Two consumers, one list:

    * `Fermix.CLI.Service` writes `dirs/1` into the unit it installs.
    * `ensure!/1` appends whatever is missing to this process's own `PATH`, and
      is called from `FermixCore.BootProfile.prepare/1`.

  **Appending only, never prepending.** `PATH` is first-match-wins, so a tail
  entry can make an unresolvable name resolvable and can never shadow a binary
  the operator's own `PATH` already chose. That property is why `ensure!/1` is
  safe to run on a process whose environment someone deliberately arranged.

  **Its reach is the daemon boot path, not every verb.** `BootProfile.prepare/1`
  runs for `:app_engine` and for `fermix run`; every other tree-less verb
  inherits the invoking shell's `PATH`, which is normally a superset and is the
  environment the operator chose. A source run gets no baseline at all, because
  appending to a developer's shell `PATH` would hide a `PATH` problem they need
  to see.
  """

  @darwin_bindirs ~w(/opt/homebrew/bin /usr/local/bin /usr/bin /bin /usr/sbin /sbin)
  @linux_bindirs ~w(/usr/local/bin /usr/bin /bin /usr/sbin /sbin)

  @type os :: :darwin | :linux

  @doc """
  The ordered baseline directories.

  `:binary_dir` leads when given — on a Homebrew install its siblings include
  `cosign`. `~/.local/bin` is last, because it is where the official Codex and
  Claude Code installers put their binaries and it is the entry most likely to
  collide with something the operator already chose.
  """
  @spec dirs(keyword()) :: [String.t()]
  def dirs(opts \\ []) when is_list(opts) do
    os = Keyword.get(opts, :os) || os_family()

    leading =
      case Keyword.get(opts, :binary_dir) do
        dir when is_binary(dir) and dir != "" -> [dir]
        _absent -> []
      end

    Enum.uniq(leading ++ standard_bindirs(os) ++ [user_bindir(opts)])
  end

  @doc """
  Appends every baseline directory this process's `PATH` is missing.

  Returns the directories that were added, so a caller can report what it
  changed rather than asserting it changed nothing.
  """
  @spec ensure!(keyword()) :: [String.t()]
  def ensure!(opts \\ []) when is_list(opts) do
    current = current_dirs()
    missing = Enum.reject(dirs(opts), &(&1 in current))

    case missing do
      [] -> []
      _added -> put_path(current ++ missing)
    end
  end

  @doc "The directories on this process's `PATH`, in order."
  @spec current_dirs() :: [String.t()]
  def current_dirs do
    case System.get_env("PATH") do
      path when is_binary(path) and path != "" -> String.split(path, ":", trim: true)
      _unset -> []
    end
  end

  @doc "Baseline directories this process's `PATH` does not carry."
  @spec missing_dirs(keyword()) :: [String.t()]
  def missing_dirs(opts \\ []) when is_list(opts) do
    current = current_dirs()
    Enum.reject(dirs(opts), &(&1 in current))
  end

  @doc "The OS family this baseline is built for."
  @spec os_family() :: os()
  def os_family do
    case :os.type() do
      {:unix, :darwin} -> :darwin
      _other -> :linux
    end
  end

  defp put_path(dirs) do
    added = dirs -- current_dirs()
    System.put_env("PATH", Enum.join(dirs, ":"))
    added
  end

  defp standard_bindirs(:darwin), do: @darwin_bindirs
  defp standard_bindirs(:linux), do: @linux_bindirs

  defp user_bindir(opts) do
    home = Keyword.get(opts, :user_home) || System.user_home!()
    Path.join(home, ".local/bin")
  end
end
