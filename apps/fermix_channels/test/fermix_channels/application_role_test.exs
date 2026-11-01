defmodule FermixChannels.ApplicationRoleTest do
  # async: false: the transport children are read from channel settings in
  # application environment, which these cases set.
  use ExUnit.Case, async: false

  alias FermixChannels.Application, as: ChannelsApplication
  alias FermixCore.Home.Role

  @ready %{status: :ready, failures: []}
  @setup_required %{status: :setup_required, failures: [%{component: "channel"}]}

  @kept [
    FermixChannels.Gateway.QueueSupervisor,
    FermixChannels.Companion.Supervisor,
    FermixChannels.BrowserHost.Supervisor,
    FermixChannels.Gateway.BackgroundSupervisor,
    FermixChannels.Gateway.Commands.Sandbox.Confirmations,
    FermixChannels.Gateway.Commands.Soul.Confirmations,
    FermixChannels.Gateway.AlbumBuffer
  ]

  # Primary-only, though no transport: each opens the database a device does
  # not open (its home is a retired copy that a return replaces in place).
  @database [FermixChannels.Gateway.Idempotency]

  @transports [
    FermixChannels.Voice.Supervisor,
    FermixChannels.Channels.Telegram.Poller,
    FermixChannels.Channels.Discord.Gateway,
    FermixChannels.Channels.Slack.SocketMode,
    FermixChannels.Channels.Acp.Supervisor
  ]

  setup do
    keys = [:telegram, :discord, :slack, :acp]
    saved = for key <- keys, do: {key, Application.fetch_env(:fermix_channels, key)}

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, value} -> Application.put_env(:fermix_channels, key, value)
          :error -> Application.delete_env(:fermix_channels, key)
        end
      end
    end)

    Application.put_env(:fermix_channels, :telegram, enabled: true, owner_user_id: "111")
    Application.put_env(:fermix_channels, :discord, enabled: true, owner_user_id: "222")
    # M75: Slack over Socket Mode is a transport the primary runs, and a device
    # must not, like every other channel transport.
    Application.put_env(:fermix_channels, :slack,
      enabled: true,
      mode: :socket,
      owner_user_id: "333"
    )

    Application.put_env(:fermix_channels, :acp, enabled: true)
    :ok
  end

  defp modules(children), do: Enum.map(children, &module/1)

  defp module(%{start: {module, _function, _args}}), do: module
  defp module({module, _arg}), do: module
  defp module(module) when is_atom(module), do: module

  test "the primary starts every enabled transport beside the kept children" do
    %{children: children} = ChannelsApplication.boot_plan(@ready, "primary-epoch", :primary)

    for module <- @transports ++ @kept do
      assert module in modules(children), "the primary tree lost #{inspect(module)}"
    end
  end

  test "a device starts no transport and keeps everything else, in the same order" do
    %{children: primary} = ChannelsApplication.boot_plan(@ready, "device-epoch", :primary)
    %{children: device} = ChannelsApplication.boot_plan(@ready, "device-epoch", :device)

    for module <- Role.primary_only() do
      refute module in modules(device), "a device tree starts #{inspect(module)}"
    end

    # Named rather than read back from `Role.primary_only/0`, so a transport
    # missing from that list is caught here.
    for module <- @transports do
      refute module in modules(device), "a device tree starts the transport #{inspect(module)}"
    end

    for module <- @kept do
      assert module in modules(device), "a device tree lost #{inspect(module)}"
    end

    for module <- @database do
      assert module in modules(primary), "the primary tree lost #{inspect(module)}"
      refute module in modules(device), "a device tree opens the database: #{inspect(module)}"
    end

    assert Enum.reject(device, &(module(&1) in Role.device_only())) ==
             Enum.reject(primary, &(module(&1) in Role.primary_only()))
  end

  # M75 §2: the desktop's link to its primary is the device's alone.
  test "only a device starts the tree that reaches its primary" do
    %{children: primary} = ChannelsApplication.boot_plan(@ready, "link-epoch", :primary)
    %{children: device} = ChannelsApplication.boot_plan(@ready, "link-epoch", :device)

    assert FermixChannels.Desktop.DeviceSupervisor in modules(device)
    refute FermixChannels.Desktop.DeviceSupervisor in modules(primary)
  end

  # A held transport asks for the restart that would start it; a device's
  # restart starts none, so a device boot holds nothing and asks for nothing.
  test "a device boot holds no transport for setup, so it never waits for a restart" do
    assert %{held: held} = ChannelsApplication.boot_plan(@setup_required, "held-epoch", :primary)
    assert FermixChannels.Channels.Telegram.Poller in held

    assert %{held: []} = ChannelsApplication.boot_plan(@setup_required, "held-epoch", :device)
  end
end
