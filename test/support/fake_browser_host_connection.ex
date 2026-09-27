defmodule FermixTestSupport.FakeBrowserHostConnection do
  @moduledoc """
  Stands in for `FermixChannels.BrowserHost.Connection` in
  `FermixCore.Browser.HostServer` tests: a plain process that speaks
  `FermixCore.BrowserHost.Link`'s messages, with no real `browser_host.sock`.

  It answers every `{:browser_host_request, ...}` it receives from a script
  keyed by the request `type` (a fixed answer, or a `(payload -> answer)`
  function for one whose result depends on what was asked), and records every
  request and release it saw so a test can assert on them: order, that a
  release travelled behind the requests it was queued behind (BROWSER-1), and
  that a request never sent is a request never answered.
  """

  use GenServer

  alias FermixCore.BrowserHost.Link

  @typedoc "A request's answer, or a function of its payload that produces one."
  @type responder :: Link.answer() | (map() -> Link.answer())

  @doc "Starts a fake connection. `responses` maps a request `type` to its `responder`."
  @spec start_link(%{String.t() => responder()}) :: GenServer.on_start()
  def start_link(responses \\ %{}) when is_map(responses), do: GenServer.start(__MODULE__, responses)

  @doc "Sets (or replaces) the answer for one request `type`."
  @spec respond(pid(), String.t(), responder()) :: :ok
  def respond(pid, type, responder) when is_pid(pid) and is_binary(type),
    do: GenServer.call(pid, {:respond, type, responder})

  @doc "Every `{type, payload}` request this connection has answered, oldest first."
  @spec requests(pid()) :: [{String.t(), map()}]
  def requests(pid) when is_pid(pid), do: GenServer.call(pid, :requests)

  @doc "Every task id released, oldest first, one entry per `task.release` sent."
  @spec releases(pid()) :: [String.t()]
  def releases(pid) when is_pid(pid), do: GenServer.call(pid, :releases)

  @impl true
  def init(responses), do: {:ok, %{responses: responses, requests: [], releases: []}}

  @impl true
  def handle_call({:respond, type, responder}, _from, state),
    do: {:reply, :ok, put_in(state.responses[type], responder)}

  def handle_call(:requests, _from, state), do: {:reply, Enum.reverse(state.requests), state}
  def handle_call(:releases, _from, state), do: {:reply, Enum.reverse(state.releases), state}

  @impl true
  def handle_info({:browser_host_request, from, ref, _task_id, type, payload}, state) do
    :ok = Link.answer(from, ref, answer_for(state.responses, type, payload))
    {:noreply, %{state | requests: [{type, payload} | state.requests]}}
  end

  def handle_info({:browser_host_release, _from, task_id}, state),
    do: {:noreply, %{state | releases: [task_id | state.releases]}}

  defp answer_for(responses, type, payload) do
    case Map.get(responses, type, {:ok, %{}}) do
      responder when is_function(responder, 1) -> responder.(payload)
      answer -> answer
    end
  end
end
