defmodule FermixChannels.Test.IMessageFakeHelper do
  @moduledoc """
  A scripted `FermixChannels.Channels.IMessage.Helper` for tests: no OS process,
  no `chat.db`, no keychain.

  Every request is answered from a per-method script and reported to the test
  as `{:fake_helper_call, name, method, params}`. A script is a reply
  (`{:ok, map}` or `{:error, {kind, message, data}}`), a one-arity function of
  the params, or a list of either consumed in order whose last entry sticks.
  The test pushes notifications and lifecycle messages to the attached process
  with `push/3`, `helper_up/2` and `helper_down/2`.

  Options: `:name` (an atom, so it can ride in message metadata), `:home`,
  `:test_pid`, `:handshake`, `:attach` (`:up` or `{:down, class}`), and
  `:responses` (a map of method to script, merged over the defaults).
  """

  use GenServer

  @behaviour FermixChannels.Channels.IMessage.Helper

  @good_probe %{
    "helper_version" => "0.0.0-fake",
    "full_disk_access" => "granted",
    "db" => "readable",
    "automation" => "granted",
    "messages_running" => true,
    "signed_in" => true,
    "user_session" => true,
    "policy" => "confirmed",
    "self_aliases" => []
  }

  @handshake %{
    "protocol_version" => 1,
    "helper_version" => "0.0.0-fake",
    "macos_version" => "27.0",
    "bundle_id" => "io.tezra.fermix.messages",
    "db_generation" => %{"inode" => 42, "birth_time" => "2026-09-01T00:00:00Z"}
  }

  @doc "A probe with every gate open."
  @spec good_probe() :: map()
  def good_probe, do: @good_probe

  @doc "The default `initialize` result."
  @spec handshake() :: map()
  def handshake, do: @handshake

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @impl FermixChannels.Channels.IMessage.Helper
  def call(server, method, params, timeout) do
    GenServer.call(server, {:call, method, params}, timeout + 1_000)
  end

  @impl FermixChannels.Channels.IMessage.Helper
  def attach(server, pid), do: GenServer.call(server, {:attach, pid})

  @impl FermixChannels.Channels.IMessage.Helper
  def home(server), do: GenServer.call(server, :home)

  @doc "Replaces the script for `method`."
  @spec script(GenServer.server(), String.t(), term()) :: :ok
  def script(server, method, script), do: GenServer.call(server, {:script, method, script})

  @doc "Sends a helper notification to the attached process."
  @spec push(GenServer.server(), String.t(), map()) :: :ok
  def push(server, event, params),
    do: GenServer.call(server, {:send, {:imessage_event, event, params}})

  @doc "Tells the attached process the helper (re)started."
  @spec helper_up(GenServer.server(), map()) :: :ok
  def helper_up(server, handshake \\ @handshake),
    do: GenServer.call(server, {:send, {:imessage_helper, :up, handshake}})

  @doc "Tells the attached process the helper stopped."
  @spec helper_down(GenServer.server(), term()) :: :ok
  def helper_down(server, class),
    do: GenServer.call(server, {:send, {:imessage_helper, :down, class}})

  @doc "The params of every call to `method`, oldest first."
  @spec calls(GenServer.server(), String.t()) :: [map()]
  def calls(server, method), do: GenServer.call(server, {:calls, method})

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       name: Keyword.fetch!(opts, :name),
       home: Keyword.get(opts, :home, "/nonexistent/fermix-home"),
       test_pid: Keyword.get(opts, :test_pid),
       handshake: Keyword.get(opts, :handshake, @handshake),
       attach: Keyword.get(opts, :attach, :up),
       responses: Map.merge(default_responses(), Keyword.get(opts, :responses, %{})),
       attached: nil,
       calls: []
     }}
  end

  @impl GenServer
  def handle_call({:call, method, params}, _from, state) do
    report(state, {:fake_helper_call, state.name, method, params})
    {reply, state} = next_reply(state, method, params)
    {:reply, reply, %{state | calls: [{method, params} | state.calls]}}
  end

  def handle_call({:attach, pid}, _from, state) do
    reply =
      case state.attach do
        :up -> {:ok, state.handshake}
        {:down, class} -> {:error, {:helper_unavailable, "fake helper down", %{"class" => class}}}
      end

    {:reply, reply, %{state | attached: pid}}
  end

  def handle_call(:home, _from, state), do: {:reply, {:ok, state.home}, state}

  def handle_call({:script, method, script}, _from, state),
    do: {:reply, :ok, put_in(state.responses[method], script)}

  def handle_call({:send, message}, _from, %{attached: pid} = state) when is_pid(pid) do
    send(pid, message)
    {:reply, :ok, state}
  end

  def handle_call({:calls, method}, _from, state) do
    params = for {^method, params} <- Enum.reverse(state.calls), do: params
    {:reply, params, state}
  end

  defp next_reply(state, method, params) do
    case Map.get(state.responses, method, {:ok, %{}}) do
      [only] -> {resolve(only, params), state}
      [next | rest] -> {resolve(next, params), put_in(state.responses[method], rest)}
      script -> {resolve(script, params), state}
    end
  end

  defp resolve(fun, params) when is_function(fun, 1), do: fun.(params)
  defp resolve(reply, _params), do: reply

  defp report(%{test_pid: nil}, _message), do: :ok
  defp report(%{test_pid: pid}, message), do: send(pid, message)

  defp default_responses do
    %{
      "probe" => {:ok, @good_probe},
      "watch.subscribe" => {:ok, %{"started_at_rowid" => 100, "replay_skipped" => 0}},
      "watch.unsubscribe" => {:ok, %{}},
      "messages.after" => {:ok, %{"messages" => [], "has_more" => false}},
      "send.text" => &recorded/1,
      "send.file" => &recorded/1
    }
  end

  defp recorded(_params) do
    {:ok,
     %{
       "disposition" => "recorded",
       "guid" => "sent-#{System.unique_integer([:positive])}",
       "rowid" => System.unique_integer([:positive])
     }}
  end
end
