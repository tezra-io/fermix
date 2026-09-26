defmodule Fermix.CLI.Service.Templates do
  @moduledoc """
  Renders OS-specific service unit files.

  All values are interpolated as plain strings — paths are expected
  to come from `Fermix.CLI.Service.spec/2`, which controls the
  trust boundary. Templates are intentionally minimal: they restart
  on failure and run `fermix run` with no extra environment beyond
  `FERMIX_HOME` (when present).

  On Linux the daemon's rotating file handler is the single writer of
  `$FERMIX_HOME/logs/fermix.log`, so the unit sends its own streams to the
  journal instead (M38 §11.1). Two writers on one file meant systemd held an
  `O_APPEND` descriptor to an inode the daemon had already rotated away.

  A Linux system unit carries two lines a user unit does not: the account the
  daemon drops to (`run_as`, chosen by `Fermix.CLI.Service` when it renders a
  unit; none is systemd's root), and a refusal of the cloud instance-metadata
  endpoints.
  """

  # The BEAM opens many file descriptors (sockets, .beam modules, the SQLite
  # DB, channel pollers). macOS launchd defaults to 256 and systemd to ~1024 —
  # both far too low; raise the limit so the daemon never hits :emfile.
  @max_open_files 65_536

  # The instance-metadata endpoints (the shared IPv4 one and AWS's IPv6 one)
  # hand out the machine's cloud credentials to any local process that asks. A
  # daemon steered by something it read could ask through any tool that opens a
  # socket (the shell, the browser), so the unit's whole cgroup refuses them;
  # nothing Fermix does needs them. Only the system manager enforces an IP access
  # list: a per-user manager logs that it is not running as root and starts the
  # unit without one, so a user unit does not carry a line it cannot honour.
  # The browser refuses the same endpoints (`FermixCore.Net.Guard`): an endpoint
  # added here is added there too.
  @metadata_deny "IPAddressDeny=169.254.169.254/32 fd00:ec2::254/128"

  @spec render_darwin_plist(map()) :: String.t()
  def render_darwin_plist(%{
        label: label,
        fermix_path: fermix_path,
        service_env: service_env,
        log_path: log_path
      }) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>#{label}</string>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><true/>
      <key>ProcessType</key><string>Standard</string>
      <key>ExitTimeOut</key><integer>30</integer>
      <key>EnvironmentVariables</key>
      <dict>
    #{render_plist_env(service_env)}
      </dict>
      <key>SoftResourceLimits</key>
      <dict>
        <key>NumberOfFiles</key><integer>#{@max_open_files}</integer>
      </dict>
      <key>HardResourceLimits</key>
      <dict>
        <key>NumberOfFiles</key><integer>#{@max_open_files}</integer>
      </dict>
      <key>ProgramArguments</key>
      <array>
        <string>#{fermix_path}</string>
        <string>run</string>
      </array>
      <key>StandardOutPath</key><string>#{log_path}</string>
      <key>StandardErrorPath</key><string>#{log_path}</string>
    </dict>
    </plist>
    """
  end

  @spec render_linux_unit(map()) :: String.t()
  def render_linux_unit(
        %{
          scope: scope,
          fermix_path: fermix_path,
          service_env: service_env
        } = spec
      ) do
    description = "Fermix multi-agent platform daemon (#{scope}-scope)"

    """
    [Unit]
    Description=#{description}
    After=network-online.target
    Wants=network-online.target
    StartLimitIntervalSec=infinity
    StartLimitBurst=5

    [Service]
    Type=simple
    #{render_unit_env(service_env)}
    EnvironmentFile=-#{env_file(scope)}
    ExecStart=#{fermix_path} run
    Restart=always
    RestartSec=5
    TimeoutStopSec=30
    KillMode=mixed
    LimitNOFILE=#{@max_open_files}
    StandardOutput=journal
    StandardError=journal
    #{system_lines(scope, Map.get(spec, :run_as))}
    [Install]
    WantedBy=#{install_target(scope)}
    """
  end

  @doc """
  The account an installed unit's `User=` names, or `nil` when it names none.

  The inverse of the line `render_linux_unit/1` writes, read the way systemd
  reads it: only in `[Service]`, with the whitespace around `=` dropped, the
  last assignment winning, and an empty one resetting it to the default, root.
  """
  @spec unit_run_as(String.t()) :: String.t() | nil
  def unit_run_as(unit) when is_binary(unit) do
    unit
    |> service_section()
    |> Enum.flat_map(&(Regex.run(~r/^User\s*=\s*(.*)$/, &1, capture: :all_but_first) || []))
    |> List.last()
    |> assigned_account()
  end

  @doc """
  Whether a `User=` line can carry `name` as written.

  Whitespace would split the value, a control character would end the line, and
  `%` starts a specifier systemd would expand into some other name.
  """
  @spec unit_account?(String.t()) :: boolean()
  def unit_account?(name) when is_binary(name) do
    name != "" and not String.match?(name, ~r/[\s\x00-\x1f\x7f%]/)
  end

  @doc """
  The vendor unit the Linux distribution package installs (M38 §4.2).

  The package owns `/usr/lib/systemd/user/fermix.service`, so this text carries
  no install-time values at all: the home comes from the CLI-owned binding that
  `fermix service run` resolves, and the runtime payload lives under a directory
  named by a systemd specifier rather than an interpolated path.

  `packaging/linux/systemd/fermix.service` is the checked-in copy, and a test
  pins the two byte for byte.
  """
  @spec render_vendor_unit() :: String.t()
  def render_vendor_unit do
    """
    [Unit]
    Description=Fermix multi-agent platform daemon (user-scope)
    StartLimitIntervalSec=infinity
    StartLimitBurst=5

    [Service]
    Type=simple
    ExecStart=/usr/bin/fermix service run
    Environment=FERMIX_LINUX_PACKAGE_INSTALL_DIR=%h/.cache/fermix/runtime
    EnvironmentFile=-#{env_file(:user)}
    Restart=always
    RestartSec=5
    TimeoutStopSec=30
    KillMode=mixed
    LimitNOFILE=#{@max_open_files}
    StandardOutput=journal
    StandardError=journal

    [Install]
    WantedBy=default.target
    """
  end

  @doc """
  One `Environment=` assignment, serialized the way systemd reads it back.

  The whole assignment is quoted and the value escaped, because an unquoted
  value ends at the first space and a bare `%` is a specifier systemd expands:
  a home containing a space would silently become two assignments, and one
  containing `%h` would become the caller's home directory. Backslash and double
  quote are escaped, `%` is doubled, and a control character raises rather than
  producing a unit file systemd refuses to load at the worst possible moment.
  """
  @spec systemd_environment(String.t(), String.t()) :: String.t()
  def systemd_environment(key, value) when is_binary(key) and is_binary(value) do
    refuse_control_characters(key, "key")
    refuse_control_characters(value, "value")

    if key == "", do: raise(ArgumentError, "systemd Environment key must not be empty")

    ~s(Environment="#{key}=#{escape_unit_value(value)}")
  end

  # Sorted so generated files are stable across installs. Values are XML-escaped:
  # an unescaped `&` (e.g. in an Opik base URL query) produces an invalid plist
  # that launchd silently refuses to load.
  defp render_plist_env(service_env) do
    service_env
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join("\n", fn {key, value} ->
      "    <key>#{key}</key><string>#{xml_escape(value)}</string>"
    end)
  end

  defp render_unit_env(service_env) do
    service_env
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join("\n", fn {key, value} -> systemd_environment(key, value) end)
  end

  # Backslash first, so the backslashes the quote escape introduces are not
  # doubled again; `%` last, because doubling it touches nothing else.
  defp escape_unit_value(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("%", "%%")
  end

  defp refuse_control_characters(value, part) do
    if String.match?(value, ~r/[\x00-\x1f\x7f]/) do
      raise ArgumentError,
            "systemd Environment #{part} contains a control character, which a unit file " <>
              "cannot carry"
    end

    :ok
  end

  defp xml_escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp install_target(:user), do: "default.target"
  defp install_target(:system), do: "multi-user.target"

  # Each line ends in its own newline, so a user unit, which carries neither,
  # renders byte for byte as it always has. A user unit is its own account's by
  # construction, so an account for one has no clause and fails loud.
  defp system_lines(:user, nil), do: ""
  defp system_lines(:system, run_as), do: account_line(run_as) <> @metadata_deny <> "\n"

  # `Fermix.CLI.Service` checks the name before it renders; the raise is the
  # backstop that keeps a name it let through from injecting unit lines.
  defp account_line(nil), do: ""

  defp account_line(name) when is_binary(name) do
    if unit_account?(name),
      do: "User=#{name}\n",
      else: raise(ArgumentError, "systemd User= cannot carry #{inspect(name)} as written")
  end

  defp assigned_account(nil), do: nil
  defp assigned_account(""), do: nil
  defp assigned_account(name), do: name

  # A unit's `[Service]` lines, trimmed.
  defp service_section(unit) do
    unit
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.drop_while(&(&1 != "[Service]"))
    |> Enum.drop(1)
    |> Enum.take_while(&(not String.starts_with?(&1, "[")))
  end

  # The optional environment file a server with no keyring stores allowed
  # sandbox variables in (M45 §4.9); the unit's leading `-` makes it optional,
  # and Fermix never writes it. `%h` is the account's home in a user unit, but
  # `/root` in the system manager whatever `User=` says, so a system unit names
  # the machine-wide path.
  defp env_file(:user), do: "%h/.config/fermix/env"
  defp env_file(:system), do: "/etc/fermix/env"
end
