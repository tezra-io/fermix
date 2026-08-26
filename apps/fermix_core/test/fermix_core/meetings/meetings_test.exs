defmodule FermixCore.MeetingsTest.IdleSource do
  @moduledoc false
  # An `AudioSource` that starts and then does nothing: the join gates are what
  # this suite is about, and a meeting that never progresses keeps the assertion
  # on the row the join wrote.

  @behaviour FermixCore.Meetings.AudioSource

  use GenServer, restart: :temporary

  @impl FermixCore.Meetings.AudioSource
  def start_link(session, args), do: GenServer.start_link(__MODULE__, {session, args})

  @impl FermixCore.Meetings.AudioSource
  def leave(_source), do: :ok

  @impl FermixCore.Meetings.AudioSource
  def stop(source) do
    if Process.alive?(source), do: GenServer.stop(source, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl FermixCore.Meetings.AudioSource
  def self_count, do: 0

  @impl GenServer
  def init({session, args}), do: {:ok, %{session: session, args: args}}
end

defmodule FermixCore.MeetingsTest do
  # async: false — the join gates read `[fermix_core.meetings]` and
  # `[fermix_core.plugins]` app env, and the concurrency gate reads the one
  # process-wide meetings registry.
  use ExUnit.Case, async: false

  alias FermixCore.Meetings
  alias FermixCore.Meetings.Session
  alias FermixCore.Meetings.SidecarInstaller
  alias FermixCore.Meetings.Store
  alias FermixCore.Meetings.Supervisor, as: MeetingsSupervisor
  alias FermixCore.MeetingsTest.IdleSource
  alias FermixCore.Memory.Repo

  @meet_url "https://meet.google.com/abc-defg-hij"
  @zoom_url "https://zoom.us/j/123456789"
  @created_at ~U[2026-08-17 09:00:00Z]

  @operator %{source_trust: :operator, computer_use_origin: :interactive}

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-meetings-api-#{unique}.db")
    repo_name = :"memory_repo_meetings_api_#{unique}"
    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    dev_local = FermixTestSupport.SafeRm.make_tmp_dir!("meetings-dev-local")
    prior_meetings = Application.get_env(:fermix_core, :meetings)
    prior_plugins = Application.get_env(:fermix_core, :plugins)

    # Both lanes' readiness is established here rather than inherited: an empty
    # dev_local makes "the sidecar is not installed" a fact of this test, not of
    # whatever checkout the operator happens to have.
    put_meetings(enabled: true)
    Application.put_env(:fermix_core, :plugins, dev_local: dev_local)

    on_exit(fn ->
      restore(:meetings, prior_meetings)
      restore(:plugins, prior_plugins)
      FermixTestSupport.SafeRm.rm_rf!(dev_local)

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo_name, dev_local: dev_local}
  end

  describe "join/2 gates, in order" do
    test "1. refuses while the subsystem is disabled", %{repo: repo} do
      put_meetings(enabled: false)

      assert {:error, :meetings_disabled} = join(@zoom_url, repo)
    end

    test "2. refuses anyone but the owner on an attended top-level turn", %{repo: repo} do
      assert {:error, :operator_only} =
               Meetings.join(@zoom_url, context: %{}, store_opts: [server: repo])

      assert {:error, :operator_only} =
               join(@zoom_url, repo, %{source_trust: :guest, computer_use_origin: :interactive})

      assert {:error, :operator_only} =
               join(@zoom_url, repo, Map.put(@operator, :subagent_depth, 1))

      assert {:error, :operator_only} =
               join(@zoom_url, repo, %{source_trust: :operator, computer_use_origin: :unattended})
    end

    test "3. refuses a URL it cannot place", %{repo: repo} do
      assert {:error, :unrecognized_meeting_url} = join("https://example.com/standup", repo)

      assert {:error, :unrecognized_meeting_url} =
               join("https://meet.google.com/lookup/xyz", repo)
    end

    test "4. refuses each lane that is not installed or configured", %{repo: repo} do
      assert {:error, :sidecar_not_installed} = join(@meet_url, repo)
      assert {:error, :zoom_rtms_not_configured} = join(@zoom_url, repo)
    end

    test "5. refuses a second meeting while one is running", %{repo: repo} do
      put_meetings(enabled: true, zoom: :configured)
      hold_registry_slot("mtg_00000000009")

      assert {:error, {:max_concurrent, "mtg_00000000009"}} = join(@zoom_url, repo)
    end

    @tag :capture_log
    test "5b. refuses the loser of a race the fast-path gate cannot see", %{repo: repo} do
      put_meetings(enabled: true, zoom: :configured)
      # The slot is held, but no meeting id is registered — exactly the window
      # between a concurrent join's capacity read and its session registering.
      hold_capacity_slot("mtg_00000000008")

      assert Meetings.active_ids() == []
      assert {:error, {:max_concurrent, "mtg_00000000008"}} = join(@zoom_url, repo)

      # The row inserted before the refused start is failed in place — not left
      # a phantom that `list(scope: :active)` reports and `leave` cannot clear.
      assert {:ok, []} = Meetings.list(scope: :active, store_opts: [server: repo])
      assert {:ok, [stranded]} = Meetings.list(store_opts: [server: repo])
      assert stranded.status == "failed"

      assert {:ok, %{error: "session start failed: " <> _reason}} =
               Meetings.get(stranded.id, store_opts: [server: repo])
    end

    @tag :capture_log
    test "5c. exactly one of two simultaneous joins starts a meeting", %{repo: repo} do
      put_meetings(enabled: true, zoom: :configured)

      results =
        [1, 2]
        |> Enum.map(fn _attempt -> Task.async(fn -> join(@zoom_url, repo) end) end)
        |> Task.await_many(5_000)

      assert [{:ok, %{id: id}}] = Enum.filter(results, &match?({:ok, _started}, &1))

      assert [{:error, {:max_concurrent, _held}}] =
               Enum.filter(results, &match?({:error, _r}, &1))

      assert Meetings.active_ids() == [id]

      {:ok, session} = lookup(id)
      stop_session(session)
    end

    test "6. inserts the row and starts the session", %{repo: repo} do
      put_meetings(enabled: true, zoom: :configured)

      assert {:ok, %{id: id, status: :requested}} =
               join(@zoom_url, repo, @operator, title: "Standup")

      assert {:ok, session} = lookup(id)

      # The lane is chosen once, in join/2; the session is already past the row
      # the insert wrote.
      assert Session.status(session) == :launching
      assert {:ok, meeting} = Meetings.get(id, store_opts: [server: repo])
      assert meeting.platform == "zoom"
      assert meeting.title == "Standup"
      assert meeting.requested_by == "operator"
      assert meeting.status == "launching"
      assert Meetings.active_ids() == [id]

      stop_session(session)
    end

    test "records the conversation the meeting was asked for in", %{repo: repo} do
      put_meetings(enabled: true, zoom: :configured)
      context = Map.put(@operator, :conversation_key, {"telegram", 4242, :root})

      assert {:ok, %{id: id}} = join(@zoom_url, repo, context)

      assert {:ok, %{origin_session_id: "telegram:4242:root"}} =
               Meetings.get(id, store_opts: [server: repo])

      {:ok, session} = lookup(id)
      stop_session(session)
    end
  end

  describe "leave/2" do
    test "is :not_found for an id nobody ever requested", %{repo: repo} do
      assert {:error, :not_found} = Meetings.leave("mtg_zzzzzzzzzzz", store_opts: [server: repo])
    end

    test "is :not_active for a meeting that already ended", %{repo: repo} do
      seed(repo, "mtg_00000000001", "delivered")

      assert {:error, :not_active} = Meetings.leave("mtg_00000000001", store_opts: [server: repo])
    end

    test "winds down the running meeting", %{repo: repo} do
      put_meetings(enabled: true, zoom: :configured)
      assert {:ok, %{id: id}} = join(@zoom_url, repo)
      {:ok, session} = lookup(id)
      ref = Process.monitor(session)

      assert Meetings.leave(id, store_opts: [server: repo]) == :ok
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 2_000

      assert {:ok, %{status: "failed", error: ":operator_left"}} =
               Meetings.get(id, store_opts: [server: repo])
    end
  end

  describe "list/1" do
    test "defaults to recent, newest first, and clamps the limit", %{repo: repo} do
      seed(repo, "mtg_00000000001", "capturing", ~U[2026-08-17 10:00:00Z])
      seed(repo, "mtg_00000000002", "delivered", ~U[2026-08-17 11:00:00Z])

      assert {:ok, recent} = Meetings.list(store_opts: [server: repo])
      assert Enum.map(recent, & &1.id) == ["mtg_00000000002", "mtg_00000000001"]

      assert {:ok, [%{id: "mtg_00000000001"}]} =
               Meetings.list(scope: :active, store_opts: [server: repo])

      assert {:ok, clamped} = Meetings.list(limit: 5_000, store_opts: [server: repo])
      assert length(clamped) == 2
    end
  end

  describe "ready?/0" do
    test "needs the toggle and at least one usable lane", %{dev_local: dev_local} do
      put_meetings(enabled: false)
      refute Meetings.ready?()

      put_meetings(enabled: true)
      assert Meetings.enabled?()
      refute Meetings.ready?()

      put_meetings(enabled: true, zoom: :configured)
      assert Meetings.ready?()

      put_meetings(enabled: true)
      install_fake_sidecar(dev_local)
      assert Meetings.ready?()

      put_meetings(enabled: false)
      refute Meetings.ready?()
    end
  end

  # --- helpers --------------------------------------------------------------

  defp join(url, repo, context \\ @operator, opts \\ []) do
    Meetings.join(
      url,
      [
        context: context,
        store_opts: [server: repo],
        session_opts: [source_module: IdleSource]
      ] ++ opts
    )
  end

  defp lookup(id) do
    case Registry.lookup(MeetingsSupervisor.registry(), id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp stop_session(session) do
    ref = Process.monitor(session)
    DynamicSupervisor.terminate_child(MeetingsSupervisor.session_supervisor(), session)
    assert_receive {:DOWN, ^ref, :process, ^session, _reason}, 2_000
  end

  # A registered-but-foreign process is exactly what the concurrency gate counts:
  # one live session per meeting id, whoever owns it.
  defp hold_registry_slot(id) do
    owner = self()

    holder =
      spawn(fn ->
        {:ok, _pid} = Registry.register(MeetingsSupervisor.registry(), id, nil)
        send(owner, :slot_held)

        receive do
          :release -> :ok
        end
      end)

    assert_receive :slot_held, 1_000
    on_exit(fn -> send(holder, :release) end)
  end

  # The atomic half of the same gate: the one capacity slot, held under the key
  # `Session.init/1` claims, with the holder's meeting id as its value.
  defp hold_capacity_slot(id) do
    owner = self()

    holder =
      spawn(fn ->
        {:ok, _pid} = Registry.register(MeetingsSupervisor.registry(), :capacity_slot, id)
        send(owner, :slot_held)

        receive do
          :release -> :ok
        end
      end)

    assert_receive :slot_held, 1_000
    on_exit(fn -> send(holder, :release) end)
  end

  defp install_fake_sidecar(dev_local) do
    {:ok, target} = SidecarInstaller.target()
    dir = Path.join([dev_local, "meetbot_sidecar", "bin", target])
    File.mkdir_p!(dir)
    path = Path.join(dir, "fermix-meetbot")
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
  end

  defp put_meetings(opts) do
    Application.put_env(
      :fermix_core,
      :meetings,
      [enabled: Keyword.get(opts, :enabled, false)] ++ zoom_keys(Keyword.get(opts, :zoom))
    )
  end

  defp zoom_keys(:configured) do
    [
      zoom_account_id: "acct-1",
      zoom_client_id: "client-1",
      zoom_client_secret: "secret-1",
      zoom_ws_subscription_id: "sub-1"
    ]
  end

  defp zoom_keys(_absent), do: []

  defp seed(repo, id, status, created_at \\ @created_at) do
    {:ok, _meeting} =
      Store.insert(
        %{
          id: id,
          platform: "zoom",
          url: @zoom_url,
          title: nil,
          requested_by: "operator",
          origin_session_id: nil,
          created_at: created_at
        },
        server: repo
      )

    {:ok, _row} = Store.update_status(id, status, %{}, server: repo)
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, prior), do: Application.put_env(:fermix_core, key, prior)
end
