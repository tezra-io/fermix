defmodule FermixChannels.Mobile.FreshHomeTest do
  @moduledoc """
  The phone channel on a home as a boot leaves it: the workspace step creates
  `mobile/` before anything of the channel runs. The step reads `FERMIX_HOME`,
  so this module sets it and runs alone.
  """

  use ExUnit.Case, async: false

  alias FermixChannels.Mobile.Management
  alias FermixChannels.Mobile.Supervisor, as: MobileSupervisor
  alias FermixCore.Setup.ConfigStore
  alias FermixTestSupport.SafeRm

  setup do
    previous = System.get_env("FERMIX_HOME")
    home = SafeRm.make_tmp_dir!("mobile-fresh-home")
    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      SafeRm.rm_rf!(home)
    end)

    %{home: home}
  end

  # R5-1: a boot made `mobile/` at the umask's 0755, and the trust store reads
  # only a 0700 directory, so `fermix devices list` with the channel off said
  # the channel was not running, and turning it on refused the whole subtree.
  test "a home whose boot left mobile/ open lists no phone and admits the channel", %{home: home} do
    mobile = Path.join(home, "mobile")
    File.mkdir_p!(mobile)
    File.chmod!(mobile, 0o755)

    assert :ok = ConfigStore.ensure_workspace()
    refute MobileSupervisor.running?()
    assert {:ok, []} = Management.devices_list([])

    names = names()
    on_exit(fn -> MobileSupervisor.forget_refusal(names.device_store) end)

    assert {:ok, supervisor} =
             MobileSupervisor.start_link(
               name: nil,
               root: home,
               boot_epoch: "fresh-home-epoch",
               config: [advertise_mdns: false],
               start_listener?: false,
               memory_enabled?: fn -> true end,
               names: names
             )

    on_exit(fn -> if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown) end)
    assert MobileSupervisor.refusal(names.device_store) == :none
  end

  defp names do
    suffix = System.unique_integer([:positive, :monotonic])

    Map.new(
      [
        device_store: "Store",
        device_registry: "Registry",
        pair_manager: "Pair",
        media_store: "Media",
        unfurl_supervisor: "Unfurl",
        discovery: "Discovery",
        request_coordinator: "Coordinator",
        listener: "Listener",
        mdns_advertiser: "Mdns",
        push_dispatcher: "Push"
      ],
      fn {key, name} -> {key, Module.concat(__MODULE__, "#{name}#{suffix}")} end
    )
  end
end
