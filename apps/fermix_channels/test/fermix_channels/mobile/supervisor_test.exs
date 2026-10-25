defmodule FermixChannels.Mobile.SupervisorTest do
  # async: false — the APNs key tests assert what the log never says, and an
  # async module's captured log also holds other modules' lines.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Mobile.Iroh
  alias FermixChannels.Mobile.Iroh.Helper
  alias FermixChannels.Mobile.Listener
  alias FermixChannels.Mobile.Management
  alias FermixChannels.Mobile.RequestCoordinator
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

    assert Enum.find_index(ids, &(&1 == instance_names.request_coordinator)) <
             Enum.find_index(ids, &(&1 == Listener))

    # Sockets read their candidates from the discovery cache.
    assert Enum.find_index(ids, &(&1 == FermixChannels.Mobile.Discovery)) <
             Enum.find_index(ids, &(&1 == Listener))

    # The media store and the link previews are the timeline's, shared with
    # the Mac: the channels application runs them, whether or not a phone is
    # paired, so this subtree starts neither.
    refute Enum.any?(ids, &match?({FermixChannels.Mobile.MediaStore, _instance}, &1))
    refute Enum.any?(children, &match?(%{start: {Task.Supervisor, _function, _args}}, &1))
  end

  # M51 §5.5: the candidates a phone is given are the addresses the listener
  # answers on, so discovery is told the bind the listener is given.
  test "discovery enumerates for the bind the listener serves" do
    cases = [
      {[config: [bind: "192.168.1.8"]], "192.168.1.8"},
      {[config: [bind: "192.168.1.8"], listener: [bind: {127, 0, 0, 1}]], {127, 0, 0, 1}},
      {[config: []], "0.0.0.0"}
    ]

    for {opts, bind} <- cases do
      children = init_children(opts)
      assert child_opts(children, FermixChannels.Mobile.Discovery)[:bind] == bind
      assert child_opts(children, Listener)[:bind] == bind
    end
  end

  # A session loads the gateway identity from its subtree's home on either
  # carrier: the WebSocket's from the listener, the bridge's from here.
  test "the rail's sessions read the identity of the subtree's own home" do
    session = child_opts(init_children([]), Iroh)[:session_opts]
    assert session[:identity_root] == "/tmp/fermix-mobile-supervisor-children-test"
  end

  test "the local-network announcement starts only when the config turns it on" do
    for {config, enabled?} <- [
          {[], false},
          {[advertise_mdns: false], false},
          {[advertise_mdns: true], true}
        ] do
      children = init_children(config: config)
      assert child_opts(children, FermixChannels.Mobile.MdnsAdvertiser)[:enabled] == enabled?
    end
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
               memory_enabled?: fn -> true end,
               names: instance_names
             )

    on_exit(fn -> if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown) end)
    assert Listener.status(instance_names.listener) == :dormant
  end

  # Live on/off (M51 §5.5, owner 2026-10-10): the subtree's spec stays with its
  # parent for the whole boot and starts nothing while the switch is off, so
  # turning the channel on or off is a child restart or termination that keeps
  # the boot's epoch, and the daemon never restarts for it.
  describe "the live switch" do
    test "a subtree whose switch is off starts nothing and records no refusal" do
      instance_names = names()

      assert :ignore =
               MobileSupervisor.start_link(switch_opts(instance_names, fn -> false end))

      assert MobileSupervisor.refusal(instance_names.device_store) == :none
      refute Process.whereis(instance_names.request_coordinator)
    end

    test "turning the channel on, off and on again keeps the boot's epoch" do
      instance_names = names()
      switch = start_supervised!({Agent, fn -> false end}, id: :switch)
      parent = start_parent!(instance_names, fn -> Agent.get(switch, & &1) end)

      assert [{MobileSupervisor, :undefined, :supervisor, _}] = Supervisor.which_children(parent)

      Agent.update(switch, fn _ -> true end)
      assert {:ok, :started} = MobileSupervisor.switch(true, parent: parent)
      assert RequestCoordinator.epoch(instance_names.request_coordinator) == "live-switch-epoch"
      assert {:ok, :started} = MobileSupervisor.switch(true, parent: parent)

      Agent.update(switch, fn _ -> false end)

      assert {:ok, :stopped} =
               MobileSupervisor.switch(false,
                 parent: parent,
                 device_store: instance_names.device_store
               )

      refute Process.whereis(instance_names.request_coordinator)

      assert {:ok, :stopped} =
               MobileSupervisor.switch(false,
                 parent: parent,
                 device_store: instance_names.device_store
               )

      Agent.update(switch, fn _ -> true end)
      assert {:ok, :started} = MobileSupervisor.switch(true, parent: parent)
      assert RequestCoordinator.epoch(instance_names.request_coordinator) == "live-switch-epoch"
    end

    test "turning it on while the switch still reads off starts nothing" do
      instance_names = names()
      parent = start_parent!(instance_names, fn -> false end)

      assert {:ok, :not_started} = MobileSupervisor.switch(true, parent: parent)
      refute Process.whereis(instance_names.request_coordinator)
    end

    # Setup was not ready at boot, so no transport was registered at all.
    test "turning it on with no subtree registered is refused as not ready" do
      parent =
        start_supervised!(%{
          id: :empty_parent,
          start: {Supervisor, :start_link, [[], [strategy: :one_for_one]]},
          type: :supervisor
        })

      assert {:error, :not_ready} = MobileSupervisor.switch(true, parent: parent)
      assert {:ok, :stopped} = MobileSupervisor.switch(false, parent: parent)
    end
  end

  # Remote reach (M62 D4) is the phone subtree's last child, with a live switch
  # of its own: off stops the rail and nothing else, on starts it again, and
  # neither restarts the phone channel.
  describe "the reach switch" do
    test "turning reach off and on touches only the rail" do
      instance_names = names()
      reach = start_supervised!({Agent, fn -> true end}, id: :reach)

      parent =
        start_parent!(instance_names, fn -> true end,
          iroh_switch: fn -> Agent.get(reach, & &1) end,
          iroh_helper_opts: [binary_path: "/nonexistent/fermix-iroh"]
        )

      phone = child_pid(parent, MobileSupervisor)
      coordinator = Process.whereis(instance_names.request_coordinator)
      assert is_pid(child_pid(phone, Iroh))
      refute Helper.status(instance_names.iroh_helper) == %{state: :off}

      Agent.update(reach, fn _ -> false end)
      assert {:ok, :stopped} = MobileSupervisor.switch_iroh(false, parent: phone)
      assert child_pid(phone, Iroh) == :undefined
      assert Helper.status(instance_names.iroh_helper) == %{state: :off}

      # The switch still reads off, so a start comes back empty.
      assert {:ok, :not_started} = MobileSupervisor.switch_iroh(true, parent: phone)

      Agent.update(reach, fn _ -> true end)
      assert {:ok, :started} = MobileSupervisor.switch_iroh(true, parent: phone)
      assert is_pid(child_pid(phone, Iroh))
      assert Process.whereis(instance_names.request_coordinator) == coordinator
    end

    test "a rail whose switch is off starts nothing" do
      assert :ignore = Iroh.start_link(switch: fn -> false end)
    end

    test "with no phone subtree running there is no rail to switch" do
      assert {:error, :not_ready} = MobileSupervisor.switch_iroh(true, parent: :no_phone_here)
      assert {:ok, :stopped} = MobileSupervisor.switch_iroh(false, parent: :no_phone_here)
    end
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

    # The sessions on either carrier tell a phone the service this daemon has.
    assert router_opts(children)[:push_services] == ["apns"]
    assert iroh_session_opts(children)[:push_services] == ["apns"]
  end

  test "with push off, sessions say this daemon pushes through nothing" do
    children =
      init_children(config: [advertise_mdns: false, push: [enabled: false]], names: names())

    assert router_opts(children)[:push_services] == []
    assert iroh_session_opts(children)[:push_services] == []
  end

  test "disabled push starts no dispatcher" do
    assert {:ok, {_flags, children}} =
             MobileSupervisor.init(
               root: "/tmp/fermix-mobile-supervisor-disabled-push-test",
               boot_epoch: "disabled-push-test-epoch",
               config: [advertise_mdns: false, push: [enabled: false]],
               start_listener?: false,
               names: names()
             )

    refute Enum.any?(children, &(&1.id == FermixChannels.Mobile.Push.PigeonDispatcher))
  end

  # M51 §10: a push setting that does not resolve starts the phone channel
  # without the dispatcher and says why; it never takes the channels down.
  test "an APNs table that does not parse starts mobile without push and names the fault" do
    key = X509.PrivateKey.new_ec(:secp256r1) |> X509.PrivateKey.to_pem()
    staging = push_config(key) |> Keyword.fetch!(:push) |> Keyword.put(:environment, "staging")

    for {push, reason} <- [
          {[enabled: true], "{:invalid_push_config, :team_id, :missing}"},
          {[enabled: "yes"], ~s({:invalid_push_enabled, "yes"})},
          {staging, ~s({:invalid_push_config, :environment, "staging"})}
        ] do
      instance_names = names()

      {children, log} =
        with_log(fn ->
          init_children(config: [advertise_mdns: false, push: push], names: instance_names)
        end)

      ids = Enum.map(children, & &1.id)
      refute instance_names.push_dispatcher in ids
      assert Listener in ids
      assert Iroh in ids
      assert router_opts(children)[:push_services] == []
      assert iroh_session_opts(children)[:push_services] == []
      assert log =~ "[error]"
      assert log =~ "Mobile started WITHOUT push"
      assert log =~ reason
    end
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

  test "a structurally invalid APNs key starts mobile without push, never logging the key" do
    instance_names = names()
    key = "-----BEGIN PRIVATE KEY-----\nnot a key\n-----END PRIVATE KEY-----"

    {children, log} =
      with_log(fn -> init_children(config: push_config(key), names: instance_names) end)

    ids = Enum.map(children, & &1.id)
    refute instance_names.push_dispatcher in ids
    assert Listener in ids
    assert router_opts(children)[:push_services] == []
    assert log =~ "Mobile started WITHOUT push"
    assert log =~ "{:invalid_push_config, :key, :invalid_pem}"
    refute log =~ "not a key"
    refute log =~ "missing_padding"
  end

  # A raise here used to fail the subtree's start, and with it the channels
  # application, which a release runs :permanent: every channel went down.
  test "a bad APNs key never takes the channels down: the subtree starts beside them" do
    instance_names = names()
    key = "-----BEGIN PRIVATE KEY-----\nnot a key\n-----END PRIVATE KEY-----"
    opts = switch_opts(instance_names, fn -> true end) ++ [config: push_config(key)]

    siblings = [
      Supervisor.child_spec({Agent, fn -> :other_channel end}, id: :sibling_channel),
      Supervisor.child_spec({MobileSupervisor, opts}, id: :mobile_subtree)
    ]

    {parent, log} =
      with_log(fn ->
        start_supervised!(%{
          id: :push_fault_parent,
          start: {Supervisor, :start_link, [siblings, [strategy: :one_for_one]]},
          type: :supervisor
        })
      end)

    started = Map.new(Supervisor.which_children(parent), fn {id, pid, _t, _m} -> {id, pid} end)
    assert is_pid(started[:sibling_channel])
    assert is_pid(started[:mobile_subtree])
    assert is_pid(Process.whereis(instance_names.device_store))
    assert is_pid(Process.whereis(instance_names.pair_manager))
    refute Process.whereis(instance_names.push_dispatcher)
    assert log =~ "Mobile started WITHOUT push"
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

    # The management verbs name the refusal; status still answers, from
    # configuration alone, because nothing it could ask was meant to run. The
    # device list reads the file where it lies, and names what is wrong with it.
    refused = [config: [enabled: true], device_store: store, root: root]
    assert {:error, :mobile_surface_refused} = Management.pair_start(refused)
    assert {:error, {:devices_decode_failed, ^path, _}} = Management.devices_list(refused)

    assert {:ok, %{enabled: true, started: false, refused: true, paired_devices: 0, pairing: nil}} =
             Management.status(refused)
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
        memory_enabled?: fn -> true end,
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

  # STB-16: the whole timeline lives in Memory.Repo, which answers
  # `{:error, :disabled}` to everything with memory off. A subtree started then
  # fails every hello while health reports ready; refuse it, named, instead.
  test "memory turned off refuses the subtree with a named reason" do
    root = SafeRm.make_tmp_dir!("mobile-memory-disabled")
    on_exit(fn -> SafeRm.rm_rf!(root) end)

    instance_names = names()
    store = instance_names.device_store
    on_exit(fn -> MobileSupervisor.forget_refusal(store) end)

    log =
      capture_log(fn ->
        assert :ignore ==
                 MobileSupervisor.start_link(
                   name: nil,
                   root: root,
                   boot_epoch: "memory-disabled-epoch",
                   start_listener?: false,
                   memory_enabled?: fn -> false end,
                   names: instance_names
                 )
      end)

    assert {:error, :memory_disabled} = MobileSupervisor.refusal(store)
    assert log =~ "memory is turned off"
    refute Process.whereis(store)
    refute File.exists?(Path.join(root, "mobile"))

    assert {:ok, %{refused: true, refusal: :memory_disabled}} =
             Management.status(config: [enabled: true], device_store: store, root: root)
  end

  test "each refusal publishes the word for its fault class" do
    for {reason, word} <- [
          {:memory_disabled, :memory_disabled},
          {{:identity_incomplete, ["/x/tls.crt"]}, :identity},
          {{:identity_unreadable, "/x", :eacces}, :identity},
          {{:invalid_identity_transaction, "/x"}, :identity},
          {{:insecure_attachment_manifest, "/x", 0o644}, :attachment_manifest},
          {{:devices_decode_failed, "/x", :bad}, :trust_store},
          {{:devices_store_empty, "/x"}, :trust_store}
        ] do
      assert MobileSupervisor.refusal_word(reason) == word
    end
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

  # The child specs `init/1` returns for `opts`, nothing started.
  defp init_children(opts) do
    assert {:ok, {_flags, children}} =
             MobileSupervisor.init(
               Keyword.merge(
                 [
                   root: "/tmp/fermix-mobile-supervisor-children-test",
                   boot_epoch: "children-test-epoch",
                   start_listener?: false,
                   names: names()
                 ],
                 opts
               )
             )

    children
  end

  defp child_opts(children, id) do
    %{start: {_module, :start_link, [opts]}} = Enum.find(children, &(&1.id == id))
    opts
  end

  # What the listener's sessions and the rail's are started with.
  defp router_opts(children), do: child_opts(children, Listener)[:router_opts]
  defp iroh_session_opts(children), do: child_opts(children, Iroh)[:session_opts]

  defp switch_opts(instance_names, switch) do
    root =
      Path.join(
        System.tmp_dir!(),
        "fermix-mobile-switch-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> SafeRm.rm_rf!(root) end)

    [
      name: nil,
      root: root,
      boot_epoch: "live-switch-epoch",
      start_listener?: false,
      listener: [bind: {127, 0, 0, 1}, port: 0],
      memory_enabled?: fn -> true end,
      names: instance_names,
      switch: switch
    ]
  end

  defp start_parent!(instance_names, switch, extra \\ []) do
    opts = switch_opts(instance_names, switch) ++ extra
    child = Supervisor.child_spec({MobileSupervisor, opts}, [])

    start_supervised!(%{
      id: :live_switch_parent,
      start: {Supervisor, :start_link, [[child], [strategy: :one_for_one]]},
      type: :supervisor
    })
  end

  defp names do
    suffix = System.unique_integer([:positive, :monotonic])

    %{
      device_store: Module.concat(__MODULE__, "Store#{suffix}"),
      device_registry: Module.concat(__MODULE__, "Registry#{suffix}"),
      pair_manager: Module.concat(__MODULE__, "Pair#{suffix}"),
      media_store: Module.concat(__MODULE__, "Media#{suffix}"),
      discovery: Module.concat(__MODULE__, "Discovery#{suffix}"),
      request_coordinator: Module.concat(__MODULE__, "Coordinator#{suffix}"),
      listener: Module.concat(__MODULE__, "Listener#{suffix}"),
      mdns_advertiser: Module.concat(__MODULE__, "Mdns#{suffix}"),
      push_dispatcher: Module.concat(__MODULE__, "Push#{suffix}"),
      iroh_helper: Module.concat(__MODULE__, "IrohHelper#{suffix}"),
      bridge: Module.concat(__MODULE__, "Bridge#{suffix}"),
      bridge_connections: Module.concat(__MODULE__, "BridgeConnections#{suffix}")
    }
  end

  defp child_pid(supervisor, id) do
    {^id, pid, _type, _modules} = List.keyfind(Supervisor.which_children(supervisor), id, 0)
    pid
  end
end
