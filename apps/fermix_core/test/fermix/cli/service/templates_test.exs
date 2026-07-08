defmodule Fermix.CLI.Service.TemplatesTest do
  use ExUnit.Case, async: true

  alias Fermix.CLI.Service.Templates

  describe "render_darwin_plist/1" do
    test "embeds label, fermix path, FERMIX_HOME, log paths" do
      plist =
        Templates.render_darwin_plist(%{
          label: "io.tezra.fermix",
          fermix_path: "/usr/local/bin/fermix",
          service_env: %{"FERMIX_HOME" => "/Users/dev/.fermix"},
          log_path: "/Users/dev/.fermix/logs/fermix.log"
        })

      assert plist =~ "<key>Label</key><string>io.tezra.fermix</string>"
      assert plist =~ "<key>RunAtLoad</key><true/>"
      assert plist =~ "<key>KeepAlive</key><true/>"
      # Standard (not Background): Background puts the daemon in macOS's darwinbg
      # QoS band — CPU/IO/timer throttled under load, which starved the
      # user-facing HTTP daemon while the foreground dev process stayed fast.
      assert plist =~ "<key>ProcessType</key><string>Standard</string>"

      # ExitTimeOut > launchd's 20s default so a graceful shutdown (Phoenix
      # connection drain) on SIGTERM/bootout is not escalated to SIGKILL.
      assert plist =~ "<key>ExitTimeOut</key><integer>30</integer>"
      assert plist =~ "<key>FERMIX_HOME</key><string>/Users/dev/.fermix</string>"
      assert plist =~ "<string>/usr/local/bin/fermix</string>"
      assert plist =~ "<string>run</string>"
      assert plist =~ "<key>NumberOfFiles</key><integer>65536</integer>"

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
          service_env: %{"FERMIX_HOME" => "/home/dev/.fermix"},
          log_path: "/home/dev/.fermix/logs/fermix.log"
        })

      assert unit =~ "Description=Fermix multi-agent platform daemon (user-scope)"
      assert unit =~ "After=network-online.target"
      assert unit =~ "Type=simple"
      assert unit =~ "Environment=FERMIX_HOME=/home/dev/.fermix"
      assert unit =~ "ExecStart=/usr/local/bin/fermix run"
      assert unit =~ "Restart=on-failure"
      assert unit =~ "RestartSec=5"
      assert unit =~ "LimitNOFILE=65536"
      assert unit =~ "StandardOutput=append:/home/dev/.fermix/logs/fermix.log"
      assert unit =~ "WantedBy=default.target"
    end

    test "system-scope unit installs to multi-user.target" do
      unit =
        Templates.render_linux_unit(%{
          scope: :system,
          fermix_path: "/usr/local/bin/fermix",
          service_env: %{"FERMIX_HOME" => "/var/lib/fermix"},
          log_path: "/var/log/fermix/fermix.log"
        })

      assert unit =~ "Description=Fermix multi-agent platform daemon (system-scope)"
      assert unit =~ "WantedBy=multi-user.target"
      assert unit =~ "Environment=FERMIX_HOME=/var/lib/fermix"
    end
  end

  describe "service env rendering" do
    test "darwin renders all env vars sorted in EnvironmentVariables" do
      plist =
        Templates.render_darwin_plist(%{
          label: "io.tezra.fermix",
          fermix_path: "/usr/local/bin/fermix",
          service_env: %{
            "FERMIX_HOME" => "/Users/dev/.fermix",
            "FERMIX_OPIK_ENABLED" => "1",
            "FERMIX_OPIK_BASE_URL" => "http://localhost:5173/api"
          },
          log_path: "/Users/dev/.fermix/logs/fermix.log"
        })

      assert plist =~ "<key>FERMIX_HOME</key><string>/Users/dev/.fermix</string>"
      assert plist =~ "<key>FERMIX_OPIK_ENABLED</key><string>1</string>"

      assert plist =~
               "<key>FERMIX_OPIK_BASE_URL</key><string>http://localhost:5173/api</string>"

      # Stable, sorted output: FERMIX_HOME < FERMIX_OPIK_BASE_URL < FERMIX_OPIK_ENABLED
      assert pos(plist, "FERMIX_HOME") < pos(plist, "FERMIX_OPIK_BASE_URL")
      assert pos(plist, "FERMIX_OPIK_BASE_URL") < pos(plist, "FERMIX_OPIK_ENABLED")
    end

    test "darwin xml-escapes env values" do
      plist =
        Templates.render_darwin_plist(%{
          label: "io.tezra.fermix",
          fermix_path: "/usr/local/bin/fermix",
          service_env: %{"FERMIX_OPIK_BASE_URL" => "http://h/api?a=1&b=2"},
          log_path: "/l"
        })

      assert plist =~ "<string>http://h/api?a=1&amp;b=2</string>"
      refute plist =~ "?a=1&b=2"
    end

    test "linux renders all env vars sorted as Environment= lines" do
      unit =
        Templates.render_linux_unit(%{
          scope: :user,
          fermix_path: "/usr/local/bin/fermix",
          service_env: %{
            "FERMIX_HOME" => "/home/dev/.fermix",
            "FERMIX_OPIK_ENABLED" => "1"
          },
          log_path: "/home/dev/.fermix/logs/fermix.log"
        })

      assert unit =~ "Environment=FERMIX_HOME=/home/dev/.fermix"
      assert unit =~ "Environment=FERMIX_OPIK_ENABLED=1"
      assert pos(unit, "Environment=FERMIX_HOME") < pos(unit, "Environment=FERMIX_OPIK_ENABLED")
    end
  end

  defp pos(haystack, needle), do: :binary.match(haystack, needle) |> elem(0)
end
