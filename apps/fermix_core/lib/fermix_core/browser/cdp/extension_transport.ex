defmodule FermixCore.Browser.CDP.ExtensionTransport do
  @moduledoc """
  The `Transport` for a tab the person granted through the browser extension.

  Where `Connection` is a WebSocket to a whole browser, this addresses exactly
  one tab through the extension's `chrome.debugger` attachment: `start_link/2`
  takes `"bridge:<tab_id>"`, binds to the grant in `Bridge.Grants`, and every
  command travels as one `cdp` frame over the bridge socket.

  The **method allowlist is here, at the boundary, and refuses before
  transmission**. A grant is one tab of the person's own browser, so anything
  browser-wide — the `Browser` domain, `Target.*`, cookie reads — must not be
  reachable through this path even by accident, and a future action that
  reaches for one is refused by this list rather than by remembering to ask.
  Chrome's extension debugger would refuse most of them itself; being refused
  here means the model gets a sentence naming the managed profile instead of a
  raw protocol error, and the command never leaves the daemon.

  Timeouts match `Connection` exactly: a server-side timer fires at
  `timeout_ms` with a precise error and the caller's own `receive` waits
  `timeout_ms + grace_ms` behind it, so the precise error wins the race.
  """

  use GenServer

  @behaviour FermixCore.Browser.CDP.Transport

  require Logger

  alias FermixCore.Browser.Bridge.Grants
  alias FermixCore.Browser.Error

  # The domains a granted tab may be driven with: read it, run script in it,
  # resolve and act on its nodes, and read its accessibility tree. Nothing that
  # addresses the browser rather than the tab.
  @allowed_domains ~w(Page Runtime DOM Input Accessibility)
  # Chrome's own ceiling on a native-messaging message in this direction.
  @max_command_bytes 1_048_576

  @unsupported_method "That browser command is not available in the tab you granted — it " <>
                        "addresses the whole browser, and the grant covers one tab. Use the " <>
                        "managed browser profile for browser-wide work."

  @spec allowed_domains() :: [String.t()]
  def allowed_domains, do: @allowed_domains

  @doc """
  Start a transport for one claimed grant.

  The url names the tab for a reader; the grant itself travels in `:grant`,
  because a tab id alone does not identify a tab — two connected browsers hand
  out the same small integers.
  """
  @impl FermixCore.Browser.CDP.Transport
  @spec start_link(String.t(), keyword()) :: GenServer.on_start()
  def start_link("bridge:" <> _tab_id, opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl FermixCore.Browser.CDP.Transport
  @spec command(
          pid(),
          String.t(),
          map() | nil,
          String.t() | nil,
          pos_integer(),
          non_neg_integer()
        ) ::
          {:ok, map() | list() | nil} | {:error, Error.t()}
  def command(pid, method, params, session_id, timeout_ms, grace_ms)
      when is_pid(pid) and is_binary(method) and is_integer(timeout_ms) and timeout_ms > 0 and
             is_integer(grace_ms) and grace_ms >= 0 do
    with :ok <- allowed_method(method),
         :ok <- within_command_cap(params) do
      await(pid, method, params, session_id, timeout_ms, grace_ms)
    end
  end

  @impl FermixCore.Browser.CDP.Transport
  @spec close(pid()) :: :ok
  def close(pid) when is_pid(pid), do: GenServer.cast(pid, :close)

  @impl GenServer
  def init(opts) do
    grants = Keyword.get(opts, :grants, Grants)
    grant = Keyword.fetch!(opts, :grant)

    case Grants.bind(grants, grant.key, self()) do
      {:ok, peer} ->
        {:ok,
         %{
           tab_id: grant.tab_id,
           peer: peer,
           owner: Keyword.get(opts, :owner, self()),
           next_id: 1,
           pending: %{}
         }}

      {:error, :unknown_tab} ->
        {:stop, :attached_tab_detached}
    end
  end

  @impl GenServer
  def handle_cast({:command, caller, ref, method, params, session_id, timeout_ms}, state) do
    id = state.next_id
    Process.send_after(self(), {:request_timeout, id, method}, timeout_ms)
    send(state.peer, {:bridge_command, self(), id, state.tab_id, method, params, session_id})
    {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, {caller, ref})}}
  end

  def handle_cast(:close, state), do: {:stop, :normal, state}

  @impl GenServer
  def handle_info({:bridge_reply, id, outcome}, state) do
    {:noreply, resolve(id, outcome, state)}
  end

  def handle_info({:request_timeout, id, method}, state) do
    {:noreply,
     resolve(id, {:error, Error.new("cdp_timeout", "CDP command timed out: #{method}")}, state)}
  end

  def handle_info({:bridge_event, method, params}, state) do
    send(state.owner, {:cdp_event, method, %{"method" => method, "params" => params}})
    {:noreply, state}
  end

  # The person took the tab back, closed it, dismissed Chrome's debugging bar,
  # or opened DevTools on it. Tell the owner why before the link takes it down,
  # so the next request says what happened instead of starting again.
  def handle_info({:bridge_revoked, _tab_id, reason}, state) do
    send(state.owner, {:cdp_detached, reason})
    {:stop, :normal, fail_pending(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    fail_pending(state)
    :ok
  end

  defp await(pid, method, params, session_id, timeout_ms, grace_ms) do
    ref = make_ref()
    GenServer.cast(pid, {:command, self(), ref, method, params, session_id, timeout_ms})

    receive do
      {:cdp_response, ^ref, reply} -> reply
    after
      timeout_ms + grace_ms ->
        {:error, Error.new("cdp_timeout", "CDP command timed out: #{method}")}
    end
  end

  defp resolve(id, outcome, state) do
    case Map.pop(state.pending, id) do
      {nil, pending} ->
        %{state | pending: pending}

      {{caller, ref}, pending} ->
        send(caller, {:cdp_response, ref, outcome})
        %{state | pending: pending}
    end
  end

  defp fail_pending(state) do
    Enum.each(state.pending, fn {_id, {caller, ref}} ->
      send(
        caller,
        {:cdp_response, ref, {:error, Error.new("cdp_closed", "The granted tab detached")}}
      )
    end)

    %{state | pending: %{}}
  end

  defp allowed_method(method) do
    case String.split(method, ".", parts: 2) do
      [domain, _rest] when domain in @allowed_domains -> :ok
      _other -> {:error, Error.new("unsupported_in_attached_tab", @unsupported_method)}
    end
  end

  # The cap is on what the runtime puts in a command — a file's bytes, a script,
  # a params blob. The envelope around it is a handful of fields and under a
  # hundred bytes, so this is the ceiling in every way that can be reached.
  defp within_command_cap(params) do
    size = params |> Jason.encode!() |> byte_size()

    if size <= @max_command_bytes do
      :ok
    else
      {:error,
       Error.new(
         "command_too_large",
         "That command is #{size} bytes, over the #{@max_command_bytes}-byte limit the " <>
           "browser extension accepts. Use the managed browser profile for work this large."
       )}
    end
  end
end
