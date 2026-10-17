defmodule FermixChannels.X.ManagementTest do
  # The `x.*` provider (M63) through the wire module that calls it, so every
  # fact it answers is held to `FermixCore.Management.X`'s contract (which
  # raises on a word it does not publish), not to a copy of it. The pairing lives under a
  # home of the test's own, the pump and the subtree are stand-ins, and
  # Connect is a fake module.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixChannels.Test.XConnectHelper, as: Fixtures
  alias FermixChannels.X.Management, as: Provider
  alias FermixChannels.X.Pairing
  alias FermixChannels.X.PairSession
  alias FermixCore.Management.X
  alias FermixCore.Net.Egress
  alias FermixTestSupport.SafeRm

  @status_keys ~w(connection enabled last_failure paired pairing pending refusal running)

  defmodule FakePump do
    @moduledoc false
    use GenServer

    def start_link({name, status}), do: GenServer.start_link(__MODULE__, status, name: name)

    @impl true
    def init(status), do: {:ok, status}

    @impl true
    def handle_call(:status, _from, status), do: {:reply, status, status}
  end

  defmodule FakeConnect do
    @moduledoc false

    def delete_instance(origin, instance_id, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:delete_instance, origin, instance_id})
      Keyword.fetch!(opts, :delete_reply)
    end
  end

  defmodule OpenConnect do
    @moduledoc false

    def create(_origin, _label, _opts) do
      {:ok,
       %{
         enrollment_id: "enr_5c1e9a3b7d2f",
         confirm_url: "https://connect.fermix.example/confirm/EXAMPLE",
         expires_at: ~U[2026-10-16 05:10:00Z]
       }}
    end
  end

  setup do
    home = SafeRm.make_tmp_dir!("x-management")
    on_exit(fn -> SafeRm.rm_rf(home) end)
    unique = System.unique_integer([:positive])

    %{
      home: home,
      pairing: [root: home],
      pump: :"x_management_pump_#{unique}",
      session: :"x_management_session_#{unique}"
    }
  end

  defp opts(ctx, extra) do
    Keyword.merge(
      [
        provider: Provider,
        config: [enabled: false],
        pairing: ctx.pairing,
        pump: ctx.pump,
        session: ctx.session,
        admit: [memory: fn -> :ok end, egress: %Egress{}]
      ],
      extra
    )
  end

  defp pair!(ctx) do
    {:ok, public_key} = Pairing.ensure_key(ctx.pairing)
    {connect_public, _seed} = Fixtures.connect_key()
    record = Fixtures.record(connect_public, %{key_id: Pairing.key_id(public_key)})
    :ok = Pairing.save(record, ctx.pairing)
    {record, public_key}
  end

  defp pump!(ctx, status), do: start_supervised!({FakePump, {ctx.pump, status}})

  defp status!(ctx, extra) do
    assert {:ok, view} = X.status(opts(ctx, extra))
    assert view |> Map.keys() |> Enum.sort() == @status_keys
    view
  end

  describe "status/1" do
    test "a fresh home with the channel off answers every field", ctx do
      assert status!(ctx, []) == %{
               "enabled" => false,
               "paired" => nil,
               "connection" => "off",
               "refusal" => nil,
               "pending" => 0,
               "running" => 0,
               "last_failure" => nil,
               "pairing" => nil
             }
    end

    test "switched on with no pairing is refused by name, never a silent off", ctx do
      view = status!(ctx, config: [enabled: true])

      assert view["connection"] == "refused"
      assert view["refusal"]["reason"] == "not_paired"
      assert view["refusal"]["sentence"] == X.refusal_sentence(:not_paired)
    end

    test "a pairing names the account, the origin and this key's fingerprint", ctx do
      {record, public_key} = pair!(ctx)

      assert status!(ctx, [])["paired"] == %{
               "instance_id" => record.instance_id,
               "handle" => "@sujeeth",
               "fingerprint" => Pairing.fingerprint(public_key),
               "origin" => record.origin,
               "tenant_generation" => 1,
               "paired_at" => "2026-10-16T05:00:00Z"
             }
    end

    test "switched on and not running is refused for the reason admission names", ctx do
      {_record, _public_key} = pair!(ctx)
      on = [config: [enabled: true]]

      assert status!(ctx, on)["connection"] == "off"

      memory = [admit: [memory: fn -> {:error, :memory_unavailable} end, egress: %Egress{}]]
      assert status!(ctx, on ++ memory)["refusal"]["reason"] == "memory_disabled"

      proxied = Egress.new(proxy: "http://proxy.fermix.example:3128")
      proxy = [admit: [memory: fn -> :ok end, egress: proxied]]
      assert status!(ctx, on ++ proxy)["refusal"]["reason"] == "proxy_unsupported"

      SafeRm.rm!(Pairing.key_path(ctx.pairing))
      view = status!(ctx, on)
      assert view["refusal"]["reason"] == "pairing_invalid"
      assert view["paired"] == nil

      File.write!(Pairing.record_path(ctx.pairing), "{}")
      assert status!(ctx, on)["refusal"]["reason"] == "pairing_invalid"
    end

    test "a running channel answers its connection, counters and newest failure", ctx do
      pair!(ctx)

      pump!(ctx, %{
        connection: :connected,
        pending: 2,
        running: 1,
        last_failure: %{at: ~U[2026-10-16 05:02:03.456Z], reason: {:result_rejected, :too_long}}
      })

      view = status!(ctx, config: [enabled: true])

      assert %{"connection" => "connected", "refusal" => nil, "pending" => 2, "running" => 1} =
               view

      assert view["last_failure"] == %{
               "at" => "2026-10-16T05:02:03Z",
               "sentence" => "Fermix Connect refused the reply this Fermix sent."
             }
    end

    test "Connect's refusals of a running channel", ctx do
      pump!(ctx, %{
        connection: {:refused, :revoked},
        pending: 0,
        running: 0,
        last_failure: %{at: ~U[2026-10-16 05:02:03Z], reason: {:refused, :revoked}}
      })

      view = status!(ctx, config: [enabled: true])
      assert view["connection"] == "refused"
      assert view["refusal"]["reason"] == "revoked"
      assert view["last_failure"]["sentence"] == "Fermix Connect refused this Fermix's key."
    end

    test "a socket another one replaced is refused with no reason of its own", ctx do
      pump!(ctx, %{
        connection: {:refused, :replaced},
        pending: 0,
        running: 0,
        last_failure: %{at: ~U[2026-10-16 05:02:03Z], reason: {:refused, :replaced}}
      })

      view = status!(ctx, config: [enabled: true])
      assert %{"connection" => "refused", "refusal" => nil} = view
      assert view["last_failure"]["sentence"] =~ "replaced this one"
    end

    test "every failure the pump records has a word, or is not one the owner acts on" do
      for {reason, word} <- [
            {{:refused, :revoked}, :auth_failed},
            {{:refused, :replaced}, :replaced},
            {{:refused, :proxy_unsupported_transport}, :connect_failed},
            {{:assignment_rejected, :bad_signature}, :assignment_rejected},
            {{:result_rejected, :conflict}, :result_rejected},
            {{:start_refused, :expired}, :expired},
            {{:start_refused, :suppressed}, nil},
            {{:start_refused, :already_settled}, nil},
            {{:start_failed, :not_connected}, :connection_lost},
            {:malformed_start_grant, :turn_failed},
            {:stored_assignment_unreadable, :turn_failed},
            {:turn_stopped, :turn_failed},
            {:result_too_large, :turn_failed},
            {:deadline, :turn_failed},
            {:runner_restarted, :turn_failed},
            {{:store_failed, :busy}, :turn_failed},
            {{:recovery_failed, :busy}, :turn_failed},
            {{:ingest_failed, :unauthorized}, :turn_failed},
            {{:turn_failed, :boom}, :turn_failed},
            {{:reply_not_staged, :gone}, :turn_failed}
          ] do
        assert Provider.failure_word(reason) == word, inspect(reason)
      end

      assert_raise FunctionClauseError, fn -> Provider.failure_word(:something_new) end
    end

    test "the session in flight is named", ctx do
      start_supervised!(
        {PairSession,
         name: ctx.session,
         pairing: ctx.pairing,
         enrollment: OpenConnect,
         timer: fn _message, _ms -> :ok end}
      )

      assert status!(ctx, [])["pairing"] == nil

      assert {:ok,
              %{
                "session_id" => id,
                "confirm_url" => "https://connect.fermix.example/confirm/EXAMPLE?" <> _query,
                "handle" => nil
              }} = X.pair_start("https://connect.fermix.example", opts(ctx, []))

      assert status!(ctx, [])["pairing"] == %{
               "session_id" => id,
               "state" => "awaiting_browser"
             }
    end
  end

  describe "the pairing methods" do
    test "reach the pairing session, which refuses a start while paired", ctx do
      start_supervised!({PairSession, name: ctx.session, pairing: ctx.pairing})
      pair!(ctx)

      assert {:ok, view} = X.pair_start(nil, opts(ctx, []))
      assert view["state"] == "failed"
      assert view["failure"]["sentence"] =~ "already paired"

      assert X.pair_get("unknown", opts(ctx, [])) ==
               {:error, {:unknown_pairing_session, "unknown"}}

      assert X.pair_paste("unknown", "http://127.0.0.1:1/callback", opts(ctx, [])) ==
               {:error, {:unknown_pairing_session, "unknown"}}
    end
  end

  describe "unpair/1" do
    setup ctx do
      parent =
        start_supervised!(%{
          id: :x_parent,
          start: {Supervisor, :start_link, [[], [strategy: :one_for_one]]}
        })

      {:ok, _child} =
        Supervisor.start_child(parent, %{
          id: FermixChannels.X.Supervisor,
          start: {Agent, :start_link, [fn -> :subtree end]}
        })

      Map.put(ctx, :parent, parent)
    end

    defp unpair_opts(ctx, reply) do
      [
        pairing: ctx.pairing,
        enrollment: FakeConnect,
        enrollment_opts: [test_pid: self(), delete_reply: reply],
        subtree: [parent: ctx.parent]
      ]
    end

    defp subtree_running?(ctx) do
      [{FermixChannels.X.Supervisor, pid, _type, _modules}] =
        Supervisor.which_children(ctx.parent)

      is_pid(pid)
    end

    test "revokes at Connect, then forgets the key and the record, then stops the channel",
         ctx do
      {record, _public_key} = pair!(ctx)

      assert {:ok, %{instance_id: instance_id}} = Provider.unpair(unpair_opts(ctx, :ok))
      assert instance_id == record.instance_id
      assert_received {:delete_instance, origin, ^instance_id}
      assert origin == record.origin

      assert {:error, :unpaired} = Pairing.load(ctx.pairing)
      assert {:error, {:missing, _path}} = Pairing.public_key(ctx.pairing)
      refute subtree_running?(ctx)
    end

    test "through the wire it answers the instance id", ctx do
      {record, _public_key} = pair!(ctx)

      assert {:ok, %{"instance_id" => id, "unpaired" => true}} =
               X.unpair([provider: Provider] ++ unpair_opts(ctx, :ok))

      assert id == record.instance_id
    end

    test "nothing paired is said so, and a stray key is left for the session using it", ctx do
      {:ok, _public_key} = Pairing.ensure_key(ctx.pairing)

      assert {:error, :not_paired} = Provider.unpair(unpair_opts(ctx, :ok))
      assert {:ok, _public_key} = Pairing.public_key(ctx.pairing)
      refute_received {:delete_instance, _origin, _id}
    end

    test "a Connect out of reach changes nothing here", ctx do
      pair!(ctx)

      assert {:error, :connect_unreachable} =
               Provider.unpair(unpair_opts(ctx, {:error, :connect_unreachable}))

      assert {:ok, _record} = Pairing.load(ctx.pairing)
      assert subtree_running?(ctx)
    end

    test "a Connect that no longer knows the instance has revoked it already", ctx do
      pair!(ctx)
      reply = {:error, {:connect_refused, "unknown_instance"}}

      assert {:ok, _unpaired} = Provider.unpair(unpair_opts(ctx, reply))
      assert {:error, :unpaired} = Pairing.load(ctx.pairing)
    end

    test "another refusal keeps the pairing and says which", ctx do
      pair!(ctx)
      reply = {:error, {:connect_refused, "stale_request"}}

      assert {:error, {:unpair_refused, {:connect_refused, "stale_request"}}} =
               Provider.unpair(unpair_opts(ctx, reply))

      assert {:ok, _record} = Pairing.load(ctx.pairing)
    end

    test "a pairing whose key cannot sign is forgotten here, and the log says what to do", ctx do
      {record, _public_key} = pair!(ctx)
      SafeRm.rm!(Pairing.key_path(ctx.pairing))

      log =
        capture_log(fn ->
          assert {:ok, %{instance_id: id}} = Provider.unpair(unpair_opts(ctx, :ok))
          assert id == record.instance_id
        end)

      assert log =~ "remove it from the Connect account page"
      refute_received {:delete_instance, _origin, _id}
      assert {:error, :unpaired} = Pairing.load(ctx.pairing)
    end

    test "a record that cannot be read is removed, and this Fermix is then unpaired", ctx do
      pair!(ctx)
      File.write!(Pairing.record_path(ctx.pairing), "not json")

      log =
        capture_log(fn ->
          assert {:error, :not_paired} = Provider.unpair(unpair_opts(ctx, :ok))
        end)

      assert log =~ "the pairing record could not be read"
      assert {:error, :unpaired} = Pairing.load(ctx.pairing)
      refute subtree_running?(ctx)
    end
  end
end
