defmodule FermixCore.Setup.SecretAclState do
  @moduledoc """
  The last measurement of which stored keys the keychain will not hand over
  without a prompt (M34 native setup §7.3, §15.2).

  The measurement itself costs one `security find-generic-password -w`
  subprocess per stored sentinel, and on the exact population it exists to name
  — items written before the `-A` flag arrived — each read raises the macOS
  allow dialog. That is affordable in Doctor, which the operator started and
  which is allowed to take seconds and to prompt. It is not affordable on
  `setup.state.get`, which every setup surface polls and whose contract is
  "presence only, no shell-outs".

  So the measuring and the publishing are split: `Setup.Coexistence` measures
  and records here, Doctor is the only caller that measures, and
  `setup.state.get` publishes what was last recorded. Until a Doctor run has
  happened this process holds nothing and the answer is `present: nil` — "not
  measured", which is a different fact from "measured, nothing restricted" and
  is published as a different value rather than guessed.

  Reads and records answer truthfully with no server running: a tree-less verb
  has measured nothing through this process. That is two declared
  configurations of one read, not a fallback — the measurement itself always
  happens, only the record is skipped.
  """

  use GenServer

  @type measurement :: %{present: boolean() | nil, keys: [String.t()]}

  @unmeasured %{present: nil, keys: []}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The measurement this VM last recorded, or `present: nil` when none has."
  @spec last(keyword()) :: measurement()
  def last(opts \\ []) when is_list(opts), do: call(opts, :last, @unmeasured)

  @doc "Records one measurement, replacing the previous one."
  @spec record(measurement(), keyword()) :: :ok
  def record(%{present: present, keys: keys} = measurement, opts \\ [])
      when is_boolean(present) and is_list(keys) and is_list(opts) do
    call(opts, {:record, measurement}, :ok)
  end

  @doc "The answer published before any measurement has been recorded."
  @spec unmeasured() :: measurement()
  def unmeasured, do: @unmeasured

  @impl true
  def init(_opts), do: {:ok, %{measurement: @unmeasured}}

  @impl true
  def handle_call(:last, _from, state), do: {:reply, state.measurement, state}

  def handle_call({:record, measurement}, _from, state),
    do: {:reply, :ok, %{state | measurement: measurement}}

  defp call(opts, message, absent_answer) do
    case Process.whereis(Keyword.get(opts, :secret_acl_state, __MODULE__)) do
      nil -> absent_answer
      pid -> GenServer.call(pid, message)
    end
  catch
    :exit, {:noproc, _call} -> absent_answer
  end
end
