defmodule FermixNif do
  @moduledoc """
  Native (C) NIFs for the `fermix` umbrella.

  Currently exposes a single POSIX `kill(2)` process-group signal shim,
  `kill_pgid/2`, used by the subprocess-lifecycle sweep. Delivering the signal
  as a direct syscall (rather than spawning `kill`) is deliberate: the sweep
  runs precisely during fd/process-table exhaustion, where spawning a helper
  process would itself fail.

  The NIF is built via `elixir_make` (already a hard build dependency through
  `exqlite`) — no Rust or Rustler toolchain is involved.
  """

  @on_load :load_nif

  @doc false
  @spec load_nif() :: :ok | {:error, term()}
  def load_nif do
    :code.priv_dir(:fermix_nif)
    |> :filename.join(~c"fermix_nif")
    |> :erlang.load_nif(0)
  end

  @doc """
  Signals the process group `pgid` via `kill(-pgid, signal)`.

  `pgid` must be a positive integer (a real POSIX process-group id) and
  `signal` one of `:sigterm` / `:sigkill` — the only two signals the sweep
  uses. No general signal surface is exposed.

  Returns `:ok` on success. Errno results map to atoms — `:esrch` (no such
  group; the expected, silent success of a sweep over an empty group),
  `:eperm`, `:einval` — and any other errno to `{:errno, n}`. Policy (treating
  `:esrch` as success) lives with the caller, not here.

  Guards reject an invalid `pgid` or `signal` with `FunctionClauseError`; the
  guarded head is kept separate from the NIF-bound function so the guards
  survive after the NIF loads.
  """
  @spec kill_pgid(pos_integer(), :sigterm | :sigkill) ::
          :ok | {:error, :esrch | :eperm | :einval | {:errno, integer()}}
  def kill_pgid(pgid, signal)
      when is_integer(pgid) and pgid > 0 and signal in [:sigterm, :sigkill] do
    kill_pgid_nif(pgid, signal)
  end

  @doc false
  @spec kill_pgid_nif(pos_integer(), :sigterm | :sigkill) ::
          :ok | {:error, :esrch | :eperm | :einval | {:errno, integer()}}
  def kill_pgid_nif(_pgid, _signal), do: :erlang.nif_error(:nif_not_loaded)
end
