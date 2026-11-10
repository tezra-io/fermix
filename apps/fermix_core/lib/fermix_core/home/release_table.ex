defmodule FermixCore.Home.ReleaseTable do
  @moduledoc """
  The release table an Always On server reads to choose the release it may
  install (M97 §3.4, D14: the server leads), kept by the primary.

  On an Always On server's primary where this build offers Always On
  (`Home.AlwaysOn.server?/1` and `Home.AlwaysOnRelease.available?/0`, both
  decided once at boot by `FermixCore.Application`), it fetches
  `https://fermix.ai/install/releases` at start and every five minutes after,
  each fetch in a task of its own so a call is never held behind one: a
  10 second timeout, a 1 MiB body at most, no redirect followed, and the text
  read by `Home.Releases.parse/1`. The last table read is kept; a fetch that
  fails keeps it and is said in one sentence beside it, and with no table
  read yet the answer is that sentence alone, so `home.status` names no
  eligible release and the server's update installs nothing: it fails
  closed. Anywhere else (a computer, a candidate, a server that never moved,
  any engine where Always On is off) it fetches nothing and answers why.

  `current/1` is the one read (`Management.Home`'s `update`); `fetch/1` is
  one fetch with no process, for a move's review on the computer that moves
  (`Home.MoveReadiness`), which is no server.

  Test seams in `start_link/1`: `:fetch` (0-arity, in place of `fetch/1`,
  answering `{:ok, Releases.t()} | {:error, String.t()}`), `:fetching`
  (boolean), `:timer_enabled` (dark under `mix test`; `refresh/1` asks for one
  fetch then), `:now`, `:task_supervisor`, `:name`. There is no environment
  override: the address is the installer's own.
  """

  use GenServer

  require Logger

  alias FermixCore.Home.Releases
  alias FermixCore.Net.HttpClient

  @url "https://fermix.ai/install/releases"
  @interval_ms 5 * 60_000
  @timeout_ms 10_000
  @max_bytes 1_048_576
  @call_timeout_ms 5_000

  @not_server "This computer is not an Always On server, so it reads no release table."
  @not_running "Fermix is not running, so it has not read the release table."
  @not_read_yet "Fermix has not read the release table yet."

  @type answer ::
          {:ok, Releases.t(), DateTime.t(), String.t() | nil} | {:error, String.t()}

  @doc "Starts the table under `opts` (the moduledoc's seams)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  The last table read, when, and the sentence of a fetch that failed since
  (nil when none did); or, with none read, the sentence that says why.
  """
  @spec current(GenServer.server()) :: answer()
  def current(server \\ __MODULE__) do
    if GenServer.whereis(server),
      do: GenServer.call(server, :current, @call_timeout_ms),
      else: {:error, @not_running}
  catch
    :exit, reason ->
      Logger.warning("release table: no answer: #{inspect(reason)}")
      {:error, @not_running}
  end

  @doc """
  Asks for one fetch now and answers once it is done, with `current/1`'s
  answer; a table that fetches nothing answers at once.
  """
  @spec refresh(GenServer.server(), timeout()) :: answer()
  def refresh(server \\ __MODULE__, timeout \\ 30_000),
    do: GenServer.call(server, :refresh, timeout)

  @doc """
  One fetch of the table and its read, with no process: a body past 1 MiB,
  an answer other than 200, a timeout or a table `Releases.parse/1` refuses
  is `{:error, sentence}`, the cause logged. `:req_options` (`plug: ...`)
  stands in for the network in a test.
  """
  @spec fetch(keyword()) :: {:ok, Releases.t()} | {:error, String.t()}
  def fetch(opts \\ []) when is_list(opts) do
    req =
      [
        method: :get,
        url: @url,
        receive_timeout: Keyword.get(opts, :timeout_ms, @timeout_ms),
        retry: false,
        redirect: false,
        decode_body: false,
        into: &collect_capped/2
      ]
      |> Keyword.merge(Keyword.get(opts, :req_options, []))
      |> Req.new()

    case HttpClient.request(req, "release table") do
      {:ok, response} -> read(response)
      {:error, exception} -> failed({:transport, exception})
    end
  end

  @doc "Where the table is read from."
  @spec url() :: String.t()
  def url, do: @url

  @doc "Every sentence `current/1` answers, for the copy rules."
  @spec sentences() :: [String.t()]
  def sentences, do: [@not_server, @not_running, @not_read_yet, unreadable()]

  @impl true
  def init(opts) do
    state = %{
      fetching: Keyword.get(opts, :fetching, false),
      timer_enabled: Keyword.get(opts, :timer_enabled, true),
      fetch: Keyword.get(opts, :fetch, &fetch/0),
      now: Keyword.get(opts, :now, &DateTime.utc_now/0),
      task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
      table: nil,
      read_at: nil,
      failure: nil,
      task: nil,
      timer: nil,
      waiting: []
    }

    if state.fetching and state.timer_enabled,
      do: {:ok, state, {:continue, :fetch}},
      else: {:ok, state}
  end

  @impl true
  def handle_continue(:fetch, state), do: {:noreply, start_fetch(state)}

  @impl true
  def handle_call(:current, _from, state), do: {:reply, answer(state), state}

  def handle_call(:refresh, _from, %{fetching: false} = state),
    do: {:reply, answer(state), state}

  def handle_call(:refresh, from, state),
    do: {:noreply, start_fetch(%{state | waiting: [from | state.waiting]})}

  @impl true
  def handle_info(:fetch, state), do: {:noreply, start_fetch(state)}

  def handle_info({ref, result}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> settle(result) |> fetched()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: ref} = state) do
    Logger.error("release table: the fetch ended: #{inspect(reason)}")
    {:noreply, state |> settle({:error, unreadable()}) |> fetched()}
  end

  def handle_info(message, state) do
    Logger.debug("release table ignored #{inspect(message)}")
    {:noreply, state}
  end

  # One fetch at a time: a fetch asked for while one runs waits for it.
  defp start_fetch(%{task: ref} = state) when is_reference(ref), do: state

  defp start_fetch(state) do
    task = Task.Supervisor.async_nolink(state.task_supervisor, state.fetch)
    %{state | task: task.ref}
  end

  defp settle(state, {:ok, %Releases{} = table}),
    do: %{state | table: table, read_at: state.now.(), failure: nil}

  defp settle(state, {:error, sentence}) when is_binary(sentence),
    do: %{state | failure: sentence}

  defp settle(state, other) do
    Logger.error("release table: the fetch answered #{inspect(other)}")
    %{state | failure: unreadable()}
  end

  # The callers waiting on a refresh hear the answer, and the next fetch is
  # set, where the timer runs.
  defp fetched(state) do
    state = %{state | task: nil}
    Enum.each(state.waiting, &GenServer.reply(&1, answer(state)))
    %{state | waiting: [], timer: next_timer(state)}
  end

  # One timer at a time: a refresh's fetch replaces the one set.
  defp next_timer(%{timer_enabled: false}), do: nil

  defp next_timer(%{timer: timer}) do
    if is_reference(timer), do: Process.cancel_timer(timer)
    Process.send_after(self(), :fetch, @interval_ms)
  end

  defp answer(%{fetching: false}), do: {:error, @not_server}
  defp answer(%{table: nil, failure: nil}), do: {:error, @not_read_yet}
  defp answer(%{table: nil, failure: failure}), do: {:error, failure}
  defp answer(state), do: {:ok, state.table, state.read_at, state.failure}

  defp collect_capped({:data, data}, {req, %{body: body} = response})
       when is_binary(data) and is_binary(body) do
    if byte_size(body) + byte_size(data) > @max_bytes do
      {:halt, {req, Req.Response.put_private(response, :fermix_body_cap, :too_large)}}
    else
      {:cont, {req, %{response | body: body <> data}}}
    end
  end

  defp read(%Req.Response{status: 200, body: body} = response) when is_binary(body) do
    case Req.Response.get_private(response, :fermix_body_cap) do
      :too_large ->
        failed(:too_large)

      nil ->
        case Releases.parse(body) do
          {:ok, table} -> {:ok, table}
          {:error, {:invalid_table, reason}} -> failed({:invalid_table, reason})
        end
    end
  end

  defp read(%Req.Response{status: status}), do: failed({:status, status})

  defp failed(reason) do
    Logger.warning("release table: #{@url} could not be read: #{inspect(reason)}")
    {:error, unreadable()}
  end

  defp unreadable,
    do:
      "Fermix could not read the release table from fermix.ai, so it installs no " <>
        "new release until it can; the log says why."
end
