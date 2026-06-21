defmodule FermixCore.ComputerUse.Driver do
  @moduledoc """
  Behaviour for the OS-driver backend that captures the screen and injects
  mouse/keyboard input for `ComputerUse.Session`.

  The production driver is an Elixir Port to the vendored Rust `enigo`+`xcap`
  sidecar (Phase 1c — it needs real-Mac TCC verification and is NOT shipped/claimed
  here). Defining the behaviour lets the `Session` own "a driver" rather than a
  Port directly, so the session is fully unit-testable against a stub driver that
  speaks the same `Protocol` request/response shape without any native code.

  Contract:
    * `start/1` opens the backend (spawns/attaches the sidecar) → an opaque handle.
    * `execute/2` runs one validated `Protocol` request, returning the decoded
      response map (`%{"ok" => true, ...}` shape) or an error.
    * `stop/1` tears the backend down — for the real driver this kills the Port AND
      releases any held keys/mouse buttons (BEAM death alone does not un-press a
      physically-held key); it must be idempotent and is invoked on every teardown
      path (`/stop`, pet interrupt, supervisor shutdown) via the session's
      `terminate/2`.
  """

  @type state :: term()

  @callback start(opts :: keyword()) :: {:ok, state()} | {:error, term()}
  @callback execute(state(), request :: map()) :: {:ok, map()} | {:error, term()}
  @callback stop(state()) :: :ok
end
