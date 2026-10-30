defmodule FermixCore.Sandbox.OsSandbox do
  @moduledoc """
  Kernel enforcement of the sandbox mode for the commands a turn runs
  (OS_SANDBOX_ENFORCEMENT rev 2).

  `FermixCore.Sandbox` decides whether a command may start and where. This
  module asks the kernel to hold the running command, and everything it starts,
  to the same writable roots, and to keep Fermix out of its reach in every mode:
  Fermix's home is never writable except the workspace and skills folders, its
  secrets are never readable, its sockets never answer, its installed code and
  plugin binaries cannot be changed or run, and nothing can be mounted over them.
  Outside `open`, the owner's credential folders and files are not readable
  either.

  On macOS the command runs under `sandbox-exec` with a Seatbelt profile. The
  profile is generated with indexed parameter names only; every path travels as
  a `-D` argument, so no path is ever spliced into it. Each path is
  symlink-resolved first, and one that cannot be resolved refuses the command:
  the kernel matches the path it resolved, so a rule given `/tmp/x` for
  `/private/tmp/x` would match nothing and switch itself off in silence. Case
  does not matter; the kernel compares without it.

  Seatbelt evaluates a filtered rule ahead of an unfiltered one, and the last of
  several filtered rules that match. Every carve-out therefore lives inside the
  one filtered write allowance, as a `require-not`.

  On Linux the command runs under the `fermix_landlock` exec shim with Landlock
  rules carved from the same path sets (`Sandbox.Landlock`). A kernel that
  cannot hold them (no Landlock, or ABI below 2: Linux before 5.19) refuses
  every command by name; nothing runs unconfined. On any other system commands
  run as before, and `Capabilities.AccessGate` asks the owner before one runs
  in a turn that read outside content (`enforced?/1`).
  """

  alias FermixCore.Browser.Bridge.HostManifest
  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.Landlock
  alias FermixCore.Sandbox.Mode
  alias FermixCore.Sandbox.PathPolicy

  @sandbox_exec "/usr/bin/sandbox-exec"
  @darwin {:unix, :darwin}
  @linux {:unix, :linux}

  # Fermix-home entries a command may never read: credentials (the file secret
  # store, the phone gateway's identity bundle under `mobile/`: `gateway_key`,
  # `tls.key`, `iroh_key`, and a desktop's key and receipts under `device/`),
  # the agent's browser cookies, and the logs and traces a token can survive
  # redaction in. `auth.json` and `memory.db` are matched with the files named
  # after them (`.tmp.N`, `-wal`) by the read-deny patterns instead.
  @secret_entries ~w(
    secrets secret_key_base setup-token setup-launch-token.json acp_identities
    mobile device plugins/run chatgpt_host.json browser/profiles logs traces
  )
  @secret_prefixed ~w(auth.json memory.db)

  # Outside Fermix's home, what a command may never read in any mode: an
  # Always-On host's enrollment code (M75). `PathPolicy` protects it from
  # writes as well.
  @system_secret ~w(/run/fermix)

  # Outside Fermix's home, what a command may never write in any mode: on macOS
  # the bootstrap record the Mac app keeps, every launch agent (a plist there
  # runs outside any sandbox at the next login), and the scheduler and system
  # databases setuid helpers write; on Linux the systemd user units (Fermix's
  # own among them) and the login autostart entries, which run outside any
  # sandbox the same way, and the browser host manifests (`host_manifests/2`).
  @home_protected %{
    @darwin => ["Library/Application Support/Fermix", "Library/LaunchAgents"],
    @linux => [".config/systemd/user", ".config/autostart"]
  }
  @system_protected %{@darwin => ~w(/private/var/at /private/var/db)}

  # Ordinary scratch space, writable in every mode: the shared temp folders, the
  # daemon's own temp folder, and every per-user `T/` and `C/` folder macOS tools
  # write whatever `$TMPDIR` says (`mktemp`, compilers' module caches). Another
  # account's are closed to this one by their own permissions. On Linux the
  # shared temp folders and `/dev/shm` (POSIX shared memory and semaphores).
  @system_writable ~w(/private/tmp /private/var/tmp)
  @user_temp_pattern "^/private/var/folders/[^/]+/[^/]+/(T|C)(/|$)"
  @linux_writable ~w(/tmp /var/tmp /dev/shm)

  # The device files a command writes on Linux (Seatbelt names its own in the
  # profile): the null sinks, its terminal, and pseudo-terminals it opens.
  @linux_devices ~w(/dev/null /dev/zero /dev/full /dev/tty /dev/ptmx /dev/pts)

  # Tool caches redirected into the workspace: the owner's own caches hold code
  # the daemon or the owner later runs (the browser tool's Chromium lives under
  # `~/Library/Caches/ms-playwright`), so a command never gets them.
  @cache_env [
    {"XDG_CACHE_HOME", ""},
    {"npm_config_cache", "npm"},
    {"YARN_CACHE_FOLDER", "yarn"},
    {"PIP_CACHE_DIR", "pip"},
    {"UV_CACHE_DIR", "uv"},
    {"GOCACHE", "go-build"},
    {"GOMODCACHE", "go-mod"},
    {"PLAYWRIGHT_BROWSERS_PATH", "ms-playwright"}
  ]

  @type spawn :: {String.t(), [String.t()]}

  @typedoc """
  A path a command may never read and how far its rule reaches: `:tree` is the
  path and everything under it, `:prefix` every path that begins with it, and
  `:named` the path, everything under it and the files named after it
  (`credentials.db-wal`).
  """
  @type unreadable :: {String.t(), :tree | :prefix | :named}

  @typedoc """
  The path sets a profile or the Landlock rules are built from, every one
  symlink-resolved. `credentials` and `unreadable` are the owner's credentials
  and the read rules in their structured form, which Landlock carves from; the
  patterns are Seatbelt's.
  """
  @type rules :: %{
          fermix_home: String.t(),
          writable: [String.t()],
          writable_patterns: [String.t()],
          fermix_writable: [String.t()],
          protected: [String.t()],
          protected_patterns: [String.t()],
          credentials: [String.t()],
          ancestors: [String.t()],
          unreadable: [unreadable()],
          secret: [String.t()],
          secret_patterns: [String.t()],
          no_exec: [String.t()]
        }

  @doc """
  The `{executable, args}` that runs `executable args` under the kernel sandbox
  for `config`. `request_cwd` is the turn's origin directory, which standard mode
  admits as a root (see `Mode.effective_roots/2`); `:roots` passes those roots
  when the caller already resolved them. `:os` is the platform seam; `:scratch`
  replaces the temp roots and pattern (tests, whose homes live in the temp
  folder, pass `[]`); `:landlock_shim` and `:fs` replace the shim and the
  filesystem the Linux rules are carved from.
  """
  @spec wrap(String.t(), [String.t()], Config.t(), String.t() | nil, keyword()) ::
          {:ok, spawn()} | {:error, term()}
  def wrap(executable, args, %Config{} = config, request_cwd, opts \\ [])
      when is_binary(executable) and is_list(args) and is_list(opts) do
    case platform(opts) do
      @darwin -> seatbelt(executable, args, config, request_cwd, opts)
      @linux -> landlock(executable, args, config, request_cwd, opts)
      _other -> {:ok, {executable, args}}
    end
  end

  defp seatbelt(executable, args, config, request_cwd, opts) do
    with {:ok, rules} <- rules(config, request_cwd, opts) do
      {:ok, {@sandbox_exec, ["-p", profile(rules)] ++ parameters(rules) ++ [executable | args]}}
    end
  end

  # The shim checks the kernel itself before every command, so a host without
  # Landlock refuses at the command, by name, with no probe here.
  defp landlock(executable, args, config, request_cwd, opts) do
    shim = landlock_shim(opts)
    fs = Keyword.get_lazy(opts, :fs, &Landlock.disk/0)

    with :ok <- shim_present(shim),
         {:ok, rules} <- rules(config, request_cwd, opts),
         {:ok, grants} <- Landlock.grants(landlock_input(rules), fs) do
      {:ok, {shim, Landlock.args(grants) ++ ["--", executable | args]}}
    end
  end

  defp shim_present(shim) do
    if File.regular?(shim), do: :ok, else: {:error, {:shim_missing, shim}}
  end

  defp landlock_input(rules) do
    rules
    |> Map.take([:writable, :fermix_home, :fermix_writable, :protected])
    |> Map.merge(%{
      credentials: rules.credentials,
      unreadable: rules.unreadable,
      no_exec: rules.no_exec,
      devices: @linux_devices
    })
  end

  @doc """
  `env` with the tool caches pointed into the workspace, where the kernel
  sandbox applies; a name `env` already carries (an allowed variable) wins.
  """
  @spec with_cache_env([{String.t(), String.t()}], Config.t(), keyword()) ::
          [{String.t(), String.t()}]
  def with_cache_env(env, %Config{} = config, opts \\ []) when is_list(env) and is_list(opts) do
    if platform(opts) in [@darwin, @linux] do
      root = Path.join(config.workspace_root, ".cache")

      @cache_env
      |> Enum.reject(fn {name, _dir} -> List.keymember?(env, name, 0) end)
      |> Enum.map(fn {name, dir} -> {name, Path.join(root, dir)} end)
      |> Kernel.++(env)
    else
      env
    end
  end

  @doc """
  The sentence for a command the sandbox itself refused, or nil when the exit
  is the command's: a profile `sandbox-exec` refused (exit 64 or 65 with its
  own line), or the Landlock shim's own refusal (`Landlock.refusal/2`: a kernel
  that cannot hold commands, or a rule it could not add). `sandbox-exec`'s exit
  71, a sandbox that could not be applied, is left to the command: a command
  that starts a sandbox of its own (`codex`, `claude`) fails the same way
  inside Fermix's.
  """
  @spec refusal(integer(), String.t()) :: String.t() | nil
  def refusal(exit_code, "sandbox-exec: " <> _rest = output) when exit_code in [64, 65] do
    line = output |> String.split("\n", parts: 2) |> hd()
    "The command could not start inside Fermix's sandbox: #{line}"
  end

  def refusal(exit_code, output) when is_integer(exit_code) and is_binary(output),
    do: Landlock.refusal(exit_code, output)

  @doc "The sentence for a `rules/3` error: why no command can run."
  @spec describe(term()) :: String.t()
  def describe({:unresolvable_path, path, reason}),
    do: "Commands can't run: Fermix's sandbox could not resolve #{path} (#{inspect(reason)})."

  def describe({:relative_path, path}),
    do: "Commands can't run: Fermix's sandbox was given a relative path, #{path}."

  def describe(:no_writable_root),
    do: "Commands can't run: the sandbox mode leaves no folder a command may write."

  def describe({:shim_missing, _shim} = reason), do: Landlock.describe(reason)

  def describe({:unlistable, path, reason}),
    do: "Commands can't run: Fermix's sandbox could not list #{path} (#{inspect(reason)})."

  def describe({:too_many_rules, count, max}),
    do:
      "Commands can't run: Fermix's sandbox would need #{count} rules here, more than #{max}; " <>
        "a folder with that many entries holds a protected path (is Fermix's home inside a " <>
        "busy temp folder?)."

  @doc """
  Whether the kernel holds commands to the sandbox here, as `fermix sandbox
  explain` says it. On Linux it asks the shim (`Landlock.probe/1`).
  """
  @spec enforcement(keyword()) :: String.t()
  def enforcement(opts \\ []) when is_list(opts) do
    case platform(opts) do
      @darwin -> "held by the kernel (Seatbelt)"
      @linux -> landlock_enforcement(landlock_probe(opts))
      _other -> "not held by the kernel on this system"
    end
  end

  defp landlock_enforcement({:ok, abi}), do: "held by the kernel (Landlock ABI #{abi})"
  defp landlock_enforcement({:error, reason}), do: "refused: " <> Landlock.describe(reason)

  @doc """
  Whether the kernel holds commands to the sandbox on this host: macOS
  (Seatbelt), and Linux where the Landlock shim is installed and the kernel's
  ABI is 2 or later, which asks the shim (one short process; `:landlock` pins
  its answer in tests). `:os` is the platform seam, as in `wrap/5`. The one
  source of this fact: `Capabilities.AccessGate` reads it too, to ask the owner
  before a host command runs after outside content where it is false. A Linux
  host where it is false refuses every confined command anyway.
  """
  @spec enforced?(keyword()) :: boolean()
  def enforced?(opts \\ []) when is_list(opts) do
    case platform(opts) do
      @darwin -> true
      @linux -> match?({:ok, _abi}, landlock_probe(opts))
      _other -> false
    end
  end

  defp landlock_probe(opts),
    do: Keyword.get_lazy(opts, :landlock, fn -> Landlock.probe(landlock_shim(opts)) end)

  defp landlock_shim(opts), do: Keyword.get_lazy(opts, :landlock_shim, &Landlock.shim_path/0)

  defp platform(opts), do: Keyword.get(opts, :os, :os.type())

  @doc "The path sets for `config`. Options as `wrap/5`."
  @spec rules(Config.t(), String.t() | nil, keyword()) :: {:ok, rules()} | {:error, term()}
  def rules(%Config{} = config, request_cwd, opts)
      when (is_binary(request_cwd) or is_nil(request_cwd)) and is_list(opts) do
    roots = Keyword.get_lazy(opts, :roots, fn -> Mode.effective_roots(config, request_cwd) end)
    {scratch, scratch_patterns} = scratch(opts)

    with {:ok, fermix_home} <- resolve_one(config.home),
         {:ok, os_home} <- resolve_one(config.os_home),
         {:ok, scratch} <- resolve(scratch),
         {:ok, writable} <- writable(config, roots, scratch),
         {:ok, protected} <- protected(config, platform(opts)),
         {:ok, fermix_writable} <- fermix_writable(config, fermix_home),
         {:ok, own} <- resolve([config.workspace_root, Path.join(config.home, "skills")]),
         {:ok, credentials} <- resolve(PathPolicy.credential_paths(config)),
         {:ok, unreadable} <- unreadable(config) do
      {:ok,
       %{
         fermix_home: fermix_home,
         writable: writable,
         writable_patterns: scratch_patterns,
         fermix_writable: fermix_writable,
         protected: protected,
         protected_patterns: protected_patterns(os_home, credentials),
         credentials: credentials,
         ancestors: Enum.uniq(ancestors([fermix_home | protected]) ++ own),
         unreadable: unreadable,
         secret: for({path, reach} <- unreadable, reach != :prefix, do: path),
         secret_patterns: Enum.flat_map(unreadable, &read_pattern/1),
         no_exec: [Path.join(fermix_home, "plugins")]
       }}
    end
  end

  # Open mode reaches every path the account can write, minus the protected set;
  # the file tools keep it to the OS home. The kernel may be wider than the
  # policy, never narrower.
  defp writable(config, roots, scratch) do
    mode_roots = if config.mode == :open, do: ["/"], else: []

    case resolve(mode_roots ++ roots) do
      {:ok, resolved} when resolved == [] and scratch == [] -> {:error, :no_writable_root}
      {:ok, resolved} -> {:ok, Enum.uniq(resolved ++ scratch)}
      error -> error
    end
  end

  defp scratch(opts) do
    case Keyword.fetch(opts, :scratch) do
      {:ok, roots} when is_list(roots) -> {roots, []}
      :error -> default_scratch(platform(opts))
    end
  end

  defp default_scratch(@darwin),
    do: {@system_writable ++ [System.tmp_dir!()], [@user_temp_pattern]}

  defp default_scratch(_linux_or_other), do: {@linux_writable ++ [System.tmp_dir!()], []}

  # A blocked root stays closed to commands as it is to the file tools, even in
  # `open`, where every other folder is writable.
  defp protected(config, os) do
    code_root = List.to_string(:code.root_dir())
    home = Enum.map(Map.get(@home_protected, os, []), &Path.join(config.os_home, &1))

    resolve(
      PathPolicy.protected_paths(config) ++
        [code_root | home] ++
        Map.get(@system_protected, os, []) ++
        host_manifests(config, os) ++ @system_secret ++ config.blocked_roots
    )
  end

  # Seatbelt closes every browser's host manifest by one pattern
  # (`protected_patterns/2`); Landlock names each file.
  defp host_manifests(config, @linux) do
    base = Path.join(config.os_home, ".config")

    for browser <- HostManifest.browsers(),
        {:ok, path} <- [HostManifest.manifest_path(browser, os: :linux, base: base)],
        do: path
  end

  defp host_manifests(_config, _os), do: []

  defp protected_patterns(os_home, credentials) do
    support = Path.join(os_home, "Library/Application Support")
    host = HostManifest.host_name() <> "."

    ["^" <> escape(support) <> "/.*/NativeMessagingHosts/" <> escape(host)] ++
      Enum.map(credentials, &siblings/1)
  end

  # Inside Fermix's home only the workspace, the skills folder and a folder the
  # owner granted stay writable. A request or launch folder that happens to sit
  # inside the home does not.
  defp fermix_writable(config, fermix_home) do
    candidates = [config.workspace_root, Path.join(config.home, "skills") | config.allowed_roots]

    with {:ok, resolved} <- resolve(candidates) do
      {:ok, Enum.filter(resolved, &inside?(&1, fermix_home))}
    end
  end

  @doc """
  What a command may never read under `config`, every path symlink-resolved:
  Fermix's secrets in every mode (`/run/fermix` among them), and outside `open`
  the owner's credentials. `~/.config/fermix` is named on its own because
  `open` reads the rest of the owner's credentials. `secret_writer` stages a key
  being saved under the home's `secrets/.staging-N/`, inside the `secrets` tree.
  The one list both kernels' read rules and `fermix sandbox explain` derive
  from; every entry is write-protected too.
  """
  @spec unreadable(Config.t()) :: {:ok, [unreadable()]} | {:error, term()}
  def unreadable(%Config{} = config) do
    with {:ok, fermix_home} <- resolve_one(config.home),
         {:ok, trees} <-
           resolve(
             Enum.map(@secret_entries, &Path.join(fermix_home, &1)) ++
               [Path.join(config.os_home, ".config/fermix") | @system_secret]
           ),
         {:ok, named} <- resolve(owner_credentials(config, PathPolicy.credential_paths(config))) do
      prefixed = Enum.map(@secret_prefixed, &Path.join(fermix_home, &1))
      # A path the owner's credentials also name keeps their wider rule.
      trees = Enum.reject(trees, &(&1 in named))

      {:ok,
       Enum.map(trees, &{&1, :tree}) ++
         Enum.map(prefixed, &{&1, :prefix}) ++ Enum.map(named, &{&1, :named})}
    end
  end

  # The owner's SSH keys, cloud logins and tokens are closed to reads in `strict`
  # and `standard`; `open` lets a command use them (`git push` over SSH, `aws`).
  # Every one, and every file named after one, is also protected, so no mode can
  # rename it out from under this.
  defp owner_credentials(%Config{mode: :open}, _credentials), do: []
  defp owner_credentials(_config, credentials), do: credentials

  defp read_pattern({path, :prefix}), do: [prefix(path)]
  defp read_pattern({path, :named}), do: [siblings(path)]
  defp read_pattern({_path, :tree}), do: []

  # A protected path, or Fermix's home, renamed away from under its rule leaves
  # the rule guarding nothing, so every directory above one is closed to writes
  # on its own name (writes to the entries inside it are judged separately). The
  # workspace and skills folders are closed the same way, so one command cannot
  # move the only writable root away.
  defp ancestors(paths) do
    paths
    |> Enum.flat_map(&parents/1)
    |> Enum.uniq()
  end

  defp parents(path) do
    path
    |> Path.split()
    |> Enum.drop(-1)
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.reject(&(&1 == "/"))
  end

  defp resolve(paths) do
    paths
    |> Enum.reduce_while([], fn path, acc ->
      case resolve_one(path) do
        {:ok, resolved} -> {:cont, [resolved | acc]}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      resolved -> {:ok, resolved |> Enum.reverse() |> Enum.uniq()}
    end
  end

  defp resolve_one("/" <> _rest = path) do
    case PathPolicy.resolve_links(path) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, reason} -> {:error, {:unresolvable_path, path, reason}}
    end
  end

  defp resolve_one(path), do: {:error, {:relative_path, path}}

  defp inside?(path, dir), do: String.starts_with?(path, dir <> "/")

  defp prefix(path), do: "^" <> escape(path)

  # The files named after a path (`credentials.db-journal`, `.claude.json.backup`),
  # which `PathPolicy.protected?/2` counts as the path itself. An alternation, not
  # a bracket: Seatbelt refuses `[.-]` as an unterminated bracket expression.
  defp siblings(path), do: prefix(path) <> "(\\.|-)"

  # Seatbelt's regex is POSIX-extended: only its metacharacters are escaped, since
  # an escaped `-` or `:` (which `Regex.escape/1` produces) is not portable there.
  defp escape(text), do: String.replace(text, ~r/[\\.\[\](){}*+?^$|]/, "\\\\\\0")

  @doc "The Seatbelt profile for `rules`: indexed parameter names, never a path."
  @spec profile(rules()) :: String.t()
  def profile(rules) do
    """
    (version 1)
    (allow default)
    (deny file-write*)
    (allow file-write*
      (require-all
        (require-any #{refs("W", rules.writable, "subpath")} #{refs("WX", rules.writable_patterns, "regex")})
        #{nots("P", rules.protected, "subpath")}
        #{nots("PX", rules.protected_patterns, "regex")}
        #{nots("A", rules.ancestors, "literal")}
        (require-any (require-not (subpath (param "FH"))) #{refs("FW", rules.fermix_writable, "subpath")})))
    (allow file-write-data
      (literal "/dev/null") (literal "/dev/zero") (literal "/dev/tty")
      (literal "/dev/dtracehelper") (regex #"^/dev/fd/[0-9]+$"))
    (allow pseudo-tty)
    (allow file-read* file-write* file-ioctl (literal "/dev/ptmx"))
    (allow file-read* file-write* file-ioctl
      (require-all (regex #"^/dev/ttys[0-9]+$") (extension "com.apple.sandbox.pty")))
    (deny file-read* #{refs("S", rules.secret, "subpath")} #{refs("SX", rules.secret_patterns, "regex")})
    (deny network-outbound (remote unix-socket (path-prefix (param "FHS"))))
    (deny process-exec #{refs("X", rules.no_exec, "subpath")})
    (deny file-mount)
    (allow file-mount (subpath "/Volumes"))
    """
  end

  defp refs(prefix, paths, kind) do
    paths
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {_path, i} -> ~s|(#{kind} (param "#{prefix}#{i}"))| end)
  end

  defp nots(prefix, paths, kind) do
    paths
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {_path, i} ->
      ~s|(require-not (#{kind} (param "#{prefix}#{i}")))|
    end)
  end

  @doc "The `-D NAME=VALUE` arguments that bind `profile/1`'s parameters."
  @spec parameters(rules()) :: [String.t()]
  def parameters(rules) do
    bindings =
      [{"FH", rules.fermix_home}, {"FHS", rules.fermix_home <> "/"}] ++
        indexed("W", rules.writable) ++
        indexed("WX", rules.writable_patterns) ++
        indexed("P", rules.protected) ++
        indexed("PX", rules.protected_patterns) ++
        indexed("A", rules.ancestors) ++
        indexed("FW", rules.fermix_writable) ++
        indexed("S", rules.secret) ++
        indexed("SX", rules.secret_patterns) ++
        indexed("X", rules.no_exec)

    Enum.flat_map(bindings, fn {name, value} -> ["-D", "#{name}=#{value}"] end)
  end

  defp indexed(prefix, paths) do
    paths
    |> Enum.with_index()
    |> Enum.map(fn {path, i} -> {"#{prefix}#{i}", path} end)
  end
end
