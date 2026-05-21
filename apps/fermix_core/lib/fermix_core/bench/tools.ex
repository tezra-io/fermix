defmodule FermixCore.Bench.Tools do
  @moduledoc false

  alias FermixCore.Telemetry

  @spec echo(map(), map()) :: {:ok, %{success: true, output: String.t()}}
  def echo(args, _context) when is_map(args) do
    {output, duration_us} = Telemetry.timed_us(fn -> Map.get(args, "text", "bench tool output") end)

    :telemetry.execute(
      [:fermix, :tool, :exec],
      %{duration_us: duration_us},
      %{agent: "bench", tool: "bench_echo", success: true}
    )

    {:ok, %{success: true, output: output}}
  end
end
