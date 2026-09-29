defmodule FermixTestSupport.RealtimeSocket do
  @moduledoc """
  Drives a fake Realtime socket through the REAL `FermixCore.Realtime.OpenAIClient`
  callbacks.

  The session tests stand in for the WebSockex process with an `Agent` whose state
  keeps the socket's start options under `:opts`. These helpers run
  `OpenAIClient.handle_frame/2` and `handle_disconnect/2` inside that process, where
  WebSockex runs them, so every message the session receives has the shape and the
  sender the real socket gives it. No test writes a socket message by hand: one it
  got wrong would be dropped as another socket's, and the test would pass silently.
  """

  alias FermixCore.Realtime.OpenAIClient

  @doc "OpenAI sends `event` on `socket`."
  @spec deliver(pid(), map()) :: :ok
  def deliver(socket, %{} = event) when is_pid(socket),
    do: deliver_frame(socket, Jason.encode!(event))

  @doc "A raw text frame arrives on `socket`, decodable or not."
  @spec deliver_frame(pid(), binary()) :: :ok
  def deliver_frame(socket, payload) when is_pid(socket) and is_binary(payload) do
    {:ok, _state} =
      Agent.get(socket, &OpenAIClient.handle_frame({:text, payload}, client_state(&1)))

    :ok
  end

  @doc """
  `socket` dies. `reason` is WebSockex's close reason: `{:remote, :closed}` for a
  connection the network dropped, `{:remote, 1000, text}` for OpenAI's clean close,
  `{:local, :normal}` for a close the session asked for once its handshake or
  timeout finishes. WebSockex runs `handle_disconnect/2`, then the process exits,
  and its link hands the session the `EXIT`.

  The exit reason is WebSockex's too (`websockex.ex` `do_terminate`): `:normal`
  after a normal close, local or remote. Any other close exits with its reason,
  which this fake wraps in `{:shutdown, reason}` so the stopped Agent logs no crash
  report.
  """
  @spec finish_close(pid(), term()) :: :ok
  def finish_close(socket, reason) when is_pid(socket) do
    status = %{reason: reason, conn: nil, attempt_number: 1}

    {:ok, _state} =
      Agent.get(socket, &OpenAIClient.handle_disconnect(status, client_state(&1)))

    Agent.stop(socket, exit_reason(reason))
  end

  defp exit_reason({_side, :normal}), do: :normal
  defp exit_reason({_side, 1000, _text}), do: :normal
  defp exit_reason(reason), do: {:shutdown, reason}

  defp client_state(%{opts: opts}), do: %{parent: Keyword.fetch!(opts, :parent)}
end
