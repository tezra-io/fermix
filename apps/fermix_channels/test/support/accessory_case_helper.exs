defmodule FermixTestSupport.AccessoryCase do
  @moduledoc """
  What the accessory link's tests share: a home of the test's own, a clock the
  test moves by hand (no real time is ever raced), the pairing store seeded
  for an enrolled accessory, and the link's options against the in-memory
  bus. A link built here schedules nothing itself: the test delivers each
  `:tick` after moving the clock, so every deadline is reached by hand.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias FermixCore.Accessories.P256
  alias FermixCore.Accessories.Record
  alias FermixCore.Accessories.Store
  alias FermixTestSupport.AccessoryBus
  alias FermixTestSupport.AccessoryMemoryTransport

  @serial "80:45:6B:54:87:FC"

  @doc "The USB serial string the tests' accessory reports (A0: the K151's MAC)."
  def serial, do: @serial

  @doc "A fresh home under the system temp directory, removed when the test ends."
  def home! do
    home =
      Path.join(System.tmp_dir!(), "fermix-accessories-#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
    home
  end

  @doc "A clock at `start_ms` that only the test moves; answers the reader function."
  def clock!(start_ms \\ 1_000_000) do
    clock = start_supervised!({Agent, fn -> start_ms end}, id: {:clock, make_ref()})
    {clock, fn -> Agent.get(clock, & &1) end}
  end

  @doc "Moves the test's clock on."
  def advance(clock, ms), do: Agent.update(clock, &(&1 + ms))

  @doc "The home's host key and a record of `public` with the tests' port hint."
  def enroll!(home, public, opts \\ []) do
    {:ok, host} = Store.ensure_host_key(home)

    record = %Record{
      accessory_id: P256.id(public),
      accessory_pk: public,
      kind: "stackchan",
      name: "StackChan",
      port_hint: Keyword.get(opts, :port_hint, @serial),
      enrolled_at: ~U[2026-11-07 12:00:00Z]
    }

    :ok = Store.put(home, record)
    {host, record}
  end

  @doc "A bus with one port at `path` whose peer is `peer`."
  def bus!(path, peer, opts \\ []) do
    bus = start_supervised!(AccessoryBus, id: {AccessoryBus, make_ref()})
    :ok = AccessoryBus.plug(bus, path, Keyword.merge([serial: @serial, peer: peer], opts))
    bus
  end

  @doc """
  The link's options against `bus`: the test's clock, no timer of its own, a
  notify that sends the test every state the link publishes, and voice ready
  unless `:readiness` says otherwise.
  """
  def link_opts(bus, path, home, writer, now, overrides \\ []) do
    test = self()

    Keyword.merge(
      [
        path: path,
        serial: @serial,
        mode: :attach,
        transport: AccessoryMemoryTransport,
        transport_opts: [bus: bus],
        home: home,
        store_writer: writer,
        clock: now,
        send_after: fn _dest, _message, _ms -> make_ref() end,
        readiness: fn -> :ready end,
        notify: fn summary -> send(test, {:link_state, summary}) end
      ],
      overrides
    )
  end

  @doc "Waits for the link to publish a state `match` accepts, and answers it."
  def await_state(match, timeout \\ 2_000) do
    receive do
      {:link_state, summary} ->
        if match.(summary), do: summary, else: await_state(match, timeout)
    after
      timeout -> flunk("the link never published the state the test waits for")
    end
  end

  @doc "Waits for the accessory to read a message of `type`, and answers it."
  def await_received(sim, type, timeout \\ 2_000) do
    receive do
      {:sim, ^sim, {:received, %{type: ^type} = message}} -> message
    after
      timeout -> flunk("the accessory never read a #{type}")
    end
  end
end
