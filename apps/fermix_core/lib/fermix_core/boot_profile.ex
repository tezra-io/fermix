defmodule FermixCore.BootProfile do
  @moduledoc """
  Selects and prepares the engine boot posture.

  App-engine ownership comes only from immutable build identity. Burrito
  detection remains relevant to standalone artifacts and is never consulted to
  identify an app engine.
  """

  @type profile :: :app_engine | :standalone_cli | :source

  @doc "Selects a boot profile while giving app identity strict precedence."
  @spec select(String.t(), (-> boolean())) :: profile()
  def select("macos_app", detector) when is_function(detector, 0), do: :app_engine

  def select("standalone", detector) when is_function(detector, 0) do
    if detector.(), do: :standalone_cli, else: :source
  end

  @doc "Applies runtime gates required before sibling OTP applications start."
  @spec prepare(profile()) :: :ok
  def prepare(profile) when profile in [:app_engine, :standalone_cli] do
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
