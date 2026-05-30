defmodule FermixCore.Bench.Stats do
  @moduledoc """
  Percentile summaries for benchmark samples.
  """

  @type summary :: %{
          count: pos_integer(),
          p50_us: non_neg_integer(),
          p95_us: non_neg_integer(),
          p99_us: non_neg_integer(),
          max_us: non_neg_integer(),
          mean_us: float(),
          stdev_us: float()
        }

  @spec summarize([non_neg_integer()]) :: summary()
  def summarize(samples) when is_list(samples) and samples != [] do
    sorted = Enum.sort(samples)
    count = length(sorted)
    mean = Enum.sum(sorted) / count

    %{
      count: count,
      p50_us: percentile(sorted, 50),
      p95_us: percentile(sorted, 95),
      p99_us: percentile(sorted, 99),
      max_us: List.last(sorted),
      mean_us: Float.round(mean, 2),
      stdev_us: Float.round(stdev(sorted, mean), 2)
    }
  end

  @spec summarize_safe([non_neg_integer()]) :: {:ok, summary()} | {:error, :empty_samples}
  def summarize_safe([]), do: {:error, :empty_samples}
  def summarize_safe(samples) when is_list(samples), do: {:ok, summarize(samples)}

  defp percentile(sorted, percentile) do
    count = length(sorted)
    index = ceil(count * percentile / 100) - 1
    Enum.at(sorted, max(index, 0))
  end

  defp stdev(samples, mean) do
    variance =
      samples
      |> Enum.reduce(0, fn sample, acc -> acc + :math.pow(sample - mean, 2) end)
      |> Kernel./(length(samples))

    :math.sqrt(variance)
  end
end
