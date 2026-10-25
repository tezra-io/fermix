defmodule FermixTestSupport.FakeCueTransport do
  @moduledoc """
  A stand-in `Cues.Source.Stream.Transport` for the stream worker's tests, which
  the test drives by hand: no network, no real time.

  `start/3` spawns one process per connection, monitors it from the caller as
  the real transport does, and tells the test (the `:test` start option)
  `{:dialed, url, socket, opts}`, whose `:headers` and `:messages` are what the
  real transport would send on the upgrade and right after it. The socket then
  reports what the worker asks of it, in order: `{:pinged, socket}`,
  `{:acked, socket}`, and `{:closed, socket}`, after which it exits `:normal`.
  Sent `{:die, reason}`, it exits with `reason`, as the real transport does when
  a connection ends. It ends with the test.
  """

  @behaviour FermixCore.Cues.Source.Stream.Transport

  @impl true
  def start(url, owner, opts) when is_binary(url) and is_pid(owner) and is_list(opts) do
    test = Keyword.fetch!(opts, :test)
    socket = spawn(fn -> loop(test, Process.monitor(test)) end)
    monitor = Process.monitor(socket)
    send(test, {:dialed, url, socket, opts})
    {:ok, socket, monitor}
  end

  @impl true
  def ack(socket) when is_pid(socket), do: send(socket, :ack) && :ok

  @impl true
  def ping(socket) when is_pid(socket), do: send(socket, :ping) && :ok

  @impl true
  def close(socket) when is_pid(socket), do: send(socket, :close) && :ok

  defp loop(test, monitor) do
    receive do
      :ping ->
        send(test, {:pinged, self()})
        loop(test, monitor)

      :ack ->
        send(test, {:acked, self()})
        loop(test, monitor)

      :close ->
        send(test, {:closed, self()})

      {:die, reason} ->
        exit(reason)

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        :ok
    end
  end
end
