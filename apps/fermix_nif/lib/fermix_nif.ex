defmodule FermixNif do
  @moduledoc """
  Native (C) NIFs for the `fermix` umbrella.

  Exposes two POSIX shims:

    * `kill_pgid/2`, a `kill(2)` process-group signal used by the
      subprocess-lifecycle sweep. Delivering the signal as a direct syscall
      (rather than spawning `kill`) is deliberate: the sweep runs precisely
      during fd/process-table exhaustion, where spawning a helper process
      would itself fail.
    * `set_stdin_echo/1`, the terminal driver's ECHO flag on stdin, used by
      the CLI's hidden secret entry. The ERTS a shipped binary runs is built
      without termcap, so OTP's own no-echo mode answers `:enotsup` on every
      terminal; a port child cannot change it either, because it has no
      controlling terminal. The VM is in the terminal's foreground process
      group, so it flips the flag itself.

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

  @typedoc "Why the terminal's echo flag could not be read or changed."
  @type echo_error :: :enotty | :ebadf | :eio | :eintr | {:errno, integer()}

  @doc """
  Turns the terminal driver's ECHO flag on stdin on (`true`) or off (`false`)
  and answers whether echo was on before, so a caller can restore exactly what
  it found.

  Only ECHO changes. Canonical line editing stays on, so the kernel still
  assembles the line (backspace works) and Enter still ends it; nothing typed
  is echoed while the flag is off.

  `{:error, :enotty}` means stdin is not a terminal. `{:error, :eio}` is a
  process in an orphaned background group. Any other errno arrives as
  `{:errno, n}`. A non-boolean argument is rejected with `FunctionClauseError`
  before anything native runs.
  """
  @spec set_stdin_echo(boolean()) :: {:ok, boolean()} | {:error, echo_error()}
  def set_stdin_echo(echo?) when is_boolean(echo?), do: set_stdin_echo_nif(echo?)

  @doc false
  @spec set_stdin_echo_nif(boolean()) :: {:ok, boolean()} | {:error, echo_error()}
  def set_stdin_echo_nif(_echo?), do: :erlang.nif_error(:nif_not_loaded)
end
