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
  """

  # The BEAM opens many file descriptors (sockets, .beam modules, the SQLite
  # DB, channel pollers). macOS launchd defaults to 256 and systemd to ~1024 —
  # both far too low; raise the limit so the daemon never hits :emfile.
  @max_open_files 65_536

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
  def render_linux_unit(%{
        scope: scope,
        fermix_path: fermix_path,
        service_env: service_env
      }) do
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

    [Install]
    WantedBy=#{install_target(scope)}
    """
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

  # The optional environment file a server with no keyring stores allowed
  # sandbox variables in (M45 §4.9); the unit's leading `-` makes it optional,
  # and Fermix never writes it. `%h` is the account's home in a user unit, but
  # `/root` in the system manager whatever `User=` says, so a system unit names
  # the machine-wide path.
  defp env_file(:user), do: "%h/.config/fermix/env"
  defp env_file(:system), do: "/etc/fermix/env"
end
