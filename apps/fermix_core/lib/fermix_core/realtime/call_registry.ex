defmodule FermixCore.Realtime.CallRegistry do
  @moduledoc """
  Where the task-engine call in progress is found (M56 §4.2).

  One unique-key `Registry` under `Realtime.Supervisor`, started before any
  session. A `LiveSessionServer` or `GrokSessionServer` registers in it from
  `init/1`, under two keys:

    * its `call_uuid`, the call's durable identity, so Core code can reach the
      call without naming a Channels module (the meetings precedent);
    * the claim, an atom key naming the call's chat context.

  Admission is not decided here: every engine session first takes the home's
  one `CallLease`, so only the session holding it ever claims, and a claim that
  is already held is a defect that fails loud.

  Both keys belong to the session process and last exactly as long as it does:
  through its settle, and no longer, however it ends. A crashed session
  releases them with no code of its own.

  The claim carries what a reader of the call in progress needs without asking
  the session: its UUID, its `conversation` (`"chat"` or `"private"`, M56 §5),
  so a private call is never taken for the chat's, and when it started.
  """

  @claim_key :live_call

  @type registry :: atom()

  @typedoc "What a claim holds: the call's identity, its conversation and its start."
  @type call :: %{
          call_uuid: String.t(),
          conversation: String.t(),
          started_at: DateTime.t()
        }

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    Registry.child_spec(keys: :unique, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Claims the call in progress for the calling process and registers its UUID.

  The caller holds the home's `CallLease`, so no other process holds the
  claim: one that does is a defect, and the match fails loud.
  """
  @spec claim(registry(), call()) :: :ok
  def claim(
        registry,
        %{call_uuid: call_uuid, conversation: conversation, started_at: %DateTime{}} = call
      )
      when is_atom(registry) and is_binary(call_uuid) and call_uuid != "" and
             conversation in ["chat", "private"] do
    {:ok, _owner} = Registry.register(registry, @claim_key, call)
    register_call(registry, call_uuid)
  end

  # `Registry.lookup/2` still answers with an owner that has exited until the
  # registry has processed its exit, while `Registry.register/3` already treats
  # that owner's key as free. Both reads below skip a dead owner, so they never
  # name a call the claim no longer holds.

  @doc """
  The call in progress, its claim and its session, or `:none`. With voice off
  no registry runs (`Realtime.Supervisor` is not started), and no call is in
  progress either: Channels asks on every typed chat turn (M56 §4.3).
  """
  @spec active(registry()) ::
          {:ok,
           %{
             call_uuid: String.t(),
             conversation: String.t(),
             started_at: DateTime.t(),
             session: pid()
           }}
          | :none
  def active(registry) when is_atom(registry) do
    with pid when is_pid(pid) <- Process.whereis(registry),
         {session, call} <- live_entry(registry, @claim_key) do
      {:ok, Map.put(call, :session, session)}
    else
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
