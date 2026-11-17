defmodule FermixCore.PhoneCalls.Call.Timers do
  @moduledoc """
  The timers of one phone call's worker, each by kind, through one injected
  `schedule` function (`(message, ms) -> reference()`), so a test delivers
  any expiry by hand.

  An armed timer is the message `{:phone_call_timer, kind, token}` with a
  fresh token; arming a kind again, disarming it or taking its expiry forgets
  the token, so a late or replaced expiry is stale and does nothing.
  """

  defstruct [:schedule, armed: %{}]

  @type kind :: term()
  @type t :: %__MODULE__{schedule: (term(), non_neg_integer() -> term()), armed: map()}

  @doc "No timer armed yet, scheduling through `schedule`."
  @spec new((term(), non_neg_integer() -> term())) :: t()
  def new(schedule) when is_function(schedule, 2), do: %__MODULE__{schedule: schedule}

  @doc "Arms `kind` for `ms`, replacing any armed one."
  @spec arm(t(), kind(), non_neg_integer()) :: t()
  def arm(%__MODULE__{} = timers, kind, ms) when is_integer(ms) and ms >= 0 do
    timers = disarm(timers, kind)
    token = make_ref()
    ref = timers.schedule.({:phone_call_timer, kind, token}, ms)
    %{timers | armed: Map.put(timers.armed, kind, {token, ref})}
  end

  @doc "Forgets `kind`, cancelling its timer when it is a real one."
  @spec disarm(t(), kind()) :: t()
  def disarm(%__MODULE__{} = timers, kind) do
    case Map.pop(timers.armed, kind) do
      {nil, _armed} -> timers
      {{_token, ref}, armed} -> cancelled(%{timers | armed: armed}, ref)
    end
  end

  @doc "Forgets every kind."
  @spec disarm_all(t()) :: t()
  def disarm_all(%__MODULE__{} = timers),
    do: timers.armed |> Map.keys() |> Enum.reduce(timers, &disarm(&2, &1))

  @doc "`{:fired, timers}` when `token` is `kind`'s armed one (now forgotten), else `:stale`."
  @spec take(t(), kind(), reference()) :: {:fired, t()} | :stale
  def take(%__MODULE__{} = timers, kind, token) do
    case Map.get(timers.armed, kind) do
      {^token, _ref} -> {:fired, %{timers | armed: Map.delete(timers.armed, kind)}}
      _stale -> :stale
    end
  end

  defp cancelled(timers, ref) when is_reference(ref) do
    _remaining = Process.cancel_timer(ref)
    timers
  end

  defp cancelled(timers, _ref), do: timers
end
