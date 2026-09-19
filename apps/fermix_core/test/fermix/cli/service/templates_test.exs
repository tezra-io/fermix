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
          service_env: %{"FERMIX_HOME" => "/home/dev/.fermix"}
        })

      assert unit =~ "Description=Fermix multi-agent platform daemon (user-scope)"
      assert unit =~ "After=network-online.target"
      assert unit =~ "StartLimitIntervalSec=infinity"
      assert unit =~ "StartLimitBurst=5"
      assert unit =~ "Type=simple"
      assert unit =~ ~s(Environment="FERMIX_HOME=/home/dev/.fermix")
      assert unit =~ "ExecStart=/usr/local/bin/fermix run"
      assert unit =~ "Restart=always"
      assert unit =~ "RestartSec=5"
      assert unit =~ "TimeoutStopSec=30"
      assert unit =~ "KillMode=mixed"
      assert unit =~ "LimitNOFILE=65536"
      assert unit =~ "WantedBy=default.target"
    end

    # M38 §11.1: the daemon's rotating handler is the single writer of
    # `fermix.log`. A unit that still appended to it held a descriptor to an
    # inode the daemon had already rotated away, so half the log vanished.
    test "the unit writes to the journal and never to the daemon's own log file" do
      for scope <- [:user, :system] do
        unit =
          Templates.render_linux_unit(%{
            scope: scope,
            fermix_path: "/usr/local/bin/fermix",
            service_env: %{"FERMIX_HOME" => "/home/dev/.fermix"}
          })

        assert unit =~ "StandardOutput=journal"
        assert unit =~ "StandardError=journal"
        refute unit =~ "append:"
      end
    end

    test "system-scope unit installs to multi-user.target" do
      unit =
        Templates.render_linux_unit(%{
          scope: :system,
          fermix_path: "/usr/local/bin/fermix",
          service_env: %{"FERMIX_HOME" => "/var/lib/fermix"}
        })

      assert unit =~ "Description=Fermix multi-agent platform daemon (system-scope)"
      assert unit =~ "WantedBy=multi-user.target"
      assert unit =~ ~s(Environment="FERMIX_HOME=/var/lib/fermix")
    end

    # M45 §4.9: a server with no keyring feeds allowed sandbox variables to
    # the daemon through an optional environment file. The leading `-` keeps a
    # missing file from failing the unit. `%h` is the user manager's home in a
    # user unit, but `/root` in the system manager, so a system unit names a
    # fixed path instead.
    test "the user-scope unit loads the optional per-user env file" do
      unit =
        Templates.render_linux_unit(%{
          scope: :user,
          fermix_path: "/usr/local/bin/fermix",
          service_env: %{"FERMIX_HOME" => "/home/dev/.fermix"}
        })

      assert environment_files(unit) == ["EnvironmentFile=-%h/.config/fermix/env"]
    end

    test "the system-scope unit loads the optional machine env file" do
      unit =
        Templates.render_linux_unit(%{
          scope: :system,
          fermix_path: "/usr/local/bin/fermix",
          service_env: %{"FERMIX_HOME" => "/var/lib/fermix"}
        })

      assert environment_files(unit) == ["EnvironmentFile=-/etc/fermix/env"]
    end
  end

  describe "render_vendor_unit/0" do
    test "matches the unit the Linux package installs, byte for byte" do
      packaged =
        __DIR__
        |> Path.join("../../../../../../packaging/linux/systemd/fermix.service")
        |> Path.expand()

      assert File.read!(packaged) == Templates.render_vendor_unit()
    end

    test "carries the launch entry point, the restart budget and the journal" do
      unit = Templates.render_vendor_unit()

      assert unit =~ "Description=Fermix multi-agent platform daemon (user-scope)"
      assert unit =~ "StartLimitIntervalSec=infinity"
      assert unit =~ "StartLimitBurst=5"
      assert unit =~ "ExecStart=/usr/bin/fermix service run"
      # The payload directory is a systemd specifier, never an interpolated home:
      # the package installs one unit for every account on the machine.
      assert unit =~ "Environment=FERMIX_LINUX_PACKAGE_INSTALL_DIR=%h/.cache/fermix/runtime"
      assert unit =~ "Restart=always"
      assert unit =~ "RestartSec=5"
      assert unit =~ "TimeoutStopSec=30"
      assert unit =~ "KillMode=mixed"
      assert unit =~ "LimitNOFILE=65536"
      assert unit =~ "StandardOutput=journal"
      assert unit =~ "StandardError=journal"
      assert unit =~ "WantedBy=default.target"
      refute unit =~ "append:"
    end

    # The package owns this unit for every account on the machine, so a home, a
    # log path or an install-time PATH baked into it would be one user's.
    test "carries no install-time value" do
      unit = Templates.render_vendor_unit()

      environment_lines =
        unit |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "Environment="))

      assert environment_lines == [
               "Environment=FERMIX_LINUX_PACKAGE_INSTALL_DIR=%h/.cache/fermix/runtime"
             ]

      refute unit =~ "FERMIX_HOME"
      refute unit =~ System.user_home!()
    end

    # One file per account, named by the specifier like the payload directory.
    test "loads the optional per-user env file" do
      assert environment_files(Templates.render_vendor_unit()) == [
               "EnvironmentFile=-%h/.config/fermix/env"
             ]
    end
  end

  describe "systemd_environment/2" do
    test "quotes the whole assignment so a space cannot split it" do
      assert Templates.systemd_environment("FERMIX_HOME", "/home/o/my fermix") ==
               ~s(Environment="FERMIX_HOME=/home/o/my fermix")
    end

    # A bare `%` is a systemd specifier: `%h` in an unescaped value expands to
    # the caller's home directory and the daemon silently runs somewhere else.
    test "doubles a percent so systemd reads it as a literal" do
      assert Templates.systemd_environment("FERMIX_HOME", "/home/o/100%/%h") ==
               ~s(Environment="FERMIX_HOME=/home/o/100%%/%%h")
    end

    # A backslash is escaped before the quote escape runs, so the backslashes
    # the quote escape introduces are not doubled a second time.
    test "escapes backslash and double quote, in that order" do
      assert Templates.systemd_environment("K", ~S(a\b"c)) ==
               ~S(Environment="K=a\\b\"c")
    end

    test "refuses a control character in either half" do
      assert_raise ArgumentError, ~r/control character/, fn ->
        Templates.systemd_environment("K", "line\nbreak")
      end

      assert_raise ArgumentError, ~r/control character/, fn ->
        Templates.systemd_environment("K\0", "value")
      end
    end

    test "refuses an empty key" do
      assert_raise ArgumentError, ~r/must not be empty/, fn ->
        Templates.systemd_environment("", "value")
      end
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
          }
        })

      assert unit =~ ~s(Environment="FERMIX_HOME=/home/dev/.fermix")
      assert unit =~ ~s(Environment="FERMIX_OPIK_ENABLED=1")
      assert pos(unit, "FERMIX_HOME") < pos(unit, "FERMIX_OPIK_ENABLED")
    end

    # A home with a space round-trips through the unit as one assignment.
    test "linux escapes a home carrying spaces and percent characters" do
      unit =
        Templates.render_linux_unit(%{
          scope: :user,
          fermix_path: "/usr/local/bin/fermix",
          service_env: %{"FERMIX_HOME" => "/home/dev/my 100% fermix"}
        })

      assert unit =~ ~s(Environment="FERMIX_HOME=/home/dev/my 100%% fermix")
    end
  end

  defp pos(haystack, needle), do: :binary.match(haystack, needle) |> elem(0)

  defp environment_files(unit) do
    unit |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "EnvironmentFile="))
  end
end
