defmodule FermixCore.Realtime.CallRegistry do
  @moduledoc """
  Where the Live call in progress is found (M56 §4.2 and §4.8).

  One unique-key `Registry` under `Realtime.Supervisor`, started before any
  session. A `LiveSessionServer` registers in it from `init/1`, under two keys:

    * its `call_uuid`, the call's durable identity, so Core code can reach the
      call without naming a Channels module (the meetings precedent);
    * the one-call claim, an atom key every Live session competes for. A unique
      key is taken with one `:ets.insert_new/2`, so of two connections starting
      a call at once exactly one wins, and the other is refused before its
      session exists.

  Both keys belong to the session process and last exactly as long as it does:
  through its settle, so a call still settling counts, and no longer, however it
  ends. A crashed session releases them with no code of its own.
  """

  @claim_key :live_call

  @type registry :: atom()

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    Registry.child_spec(keys: :unique, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Claims the daemon's one call for the calling process and registers its UUID.

  `{:error, :call_in_progress}` while another process holds the claim.
  """
  @spec claim(registry(), String.t()) :: :ok | {:error, :call_in_progress}
  def claim(registry, call_uuid)
      when is_atom(registry) and is_binary(call_uuid) and call_uuid != "" do
    case Registry.register(registry, @claim_key, call_uuid) do
      {:ok, _owner} -> register_call(registry, call_uuid)
      {:error, {:already_registered, _holder}} -> {:error, :call_in_progress}
    end
  end

  # `Registry.lookup/2` still answers with an owner that has exited until the
  # registry has processed its exit, while `Registry.register/3` already treats
  # that owner's key as free. Both reads below skip a dead owner, so they never
  # name a call the claim no longer holds.

  @doc "The call in progress: its UUID and its session, or `:none`."
  @spec active(registry()) :: {:ok, %{call_uuid: String.t(), session: pid()}} | :none
  def active(registry) when is_atom(registry) do
    case live_entry(registry, @claim_key) do
      {session, call_uuid} -> {:ok, %{call_uuid: call_uuid, session: session}}
      nil -> :none
    end
  end

  @doc "The session of the call with this UUID while it is up, or `:none`."
  @spec lookup(registry(), String.t()) :: {:ok, pid()} | :none
  def lookup(registry, call_uuid) when is_atom(registry) and is_binary(call_uuid) do
    case live_entry(registry, call_uuid) do
      {session, _value} -> {:ok, session}
      nil -> :none
    end
  end

  defp live_entry(registry, key) do
    case Registry.lookup(registry, key) do
      [{owner, _value} = entry] -> if Process.alive?(owner), do: entry
      [] -> nil
    end
  end

  # The claim is held, so no other session can hold this key: a UUID already
  # registered is a defect, and the match fails loud.
  defp register_call(registry, call_uuid) do
    {:ok, _owner} = Registry.register(registry, call_uuid, nil)
    :ok
  end
end
