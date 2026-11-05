defmodule FermixChannels.Mobile.Iroh.BindPortWiringTest do
  # Which listening helper binds the Always On server's fixed port: the
  # primary's and a candidate's, on the machine `fermix home enroll` marked.
  # A computer a home moves back to, and every other engine, keeps iroh's
  # own port.
  use ExUnit.Case, async: true

  alias FermixChannels.Home.CandidateSupervisor
  alias FermixChannels.Mobile.Iroh
  alias FermixChannels.Mobile.Iroh.Helper
  alias FermixCore.Home.Candidate
  alias FermixTestSupport.SafeRm

  setup do
    home = Path.join(System.tmp_dir!(), "fx-bp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    SafeRm.mark!(home)
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home}
  end

  defp mark_server!(home) do
    File.mkdir_p!(Path.dirname(Candidate.server_path(home)))
    File.write!(Candidate.server_path(home), ~s({"v":1}))
  end

  defp helper_opts(children) do
    Enum.find_value(children, fn
      {Helper, opts} -> opts
      %{id: Helper, start: {Helper, :start_link, [opts]}} -> opts
      _other -> nil
    end)
  end

  defp primary_children(home) do
    names = %{
      bridge_connections: :"bp_conns_#{System.unique_integer([:positive])}",
      bridge: :"bp_bridge_#{System.unique_integer([:positive])}",
      iroh_helper: :"bp_helper_#{System.unique_integer([:positive])}",
      device_store: :"bp_store_#{System.unique_integer([:positive])}"
    }

    {:ok, {_flags, children}} = Iroh.init(root: home, names: names, session_opts: [])
    children
  end

  test "the primary's helper on an Always On server binds the fixed port", %{home: home} do
    assert Keyword.fetch!(helper_opts(primary_children(home)), :bind_port) == nil

    mark_server!(home)
    assert Keyword.fetch!(helper_opts(primary_children(home)), :bind_port) == 4033
  end

  test "a candidate's helper binds it on the server, not on a computer it moves back to",
       %{home: home} do
    mark_server!(home)

    assert Keyword.fetch!(helper_opts(CandidateSupervisor.children(home)), :bind_port) ==
             4033

    mac = Path.join(home, "mac")
    File.mkdir_p!(mac)
    assert Keyword.fetch!(helper_opts(CandidateSupervisor.children(mac)), :bind_port) == nil
  end
end
