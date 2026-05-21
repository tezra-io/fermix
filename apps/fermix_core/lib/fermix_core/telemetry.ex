defmodule FermixCore.Telemetry do
  @moduledoc false

  @spec timed_us((-> result)) :: {result, non_neg_integer()} when result: term()
  def timed_us(fun) when is_function(fun, 0) do
    start = System.monotonic_time(:microsecond)
    result = fun.()
    {result, System.monotonic_time(:microsecond) - start}
  end
end
