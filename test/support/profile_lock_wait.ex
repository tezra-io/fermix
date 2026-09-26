defmodule FermixTestSupport.ProfileLockWait do
  @moduledoc """
  Shortens the auth profile lock's wait for one test, so a test that proves the
  busy sentence waits milliseconds instead of the 10 s every taker waits in
  production (`FermixCore.Auth.Store`'s `:auth_profile_lock_wait` seam).

  The app env is the whole VM's, and an async test running beside it may be
  waiting out a live holder on purpose, so only a sync test may shorten it. It
  is restored when the test exits.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @key :auth_profile_lock_wait

  @spec shorten!(map()) :: :ok
  def shorten!(%{async: false}) do
    previous = Application.fetch_env(:fermix_core, @key)
    Application.put_env(:fermix_core, @key, attempts: 3, delay_ms: 10)
    on_exit(fn -> restore(previous) end)
  end

  defp restore({:ok, value}), do: Application.put_env(:fermix_core, @key, value)
  defp restore(:error), do: Application.delete_env(:fermix_core, @key)
end
