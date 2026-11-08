defmodule FermixChannels.Companion.EndpointTest do
  @moduledoc """
  The companion socket's listener answers a call the moment it comes while it
  waits for a connection: a desktop's tunnel on the primary asks it for
  `connection_opts/1` on every channel it opens. Its connections are covered
  end to end in `Companion.ConnectionTest`; here one is stood in for.
  """

  # async: false, so the run of calls below is timed with the runner to itself.
  use ExUnit.Case, async: false

  alias FermixChannels.Companion.Endpoint
  alias FermixTestSupport.SafeRm

  # Once it has taken a connection, a server that waits in a 50 ms accept takes
  # each call only when that accept times out, so these calls in a row would
  # need over 5 s; answered at once they take a few milliseconds.
  @calls_in_a_row 101
  @calls_bound_ms 2_500

  # A connection that only tells the test it holds its socket.
  defmodule HeldConnection do
    @moduledoc false
    use GenServer, restart: :temporary

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_info(:socket_handover, opts) do
      send(Keyword.fetch!(opts, :test), {:held, self()})
      {:noreply, opts}
    end
  end

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "fermix-companion-ep-#{System.unique_integer([:positive])}.sock"
      )

    on_exit(fn -> SafeRm.rm(path) end)
    connections = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    name = :"companion_endpoint_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Endpoint,
       name: name,
       socket_path: path,
       connection_supervisor: connections,
       connection_module: HeldConnection,
       connection_opts: [test: self()]}
    )

    %{endpoint: name, socket_path: path}
  end

  # The held connection is the endpoint's accept loop at work.
  test "answers a call at once while it waits for a connection", ctx do
    test = self()

    {:ok, _client} =
      :gen_tcp.connect({:local, to_charlist(ctx.socket_path)}, 0, [:binary, active: false])

    assert_receive {:held, _connection}
    started = System.monotonic_time(:millisecond)

    for _call <- 1..@calls_in_a_row,
        do: assert({:ok, [test: ^test]} = Endpoint.connection_opts(ctx.endpoint))

    took_ms = System.monotonic_time(:millisecond) - started
    assert took_ms < @calls_bound_ms, "#{@calls_in_a_row} calls took #{took_ms} ms"
  end
end
