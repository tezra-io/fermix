defmodule FermixCore.BootProfile do
  @moduledoc """
  Selects and prepares the engine boot posture.

  App-engine ownership comes only from immutable build identity. Burrito
  detection remains relevant to standalone artifacts and is never consulted to
  identify an app engine.
  """

  alias FermixCore.Boot.PathBaseline

  @type profile :: :app_engine | :standalone_cli | :source

  @doc "Selects a boot profile while giving app identity strict precedence."
  @spec select(String.t(), (-> boolean())) :: profile()
  def select("macos_app", detector) when is_function(detector, 0), do: :app_engine

  def select("standalone", detector) when is_function(detector, 0) do
    if detector.(), do: :standalone_cli, else: :source
  end

  @doc """
  Applies runtime gates required before sibling OTP applications start.

  The `PATH` baseline is applied here and only here: an `SMAppService`-launched
  engine inherits launchd's bare `PATH` and would otherwise resolve no `cosign`,
  no brew `node` or `python`, and no `codex` or `claude` in `~/.local/bin`.
  A `:source` run deliberately gets none, so a developer sees their own `PATH`.
  """
  @spec prepare(profile()) :: :ok
  def prepare(profile) when profile in [:app_engine, :standalone_cli] do
    PathBaseline.ensure!()
    enable_endpoint_server()
    Application.put_env(:fermix_core, :daemon_socket_enabled, true)
    Application.put_env(:fermix_core, :realtime_socket_enabled, true)
  end

  def prepare(:source), do: :ok

  defp enable_endpoint_server do
    existing = Application.get_env(:fermix_web, FermixWebWeb.Endpoint, [])
    Application.put_env(:fermix_web, FermixWebWeb.Endpoint, Keyword.put(existing, :server, true))
  end
end
