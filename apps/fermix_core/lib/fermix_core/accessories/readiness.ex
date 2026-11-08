defmodule FermixCore.Accessories.Readiness do
  @moduledoc """
  Whether an accessory call can start now (M91 D9), as `voice.readiness`
  tells the accessory. The accessory link runs whenever accessories are on,
  independent of the voice runtime, so an attached accessory may find voice
  off, its key missing, or its runtime not started this boot (the Realtime
  settings are boot-bound); its `call.request` is then refused with the same
  code before any provider session.

  The codes are the readiness vocabulary of `priv/accessory/PROTOCOL.md`
  (*State and settings*): `voice_disabled`, `missing_key`,
  `restart_required`. `needs_local_primary` never arises here: the
  accessories subtree starts only on a local Mac primary. In core because
  both the link (channels) and `accessories.status` (`Management.Accessories`)
  read it, and core never depends on channels.
  """

  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.SessionGuard

  @type t :: :ready | {:not_ready, String.t()}

  @doc """
  Voice readiness for an accessory call. `:config` and `:runtime_running?`
  replace the running config and the runtime probe in a test.
  """
  @spec voice(keyword()) :: t()
  def voice(opts \\ []) when is_list(opts) do
    config = Keyword.get_lazy(opts, :config, &Config.current/0)
    running? = Keyword.get_lazy(opts, :runtime_running?, &runtime_running?/0)

    cond do
      not config.enabled? -> {:not_ready, "voice_disabled"}
      not Config.api_key_present?(config) -> {:not_ready, "missing_key"}
      not running? -> {:not_ready, "restart_required"}
      true -> :ready
    end
  end

  # The voice runtime starts at boot when voice is on and its key is present;
  # its session guard is the part every call goes through.
  defp runtime_running?, do: is_pid(GenServer.whereis(SessionGuard))
end
