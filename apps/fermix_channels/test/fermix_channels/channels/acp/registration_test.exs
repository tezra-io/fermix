defmodule FermixChannels.Channels.Acp.RegistrationTest do
  @moduledoc """
  The acp channel's registry entry and its one gate (M29 §4, G4): an enabled
  surface starts its transport child with no ingress config; a disabled one
  leaves nothing behind — no child, no socket.
  """

  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Acp
  alias FermixChannels.Gateway.Authorizer
  alias FermixChannels.Gateway.ChannelRegistry
  alias FermixChannels.Gateway.Source

  setup do
    previous = Application.fetch_env(:fermix_channels, :acp)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:fermix_channels, :acp, value)
        :error -> Application.delete_env(:fermix_channels, :acp)
      end
    end)

    :ok
  end

  describe "registry entry" do
    test "carries the pinned shape" do
      entry = Enum.find(ChannelRegistry.channels(), &(&1.name == "acp"))

      assert entry == %{
               name: "acp",
               config_key: :acp,
               adapter: Acp,
               remote?: true,
               trust: :local_operator,
               commands?: false,
               transport: :gateway,
               child: Acp.Supervisor
             }
    end

    test "reads through the registry accessors" do
      assert ChannelRegistry.channel_key("acp") == :acp
      assert ChannelRegistry.adapter("acp") == Acp
      assert ChannelRegistry.trust("acp") == :local_operator
      refute ChannelRegistry.commands?("acp")
      # `remote?: true` keeps browsers warm across a persistent session's turns
      # and makes detached continuation delivery refuse loudly (§4).
      refute ChannelRegistry.local?("acp")
    end

    test "authorizes as the operator with no sender id and no ingress list" do
      source = Source.from_message(%{channel: "acp", chat_id: "acp-1", metadata: %{}})

      assert {:ok, %{role: :operator, trust: :operator}} = Authorizer.resolve(source)
    end
  end

  describe "the enabled gate (G4)" do
    test "an enabled acp starts its transport child with no ingress config" do
      Application.put_env(:fermix_channels, :acp, enabled: true)

      children = ChannelRegistry.transport_children(%{status: :ready})

      assert {Acp.Supervisor, []} in children
      refute :acp in ChannelRegistry.missing_ingress_authorizations()
    end

    test "a disabled acp starts nothing and leaves no socket" do
      Application.put_env(:fermix_channels, :acp, enabled: false)

      children = ChannelRegistry.transport_children(%{status: :ready})

      refute Enum.any?(children, fn {child, _opts} -> child == Acp.Supervisor end)
      refute File.exists?(Acp.Endpoint.socket_path())
    end

    # Not the shipped default (config/config.exs enables the surface) — this is
    # the registry refusing to guess for a config key that is not in app env at
    # all, the shared `enabled?/1` floor every channel sits on.
    test "a config key missing from app env starts nothing" do
      Application.delete_env(:fermix_channels, :acp)

      children = ChannelRegistry.transport_children(%{status: :ready})

      refute Enum.any?(children, fn {child, _opts} -> child == Acp.Supervisor end)
      refute File.exists?(Acp.Endpoint.socket_path())
    end
  end

  describe "adapter surface" do
    test "declares the raw stream tier and refuses webhook transport" do
      assert Acp.stream_capability() == :raw
      assert Acp.parse_webhook(%{}) == {:error, :unsupported_transport}
      assert Acp.verify_webhook(%Plug.Conn{}) == {:error, :unsupported_transport}
    end

    test "exports every optional callback the raw tier needs and none it does not" do
      # `function_exported?/3` — which is how the gateway resolves optional
      # callbacks — answers false for a module that has not been loaded yet.
      {:module, _module} = Code.ensure_loaded(Acp)

      for {fun, arity} <- [
            build_raw_stream_callback: 1,
            build_activity_callback: 1,
            build_turn_result: 1,
            stream_capability: 0
          ] do
        assert function_exported?(Acp, fun, arity), "Acp must export #{fun}/#{arity}"
      end

      # No approval affordance, no reactions, no draft editing on a machine wire.
      for {fun, arity} <- [
            send_approval: 3,
            react: 2,
            reaction_capability: 0,
            open_draft: 2,
            edit_draft: 3,
            seal_draft: 3,
            album_classify: 1
          ] do
        refute function_exported?(Acp, fun, arity), "Acp must not export #{fun}/#{arity}"
      end
    end
  end
end
