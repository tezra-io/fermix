defmodule FermixChannels.Accessories.LinkSerialTest do
  @moduledoc """
  A link over the real USB serial transport (`Serial` and its `fermix_serial`
  helper, through the disclaim shim) on a pseudo-terminal, with the test
  playing the accessory at the pty's master: the link's HELLO crosses the
  helper intact, an unenrolled accessory's answer reaches the link, and the
  master closing (an unplug) ends the link as a vanished port. No real
  serial device is opened. macOS-only, like the helper; skipped elsewhere
  with the reason printed.
  """

  use ExUnit.Case, async: false

  alias FermixChannels.Accessories.Link
  alias FermixChannels.Accessories.Serial
  alias FermixChannels.Accessories.StoreWriter
  alias FermixCore.Accessories.Control
  alias FermixCore.Accessories.Frame
  alias FermixCore.Accessories.Parser
  alias FermixTestSupport.AccessoryCase
  alias FermixTestSupport.AccessoryPty

  @darwin? :os.type() == {:unix, :darwin}
  @moduletag skip: if(@darwin?, do: false, else: "needs macOS: fermix_serial is macOS-only")
  @process_bound 10_000

  setup_all do
    unless @darwin?, do: IO.puts("#{inspect(__MODULE__)} skipped: fermix_serial is macOS-only")
    :ok
  end

  setup do
    home = AccessoryCase.home!()
    writer = start_supervised!({StoreWriter, home: home, name: nil})
    {_clock, now} = AccessoryCase.clock!()
    pty = AccessoryPty.open!(@process_bound)
    test = self()

    opts = [
      path: pty.slave,
      serial: nil,
      mode: :pairing,
      transport: Serial,
      transport_opts: [open_timeout_ms: @process_bound],
      home: home,
      store_writer: writer,
      clock: now,
      send_after: fn _dest, _message, _ms -> make_ref() end,
      readiness: fn -> :ready end,
      notify: fn view -> send(test, {:link_state, view}) end
    ]

    %{pty: pty, opts: opts}
  end

  test "the HELLO crosses the real helper, and an unenrolled answer reaches the link", ctx do
    link = start_supervised!({Link, ctx.opts}, restart: :temporary)

    hello = read_message(ctx.pty.double, Parser.new(:host))
    assert %{type: "hello", gen: 1} = hello

    ack = %{
      type: "hello_ack",
      gen: 1,
      wire: 1,
      kind: "stackchan",
      accessory_id: nil,
      firmware: "0.1.0",
      pack: nil,
      caps: 3,
      accessory_nonce: :crypto.strong_rand_bytes(32),
      sig: nil
    }

    {:ok, json} = Control.encode(:accessory, ack)
    frame = Frame.encode(%Frame{type: :control, flags: 3, stream: 0, seq: 0, payload: json})
    Port.command(ctx.pty.double, ["W", frame])

    assert AccessoryCase.await_state(&(&1.phase == :unenrolled), @process_bound).kind ==
             "stackchan"

    ref = Process.monitor(link)
    Port.command(ctx.pty.double, "C")

    assert_receive {:DOWN, ^ref, :process, ^link, {:shutdown, {:transport_closed, :vanished}}},
                   @process_bound
  end

  # Reads what the helper wrote to the slave, from the master, until one whole
  # control message is in.
  defp read_message(double, parser) do
    assert_receive {^double, {:data, "R" <> bytes}}, @process_bound

    case Parser.feed(parser, bytes, 0) do
      {[{:frame, %Frame{type: :control, payload: payload}} | _rest], _parser} ->
        {:ok, message} = Control.decode(:host, 0, payload)
        message

      {[], parser} ->
        read_message(double, parser)
    end
  end
end
