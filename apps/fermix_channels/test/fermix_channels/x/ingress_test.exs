defmodule FermixChannels.X.IngressTest do
  # The X channel's ingress (MILESTONE_63 D4): the registry entry, the proof
  # the pump alone can hand the gateway, and the Authorizer's third path, which
  # reads the stored assignment and grants a guest, never an operator.
  use ExUnit.Case, async: false

  alias FermixChannels.Gateway.Authorization
  alias FermixChannels.Gateway.Authorizer
  alias FermixChannels.Gateway.ChannelRegistry
  alias FermixChannels.Gateway.Source
  alias FermixChannels.Mobile.DeviceStore
  alias FermixCore.Config
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.SafeRm

  @child {FermixChannels.X.Supervisor, []}

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  setup do
    previous_x = Application.get_env(:fermix_channels, :x)
    previous_registry = Application.get_env(:fermix_channels, :channel_registry)
    Application.delete_env(:fermix_channels, :channel_registry)

    on_exit(fn ->
      restore_env(:fermix_channels, :x, previous_x)
      restore_env(:fermix_channels, :channel_registry, previous_registry)
    end)

    :ok
  end

  describe "the registry entry" do
    test "is a remote, command-less channel admitted by a Connect assignment" do
      x = Enum.find(ChannelRegistry.channels(), &(&1.name == "x"))

      assert x == %{
               name: "x",
               config_key: :x,
               adapter: FermixChannels.Channels.X,
               remote?: true,
               ingress_auth: :connect_assignment,
               commands?: false,
               transport: :gateway,
               child: FermixChannels.X.Supervisor
             }

      assert ChannelRegistry.ingress_auth("x") == :connect_assignment
      assert ChannelRegistry.trust("x") == nil
      refute ChannelRegistry.commands?("x")
      refute ChannelRegistry.local?("x")
      assert Config.channel_ingress_authority(:x) == :connect_assignment
    end

    test "starts its child only when enabled, with no owner or allow-list" do
      Application.put_env(:fermix_channels, :x, enabled: false)
      refute @child in ChannelRegistry.transport_children(%{status: :ready})

      Application.put_env(:fermix_channels, :x, enabled: true)
      assert @child in ChannelRegistry.transport_children(%{status: :ready})
      refute :x in ChannelRegistry.missing_ingress_authorizations()

      Application.delete_env(:fermix_channels, :x)
      refute @child in ChannelRegistry.transport_children(%{status: :ready})
    end
  end

  describe "the transport proof" do
    test "comes from the pump's ingress context on the x channel, and only there" do
      message = %{channel: "x", chat_id: "1:2:1", metadata: %{}}
      context = %{transport: :x, assignment_id: " as_1 "}

      assert Source.from_message(message, context).transport_auth == {:connect_assignment, "as_1"}
      assert Source.from_message(message, %{context | assignment_id: "  "}).transport_auth == nil

      assert Source.from_message(message, %{transport: :mobile, assignment_id: "as_1"}).transport_auth ==
               nil

      assert Source.from_message(%{message | channel: "telegram"}, context).transport_auth == nil
    end

    test "can never be set from message metadata" do
      message = %{
        channel: "x",
        chat_id: "1:2:1",
        metadata: %{"transport_auth" => {:connect_assignment, "as_1"}, assignment_id: "as_1"}
      }

      assert Source.from_message(message).transport_auth == nil
      assert Source.from_message(message, nil).transport_auth == nil
      assert {:error, :unauthorized} = Authorizer.resolve(Source.from_message(message))
    end
  end

  describe "the Authorizer's Connect path" do
    setup do
      unique = System.unique_integer([:positive])
      dir = SafeRm.make_tmp_dir!("x-ingress")
      repo = :"x_ingress_repo_#{unique}"

      start_supervised!(
        {Repo, name: repo, enabled: true, database_path: Path.join(dir, "memory.db")}
      )

      previous_memory = Application.get_env(:fermix_core, :memory)
      Application.put_env(:fermix_core, :memory, Keyword.put(previous_memory || [], :repo, repo))

      on_exit(fn ->
        restore_env(:fermix_core, :memory, previous_memory)
        SafeRm.rm_rf(dir)
      end)

      %{repo: repo}
    end

    defp claim!(repo, id, expires_at) do
      attrs = %{
        assignment_id: id,
        interaction_id: "ix_" <> id,
        tenant_id: "1234567890",
        instance_id: "ins_7f3c2a9e1b4d",
        requester_x_user_id: "1234567890",
        conversation_id: "1844999999999999990",
        request_sha256: String.duplicate("a", 64),
        jws: "aGVhZGVy.cGF5bG9hZA.c2ln",
        expires_at: expires_at,
        claimed_at: DateTime.utc_now()
      }

      {:ok, {:claimed, _row}} = Repo.x_claim_assignment(attrs, server: repo)
    end

    defp start!(repo, id) do
      grant = %{
        attempt: 1,
        runner_epoch: "epoch-ingress",
        deadline_at: DateTime.add(DateTime.utc_now(), 90, :second),
        now: DateTime.utc_now()
      }

      {:ok, _row} = Repo.x_start_assignment(id, grant, server: repo)
    end

    defp resolve(id) do
      %{channel: "x", chat_id: "1234567890:1234567890:1", metadata: %{}}
      |> Source.from_message(%{transport: :x, assignment_id: id})
      |> Authorizer.resolve()
    end

    test "a running, unexpired assignment is a guest, never an operator", %{repo: repo} do
      claim!(repo, "as_run", ~U[2099-01-01 00:00:00Z])
      start!(repo, "as_run")

      assert {:ok, %Authorization{role: :guest, trust: :guest}} = resolve("as_run")
    end

    test "needs no paired-device store", %{repo: repo} do
      assert Process.whereis(DeviceStore) == nil
      claim!(repo, "as_nostore", ~U[2099-01-01 00:00:00Z])
      start!(repo, "as_nostore")

      assert {:ok, %Authorization{trust: :guest}} = resolve("as_nostore")
    end

    test "an accepted, settled, expired or unknown assignment is refused", %{repo: repo} do
      claim!(repo, "as_waiting", ~U[2099-01-01 00:00:00Z])
      assert {:error, :unauthorized} = resolve("as_waiting")

      claim!(repo, "as_done", ~U[2099-01-01 00:00:00Z])
      start!(repo, "as_done")

      result = %{
        decision: :no_reply,
        result_sha256: String.duplicate("b", 64),
        result_json: ~s({"t":"result"}),
        now: DateTime.utc_now()
      }

      {:ok, _row} = Repo.x_complete_assignment("as_done", 1, result, server: repo)
      assert {:error, :unauthorized} = resolve("as_done")

      claim!(repo, "as_lapsed", ~U[2000-01-01 00:00:00Z])
      start!(repo, "as_lapsed")
      assert {:error, :unauthorized} = resolve("as_lapsed")

      assert {:error, :unauthorized} = resolve("as_unknown")
    end

    test "a store that is not running authorizes nothing", %{repo: repo} do
      claim!(repo, "as_down", ~U[2099-01-01 00:00:00Z])
      start!(repo, "as_down")
      stop_supervised!(Repo)

      assert {:error, :unauthorized} = resolve("as_down")
    end
  end
end
