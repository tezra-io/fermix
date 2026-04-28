defmodule Fermix.CLI.Run do
  @moduledoc """
  `fermix run` — foreground daemon entry point used by service managers
  (launchd, systemd) and by operators running the binary interactively.

  By the time this module is invoked, `FermixCore.Application.start/2`
  has already enabled the Phoenix endpoint server and built the
  supervision tree. OTP will then auto-start `fermix_channels` and
  `fermix_web` (both `:permanent` in the release). This function only
  emits a "daemon online" log line and blocks; the BEAM stays alive
  because all sibling apps are `:permanent`.
  """

  require Logger

  @spec run([String.t()]) :: non_neg_integer()
  def run(_argv) do
    Logger.info("fermix daemon online — press Ctrl+C to stop")
    block_until_shutdown()
  end

  defp block_until_shutdown do
    Process.flag(:trap_exit, true)

    receive do
      :shutdown -> 0
    end
  end
end
