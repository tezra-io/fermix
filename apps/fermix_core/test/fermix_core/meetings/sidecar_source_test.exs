defmodule FermixCore.Meetings.SidecarSourceTest do
  use ExUnit.Case, async: true

  alias FermixCore.Meetings.Config
  alias FermixCore.Meetings.SidecarSource

  @url "https://meet.google.com/abc-defg-hij"

  defmodule StubSidecar do
    @moduledoc false
    @behaviour FermixCore.Meetings.Sidecar

    @impl true
    def launch(owner, opts) do
      controller = Keyword.fetch!(opts, :controller)
      send(controller, {:stub_launch, owner, opts})
      {:ok, %{controller: controller}}
    end

    @impl true
    def send_control(%{controller: controller}, msg) do
      send(controller, {:stub_control, msg})
      :ok
    end

    @impl true
    def handle_message(_state, {:sidecar_control, _msg} = event), do: event
    def handle_message(_state, {:sidecar_audio, _pcm} = event), do: event
    def handle_message(_state, {:sidecar_exit, _status} = event), do: event
    def handle_message(_state, _other), do: :ignore

    @impl true
    def stop(%{controller: controller}) do
      send(controller, :stub_stop)
      :ok
    end
  end

  defmodule RefusingSidecar do
    @moduledoc false
    @behaviour FermixCore.Meetings.Sidecar

    @impl true
    def launch(_owner, opts), do: {:error, Keyword.fetch!(opts, :refusal)}

    @impl true
    def send_control(_state, _msg), do: {:error, :closed}

    @impl true
    def handle_message(_state, _message), do: :ignore

    @impl true
    def stop(_state), do: :ok
  end

  describe "launch" do
    test "sends exactly one join and reports the joining phase" do
      {:ok, source} = start_source()

      assert_receive {:stub_launch, ^source, opts}
      assert opts[:binary_path] == "/test/fermix-meetbot"
      assert opts[:profile_dir] == "/test/profile"

      assert_receive {:stub_control, join}

      assert join == %{
               "type" => "join",
               "platform" => "meet",
               "url" => @url,
               "passcode" => nil,
               "bot_name" => "Fermix Notetaker",
               "announce" => true,
               "announce_message" => "hello from the notetaker",
               "profile_dir" => "/test/profile"
             }

      assert_receive {:meeting_phase, :joining, %{}}
      refute_receive {:stub_control, _second_join}, 50
    end

    test "a handshake timeout is reported through the shared expiry emitter" do
      {:ok, source} =
        start_source(
          sidecar_module: RefusingSidecar,
          sidecar_opts: [refusal: {:handshake_timeout, 300}]
        )

      ref = Process.monitor(source)

      assert_receive {:meeting_source_error, {:timeout, :meetbot_handshake, 300}}
      assert_receive {:DOWN, ^ref, :process, ^source, :normal}
    end

    test "any other launch failure is reported verbatim" do
      {:ok, _source} =
        start_source(
          sidecar_module: RefusingSidecar,
          sidecar_opts: [refusal: {:sidecar_missing, "/no/such"}]
        )

      assert_receive {:meeting_source_error, {:sidecar_missing, "/no/such"}}
    end
  end

  describe "frame translation" do
    setup do
      {:ok, source} = start_source()
      assert_receive {:stub_control, %{"type" => "join"}}
      assert_receive {:meeting_phase, :joining, %{}}
      %{source: source}
    end

    test "state phases", %{source: source} do
      control(source, %{"type" => "state", "phase" => "knocking"})
      assert_receive {:meeting_phase, :knocking, %{}}

      # "leaving" has no normalized counterpart — meeting_ended carries it.
      control(source, %{"type" => "state", "phase" => "leaving"})
      refute_receive {:meeting_phase, _phase, _meta}, 50
    end

    test "every join_result status", %{source: source} do
      for status <- ~w(denied login_required signin_required bot_blocked knock_timeout admitted) do
        control(source, %{"type" => "join_result", "status" => status})
        expected = String.to_existing_atom(status)
        assert_receive {:meeting_join_result, ^expected, %{}}
      end
    end

    test "roster snapshots are normalized and capped", %{source: source} do
      participants =
        for index <- 1..250, do: %{"id" => "p_#{index}", "name" => "Guest #{index}"}

      control(source, %{"type" => "roster", "participants" => participants})

      assert_receive {:meeting_roster, roster}
      assert length(roster) == 200
      assert hd(roster) == %{id: "p_1", name: "Guest 1"}
    end

    test "a malformed roster entry is a protocol error, not a partial roster", %{source: source} do
      control(source, %{"type" => "roster", "participants" => [%{"id" => "p_1"}]})

      assert_receive {:meeting_source_error, {:protocol_error, :malformed_roster}}
      refute_receive {:meeting_roster, _roster}, 50
    end

    test "active speaker, chat, and meeting end", %{source: source} do
      control(source, %{"type" => "active_speaker", "id" => "p_ab12", "t_ms" => 4_000})
      assert_receive {:meeting_active_speaker, "p_ab12", 4_000}

      control(source, %{"type" => "chat_posted"})
      assert_receive {:meeting_chat_posted}

      control(source, %{"type" => "meeting_ended", "reason" => "host_removed"})
      assert_receive {:meeting_ended, :host_removed}
    end

    test "audio is forwarded untouched", %{source: source} do
      pcm = :binary.copy(<<1, 2>>, 800)
      send(source, {:sidecar_audio, pcm})

      assert_receive {:meeting_audio, ^pcm}
    end

    test "a terminal sidecar error stops the source", %{source: source} do
      ref = Process.monitor(source)
      control(source, %{"type" => "error", "code" => "page_crash", "message" => "tab died"})

      assert_receive {:meeting_source_error, {:sidecar_error, "page_crash", "tab died"}}
      assert_receive {:DOWN, ^ref, :process, ^source, :normal}
      assert_receive :stub_stop
    end

    test "a control type this daemon does not handle is a protocol error", %{source: source} do
      control(source, %{"type" => "hello", "protocol_version" => 1})

      assert_receive {:meeting_source_error, {:protocol_error, {:unexpected_control, "hello"}}}
    end

    test "log lines are forwarded, not translated", %{source: source} do
      control(source, %{"type" => "log", "level" => "warn", "message" => "slow page"})

      refute_receive {:meeting_source_error, _reason}, 50
      assert Process.alive?(source)
    end
  end

  describe "relaunch bound" do
    test "a pre-admission crash is retried exactly once" do
      {:ok, source} = start_source()
      assert_receive {:stub_launch, ^source, _opts}
      assert_receive {:stub_control, %{"type" => "join"}}

      send(source, {:sidecar_exit, 1})

      assert_receive :stub_stop
      assert_receive {:stub_launch, ^source, _opts}
      assert_receive {:stub_control, %{"type" => "join"}}
      refute_receive {:meeting_source_error, _reason}, 50

      # The second crash has spent the budget.
      send(source, {:sidecar_exit, 1})
      assert_receive {:meeting_source_error, {:sidecar_crashed, 1}}
    end

    test "a post-admission crash never relaunches — the bot would rejoin unbidden" do
      {:ok, source} = start_source()
      assert_receive {:stub_launch, ^source, _opts}
      assert_receive {:stub_control, %{"type" => "join"}}

      control(source, %{"type" => "join_result", "status" => "admitted"})
      assert_receive {:meeting_join_result, :admitted, _meta}

      send(source, {:sidecar_exit, 0})

      assert_receive {:meeting_source_error, {:sidecar_crashed, 0}}
      refute_receive {:stub_launch, _source, _opts}, 50
    end

    test "a protocol error from the transport arrives as a crash" do
      {:ok, source} = start_source()
      assert_receive {:stub_control, %{"type" => "join"}}
      control(source, %{"type" => "join_result", "status" => "admitted"})
      assert_receive {:meeting_join_result, :admitted, _meta}

      send(source, {:sidecar_exit, {:protocol_error, :empty_frame}})

      assert_receive {:meeting_source_error, {:sidecar_crashed, {:protocol_error, :empty_frame}}}
    end
  end

  describe "ping policy" do
    test "an idle sidecar is pinged, and an answering one is left alone" do
      {:ok, source} = start_source(timers: %{tick_ms: 10, ping_idle_ms: 20, pong_grace_ms: 5_000})
      assert_receive {:stub_control, %{"type" => "join"}}

      assert_receive {:stub_control, %{"type" => "ping"}}, 1_000

      control(source, %{"type" => "pong"})
      refute_receive {:meeting_source_error, _reason}, 100
    end

    test "a sidecar that answers nothing is wedged" do
      {:ok, _source} = start_source(timers: %{tick_ms: 10, ping_idle_ms: 20, pong_grace_ms: 30})
      assert_receive {:stub_control, %{"type" => "join"}}

      assert_receive {:stub_control, %{"type" => "ping"}}, 1_000
      assert_receive {:meeting_source_error, :sidecar_wedged}, 1_000
    end
  end

  defmodule WedgedSidecar do
    @moduledoc false
    # A sidecar whose teardown fails, so the source exits with a reason that is
    # not `:noproc` — the same shape the caller sees when a source wedged in the
    # handshake outlasts the stop timeout.

    @behaviour FermixCore.Meetings.Sidecar

    @impl true
    def launch(_owner, _opts), do: {:ok, %{}}

    @impl true
    def send_control(_state, _msg), do: :ok

    @impl true
    def handle_message(_state, _message), do: :ignore

    @impl true
    def stop(_state), do: raise("sidecar teardown failed")
  end

  describe "operator control" do
    test "leave sends the polite leave frame" do
      {:ok, source} = start_source()
      assert_receive {:stub_control, %{"type" => "join"}}

      assert SidecarSource.leave(source) == :ok
      assert_receive {:stub_control, %{"type" => "leave"}}
    end

    test "stop tears the sidecar down and is safe on a dead source" do
      {:ok, source} = start_source()
      assert_receive {:stub_control, %{"type" => "join"}}

      assert SidecarSource.stop(source) == :ok
      assert_receive :stub_stop
      assert SidecarSource.stop(source) == :ok
    end

    @tag :capture_log
    test "stop survives a source that cannot end cleanly" do
      # The real caller is the Session, which traps exits: the link carries no
      # decision here, only the `stop/1` return does.
      Process.flag(:trap_exit, true)
      {:ok, source} = start_source(sidecar_module: WedgedSidecar)
      assert_receive {:meeting_phase, :joining, %{}}

      # The caller is a Session in teardown: whatever the source does on its way
      # out, the terminal row write that follows this call must still happen.
      assert SidecarSource.stop(source) == :ok
      refute Process.alive?(source)
    end
  end

  test "the Meet bot counts as one roster seat of its own" do
    assert SidecarSource.self_count() == 1
  end

  defp start_source(overrides \\ []) do
    args =
      %{
        url: @url,
        config: %Config{
          bot_name: "Fermix Notetaker",
          announce: true,
          announce_message: "hello from the notetaker"
        },
        binary_path: "/test/fermix-meetbot",
        profile_dir: "/test/profile",
        session_id: "meeting_test",
        sidecar_module: StubSidecar,
        sidecar_opts: [controller: self()]
      }
      |> Map.merge(Map.new(overrides))
      |> put_controller()

    SidecarSource.start_link(self(), args)
  end

  # A stub that replaces the default still needs the control channel.
  defp put_controller(args) do
    Map.update!(args, :sidecar_opts, &Keyword.put_new(&1, :controller, self()))
  end

  defp control(source, msg), do: send(source, {:sidecar_control, msg})
end
