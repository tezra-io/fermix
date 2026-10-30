defmodule FermixTestSupport.DeviceActionsDouble do
  @moduledoc false
  # The desktops `device_action` reaches in tests (`config :fermix_core,
  # :device_actions` in config/test.exs). It answers from the calling process's
  # own script, kept in that process's dictionary, so async tests never share
  # one: `install/2` names the desktop rows `desktops/0` lists and the function
  # `invoke/4` answers with. A process that installed nothing has no desktop,
  # which is what every other test of the suite sees. Each invoke is reported
  # to the calling process as `{:device_action_invoked, device_id, action, args,
  # opts}`, so a test proves what was (and was not) sent.
  @behaviour FermixCore.DeviceActions

  @key __MODULE__

  @doc "Script this process: the desktop rows, and how an invoke answers."
  @spec install([FermixCore.DeviceActions.desktop()], (String.t(), String.t(), map(), keyword() ->
                                                         term())) :: :ok
  def install(desktops, invoke) when is_list(desktops) and is_function(invoke, 4) do
    Process.put(@key, %{desktops: desktops, invoke: invoke})
    :ok
  end

  @impl true
  def desktops, do: script().desktops

  @impl true
  def invoke(device_id, action, args, opts) do
    send(self(), {:device_action_invoked, device_id, action, args, opts})
    script().invoke.(device_id, action, args, opts)
  end

  defp script do
    Process.get(@key, %{desktops: [], invoke: fn _id, _action, _args, _opts -> unscripted() end})
  end

  defp unscripted, do: raise("DeviceActionsDouble: invoke/4 called with no script installed")
end
