defmodule FermixChannels.Test.SessionDriver do
  @moduledoc """
  A carrier for one `Mobile.Session` in a process of its own, as
  `Mobile.SocketHandler` carries one in Bandit's: it hands the session each
  wire message the test sends (`wire/2`) and every other message it receives,
  and tells the test each run of frames the session pushes
  (`{:driver_out, driver, frames}`) and how it closed (`{:driver_closed,
  driver, reason, close, frames}`). A `{:driver_to_test, message}` it receives
  goes to the test as `message`, so a family in a desktop's peer can report
  through its session.

  The client half (`client_*`) is the phone's or the desktop's: it encodes
  and encrypts a client frame, and decrypts and decodes what the session sent.
  """

  import ExUnit.Assertions

  alias FermixChannels.Mobile.Noise
  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Mobile.Session

  @doc "Starts a session with `opts` in a process linked to the test."
  def start!(opts) do
    test = self()
    spawn_link(fn -> init(Map.new(opts), test) end)
  end

  @doc "Hands the session one wire message."
  def wire(driver, bytes), do: send(driver, {:driver_wire, bytes})

  @doc "Runs the Noise handshake of `client` against the session in `driver`."
  def handshake!(driver, client) do
    assert {:ok, first, client} = Noise.write_handshake(client, <<>>)
    wire(driver, first)
    assert_receive {:driver_out, ^driver, [second]}
    assert {:ok, <<>>, client} = Noise.read_handshake(client, second)
    client
  end

  @doc "Sends one client event, encrypted, at `seq`."
  def client_send(driver, client, type, payload, seq, bytes \\ <<>>) do
    header =
      payload
      |> Map.merge(%{"v" => Protocol.protocol_version(), "t" => type, "seq" => seq})
      |> Jason.encode!()

    plaintext = <<byte_size(header)::unsigned-big-32, header::binary, bytes::binary>>
    assert {:ok, ciphertext, client} = Noise.encrypt(client, plaintext)
    wire(driver, ciphertext)
    client
  end

  @doc "Waits for the session's next push and decodes its events: `{[{header, bytes}], client}`."
  def client_receive(driver, client) do
    assert_receive {:driver_out, ^driver, frames}
    decode_frames(frames, client)
  end

  @doc "Waits for the session to close: `{reason, close, events, client}`."
  def client_closed(driver, client) do
    assert_receive {:driver_closed, ^driver, reason, close, frames}
    {events, client} = decode_frames(frames, client)
    {reason, close, events, client}
  end

  @doc "Decrypts and decodes a run of frames the session sent."
  def decode_frames(frames, client) do
    Enum.map_reduce(frames, client, fn frame, client ->
      assert {:ok, plaintext, client} = Noise.decrypt(client, frame)
      <<size::unsigned-big-32, header::binary-size(size), bytes::binary>> = plaintext
      {{Jason.decode!(header), bytes}, client}
    end)
  end

  defp init(opts, test) do
    case Session.init(opts) do
      {:ok, state} -> loop(state, test)
      {:stop, reason, _opts} -> send(test, {:driver_closed, self(), reason, nil, []})
    end
  end

  defp loop(state, test) do
    receive do
      {:driver_wire, bytes} -> bytes |> Session.handle_frame(state) |> carry(test)
      {:driver_to_test, message} -> forward(message, state, test)
      message -> message |> Session.handle_info(state) |> carry(test)
    end
  end

  defp forward(message, state, test) do
    send(test, message)
    loop(state, test)
  end

  defp carry({:ok, state}, test), do: loop(state, test)

  defp carry({:push, frames, state}, test) do
    send(test, {:driver_out, self(), frames})
    loop(state, test)
  end

  defp carry({:stop, reason, close, state}, test), do: closed(reason, close, [], state, test)

  defp carry({:stop, reason, close, frames, state}, test),
    do: closed(reason, close, frames, state, test)

  defp closed(reason, close, frames, state, test) do
    :ok = Session.terminate(reason, state)
    send(test, {:driver_closed, self(), reason, close, frames})
  end
end
