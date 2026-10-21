defmodule FermixChannels.Mobile.SocketHandler do
  @moduledoc """
  The WebSocket carrier of a phone's session: Bandit runs it in the
  connection's own process, right after `Mobile.Router` upgrades the request.

  Everything the session says and does lives in `Mobile.Session`; this module
  only carries it. It ends the TLS upgrade deadline, refuses text messages
  (`1003`), hands each binary message to the session as one Noise message, and
  sends the session's frames as binary messages.
  """

  @behaviour WebSock

  alias FermixChannels.Mobile.Session
  alias FermixChannels.Mobile.TlsTransport

  @impl true
  @spec init(keyword() | map()) :: {:ok, Session.state()} | {:stop, term(), map()}
  def init(opts) when is_list(opts) or is_map(opts) do
    :ok = TlsTransport.clear_upgrade_deadline()
    opts |> Session.init() |> carry()
  end

  @impl true
  def handle_in({_payload, opcode: :text}, state) do
    {:stop, :unsupported_frame, {1003, "binary frames required"}, state}
  end

  def handle_in({payload, opcode: :binary}, state) do
    payload |> Session.handle_frame(state) |> carry()
  end

  @impl true
  def handle_info(message, state), do: message |> Session.handle_info(state) |> carry()

  @impl true
  def terminate(reason, state), do: Session.terminate(reason, state)

  defp carry({:push, [frame], state}), do: {:push, {:binary, frame}, state}
  defp carry({:push, frames, state}), do: {:push, Enum.map(frames, &{:binary, &1}), state}

  defp carry({:stop, reason, close, frames, state}),
    do: {:stop, reason, close, Enum.map(frames, &{:binary, &1}), state}

  defp carry(result), do: result
end
