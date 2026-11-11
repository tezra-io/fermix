defmodule FermixChannels.Desktop.CompanionTest do
  # M97 §3.4: a computer past the server's window keeps its link for settings
  # alone, so its peer's companion family refuses every chat it opens, and a
  # computer inside the window opens one as ever.
  use ExUnit.Case, async: true

  alias FermixChannels.Desktop.Companion
  alias FermixChannels.Desktop.Peer
  alias FermixChannels.Desktop.Supervisor, as: DesktopSupervisor
  alias FermixTestSupport.SafeRm

  @device "3b9c1e4f-7a2d-4c86-9e15-0f8a2b6d4c71"

  setup do
    suffix = System.unique_integer([:positive])
    registry = Module.concat(__MODULE__, "Peers#{suffix}")
    supervisor = Module.concat(__MODULE__, "PeerSupervisor#{suffix}")
    tunnels = Module.concat(__MODULE__, "Tunnels#{suffix}")

    start_supervised!(
      {DesktopSupervisor, name: nil, registry: registry, peer_supervisor: supervisor}
    )

    start_supervised!({DynamicSupervisor, name: tunnels, strategy: :one_for_one})
    socket_dir = SafeRm.make_tmp_dir!("desktop_companion")
    on_exit(fn -> SafeRm.rm_rf!(socket_dir) end)

    %{registry: registry, supervisor: supervisor, tunnels: tunnels, socket_dir: socket_dir}
  end

  test "a computer past the window is refused every chat, and nothing starts", ctx do
    peer = start_peer!(ctx, :settings_only)

    for channel <- [1, 2] do
      assert :ok = Peer.deliver(peer, open(channel))

      assert_receive {:mobile_event,
                      %{"t" => "companion_close", "channel" => ^channel, "reason" => reason}}

      assert reason == Companion.settings_only_sentence()
    end

    assert DynamicSupervisor.which_children(ctx.tunnels) == []
  end

  test "the sentence names the computer to update and no version" do
    sentence = Companion.settings_only_sentence()

    assert sentence =~ "Update Fermix on this computer"
    refute sentence =~ ~r/\d+\.\d+/
  end

  # The standing reaches every family as the session gave it, and a peer
  # started without one (a phone's list channel) is current.
  defmodule StandingFamily do
    @moduledoc false
    @behaviour FermixChannels.Desktop.Family

    @impl true
    def init(context) do
      send(context.session, {:standing, context.standing})
      {:ok, context}
    end

    @impl true
    def handle_event(_type, _fields, _payload, context), do: {:ok, context}

    @impl true
    def handle_info(_message, context), do: {:ok, context}

    @impl true
    def terminate(_reason, _context), do: :ok
  end

  test "each family is told where the computer stands", ctx do
    for standing <- [:current, :behind, :ahead, :settings_only] do
      {:ok, _peer} =
        Peer.start(ctx.supervisor,
          device_id: @device,
          session: forwarder(),
          registry: ctx.registry,
          standing: standing,
          families: %{manage: StandingFamily}
        )

      assert_receive {:standing, ^standing}
    end

    # Where it stands is never assumed: a peer told nothing does not start.
    Process.flag(:trap_exit, true)

    assert {:error, _missing} =
             Peer.start_link(
               device_id: @device,
               session: forwarder(),
               registry: ctx.registry,
               families: %{manage: StandingFamily}
             )

    refute_received {:standing, _assumed}
  end

  defp start_peer!(ctx, standing) do
    families = %{
      companion:
        {Companion,
         supervisor: ctx.tunnels,
         socket_dir: ctx.socket_dir,
         endpoint: Module.concat(__MODULE__, NoEndpoint)}
    }

    {:ok, peer} =
      Peer.start(ctx.supervisor,
        device_id: @device,
        session: forwarder(),
        registry: ctx.registry,
        standing: standing,
        families: families
      )

    peer
  end

  defp open(channel), do: %{type: "companion_open", payload: %{"channel" => channel}, bytes: <<>>}

  # A stand-in for the desktop's session: whatever reaches it reaches the test.
  defp forwarder do
    test = self()
    spawn_link(fn -> forward(test) end)
  end

  defp forward(test) do
    receive do
      message ->
        send(test, message)
        forward(test)
    end
  end
end
