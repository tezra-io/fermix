defmodule FermixCore.Browser.Handoff.SweeperTest do
  # The sweeper's cadence with an injected timer and clock: each tick is
  # delivered by hand with the token the sweeper planned.
  use ExUnit.Case, async: true

  alias FermixCore.Browser.Handoff.Ledger
  alias FermixCore.Browser.Handoff.Sweeper
  alias FermixTestSupport.SafeRm

  @stored_at ~U[2026-10-27 09:00:00Z]

  setup do
    home = SafeRm.make_tmp_dir!("handoff_sweeper")
    on_exit(fn -> SafeRm.rm_rf!(home) end)

    key = %{"site" => "a.example", "domain" => "a.example", "name" => "sid", "path" => "/"}

    ledger =
      Ledger.record(Ledger.empty(), %{
        handoff_id: "ho-1",
        from: "Studio Mac",
        sites: ["a.example"],
        stored_at: @stored_at,
        expires_at: ~U[2026-10-27 10:00:00Z],
        cookies: [key]
      })

    :ok = Ledger.write(home, ledger)
    clock = start_supervised!({Agent, fn -> @stored_at end})
    %{home: home, clock: clock}
  end

  defp start_sweeper(ctx) do
    test = self()

    devtools = fn mode, fun, _opts ->
      send(test, {:devtools, mode})
      fun.(fn method, params -> send(test, {:command, method, params}) && {:ok, %{}} end)
    end

    start_supervised!(
      {Sweeper,
       name: nil,
       timer: fn message, delay -> send(test, {:planned, message, delay}) end,
       sweep_opts: [home: ctx.home, now: fn -> Agent.get(ctx.clock, & &1) end, devtools: devtools]}
    )
  end

  test "every 60 s it deletes the expired hand-offs from the running Chrome", ctx do
    sweeper = start_sweeper(ctx)
    assert_receive {:planned, {:sweep, token}, 60_000}

    send(sweeper, {:sweep, token})
    assert_receive {:planned, {:sweep, token}, 60_000}
    refute_received {:devtools, _mode}

    Agent.update(ctx.clock, fn _ -> ~U[2026-10-27 10:00:00Z] end)
    send(sweeper, {:sweep, token})
    assert_receive {:devtools, :running_only}

    assert_receive {:command, "Storage.setCookies",
                    %{"cookies" => [%{"name" => "sid", "expires" => 1}]}}

    assert_receive {:planned, {:sweep, _next}, 60_000}
    assert {:ok, %{handoffs: []}} = Ledger.read(ctx.home)
  end

  test "a stale tick is ignored", ctx do
    sweeper = start_sweeper(ctx)
    assert_receive {:planned, {:sweep, _token}, 60_000}
    send(sweeper, {:sweep, make_ref()})
    refute_receive {:planned, _message, _delay}, 100
  end

  test "with its timer off it plans nothing", ctx do
    start_supervised!({Sweeper, name: nil, timer_enabled: false, sweep_opts: [home: ctx.home]})
    refute_receive {:planned, _message, _delay}, 100
  end
end
