defmodule FermixChannels.Mobile.SupervisorTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Supervisor, as: MobileSupervisor

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

    assert Enum.find_index(ids, &(&1 == FermixChannels.Mobile.MediaStore)) <
             Enum.find_index(ids, &(&1 == instance_names.request_coordinator))

    assert Enum.find_index(ids, &(&1 == instance_names.request_coordinator)) <
             Enum.find_index(ids, &(&1 == FermixChannels.Mobile.Listener))
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
    assert FermixChannels.Mobile.Listener.status(instance_names.listener) == :dormant
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
             Enum.find_index(ids, &(&1 == FermixChannels.Mobile.Listener))
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
