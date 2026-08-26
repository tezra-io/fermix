defmodule FermixChannels.Mobile.SupervisorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Mobile.Listener
  alias FermixChannels.Mobile.Management
  alias FermixChannels.Mobile.Supervisor, as: MobileSupervisor
  alias FermixCore.Setup.SecretWriter
  alias FermixTestSupport.SafeRm

  test "orders durable state and pairing before the TLS listener" do
    instance_names = names()

    assert {:ok, {flags, children}} =
             MobileSupervisor.init(
               root: "/tmp/fermix-mobile-supervisor-test",
               boot_epoch: "supervisor-test-epoch",
               listener: [port: 0],
               start_listener?: false,
               names: instance_names
             )

    assert flags.strategy == :rest_for_one

    ids = Enum.map(children, & &1.id)

    assert Enum.find_index(ids, &(&1 == FermixChannels.Mobile.DeviceStore)) <
             Enum.find_index(ids, &(&1 == FermixChannels.Mobile.DeviceRegistry))

    assert Enum.find_index(ids, &(&1 == FermixChannels.Mobile.DeviceRegistry)) <
             Enum.find_index(ids, &(&1 == FermixChannels.Mobile.PairManager))

    # MediaStore names its child by {module, instance} so two stores can run
    # side by side; the ordering gate has to look the child up by that id.
    media_store_id = {FermixChannels.Mobile.MediaStore, instance_names.media_store}

    assert Enum.find_index(ids, &(&1 == media_store_id)) <
             Enum.find_index(ids, &(&1 == instance_names.request_coordinator))

    assert Enum.find_index(ids, &(&1 == instance_names.request_coordinator)) <
             Enum.find_index(ids, &(&1 == Listener))
  end

  test "a fresh install starts a dormant listener until first pairing creates identity" do
    root =
      Path.join(
        System.tmp_dir!(),
        "fermix-mobile-no-identity-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)

    instance_names = names()

    assert {:ok, supervisor} =
             MobileSupervisor.start_link(
               name: nil,
               root: root,
               boot_epoch: "fresh-install-test-epoch",
               start_listener?: true,
               listener: [bind: {127, 0, 0, 1}, port: 0],
               names: instance_names
             )

    on_exit(fn -> if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown) end)
    assert Listener.status(instance_names.listener) == :dormant
  end

  test "enabled push owns one validated dispatcher before the listener" do
    private_key = X509.PrivateKey.new_ec(:secp256r1) |> X509.PrivateKey.to_pem()
    instance_names = names()

    config = [
      advertise_mdns: false,
      push: [
        enabled: true,
        team_id: "ABCDE12345",
        key_id: "KEY123",
        key: private_key,
        topic: "io.tezra.fermix",
        environment: "development"
      ]
    ]

    assert {:ok, {_flags, children}} =
             MobileSupervisor.init(
               root: "/tmp/fermix-mobile-supervisor-push-test",
               boot_epoch: "push-test-epoch",
               config: config,
               start_listener?: false,
               names: instance_names
             )

    ids = Enum.map(children, & &1.id)

    assert Enum.find_index(ids, &(&1 == instance_names.push_dispatcher)) <
             Enum.find_index(ids, &(&1 == Listener))
  end

  test "disabled push starts no dispatcher and enabled invalid config fails loud" do
    assert {:ok, {_flags, children}} =
             MobileSupervisor.init(
               root: "/tmp/fermix-mobile-supervisor-disabled-push-test",
               boot_epoch: "disabled-push-test-epoch",
               config: [advertise_mdns: false, push: [enabled: false]],
               start_listener?: false,
               names: names()
             )

    refute Enum.any?(children, &(&1.id == FermixChannels.Mobile.Push.PigeonDispatcher))

    error =
      assert_raise ArgumentError, fn ->
        MobileSupervisor.init(
          root: "/tmp/fermix-mobile-supervisor-invalid-push-test",
          boot_epoch: "invalid-push-test-epoch",
          config: [advertise_mdns: false, push: [enabled: true]],
          start_listener?: false,
          names: names()
        )
      end

    assert error.message =~ "invalid mobile push config"
    assert error.message =~ "{:invalid_push_config, :team_id, :missing}"
  end

  test "an unresolved APNs credential starts mobile without push instead of crash-looping" do
    instance_names = names()

    {result, log} =
      with_log(fn ->
        MobileSupervisor.init(
          root: "/tmp/fermix-mobile-supervisor-sentinel-test",
          boot_epoch: "sentinel-test-epoch",
          config: push_config(SecretWriter.sentinel()),
          start_listener?: false,
          names: instance_names
        )
      end)

    assert {:ok, {_flags, children}} = result
    ids = Enum.map(children, & &1.id)

    refute instance_names.push_dispatcher in ids
    assert Listener in ids
    assert log =~ "APNs"
    assert log =~ SecretWriter.sentinel()
  end

  test "a structurally invalid APNs key still refuses the boot" do
    error =
      assert_raise ArgumentError, fn ->
        MobileSupervisor.init(
          root: "/tmp/fermix-mobile-supervisor-bad-key-test",
          boot_epoch: "bad-key-test-epoch",
          config:
            push_config("-----BEGIN PRIVATE KEY-----\nnot a key\n-----END PRIVATE KEY-----"),
          start_listener?: false,
          names: names()
        )
      end

    assert error.message =~ "invalid mobile push config"
    assert error.message =~ ":key"
  end

  test "defaults a cryptographically random epoch for the request coordinator" do
    instance_names = names()

    assert {:ok, {_flags, children}} =
             MobileSupervisor.init(
               root: "/tmp/fermix-mobile-supervisor-default-epoch-test",
               config: [advertise_mdns: false],
               start_listener?: false,
               names: instance_names
             )

    child = Enum.find(children, &(&1.id == instance_names.request_coordinator))
    {FermixChannels.Mobile.RequestCoordinator, :start_link, [opts]} = child.start
    epoch = Keyword.fetch!(opts, :boot_epoch)

    assert {:ok, <<_::256>>} = Base.url_decode64(epoch, padding: false)
  end

  test "a corrupt trust store refuses only the mobile surface, loudly and without rebuilding it" do
    root = SafeRm.make_tmp_dir!("mobile-corrupt-trust-store")
    on_exit(fn -> SafeRm.rm_rf!(root) end)

    path = DeviceStore.store_path(root)
    File.mkdir_p!(Path.dirname(path))
    File.chmod!(Path.dirname(path), 0o700)
    File.write!(path, "devices = [ this is not toml")
    File.chmod!(path, 0o600)

    instance_names = names()
    store = instance_names.device_store
    on_exit(fn -> MobileSupervisor.forget_refusal(store) end)

    siblings = [
      Supervisor.child_spec({Agent, fn -> :other_channel end}, id: :sibling_channel),
      Supervisor.child_spec(
        {MobileSupervisor,
         name: nil,
         root: root,
         boot_epoch: "refused-boot-epoch",
         start_listener?: false,
         names: instance_names},
        id: :mobile_subtree
      )
    ]

    log =
      capture_log(fn ->
        assert {:ok, parent} = Supervisor.start_link(siblings, strategy: :one_for_one)
        send(self(), {:parent, parent})
      end)

    assert_received {:parent, parent}
    on_exit(fn -> if Process.alive?(parent), do: Process.exit(parent, :shutdown) end)

    started = Map.new(Supervisor.which_children(parent), fn {id, pid, _t, _m} -> {id, pid} end)
    assert is_pid(started[:sibling_channel])
    assert started[:mobile_subtree] == :undefined

    assert log =~ "mobile surface refused this boot"
    assert log =~ path
    assert {:error, {:devices_decode_failed, ^path, _reason}} = MobileSupervisor.refusal(store)
    refute Process.whereis(store)
    refute Process.whereis(instance_names.listener)

    # The file is refused, never rebuilt: its bytes are exactly as written.
    assert File.read!(path) == "devices = [ this is not toml"

    assert {:error, {:mobile_surface_refused, {:devices_decode_failed, ^path, _}}} =
             Management.health(config: [enabled: true], device_store: store)

    assert {:error, {:mobile_surface_refused, {:devices_decode_failed, ^path, _}}} =
             Management.status(config: [enabled: true], device_store: store)
  end

  test "a repaired trust store clears the refusal on the next boot" do
    root = SafeRm.make_tmp_dir!("mobile-repaired-trust-store")
    on_exit(fn -> SafeRm.rm_rf!(root) end)

    path = DeviceStore.store_path(root)
    File.mkdir_p!(Path.dirname(path))
    File.chmod!(Path.dirname(path), 0o700)
    File.write!(path, "not toml either")
    File.chmod!(path, 0o600)

    instance_names = names()
    store = instance_names.device_store
    on_exit(fn -> MobileSupervisor.forget_refusal(store) end)

    boot = fn ->
      MobileSupervisor.start_link(
        name: nil,
        root: root,
        boot_epoch: "repaired-boot-epoch",
        start_listener?: false,
        listener: [bind: {127, 0, 0, 1}, port: 0],
        names: instance_names
      )
    end

    capture_log(fn -> assert :ignore == boot.() end)
    assert {:error, _reason} = MobileSupervisor.refusal(store)

    SafeRm.rm!(path)

    assert {:ok, supervisor} = boot.()
    on_exit(fn -> if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown) end)
    assert MobileSupervisor.refusal(store) == :none
    assert {:ok, []} = DeviceStore.list(store)
  end

  # A child init `{:stop, ...}` escalates through this supervisor into an
  # application crash-loop under the service manager. The two states below used
  # to do exactly that (Listener.init via Identity.ensure; MediaStore.init via
  # its manifest check); each must instead refuse only the mobile surface.
  test "partial identity material refuses the subtree instead of crashing the daemon" do
    root = SafeRm.make_tmp_dir!("mobile-partial-identity")
    on_exit(fn -> SafeRm.rm_rf!(root) end)

    dir = Path.join(root, "mobile")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    for file <- ["gateway_key", "tls.key"] do
      path = Path.join(dir, file)
      File.write!(path, "stub")
      File.chmod!(path, 0o600)
    end

    instance_names = names()
    store = instance_names.device_store
    on_exit(fn -> MobileSupervisor.forget_refusal(store) end)

    log =
      capture_log(fn ->
        assert :ignore ==
                 MobileSupervisor.start_link(
                   name: nil,
                   root: root,
                   boot_epoch: "partial-identity-epoch",
                   start_listener?: false,
                   names: instance_names
                 )
      end)

    assert {:error, {:identity_incomplete, missing}} = MobileSupervisor.refusal(store)
    assert Enum.any?(missing, &String.ends_with?(&1, "tls.crt"))
    assert log =~ "identity material"
    refute Process.whereis(store)
  end

  test "an insecure attachment manifest refuses the subtree instead of crashing the daemon" do
    root = SafeRm.make_tmp_dir!("mobile-insecure-manifest")
    on_exit(fn -> SafeRm.rm_rf!(root) end)

    dir = Path.join(root, "mobile")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    manifest = Path.join(dir, "attachments.json")
    File.write!(manifest, "{}")
    File.chmod!(manifest, 0o644)

    instance_names = names()
    store = instance_names.device_store
    on_exit(fn -> MobileSupervisor.forget_refusal(store) end)

    log =
      capture_log(fn ->
        assert :ignore ==
                 MobileSupervisor.start_link(
                   name: nil,
                   root: root,
                   boot_epoch: "insecure-manifest-epoch",
                   start_listener?: false,
                   names: instance_names
                 )
      end)

    assert {:error, {:insecure_attachment_manifest, ^manifest, 0o644}} =
             MobileSupervisor.refusal(store)

    assert log =~ "attachment manifest"
    refute Process.whereis(store)
  end

  defp push_config(key) do
    [
      advertise_mdns: false,
      push: [
        enabled: true,
        team_id: "ABCDE12345",
        key_id: "KEY123",
        key: key,
        topic: "io.tezra.fermix",
        environment: "development"
      ]
    ]
  end

  defp names do
    suffix = System.unique_integer([:positive, :monotonic])

    %{
      device_store: Module.concat(__MODULE__, "Store#{suffix}"),
      device_registry: Module.concat(__MODULE__, "Registry#{suffix}"),
      pair_manager: Module.concat(__MODULE__, "Pair#{suffix}"),
      media_store: Module.concat(__MODULE__, "Media#{suffix}"),
      request_coordinator: Module.concat(__MODULE__, "Coordinator#{suffix}"),
      listener: Module.concat(__MODULE__, "Listener#{suffix}"),
      mdns_advertiser: Module.concat(__MODULE__, "Mdns#{suffix}"),
      push_dispatcher: Module.concat(__MODULE__, "Push#{suffix}")
    }
  end
end
