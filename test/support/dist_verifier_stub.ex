defmodule FermixTestSupport.DistVerifierStub do
  @moduledoc """
  Test `Verifier` that **default-denies**: `verify/4` returns an error unless a
  matching `{name, version}` was explicitly allowed. This makes it impossible
  for an install test to pass the integrity gate by accident — a forgotten
  `allow/2` fails the verification, never silently succeeds
  (green-because-stubbed is the failure mode this guards against).

  Usage:

      DistVerifierStub.init()
      DistVerifierStub.allow("github", "1.2.0")   # only this (name, version) verifies
  """

  @behaviour FermixCore.Plugins.Dist.Verifier

  @table :dist_verifier_stub

  def init do
    cleanup()
    :ets.new(@table, [:named_table, :public, :set])
    :ok
  end

  def cleanup do
    case :ets.whereis(@table) do
      :undefined -> :ok
      tid -> :ets.delete(tid)
    end
  end

  @doc "Allow exactly this `{name, version}` to verify; everything else is denied."
  def allow(name, version) when is_binary(name) and is_binary(version) do
    :ets.insert(@table, {{name, version}, :ok})
    :ok
  end

  @impl true
  def verify(_blob, _sig, _cert, opts) when is_list(opts) do
    key = {Keyword.get(opts, :name), Keyword.get(opts, :version)}

    case :ets.lookup(@table, key) do
      [{_, :ok}] -> :ok
      [] -> {:error, {:verification_denied, key}}
    end
  end
end
