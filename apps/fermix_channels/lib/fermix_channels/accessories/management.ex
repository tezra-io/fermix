defmodule FermixChannels.Accessories.Management do
  @moduledoc """
  The provider core's `accessories.*` management methods call by name (M91
  E3; `FermixCore.Management.Accessories`, registered by the channels
  application at `:accessories_management_provider`, since core never
  compiles against channels). Each function is the facade's
  (`FermixChannels.Accessories`) under the name and arity core calls, with
  the facade's options last; core owns every sentence and the wire.

  `status/1` answers whether the subtree runs and, when it does, the
  watcher's view (its ports with their links' own views, the selected port,
  how each accessory's newest call ended). A subtree that does not run is
  `running: false`, never an error: the status answers with accessories off.
  """

  alias FermixChannels.Accessories

  require Logger

  @type facts :: %{running: boolean(), watcher: map() | nil, last_calls: map()}

  @doc "Whether the subtree runs, and its watcher's view when it does."
  @spec status(keyword()) :: {:ok, facts()}
  def status(opts) when is_list(opts) do
    case Accessories.status(opts) do
      {:ok, view} -> {:ok, %{running: true, watcher: view, last_calls: view.last_calls}}
      {:error, :not_running} -> {:ok, idle()}
      {:error, reason} -> {:ok, unanswered(reason)}
    end
  end

  # The facade logged why; the status reads as a link that does not answer.
  defp unanswered(reason) do
    Logger.warning("accessories management: the watcher did not answer: #{inspect(reason)}")
    idle()
  end

  defp idle, do: %{running: false, watcher: nil, last_calls: %{}}

  @doc "Tells `pid` each change of the view; answers the watcher to monitor."
  @spec subscribe(pid(), keyword()) :: {:ok, pid()} | {:error, term()}
  def subscribe(pid, opts), do: Accessories.subscribe(pid, opts)

  @doc "Stops telling `pid`."
  @spec unsubscribe(pid(), keyword()) :: :ok | {:error, term()}
  def unsubscribe(pid, opts), do: Accessories.unsubscribe(pid, opts)

  @doc "Wakes every waiting status."
  @spec touch(keyword()) :: :ok | {:error, term()}
  def touch(opts), do: Accessories.touch(opts)

  @doc "Starts or stops the subtree after the setting moved."
  @spec apply_enabled(boolean(), keyword()) ::
          {:ok, :started | :not_started | :stopped} | {:error, term()}
  def apply_enabled(on?, opts), do: Accessories.switch(on?, opts)

  @spec pair_start(String.t(), keyword()) :: Accessories.result()
  def pair_start(path, opts), do: Accessories.pair(path, opts)

  @spec pair_begin(String.t(), String.t() | nil, keyword()) :: Accessories.result()
  def pair_begin(path, name, opts), do: Accessories.enroll_begin(path, name, opts)

  @spec pair_decide(String.t(), String.t(), boolean(), keyword()) :: Accessories.result()
  def pair_decide(path, attempt, true, opts), do: Accessories.enroll_confirm(path, attempt, opts)

  def pair_decide(path, attempt, false, opts),
    do: Accessories.enroll_mismatch(path, attempt, opts)

  @spec pair_cancel(String.t(), String.t() | nil, keyword()) :: Accessories.result()
  def pair_cancel(path, attempt, opts), do: Accessories.cancel_pairing(path, attempt, opts)

  @spec retry(String.t(), keyword()) :: Accessories.result()
  def retry(path, opts), do: Accessories.retry(path, opts)

  @spec release(String.t(), keyword()) :: Accessories.result()
  def release(path, opts), do: Accessories.release(path, opts)

  @spec reconnect(String.t(), keyword()) :: Accessories.result()
  def reconnect(path, opts), do: Accessories.reconnect(path, opts)

  @doc "Forgets an accessory, and wakes the waiting statuses: its record is gone."
  @spec forget(String.t(), keyword()) :: Accessories.result()
  def forget(accessory_id, opts), do: removed(Accessories.forget(accessory_id, opts), opts)

  @doc "Revokes an accessory at this Mac alone, and wakes the waiting statuses."
  @spec revoke(String.t(), keyword()) :: Accessories.result()
  def revoke(accessory_id, opts), do: removed(Accessories.revoke(accessory_id, opts), opts)

  defp removed(:ok, opts) do
    case Accessories.touch(opts) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("accessories management: no wake: #{inspect(reason)}")
    end

    :ok
  end

  defp removed(refused, _opts), do: refused

  @spec call_start(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def call_start(accessory_id, opts), do: Accessories.start_call(accessory_id, opts)

  @spec call_end(String.t(), String.t(), keyword()) :: Accessories.result()
  def call_end(accessory_id, call_id, opts), do: Accessories.end_call(accessory_id, call_id, opts)

  @spec call_mute(String.t(), String.t(), boolean(), keyword()) :: Accessories.result()
  def call_mute(accessory_id, call_id, muted?, opts),
    do: Accessories.mute(accessory_id, call_id, muted?, opts)

  @spec call_interrupt(String.t(), String.t(), keyword()) :: Accessories.result()
  def call_interrupt(accessory_id, call_id, opts),
    do: Accessories.interrupt(accessory_id, call_id, opts)

  @spec call_task_cancel(String.t(), String.t(), String.t(), keyword()) :: Accessories.result()
  def call_task_cancel(accessory_id, call_id, task, opts),
    do: Accessories.cancel_task(accessory_id, call_id, task, opts)

  @spec check_start(String.t(), atom(), pos_integer() | nil, keyword()) :: Accessories.result()
  def check_start(accessory_id, check, seconds, opts),
    do: Accessories.check_start(accessory_id, check, seconds, opts)

  @spec check_stop(String.t(), keyword()) :: Accessories.result()
  def check_stop(accessory_id, opts), do: Accessories.check_stop(accessory_id, opts)

  @spec calibrate(String.t(), atom(), map() | nil, keyword()) :: Accessories.result()
  def calibrate(accessory_id, op, nudge, opts),
    do: Accessories.calibrate(accessory_id, op, nudge, opts)

  @spec set(String.t(), map(), keyword()) :: Accessories.result()
  def set(accessory_id, values, opts), do: Accessories.set(accessory_id, values, opts)
end
