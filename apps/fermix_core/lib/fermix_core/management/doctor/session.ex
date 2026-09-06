defmodule FermixCore.Management.Doctor.Session do
  @moduledoc """
  The body of one management Doctor run (M34 §5).

  Runs the scope's descriptors in order under one monotonic whole-run budget,
  streaming each finished descriptor to the owning `FermixCore.Management.Doctor`
  as it lands so a polling `doctor.get` shows real progress rather than an
  opaque "running".

  The budget is checked between checks and enforced from outside by the owner,
  which terminates this task when the deadline fires. That single deadline is
  the run's only bound: there is no second per-check timer to disagree with it.
  """

  alias FermixCore.Management.Doctor.Descriptor

  @spec run([Descriptor.spec()], keyword()) :: :ok
  def run(specs, opts) when is_list(specs) and is_list(opts) do
    owner = Keyword.fetch!(opts, :owner)
    session_id = Keyword.fetch!(opts, :session_id)
    deadline_mono = Keyword.fetch!(opts, :deadline_mono)
    clock = Keyword.get(opts, :clock, &monotonic_ms/0)

    specs
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {spec, index}, _acc ->
      run_one(spec, index, owner, session_id, deadline_mono, clock)
    end)
  end

  defp run_one(spec, index, owner, session_id, deadline_mono, clock) do
    if clock.() >= deadline_mono do
      {:halt, :ok}
    else
      send(owner, {:doctor_check, session_id, index, Descriptor.run(spec, clock: clock)})
      {:cont, :ok}
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
