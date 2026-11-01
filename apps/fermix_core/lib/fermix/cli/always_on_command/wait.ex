defmodule Fermix.CLI.AlwaysOnCommand.Wait do
  @moduledoc """
  Following a step from the terminal (Always On setup §3.3, §8.2): ask
  `home.status {after: KEY, wait_ms: 25000}`, which the daemon holds until
  the summary's key moves, again and again until nothing is moving, printing
  one line on stderr each time the sentence or the step in hand changes. No
  interval: the daemon answers when the screen moves.

  **Moving** is what the screen says runs by itself: `creating` and
  `moving`; right after a step, also a code for a server of the owner's own
  still open (`connect` offering Cancel the code: the server it was opened
  for is coming); and right after Move now, also the screen before the
  engine's restart (`ready` or `undone` until the restart shows). A screen
  read with no step taken (`:screen`) waits on neither, so the owner gets
  Cancel the code there.

  **Bounded.** The whole wait stops after 45 minutes (a step's job has 15,
  a code 30) or 2,000 reads, whichever comes first, answering the screen
  as it stands (`{:bounded, summary}`). A connection that closes, or an
  engine that stops answering, is the move's restart: reconnect for up to
  90 seconds, one read a second, then `engine_stopped`. Ctrl-C stops the
  wait and leaves the step running.
  """

  alias Fermix.CLI.AlwaysOnCommand
  alias Fermix.CLI.AlwaysOnCommand.Render

  @wait_ms 25_000
  # The daemon holds the read up to `wait_ms`; the client allows 5 s more.
  @call_ms @wait_ms + 5_000
  @budget_ms 45 * 60_000
  @max_reads 2_000
  @reconnect_ms 90_000
  @reconnect_every_ms 1_000
  @reconnect_call_ms 10_000
  @gone [:not_running, :closed, :timeout, :econnreset]
  @moving ~w(creating moving)

  @type outcome :: {:ok, map()} | {:bounded, map()} | {:refused, atom(), keyword()}

  @doc """
  Follows `summary` until nothing is moving. `since`: what led to it, `:screen`
  (read with no step taken), `:step` (a step was just taken) or `:move` (a
  move was just started here, so the engine is about to restart).
  """
  @spec follow(map(), :screen | :step | :move, AlwaysOnCommand.context()) :: outcome()
  def follow(summary, since, ctx) when is_map(summary) and since in [:screen, :step, :move] do
    state = %{
      summary: summary,
      since: since,
      move?: since == :move,
      line: Render.progress(summary),
      deadline: ctx.now_ms.() + @budget_ms,
      reads: 0
    }

    if moving?(state), do: hint_and_loop(state, ctx), else: {:ok, summary}
  end

  defp hint_and_loop(state, ctx) do
    IO.puts(
      ctx.stderr,
      "Waiting for Always On to move on. Ctrl-C stops waiting; the step goes on, and " <>
        "fermix always-on shows where it stands."
    )

    loop(state, ctx)
  end

  defp loop(state, ctx) do
    cond do
      not moving?(state) -> {:ok, state.summary}
      state.reads >= @max_reads or ctx.now_ms.() >= state.deadline -> {:bounded, state.summary}
      true -> state |> read(ctx) |> moved_on(state, ctx)
    end
  end

  defp read(state, ctx) do
    params = %{"after" => state.summary["key"], "wait_ms" => @wait_ms}

    case ctx.client.("home.status", params, AlwaysOnCommand.call_opts(ctx, @call_ms)) do
      {:ok, %{"summary" => %{} = summary}} ->
        {:read, summary}

      {:error, reason} when reason in @gone ->
        reconnect(state, ctx)

      {:error, reason} ->
        {:refused, :home_status_unavailable, output: AlwaysOnCommand.said(reason)}

      {:ok, _no_summary} ->
        {:refused, :home_status_unavailable, output: "it answered no screen"}
    end
  end

  # The move's screen stands until the restart: once it shows, or the state
  # leaves it, what remains to wait on is a step's.
  defp moved_on({:read, summary}, state, ctx) do
    since = if summary["state"] in ~w(ready undone), do: state.since, else: step(state.since)
    loop(%{say(state, summary, ctx) | since: since, reads: state.reads + 1}, ctx)
  end

  defp moved_on({:restarted, summary}, state, ctx),
    do: loop(%{say(state, summary, ctx) | since: step(state.since), reads: state.reads + 1}, ctx)

  defp moved_on({:refused, _code, _details} = refused, _state, _ctx), do: refused

  defp say(state, summary, ctx) do
    line = Render.progress(summary)
    if line != state.line, do: IO.puts(ctx.stderr, "  " <> line)
    %{state | summary: summary, line: line}
  end

  # The engine restarts for the move: one read a second until it answers,
  # for at most 90 seconds.
  defp reconnect(state, ctx), do: reconnect(state, ctx, ctx.now_ms.() + @reconnect_ms)

  defp reconnect(state, ctx, deadline) do
    if ctx.now_ms.() >= deadline,
      do: {:refused, :engine_stopped, if(state.move?, do: [move: true], else: [])},
      else: state |> reread(ctx) |> reconnected(state, ctx, deadline)
  end

  defp reread(_state, ctx) do
    ctx.sleep.(@reconnect_every_ms)
    ctx.client.("home.status", %{}, AlwaysOnCommand.call_opts(ctx, @reconnect_call_ms))
  end

  defp reconnected({:ok, %{"summary" => %{} = summary}}, _state, _ctx, _deadline),
    do: {:restarted, summary}

  defp reconnected({:error, reason}, state, ctx, deadline) when reason in @gone,
    do: reconnect(state, ctx, deadline)

  defp reconnected({:error, reason}, _state, _ctx, _deadline),
    do: {:refused, :home_status_unavailable, output: AlwaysOnCommand.said(reason)}

  defp reconnected({:ok, _no_summary}, _state, _ctx, _deadline),
    do: {:refused, :home_status_unavailable, output: "it answered no screen"}

  defp step(:move), do: :step
  defp step(since), do: since

  defp moving?(%{summary: summary, since: since}) do
    summary["state"] in @moving or (since != :screen and code_open?(summary)) or
      (since == :move and summary["state"] in ~w(ready undone))
  end

  # `connect` offers Cancel the code while a code for a server of the
  # owner's own is open: the server it is for has yet to come.
  defp code_open?(%{"state" => "connect"} = summary),
    do: Enum.any?(Render.records(summary), &(&1["id"] == "cancel"))

  defp code_open?(_summary), do: false
end
