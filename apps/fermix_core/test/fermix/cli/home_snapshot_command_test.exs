defmodule Fermix.CLI.HomeSnapshotCommandTest do
  # Sync: the verbs print their refusals on `:standard_error`, one globally
  # registered device that concurrent captures would share.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.HomeCommand
  alias Fermix.CLI.MachineOutput
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Moved
  alias FermixCore.Home.Snapshot
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixTestSupport.SafeRm

  @passphrase "invented-quarry-semaphore"
  @now_ms 1_793_083_733_000

  setup_all do
    {:ok, pair} = Recipient.from_passphrase(@passphrase)
    %{pair: pair}
  end

  setup do
    tmp = SafeRm.make_tmp_dir!("home_snapshot_command")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)

    home = Path.join(tmp, "home")
    File.mkdir_p!(home)

    File.write!(
      Path.join(home, "config.toml"),
      "[sandbox]\nworkspace_root = \"#{home}/workspace\"\n"
    )

    File.write!(Path.join(home, "journal.md"), "an invented journal\n")
    :ok = Epoch.write(home, 5)

    passphrase_file = Path.join(tmp, "passphrase")
    File.write!(passphrase_file, @passphrase <> "\n")

    %{
      tmp: tmp,
      home: home,
      snapshot: Path.join(tmp, "home.fxsnap"),
      into: Path.join(tmp, "restored"),
      passphrase_file: passphrase_file
    }
  end

  describe "import of a snapshot" do
    test "restores it with the recovery passphrase, one epoch above", ctx do
      {:ok, _written} =
        Snapshot.write(ctx.home, Recipient.public(ctx.pair), ctx.snapshot, host: "macos-aarch64")

      {status, out, err} =
        run([
          "import",
          ctx.snapshot,
          "--into",
          ctx.into,
          "--passphrase-file",
          ctx.passphrase_file
        ])

      assert {status, err} == {0, ""}
      assert out =~ "Restored 3 files into #{ctx.into} at primary epoch 6."
      assert out =~ "Rewrote 1 path in config.toml: sandbox.workspace_root."
      assert File.read!(Path.join(ctx.into, "journal.md")) == "an invented journal\n"
      assert Epoch.read(ctx.into) == {:ok, 6}
    end

    test "the wrong passphrase writes nothing and says so", ctx do
      {:ok, _written} =
        Snapshot.write(ctx.home, Recipient.public(ctx.pair), ctx.snapshot, host: "macos-aarch64")

      File.write!(ctx.passphrase_file, "another-invented-passphrase\n")

      {status, out, err} =
        run([
          "import",
          ctx.snapshot,
          "--into",
          ctx.into,
          "--passphrase-file",
          ctx.passphrase_file
        ])

      assert {status, out} == {1, ""}

      assert err ==
               "fermix home: The passphrase does not open this snapshot: it was encrypted to " <>
                 "another recovery key. Nothing was written.\n"

      refute File.exists?(ctx.into)
    end

    test "a damaged snapshot writes nothing and says so", ctx do
      {:ok, written} =
        Snapshot.write(ctx.home, Recipient.public(ctx.pair), ctx.snapshot, host: "macos-aarch64")

      bytes = File.read!(ctx.snapshot)
      File.write!(ctx.snapshot, binary_part(bytes, 0, written.size - 3))

      {status, _out, err} =
        run([
          "import",
          ctx.snapshot,
          "--into",
          ctx.into,
          "--passphrase-file",
          ctx.passphrase_file
        ])

      assert status == 1
      assert err =~ "The snapshot ends before its last chunk"
      refute File.exists?(ctx.into)
    end
  end

  describe "home status" do
    test "with Fermix stopped, reads the home's own files", ctx do
      {status, out, err} = run(["status", "--json"], home: ctx.home, client: stopped())

      assert {status, err} == {0, ""}
      assert %{"ok" => true, "result" => result} = Jason.decode!(out)
      assert result["role"] == "primary"
      assert result["epoch"] == 5
      assert result["snapshots"]["sentence"] =~ "set a recovery passphrase"

      {0, human, ""} = run(["status"], home: ctx.home, client: stopped())
      assert human =~ "Role: primary\nPrimary epoch: 5\n"
      assert human =~ "Snapshots: Snapshots are off: set a recovery passphrase to turn them on."
    end

    test "a home marked moved reads as a device, naming where it went", ctx do
      :ok =
        Moved.write(ctx.home, %{epoch: 5, moved_at: ~U[2026-10-27 09:30:00Z], to: "invented vm"})

      {0, out, ""} = run(["status"], home: ctx.home, client: stopped())

      assert out =~ "Role: device\n"
      assert out =~ "Moved to invented vm at 2026-10-27T09:30:00Z, at epoch 5."
    end

    test "with Fermix running, prints what the engine answers", ctx do
      answer = %{"role" => "primary", "snapshots" => %{"sentence" => "from the engine"}}
      client = fn "home.status", %{}, opts -> socket(opts, ctx.home) && {:ok, answer} end

      {0, out, ""} = run(["status", "--json"], home: ctx.home, client: client)
      assert Jason.decode!(out) == %{"ok" => true, "result" => answer, "schema_version" => 1}
    end

    test "names the secrets to enter again, the key each point opens with, and a wait", ctx do
      answer = %{
        "role" => "primary",
        "epoch" => 5,
        "secrets_missing" => ["anthropic_api_key", "telegram_bot_token"],
        "snapshots" => %{
          "sentence" => "The last snapshot was stored at 2026-10-27 09:30 UTC.",
          "targets" => [
            %{
              "configured" => true,
              "label" => "your desktop",
              "destination" => "snapshots/ on studio-mac",
              "last_verified" => %{
                "at" => "2026-10-27T09:30:00Z",
                "name" => "n.fxsnap",
                "key_id" => "0011223344556677"
              },
              "last_error" => nil,
              "waiting" =>
                "Your studio-mac is not connected; the snapshot waits for the next run."
            }
          ]
        }
      }

      client = fn "home.status", %{}, opts -> socket(opts, ctx.home) && {:ok, answer} end
      {0, out, ""} = run(["status"], home: ctx.home, client: client)

      assert out =~ "Secrets to enter again on this host: anthropic_api_key, telegram_bot_token"
      assert out =~ "last stored n.fxsnap at 2026-10-27T09:30:00Z (key id 0011223344556677)"
      assert out =~ "Waiting: Your studio-mac is not connected"
    end

    # M75 lean v1 §7: the summary's sentence and its one action lead, the
    # same words the apps and the setup page show; the rest follows.
    test "prints the summary's sentence and action first", ctx do
      answer = %{
        "role" => "device",
        "summary" => %{
          "state" => "problem",
          "sentence" => "Your server is turned off.",
          "action" => %{"id" => "turn_on", "label" => "Turn it on"},
          "detail" => %{"kind" => "turned_off"}
        },
        "snapshots" => %{"sentence" => "Snapshots are the server's.", "targets" => []}
      }

      client = fn "home.status", %{}, opts -> socket(opts, ctx.home) && {:ok, answer} end
      {0, out, ""} = run(["status"], home: ctx.home, client: client)

      assert [
               "Your server is turned off.",
               "Next: Turn it on (fermix always-on)",
               "Role: device" | _
             ] =
               String.split(out, "\n")

      quiet = put_in(answer, ["summary", "action"], nil)
      client = fn "home.status", %{}, _opts -> {:ok, quiet} end
      {0, out, ""} = run(["status"], home: ctx.home, client: client)
      assert ["Your server is turned off.", "Role: device" | _] = String.split(out, "\n")
    end

    # Always On setup §8.2: a home the Fermix app manages takes its steps in
    # the app; any other takes them with `fermix always-on`.
    test "on a home the Fermix app manages, the next step is the app's", ctx do
      answer = %{
        "role" => "primary",
        "summary" => %{
          "state" => "off",
          "sentence" => "Keep Fermix running when this Mac sleeps.",
          "action" => %{"id" => "paste_token", "label" => "Set up"},
          "detail" => %{}
        },
        "snapshots" => %{"sentence" => "Snapshots are off.", "targets" => []}
      }

      client = fn "home.status", %{}, _opts -> {:ok, answer} end

      {0, out, ""} =
        run(["status"], home: ctx.home, client: client, app_managed?: fn -> true end)

      assert ["Keep Fermix running when this Mac sleeps.", "Next: Set up (in the Fermix app)" | _] =
               String.split(out, "\n")

      {0, json, ""} =
        run(["status", "--json"],
          home: ctx.home,
          client: client,
          app_managed?: fn -> flunk("--json names no surface, so it asks nothing") end
        )

      assert %{"result" => %{"summary" => %{"state" => "off"}}} = Jason.decode!(json)
    end

    test "with Fermix stopped, the summary comes from the home's own files too", ctx do
      {0, out, ""} = run(["status"], home: ctx.home, client: stopped())

      assert out =~
               ~r/\AKeep Fermix running when this (Mac|computer) sleeps\. It moves to a server you own\./

      {0, json, ""} = run(["status", "--json"], home: ctx.home, client: stopped())
      assert %{"result" => %{"summary" => %{"state" => "off"}}} = Jason.decode!(json)
    end

    test "snapshots status prints the snapshots alone", ctx do
      {0, out, ""} = run(["snapshots", "status", "--json"], home: ctx.home, client: stopped())

      assert %{
               "result" => %{
                 "configured" => false,
                 "targets" => [%{"id" => "s3"}, %{"id" => "desktop"}]
               }
             } = Jason.decode!(out)
    end
  end

  # Always On setup §3.5, §8.2: `home.snapshots.run` is served only to a
  # linked desktop's forward now, so the verb that called it over
  # `daemon.sock` is gone, with nothing in its place.
  describe "home snapshots run" do
    test "is a usage error, reaches no engine and is not in the usage", ctx do
      test = self()

      client = fn method, _params, _opts ->
        send(test, {:called, method})
        {:error, :not_running}
      end

      for argv <- [["snapshots", "run"], ["snapshots", "run", "--json"]] do
        {status, out, err} = run(argv, home: ctx.home, client: client)
        assert {status, out} == {2, ""}, inspect(argv)
        assert err =~ "fermix home snapshots passphrase --passphrase-file PATH", inspect(argv)
        refute err =~ ~r/snapshots (status\|)?run/, inspect(argv)
      end

      refute_received {:called, _method}
    end

    test "is not in fermix help" do
      help = capture_io(fn -> assert Fermix.CLI.main(["help"]) == 0 end)

      assert help =~ "fermix home snapshots status [--json]"
      refute help =~ ~r/snapshots (status\|)?run/
    end
  end

  describe "home snapshots passphrase" do
    test "needs Fermix running", ctx do
      argv = ["snapshots", "passphrase", "--passphrase-file", ctx.passphrase_file, "--json"]
      {status, out, _err} = run(argv, home: ctx.home, client: stopped())
      assert status == 1
      assert out == MachineOutput.error(:engine_stopped) <> "\n"
    end

    test "a refusal carries the engine's own sentence", ctx do
      sentence = "The recovery passphrase must be at least 12 bytes long."

      client = fn "home.snapshots.passphrase", %{}, _opts ->
        {:error,
         {:management_error, "invalid_params", "The request parameters are invalid.",
          %{"field" => "recovery_passphrase", "sentence" => sentence}}}
      end

      {1, "", err} =
        run(["snapshots", "passphrase", "--passphrase-file", ctx.passphrase_file],
          home: ctx.home,
          client: client
        )

      assert err == "fermix home: Fermix did not do that. It said: #{sentence}\n"
    end

    test "the passphrase goes to the engine from the file, never through argv", ctx do
      parent = self()

      answer = %{
        "recipient" => "fxsnap1.x.y",
        "key_id" => "0011223344556677",
        "snapshots" => %{"sentence" => "on"}
      }

      client = fn "home.snapshots.passphrase", params, _opts ->
        send(parent, {:params, params})
        {:ok, answer}
      end

      {0, out, ""} =
        run(["snapshots", "passphrase", "--passphrase-file", ctx.passphrase_file],
          home: ctx.home,
          client: client
        )

      assert_received {:params, %{"recovery_passphrase" => @passphrase}}
      assert out =~ "The recovery key is set (key id 0011223344556677)"
      refute out =~ @passphrase
    end
  end

  defp stopped, do: fn _method, _params, _opts -> {:error, :not_running} end

  defp socket(opts, home),
    do: Keyword.fetch!(opts, :socket_path) == Path.join(home, "daemon.sock")

  defp run(argv, deps \\ []) do
    defaults = [
      hello: fn -> {:error, :not_running} end,
      host: "macos-aarch64",
      keyring_usable?: fn -> true end,
      now_ms: @now_ms
    ]

    deps = Keyword.merge(defaults, deps)
    parent = self()

    err =
      capture_io(:stderr, fn ->
        out = capture_io(fn -> send(parent, {:status, HomeCommand.run(argv, deps)}) end)
        send(parent, {:out, out})
      end)

    assert_received {:status, status}
    assert_received {:out, out}
    {status, out, err}
  end
end
