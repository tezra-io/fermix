defmodule FermixTestSupport.StalledRepo do
  @moduledoc false

  # A Memory.Repo that takes a request and never answers: the Repo stuck
  # behind a long operation, which its callers only see as their call timing
  # out. Alone it stalls every request. With `forward_to:` (a real Repo) and
  # `stall:` (request names such as `:get_job_run`) it stalls only those and
  # forwards the rest, so a caller reaches the path that makes the stalled
  # request. Start it with `start_supervised!/1` and pass its pid as `repo:`.

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {config, server_opts} = Keyword.split(opts, [:forward_to, :stall])
    GenServer.start_link(__MODULE__, config, server_opts)
  end

  @impl true
  def init(config) do
    {:ok, %{forward_to: Keyword.get(config, :forward_to), stall: Keyword.get(config, :stall, [])}}
  end

  @impl true
  def handle_call(request, _from, state) do
    if stalls?(request, state) do
      {:noreply, state}
    else
      {:reply, GenServer.call(state.forward_to, request), state}
    end
  end

  defp stalls?(_request, %{forward_to: nil}), do: true
  defp stalls?(request, %{stall: names}), do: request_name(request) in names

  defp request_name(request) when is_tuple(request), do: elem(request, 0)
  defp request_name(request) when is_atom(request), do: request
end
