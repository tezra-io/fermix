defmodule FermixCore.ProcessGroup do
  @moduledoc """
  The single home for the command-sweep signal policy.

  Wraps `FermixNif.kill_pgid/2` — a `kill(-pgid, signal)` syscall shim — with
  the one policy the sweep needs: `:esrch` (no such group) is the expected,
  silent success of a sweep over an empty group; any other errno is logged at
  error level. The sweep must never crash its host (`CommandHost` or the
  one-shot `CommandRunner` caller), so this always returns `:ok`.

  The NIF stays policy-free (it maps errno to atoms and nothing more); the
  ESRCH-silent rule lives here.
  """

  require Logger

  @doc """
  Signals the process group `pgid` with `signal` (`:sigterm` or `:sigkill`).

  Always returns `:ok`. `:esrch` is silent success (an empty group is the
  common sweep outcome); any other errno is logged and swallowed so the sweep
  cannot crash the process that runs it.
  """
  @spec signal(pos_integer(), :sigterm | :sigkill) :: :ok
  def signal(pgid, signal)
      when is_integer(pgid) and pgid > 0 and signal in [:sigterm, :sigkill] do
    case FermixNif.kill_pgid(pgid, signal) do
      :ok ->
        :ok

      {:error, :esrch} ->
        :ok

      {:error, reason} ->
        Logger.error("process-group sweep #{signal} of pgid #{pgid} failed: #{inspect(reason)}")

        :ok
    end
  end
end
