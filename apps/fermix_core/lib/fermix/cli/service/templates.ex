defmodule Fermix.CLI.Service.Templates do
  @moduledoc """
  Renders OS-specific service unit files.

  All values are interpolated as plain strings — paths are expected
  to come from `Fermix.CLI.Service.spec/2`, which controls the
  trust boundary. Templates are intentionally minimal: they restart
  on failure, log to a single rotating file, and run `fermix run`
  with no extra environment beyond `FERMIX_HOME` (when present).
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
      <key>ProcessType</key><string>Background</string>
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
        service_env: service_env,
        log_path: log_path
      }) do
    description = "Fermix multi-agent platform daemon (#{scope}-scope)"

    """
    [Unit]
    Description=#{description}
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=simple
    #{render_unit_env(service_env)}
    ExecStart=#{fermix_path} run
    Restart=on-failure
    RestartSec=5
    LimitNOFILE=#{@max_open_files}
    StandardOutput=append:#{log_path}
    StandardError=append:#{log_path}

    [Install]
    WantedBy=#{install_target(scope)}
    """
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
    |> Enum.map_join("\n", fn {key, value} -> "Environment=#{key}=#{value}" end)
  end

  defp xml_escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp install_target(:user), do: "default.target"
  defp install_target(:system), do: "multi-user.target"
end
