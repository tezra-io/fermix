defmodule FermixCore.Browser.HostServerTest do
  use ExUnit.Case, async: true

  alias FermixCore.Browser
  alias FermixCore.Browser.Backend
  alias FermixCore.Browser.Capabilities
  alias FermixCore.Browser.CDP
  alias FermixCore.Browser.Config
  alias FermixCore.Browser.Error
  alias FermixCore.Browser.HostServer
  alias FermixCore.Browser.ProfileServer

  # A backend whose runtime always comes up and whose every operation answers,
  # so what the server refuses on its own is visible: it never reaches here.
  defmodule UpBackend do
    @behaviour FermixCore.Browser.Backend

    @ops ~w(open navigate snapshot tabs focus close screenshot pdf console dialog cookies storage
            upload download act webmcp)a

    @impl true
    def init(opts), do: %{test_pid: Keyword.fetch!(opts, :test_pid)}
    @impl true
    def status(_state), do: %{"running" => true, "tabs" => 1}
    @impl true
    def start(_context, state), do: {:ok, state}
    @impl true
    def stop(state), do: state
    @impl true
    def handle_message(_message, state), do: state
    @impl true
    def console_buffer(_state), do: []

    for op <- @ops do
      @impl true
      def unquote(op)(_args, _context, state) do
        send(state.test_pid, {:backend_asked, unquote(op)})
        {:ok, %{"ok" => true}, state}
      end
    end
  end

  @pane %{mode: :fermix_app, headless: :auto, cdp_port: :auto}

  defp start_server(opts) do
    {:ok, config} = Config.current(%{})

    start_supervised!(
      {ProfileServer,
       [owner_key: "owner-pane", profile_name: "fermix", profile: @pane, config: config] ++ opts}
    )
  end

  defp req(pid, action, args \\ %{}),
    do: ProfileServer.request(pid, %{action: action, args: args, context: %{agent_name: "t"}})

  test "the fermix_app mode is the host backend, and every other mode is CDP's" do
    assert Backend.for_mode(:fermix_app) == HostServer

    for mode <- [:managed, :existing_session, :remote_cdp, :attached_tab] do
      assert Backend.for_mode(mode) == CDP.Backend
    end
  end

  test "the app's pane is a whole browser of Fermix's own, without WebMCP" do
    caps = Capabilities.for_mode(:fermix_app)

    for capability <- [
          :new_tab,
          :close_tab,
          :focus_tab,
          :cookies,
          :downloads,
          :download_redirect,
          :target_discovery,
          :tab_cap
        ] do
      assert Map.fetch!(caps, capability), "#{capability} is withheld from the app's pane"
    end

    refute caps.webmcp
    refute caps.target_attach

    assert Map.keys(caps) |> Enum.sort() ==
             Capabilities.for_mode(:managed) |> Map.keys() |> Enum.sort()
  end

  # Until the wire lands the stub is the whole backend: the mode can be chosen
  # and every verb it is asked is refused by name, with nothing sent anywhere
  # and the profile left standing.
  test "every action on the app's pane is refused as host_unavailable" do
    pid = start_server([])

    for action <- Browser.actions() -- ["doctor", "status", "stop"] do
      assert {:error, %Error{code: "host_unavailable"} = error} = req(pid, action),
             "`#{action}` was not refused"

      assert error.message =~ "Fermix app's browser"
    end

    assert {:ok, %{"running" => false, "profile" => "fermix"}} = req(pid, "status")
    assert {:ok, %{"stopped" => true}} = req(pid, "stop")
    assert Process.alive?(pid)
  end

  test "the server refuses WebMCP on the app's pane before the backend is asked" do
    pid = start_server(backend: UpBackend, test_pid: self())

    assert {:error, %Error{code: "unsupported_in_fermix_app"} = error} = req(pid, "webmcp")
    assert error.message =~ "snapshot"
    refute_received {:backend_asked, :webmcp}

    assert {:ok, _} = req(pid, "snapshot")
    assert_received {:backend_asked, :snapshot}
  end
end
