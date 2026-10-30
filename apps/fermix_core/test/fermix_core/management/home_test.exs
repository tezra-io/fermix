defmodule FermixCore.Management.HomeTest do
  use ExUnit.Case, async: true

  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Moved
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Home.Snapshot.Scheduler
  alias FermixCore.Home.Snapshot.Status
  alias FermixCore.Management.Router
  alias FermixTestSupport.SafeRm

  @primary %{role: :primary, primary: nil}
  @device %{role: :device, primary: "invented host"}
  @passphrase "invented-lighthouse-meridian"

  setup do
    tmp = SafeRm.make_tmp_dir!("management_home")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)
    :ok = Epoch.write(tmp, 4)
    %{home: tmp, recipient: Recipient.encode(Recipient.generate())}
  end

  describe "home.status" do
    test "the primary's picture, with the places later slices fill left empty",
         %{home: home, recipient: recipient} do
      config = [recipient: recipient, s3_bucket: "invented-bucket"]

      assert {:ok, status} = route("home.status", %{}, opts(home, config: config))

      assert status["role"] == "primary"
      assert status["epoch"] == 4
      assert status["moved"] == nil
      assert status["primary"] == nil
      assert status["desktops"] == []
      assert status["enrollment"] == nil
      assert status["candidates"] == []
      assert status["move"] == nil
      assert status["secrets_missing"] == []
      assert status["snapshots"]["configured"]
      assert status["snapshots"]["sentence"] == "Snapshots are on; the first runs soon."
    end

    test "the primary names each secret reference this host could not resolve",
         %{home: home} do
      live = %{
        fermix_core: [providers: [anthropic: [api_key: "@keyring"], openai: [api_key: "sk-x"]]],
        fermix_channels: [telegram: [bot_token: "@keyring"]]
      }

      settings = fn -> live end

      assert {:ok, %{"secrets_missing" => ["anthropic_api_key", "telegram_bot_token"]}} =
               route("home.status", %{}, opts(home, settings_snapshot: settings))

      # A desktop's own settings name no secret the server needs.
      assert {:ok, %{"secrets_missing" => []}} =
               route(
                 "home.status",
                 %{},
                 opts(home, settings_snapshot: settings, engine_role: @device)
               )
    end

    test "a device names its marker and leaves snapshots to the primary",
         %{home: home, recipient: recipient} do
      :ok =
        Moved.write(home, %{epoch: 4, moved_at: ~U[2026-10-27 09:30:00Z], to: "invented host"})

      config = [recipient: recipient, s3_bucket: "invented-bucket"]

      assert {:ok, status} =
               route("home.status", %{}, opts(home, config: config, engine_role: @device))

      assert status["role"] == "device"

      assert status["moved"] == %{
               "to" => "invented host",
               "moved_at" => "2026-10-27T09:30:00Z",
               "epoch" => 4
             }

      assert status["snapshots"]["configured"] == false
      assert status["snapshots"]["next_run_at"] == nil

      assert status["snapshots"]["sentence"] ==
               "Snapshots are the primary's to write; this engine runs in the device role."
    end

    # A quiet renewal and an outage are both "not connected"; the word tells
    # them apart, so an app draws the renewal quietly.
    test "a desktop's primary carries the link's status word, from the closed set", %{
      home: home
    } do
      for word <- ~w(connected renewing unreachable revoked stale)a do
        link = fn ->
          %{
            primary: %{
              name: "invented-vm",
              connected: word == :connected,
              status: word,
              since: nil,
              epoch: 5,
              sentence: "Fermix is reconnecting to the server invented-vm."
            },
            desktops: [],
            enrollment: nil
          }
        end

        assert {:ok, status} =
                 route("home.status", %{}, opts(home, engine_role: @device, link_status: link))

        assert status["primary"]["status"] == Atom.to_string(word)
      end

      unknown = fn ->
        %{
          primary: %{name: "invented-vm", connected: false, status: :asleep, sentence: "Asleep."},
          desktops: [],
          enrollment: nil
        }
      end

      assert_raise FunctionClauseError, fn ->
        route("home.status", %{}, opts(home, engine_role: @device, link_status: unknown))
      end
    end

    test "a home that never booted as the primary has no epoch yet", %{home: home} do
      SafeRm.rm!(Epoch.path(home))

      assert {:ok, %{"epoch" => nil}} = route("home.status", %{}, opts(home))
    end

    test "the next run and a run in progress come from a running scheduler",
         %{home: home, recipient: recipient} do
      config = [recipient: recipient, s3_bucket: "invented-bucket"]
      scheduler = scheduler!(home, config)

      assert {:ok, %{"next_run_at" => "2026-10-27T09:05:00Z", "running" => false}} =
               route(
                 "home.snapshots.status",
                 %{},
                 opts(home, config: config, scheduler: scheduler)
               )
    end
  end

  describe "home.snapshots.run" do
    test "starts one, and a second while it runs is busy", %{home: home, recipient: recipient} do
      config = [recipient: recipient, s3_bucket: "invented-bucket"]
      test = self()

      run = fn _home, _config, _targets, _opts ->
        send(test, {:running, self()})

        receive do
          :finish -> :not_configured
        end
      end

      scheduler = scheduler!(home, config, run: run)
      opts = opts(home, config: config, scheduler: scheduler)

      assert {:ok, %{"started" => true, "snapshots" => snapshots}} =
               route("home.snapshots.run", %{}, opts)

      assert snapshots["running"]
      assert snapshots["sentence"] == "A snapshot is being written now."
      assert_receive {:running, task}, 10_000

      assert route("home.snapshots.run", %{}, opts) ==
               {:error, :busy, %{"operation" => "home.snapshots.run"}}

      send(task, :finish)
    end

    test "with nothing to write, says what is missing", %{home: home} do
      scheduler = scheduler!(home, [])

      assert route("home.snapshots.run", %{}, opts(home, scheduler: scheduler)) ==
               {:error, :unavailable,
                %{
                  "capability" => "snapshots",
                  "sentence" => "Snapshots are off: set a recovery passphrase to turn them on."
                }}
    end

    test "a device, and an engine with no scheduler, refuse by name", %{home: home} do
      assert {:error, :unavailable, %{"sentence" => device}} =
               route("home.snapshots.run", %{}, opts(home, engine_role: @device))

      assert device =~ "device role"

      assert route("home.snapshots.run", %{}, opts(home, scheduler: nil)) ==
               {:error, :unavailable,
                %{
                  "capability" => "snapshots",
                  "sentence" => "Snapshots are not running in this engine."
                }}
    end
  end

  describe "home.snapshots.passphrase" do
    test "keeps the derived public key, answers it, and never the passphrase", %{home: home} do
      test = self()
      save = fn recipient -> send(test, {:saved, recipient}) && {:ok, %{}} end
      params = %{"recovery_passphrase" => @passphrase}

      assert {:ok, result} =
               route("home.snapshots.passphrase", params, opts(home, save_recipient: save))

      assert_receive {:saved, saved}
      refute Map.has_key?(saved, :secret_key)
      assert result["recipient"] == Recipient.encode(saved)
      assert result["key_id"] == Base.encode16(Recipient.key_id(saved.public_key), case: :lower)
      assert result["snapshots"]["recipient_set"]
      assert result["sentence"] =~ "written before now open only with the earlier passphrase"
      refute inspect(result) =~ @passphrase

      # The key re-derives from the passphrase and the salt the recipient carries.
      {:ok, again} = Recipient.derive(@passphrase, saved.salt)
      assert again.public_key == saved.public_key
    end

    test "a short passphrase, a wrong key and a device are refused by name", %{home: home} do
      assert route(
               "home.snapshots.passphrase",
               %{"recovery_passphrase" => "too short"},
               opts(home)
             ) ==
               {:error, :invalid_params,
                %{
                  "field" => "recovery_passphrase",
                  "sentence" => "The recovery passphrase must be at least 12 bytes long."
                }}

      assert route("home.snapshots.passphrase", %{"passphrase" => @passphrase}, opts(home)) ==
               {:error, :invalid_params, %{"field" => "passphrase"}}

      assert {:error, :unavailable, %{"capability" => "snapshots"}} =
               route(
                 "home.snapshots.passphrase",
                 %{"recovery_passphrase" => @passphrase},
                 opts(home, engine_role: @device)
               )
    end
  end

  test "the reads take no params" do
    for method <- ~w(home.status home.snapshots.status home.snapshots.run) do
      assert route(method, %{"x" => 1}, []) == {:error, :invalid_params, %{"method" => method}}
    end
  end

  test "a status file the scheduler wrote is what the view reads", %{
    home: home,
    recipient: recipient
  } do
    attempt = %{
      at: ~U[2026-10-27 09:30:00Z],
      result: :verified,
      name: "20261027T093000Z-e4.fxsnap",
      epoch: 4,
      size: 48_211,
      sha256: String.duplicate("c", 64),
      location: "s3://invented-bucket/fermix/general/20261027T093000Z-e4.fxsnap",
      error: nil
    }

    :ok = Status.write(home, Status.record(Status.empty(), "s3", attempt))
    config = [recipient: recipient, s3_bucket: "invented-bucket"]

    assert {:ok, view} = route("home.snapshots.status", %{}, opts(home, config: config))
    assert view["sentence"] == "The last snapshot was stored at 2026-10-27 09:30 UTC."

    assert [
             %{"id" => "s3", "last_verified" => %{"name" => "20261027T093000Z-e4.fxsnap"}},
             %{"id" => "desktop", "configured" => false}
           ] = view["targets"]
  end

  defp route(method, params, opts) do
    Router.route(
      %{request_id: "req-1", protocol_version: 2, method: method, params: params},
      opts
    )
  end

  defp opts(home, extra \\ []) do
    home_opts =
      Keyword.merge(
        [home: home, engine_role: @primary, config: [], scheduler: nil, profile: "general"],
        extra
      )

    [operation_opts: [home: home_opts]]
  end

  defp scheduler!(home, config, extra \\ []) do
    name = :"snapshot_scheduler_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Scheduler,
       [
         name: name,
         home: home,
         config: fn -> config end,
         now: fn -> ~U[2026-10-27 09:00:00Z] end,
         timer: fn _message, _delay -> make_ref() end
       ] ++ extra}
    )

    name
  end
end
