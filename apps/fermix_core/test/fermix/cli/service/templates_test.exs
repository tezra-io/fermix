defmodule Fermix.CLI.Service.TemplatesTest do
  use ExUnit.Case, async: true

  alias Fermix.CLI.Service.Templates

  describe "render_darwin_plist/1" do
    test "embeds label, fermix path, FERMIX_HOME, log paths" do
      plist =
        Templates.render_darwin_plist(%{
          label: "io.tezra.fermix",
          fermix_path: "/usr/local/bin/fermix",
          fermix_home: "/Users/dev/.fermix",
          log_path: "/Users/dev/.fermix/logs/fermix.log"
        })

      assert plist =~ "<key>Label</key><string>io.tezra.fermix</string>"
      assert plist =~ "<key>RunAtLoad</key><true/>"
      assert plist =~ "<key>KeepAlive</key><true/>"
      assert plist =~ "<key>ProcessType</key><string>Background</string>"
      assert plist =~ "<key>FERMIX_HOME</key><string>/Users/dev/.fermix</string>"
      assert plist =~ "<string>/usr/local/bin/fermix</string>"
      assert plist =~ "<string>run</string>"

      assert plist =~
               "<key>StandardOutPath</key><string>/Users/dev/.fermix/logs/fermix.log</string>"

      assert plist =~
               "<key>StandardErrorPath</key><string>/Users/dev/.fermix/logs/fermix.log</string>"
    end
  end

  describe "render_linux_unit/1" do
    test "user-scope unit installs to default.target with linger-friendly settings" do
      unit =
        Templates.render_linux_unit(%{
          scope: :user,
          fermix_path: "/usr/local/bin/fermix",
          fermix_home: "/home/dev/.fermix",
          log_path: "/home/dev/.fermix/logs/fermix.log"
        })

      assert unit =~ "Description=Fermix multi-agent platform daemon (user-scope)"
      assert unit =~ "After=network-online.target"
      assert unit =~ "Type=simple"
      assert unit =~ "Environment=FERMIX_HOME=/home/dev/.fermix"
      assert unit =~ "ExecStart=/usr/local/bin/fermix run"
      assert unit =~ "Restart=on-failure"
      assert unit =~ "RestartSec=5"
      assert unit =~ "StandardOutput=append:/home/dev/.fermix/logs/fermix.log"
      assert unit =~ "WantedBy=default.target"
    end

    test "system-scope unit installs to multi-user.target" do
      unit =
        Templates.render_linux_unit(%{
          scope: :system,
          fermix_path: "/usr/local/bin/fermix",
          fermix_home: "/var/lib/fermix",
          log_path: "/var/log/fermix/fermix.log"
        })

      assert unit =~ "Description=Fermix multi-agent platform daemon (system-scope)"
      assert unit =~ "WantedBy=multi-user.target"
      assert unit =~ "Environment=FERMIX_HOME=/var/lib/fermix"
    end
  end
end
