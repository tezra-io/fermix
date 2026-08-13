defmodule FermixChannels.Telemetry do
  @moduledoc false

  @pair_statuses [:approved, :denied, :expired, :rate_limited]
  @push_statuses [:sent, :failed]

  @type pair_status :: :approved | :denied | :expired | :rate_limited
  @type push_status :: :sent | :failed

  @spec emit_parse(atom(), term(), non_neg_integer()) :: :ok
  def emit_parse(channel, result, duration_us)
      when is_atom(channel) and is_integer(duration_us) do
    :telemetry.execute(
      [:fermix, :channel, :parse],
      %{duration_us: duration_us},
      %{channel: channel, status: status(result)}
    )
  end

  @spec emit_authorize(atom(), boolean(), non_neg_integer()) :: :ok
  def emit_authorize(channel, allowed?, duration_us)
      when is_atom(channel) and is_boolean(allowed?) and is_integer(duration_us) do
    :telemetry.execute(
      [:fermix, :channel, :authorize],
      %{duration_us: duration_us},
      %{channel: channel, status: authorize_status(allowed?)}
    )
  end

  @spec emit_render(atom(), term(), non_neg_integer()) :: :ok
  def emit_render(channel, result, duration_us)
      when is_atom(channel) and is_integer(duration_us) do
    :telemetry.execute(
      [:fermix, :channel, :render],
      %{duration_us: duration_us},
      %{channel: channel, status: status(result)}
    )
  end

  @spec emit_message(atom(), atom(), non_neg_integer(), non_neg_integer()) :: :ok
  def emit_message(channel, direction, count, duration_us)
      when is_atom(channel) and is_atom(direction) and is_integer(count) and
             is_integer(duration_us) do
    :telemetry.execute(
      [:fermix, :channel, :message],
      %{count: count, duration_us: duration_us},
      %{channel: channel, direction: direction}
    )
  end

  @spec emit_pair(atom(), pair_status(), non_neg_integer()) :: :ok
  def emit_pair(channel, status, duration_us)
      when is_atom(channel) and status in @pair_statuses and is_integer(duration_us) and
             duration_us >= 0 do
    :telemetry.execute(
      [:fermix, :channel, :pair],
      %{count: 1, duration_us: duration_us},
      %{channel: channel, status: status}
    )
  end

  @spec emit_push(atom(), push_status(), non_neg_integer()) :: :ok
  def emit_push(channel, status, duration_us)
      when is_atom(channel) and status in @push_statuses and is_integer(duration_us) and
             duration_us >= 0 do
    :telemetry.execute(
      [:fermix, :channel, :push],
      %{count: 1, duration_us: duration_us},
      %{channel: channel, status: status}
    )
  end

  defp authorize_status(true), do: :allowed
  defp authorize_status(false), do: :denied

  defp status(:ok), do: :ok
  defp status({:ok, _value}), do: :ok
  defp status({:error, reason}) when is_atom(reason), do: reason
  defp status({:error, _reason}), do: :error
  defp status(_other), do: :ok
end
