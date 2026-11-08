defmodule FermixChannels.Accessories do
  @moduledoc """
  The accessories endpoint's internal API (M91 E2): what the management
  layer (E3, `accessories.*`) and the setting's live switch call. Every call
  goes to the running subtree (`FermixChannels.Accessories.Supervisor`) and
  answers `{:error, :not_running}` when it does not run (off, not a Mac, or
  not a primary). `opts` takes `:names` (`Supervisor.names/1`) for a test's
  own subtree.

    * **Ports**: `status/1`; `pair/2` opens the selected port for pairing;
      `retry/2` (a busy or failed port), `release/2` (for a firmware update)
      and `reconnect/2`.
    * **Pairing**, on the selected port: `enroll_begin/2`, then
      `enroll_confirm/2` once the owner sees the same code on both screens,
      or `enroll_mismatch/2` or `enroll_cancel/2`.
    * **Accessories**, by ID: `forget/2` (tells an attached accessory to erase
      its keys, and erases its record), `revoke/2` (erases the record only),
      and the Mac's call controls `start_call/2`, `end_call/2`, `mute/3`,
      `interrupt/2`, `cancel_task/3`.
    * **The setting**: `switch/2` starts or stops the subtree after the
      setting moved.
  """

  alias FermixChannels.Accessories.Link
  alias FermixChannels.Accessories.StoreWriter
  alias FermixChannels.Accessories.Supervisor, as: AccessoriesSupervisor
  alias FermixChannels.Accessories.Watcher

  require Logger

  @typedoc """
  Why a call reached no answer: the subtree does not run (off, not a Mac, not
  a primary), it did not answer within the call's bound, or it ended while
  answering. A caller is never taken down by the subtree.
  """
  @type unavailable :: :not_running | :timeout | :accessories_unavailable

  @type result :: :ok | {:error, term()}

  @call_timeout_ms 5_000

  @doc "Every watched port and its state, with the view's update key."
  @spec status(keyword()) :: {:ok, map()} | {:error, unavailable()}
  def status(opts \\ []),
    do: running(fn -> {:ok, Watcher.status(names(opts).watcher, timeout(opts))} end)

  @doc "Opens the port the owner selected, for pairing."
  @spec pair(String.t(), keyword()) :: result()
  def pair(path, opts \\ []) when is_binary(path),
    do: running(fn -> Watcher.pair(names(opts).watcher, path, timeout(opts)) end)

  @doc "Opens a busy or failed port again now."
  @spec retry(String.t(), keyword()) :: result()
  def retry(path, opts \\ []) when is_binary(path),
    do: running(fn -> Watcher.retry(names(opts).watcher, path, timeout(opts)) end)

  @doc "Releases a port for a firmware update, until `reconnect/2`."
  @spec release(String.t(), keyword()) :: result()
  def release(path, opts \\ []) when is_binary(path),
    do: running(fn -> Watcher.release(names(opts).watcher, path, timeout(opts)) end)

  @doc "Watches a released port again."
  @spec reconnect(String.t(), keyword()) :: result()
  def reconnect(path, opts \\ []) when is_binary(path),
    do: running(fn -> Watcher.reconnect(names(opts).watcher, path, timeout(opts)) end)

  @doc "Starts pairing on the selected port."
  @spec enroll_begin(String.t(), keyword()) :: result()
  def enroll_begin(path, opts \\ []), do: on_port(path, opts, &Link.enroll_begin/1)

  @doc "The owner confirmed both screens show the same code."
  @spec enroll_confirm(String.t(), keyword()) :: result()
  def enroll_confirm(path, opts \\ []), do: on_port(path, opts, &Link.enroll_confirm/1)

  @doc "The owner said the codes differ."
  @spec enroll_mismatch(String.t(), keyword()) :: result()
  def enroll_mismatch(path, opts \\ []), do: on_port(path, opts, &Link.enroll_mismatch/1)

  @doc "The owner cancelled the pairing."
  @spec enroll_cancel(String.t(), keyword()) :: result()
  def enroll_cancel(path, opts \\ []), do: on_port(path, opts, &Link.enroll_cancel/1)

  @doc """
  Forgets an accessory: an attached one is told to erase its keys; either way
  its record is erased, and one forgotten while unplugged learns at its next
  attach (`unknown_accessory`).
  """
  @spec forget(String.t(), keyword()) :: result()
  def forget(accessory_id, opts \\ []), do: remove(accessory_id, opts, &Link.forget/1)

  @doc "Revokes an accessory at the daemon alone: its record is erased, its call ends."
  @spec revoke(String.t(), keyword()) :: result()
  def revoke(accessory_id, opts \\ []), do: remove(accessory_id, opts, &Link.revoke/1)

  @doc "Starts a call from the Mac on an attached accessory."
  @spec start_call(String.t(), keyword()) :: {:ok, pos_integer()} | {:error, term()}
  def start_call(accessory_id, opts \\ []),
    do: on_accessory(accessory_id, opts, &Link.start_call/1)

  @doc "Ends an accessory's call from the Mac."
  @spec end_call(String.t(), keyword()) :: result()
  def end_call(accessory_id, opts \\ []), do: on_accessory(accessory_id, opts, &Link.end_call/1)

  @doc "The Mac's mute for an accessory's call."
  @spec mute(String.t(), boolean(), keyword()) :: result()
  def mute(accessory_id, muted?, opts \\ []) when is_boolean(muted?),
    do: on_accessory(accessory_id, opts, &Link.mute(&1, muted?))

  @doc "Interrupts the assistant's speech on an accessory's call."
  @spec interrupt(String.t(), keyword()) :: result()
  def interrupt(accessory_id, opts \\ []), do: on_accessory(accessory_id, opts, &Link.interrupt/1)

  @doc "Cancels one backend task of an accessory's task-engine call."
  @spec cancel_task(String.t(), String.t(), keyword()) :: result()
  def cancel_task(accessory_id, delegation_id, opts \\ []) when is_binary(delegation_id),
    do: on_accessory(accessory_id, opts, &Link.cancel_task(&1, delegation_id))

  @doc "Starts or stops the subtree after the setting moved (`Supervisor.switch/2`)."
  @spec switch(boolean(), keyword()) ::
          {:ok, :started | :not_started | :stopped} | {:error, :not_ready | term()}
  def switch(on?, opts \\ []) when is_boolean(on?), do: AccessoriesSupervisor.switch(on?, opts)

  defp on_port(path, opts, fun) when is_binary(path) do
    running(fn ->
      with {:ok, link} <- Watcher.link_on(names(opts).watcher, path, timeout(opts)),
           do: fun.(link)
    end)
  end

  defp on_accessory(accessory_id, opts, fun) when is_binary(accessory_id) do
    running(fn ->
      with {:ok, link} <- Watcher.link_for(names(opts).watcher, accessory_id, timeout(opts)),
           do: fun.(link)
    end)
  end

  defp remove(accessory_id, opts, fun) when is_binary(accessory_id) do
    names = names(opts)

    running(fn ->
      case Watcher.link_for(names.watcher, accessory_id, timeout(opts)) do
        {:ok, link} -> fun.(link)
        {:error, :not_attached} -> StoreWriter.forget(names.store_writer, accessory_id)
      end
    end)
  end

  defp names(opts), do: AccessoriesSupervisor.names(opts)

  defp timeout(opts) do
    case Keyword.get(opts, :timeout, @call_timeout_ms) do
      ms when is_integer(ms) and ms >= 0 -> ms
      other -> raise ArgumentError, ":timeout must be milliseconds, got #{inspect(other)}"
    end
  end

  # Every exit of a call into the subtree is a named error: one that does not
  # run answers nothing, one that does not answer in time is a timeout, and
  # one that ends while answering is logged with why.
  defp running(fun) do
    fun.()
  catch
    :exit, {reason, {GenServer, :call, _args}} -> call_exit(reason)
    :exit, {reason, {:gen_server, :call, _args}} -> call_exit(reason)
  end

  # A subtree stopping (the setting turned off, the daemon shutting down) is
  # one that no longer runs.
  defp call_exit(reason) when reason in [:noproc, :normal, :shutdown], do: {:error, :not_running}
  defp call_exit({:shutdown, _why}), do: {:error, :not_running}
  defp call_exit(:timeout), do: {:error, :timeout}

  defp call_exit(reason) do
    Logger.warning("accessories: the subtree ended while answering: #{inspect(reason)}")
    {:error, :accessories_unavailable}
  end
end
