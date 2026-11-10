defmodule FermixCore.Management.ComputerLinkTest do
  # M97 §3.1, §3.3: a computer's own link to a home, through the router, as
  # its app sends it: join with a code, cancel, disconnect. The stub
  # keychain is one table for the VM, so each home names a profile of its own.
  use ExUnit.Case, async: true

  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.EnrollmentCode
  alias FermixCore.Home.Join
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Router
  alias FermixTestSupport.SafeRm

  @now ~U[2031-05-04 10:00:00Z]

  setup do
    home = SafeRm.make_tmp_dir!("computer_link")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    profile = "cl-#{System.unique_integer([:positive])}"
    File.write!(Path.join(home, "config.toml"), ~s([fermix_core]\nprofile = "#{profile}"\n))
    test = self()
    restart = fn -> send(test, :restarted) && :ok end
    %{home: home, seams: [home: home, now: @now, restart: restart]}
  end

  test "joins with a computer's code, then restarts; a second join is refused", ctx do
    assert {:ok, %{"joining" => true, "sentence" => sentence}} =
             route("computer.join.start", %{"code" => code()}, ctx)

    assert sentence =~ "waits for you to add it"
    assert_received :restarted
    assert Join.present?(ctx.home)

    assert {:error, :unavailable, %{"capability" => "computer", "sentence" => running}} =
             route("computer.join.start", %{"code" => code()}, ctx)

    assert running =~ "already joining"

    assert {:ok, %{"cancelled" => true}} = route("computer.join.cancel", %{}, ctx)
    refute Join.present?(ctx.home)
  end

  test "a code that is not a computer's is refused on code, by name", ctx do
    assert {:error, :invalid_params, %{"field" => "code", "sentence" => sentence}} =
             route("computer.join.start", %{"code" => code(purpose: :candidate)}, ctx)

    assert sentence =~ "sets up a server of your own"

    assert {:error, :invalid_params, %{"field" => "code"}} =
             route("computer.join.start", %{}, ctx)

    assert {:error, :invalid_params, %{"field" => "token"}} =
             route("computer.join.start", %{"code" => code(), "token" => "x"}, ctx)

    refute_received :restarted
  end

  test "a computer with a home of its own is refused by name", ctx do
    File.mkdir_p!(Path.join(ctx.home, "device"))
    File.write!(DesktopLink.path(ctx.home), "{}")

    assert {:error, :unavailable, %{"sentence" => sentence}} =
             route("computer.join.start", %{"code" => code()}, ctx)

    assert sentence =~ "already has a Fermix of its own (it holds a link to a server)"
  end

  test "disconnect needs a link, and a server that cannot be told asks first", ctx do
    assert {:error, :unavailable, %{"sentence" => "This computer is not connected to a Fermix."}} =
             route("computer.disconnect", %{}, ctx)

    assert {:error, :invalid_params, %{"field" => "confirmed"}} =
             route("computer.disconnect", %{"confirmed" => "yes"}, ctx)

    unreachable = fn _request, _opts -> {:error, :primary_unreachable, %{}} end

    assert {:error, :unavailable, %{"sentence" => sentence}} =
             route("computer.disconnect", %{}, ctx, primary_forward: unreachable)

    # No link here: nothing is told, and nothing changes.
    assert sentence == "This computer is not connected to a Fermix."
  end

  defp route(method, params, ctx, opts \\ []) do
    Router.route(
      %{method: method, protocol_version: Protocol.protocol_version(), params: params},
      [operation_opts: [computer_link: ctx.seams], always_on: true] ++ opts
    )
  end

  defp code(overrides \\ []) do
    facts =
      Map.merge(
        %{
          purpose: :computer,
          secret: :binary.copy(<<0x5A>>, 32),
          gateway_pk: :binary.copy(<<0x3C>>, 32),
          node_id: String.duplicate("4f", 32),
          relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
          relays_rev: "0123456789abcdef",
          name: "studio-mac",
          expires_at: ~U[2031-05-04 10:30:00Z]
        },
        Map.new(overrides)
      )

    {:ok, code} = EnrollmentCode.encode(facts)
    code
  end
end
