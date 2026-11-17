defmodule FermixTestSupport.PhoneCallFakes do
  @moduledoc """
  Stand-ins for every seam of a phone call's worker (`PhoneCalls.Call`): its
  transport, its delegate and its outcome reader, plus its config,
  credentials and timer seams. None of them can reach a network, a carrier or
  a model, and nothing here reads a real key.

  The test that uses them registers itself as the sink (`register_sink!/0`)
  and starts the script (`script_spec/0` under `start_supervised!/1`), so its
  module must be `async: false`. Every fake tells the sink what it was asked,
  in the worker's or the worker's task's own process:

    * `{:create, task, request}` — the one create. The task waits for the
      test's answer, `answer(task, result)`, unless `:create` is scripted
      `{:result, result}` or `:crash`.
    * `{:attach, sideband, session_id, api_key}` — a fake sideband process,
      linked to the worker. The test speaks for it by sending the worker
      `{:phone_sideband, sideband, payload}`. Sent `:close` by the worker
      (`{:closed_by_worker, sideband}`), it answers `{:closed, :local_close}`
      and exits normally; sent `{:exit, reason}`, it exits with `reason` and
      says nothing; it ends with its owner.
    * `{:sideband_stopped, sideband}`, `{:dtmf, key, event_id}`,
      `{:said, delegation_id, text}`.
    * `{:hangup, task, session_id}` — answered `{:ok, :accepted}` at once
      unless `:hangup` is scripted `:wait` (then `answer/2`) or
      `{:result, result}`.
    * `{:delegate_run, request}`, and `{:delegate_cancel, call_id, id}` then
      `{:delegate_cancel_from, pid}`, the stop answered `:ok` at once unless
      `:delegate_cancel` is scripted `:wait`. A turn's stop and a hangup are
      also logged in the order they happened (`recorded/0`).
    * `Ledger` is the real ledger unless a write is scripted
      `{:ledger, name}` (`{:ledger, {:consume, counter}}` for one counter)
      to `{:result, result}`.
    * `{:extract, entries, facts, opts}` — answered at once with the
      scripted `:extract` outcome (`{:result, %Outcome{}}`, default an
      unknown one) unless scripted `:wait`.
    * `{:scheduled, message, ms}` from `schedule/2`; the test delivers an
      expiry by sending `message` to the worker.
    * `readiness/1` decides through the real `Readiness.decide/1` over a
      host where everything is set up but what the worker hands it, unless
      `:readiness` is scripted to a status.

  A fake that waits for an answer gives up after `@answer_timeout_ms`, so a
  test that never answers cannot hang one.
  """

  alias FermixCore.PhoneCalls.Config
  alias FermixCore.PhoneCalls.Readiness

  @sink :phone_call_fakes_sink
  @script FermixTestSupport.PhoneCallFakes.Script
  @answer_timeout_ms 10_000
  @caller "+14155550142"
  # Everything readiness reads beside the section and the backend, set up.
  @ready_host %{
    openai_api_key?: true,
    openai_api_key_unsendable?: false,
    sip_password?: true,
    primary?: true,
    durable_memory?: true,
    control_route?: true
  }

  @doc "Registers the calling test as the sink every fake reports to."
  @spec register_sink!() :: true
  def register_sink!, do: Process.register(self(), @sink)

  @doc "The script's child spec, for `start_supervised!/1`."
  @spec script_spec() :: Supervisor.child_spec()
  def script_spec do
    %{id: @script, start: {Agent, :start_link, [fn -> %{} end, [name: @script]]}}
  end

  @doc "Scripts how a fake answers `key`."
  @spec script(term(), term()) :: :ok
  def script(key, value), do: Agent.update(@script, &Map.put(&1, key, value))

  @doc "What `key` is scripted to, or `default`."
  @spec scripted(atom(), term()) :: term()
  def scripted(key, default), do: Agent.get(@script, &Map.get(&1, key, default))

  @doc "Answers a fake that waits (a create, a hangup or an extraction)."
  @spec answer(pid(), term()) :: term()
  def answer(task, result) when is_pid(task), do: send(task, {:fake_answer, result})

  @doc "The caller number every fixture brief calls from."
  @spec caller() :: String.t()
  def caller, do: @caller

  @doc "A phone-call section that is on and set up, with invented values."
  @spec config() :: Config.t()
  def config do
    %Config{
      enabled: true,
      voice: "marin",
      caller_number: @caller,
      sip_username: "fermixtrunk01",
      sip_password: "invented-trunk-secret"
    }
  end

  @doc "Invented credentials, resolved as the worker's seam is."
  @spec credentials(Config.t()) :: {:ok, map()}
  def credentials(%Config{}) do
    {:ok,
     %{
       api_key: "sk-invented-phone-key",
       sip_username: "fermixtrunk01",
       sip_password: "invented-trunk-secret"
     }}
  end

  @doc """
  The readiness seam: the real decision over `inputs` (the worker's
  `:config` and `:call_backend?`) on a host where everything else is set up,
  or the status `:readiness` is scripted to.
  """
  @spec readiness(keyword()) :: Readiness.status()
  def readiness(inputs) when is_list(inputs) do
    case scripted(:readiness, :decide) do
      :decide -> @ready_host |> Map.merge(Map.new(inputs)) |> Readiness.decide()
      status -> status
    end
  end

  @doc "The timer seam: tells the sink and arms nothing."
  @spec schedule(term(), non_neg_integer()) :: reference()
  def schedule(message, ms) do
    notify({:scheduled, message, ms})
    make_ref()
  end

  @doc """
  The worker's seams over these fakes; `clock` is an `:atomics` counter the
  test moves for the monotonic clock.
  """
  @spec seams(:atomics.atomics_ref()) :: map()
  def seams(clock) do
    %{
      transport: __MODULE__.Transport,
      delegate: __MODULE__.Delegate,
      outcome: __MODULE__.Outcome,
      ledger: __MODULE__.Ledger,
      readiness: &readiness/1,
      config: &config/0,
      credentials: &credentials/1,
      schedule: &schedule/2,
      monotonic: fn -> :atomics.get(clock, 1) end
    }
  end

  @doc false
  def notify(message) do
    send(@sink, message)
    :ok
  end

  @doc """
  Appends `step` to the script's ordered log: one synchronous call, so steps
  taken by different processes keep the order they happened in.
  """
  @spec record(term()) :: :ok
  def record(step),
    do: Agent.update(@script, &Map.update(&1, :log, [step], fn log -> log ++ [step] end))

  @doc "The steps `record/1` logged, oldest first."
  @spec recorded() :: [term()]
  def recorded, do: scripted(:log, [])

  @doc false
  def await_answer do
    receive do
      {:fake_answer, result} -> result
    after
      @answer_timeout_ms -> {:error, {:unknown, :fake_never_answered}}
    end
  end

  @doc false
  def answered(key, default, report) do
    case scripted(key, default) do
      :wait -> await_answer()
      :crash -> raise "scripted #{key} crash"
      {:result, result} -> result
      {:by, fun} when is_function(fun, 1) -> fun.(report)
      {:sequence, _results} -> next_in_sequence(key)
    end
  end

  # One scripted answer after another, then the last one again.
  defp next_in_sequence(key) do
    Agent.get_and_update(@script, fn script ->
      case Map.fetch!(script, key) do
        {:sequence, [last]} -> {last, script}
        {:sequence, [next | rest]} -> {next, Map.put(script, key, {:sequence, rest})}
      end
    end)
  end

  defmodule Transport do
    @moduledoc false
    @behaviour FermixCore.PhoneCalls.CallTransport

    alias FermixTestSupport.PhoneCallFakes
    alias FermixTestSupport.PhoneCallFakes.Sideband

    @impl true
    def create_session(request, _opts) do
      PhoneCallFakes.notify({:create, self(), request})
      PhoneCallFakes.answered(:create, :wait, request)
    end

    @impl true
    def attach(session_id, %{api_key: api_key}, _opts) do
      case PhoneCallFakes.scripted(:attach, :ok) do
        :ok -> attached(session_id, api_key)
        {:error, reason} -> {:error, reason}
      end
    end

    defp attached(session_id, api_key) do
      sideband = Sideband.start_link(self())
      PhoneCallFakes.notify({:attach, sideband, session_id, api_key})
      {:ok, sideband}
    end

    @impl true
    def attach_deadline_ms, do: 10_000

    @impl true
    def send_dtmf(_sideband, key) do
      event_id = "evt_dtmf_#{System.unique_integer([:positive])}"
      PhoneCallFakes.notify({:dtmf, key, event_id})

      case PhoneCallFakes.scripted(:dtmf, :ok) do
        :ok -> {:ok, event_id}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def send_commentary(_sideband, delegation_id, text) do
      PhoneCallFakes.notify({:said, delegation_id, text})
      {:ok, "evt_said_#{System.unique_integer([:positive])}"}
    end

    @impl true
    def close(sideband) do
      PhoneCallFakes.notify({:closed_by_worker, sideband})
      send(sideband, :close)
      :ok
    end

    @impl true
    def stop(sideband) do
      PhoneCallFakes.notify({:sideband_stopped, sideband})
      Process.unlink(sideband)
      Process.exit(sideband, :kill)
      :ok
    end

    @impl true
    def hangup(session_id, _api_key, _opts) do
      PhoneCallFakes.record({:hangup, session_id})
      PhoneCallFakes.notify({:hangup, self(), session_id})
      PhoneCallFakes.answered(:hangup, {:result, {:ok, :accepted}}, session_id)
    end
  end

  defmodule Sideband do
    @moduledoc false

    @doc false
    def start_link(owner) when is_pid(owner) do
      spawn_link(fn -> loop(owner, Process.monitor(owner)) end)
    end

    defp loop(owner, monitor) do
      receive do
        :close -> send(owner, {:phone_sideband, self(), {:closed, :local_close}})
        {:exit, reason} -> exit(reason)
        {:DOWN, ^monitor, :process, ^owner, _reason} -> :ok
      end
    end
  end

  defmodule Delegate do
    @moduledoc false
    @behaviour FermixCore.PhoneCalls.Delegate

    alias FermixTestSupport.PhoneCallFakes

    @impl true
    def run(request) do
      PhoneCallFakes.notify({:delegate_run, request})
      PhoneCallFakes.scripted(:delegate_run, :ok)
    end

    @impl true
    def cancel(call_id, delegation_id) do
      PhoneCallFakes.record({:delegate_cancel, delegation_id})
      PhoneCallFakes.notify({:delegate_cancel, call_id, delegation_id})
      PhoneCallFakes.notify({:delegate_cancel_from, self()})
      PhoneCallFakes.answered(:delegate_cancel, {:result, :ok}, delegation_id)
    end
  end

  defmodule Ledger do
    @moduledoc false
    # The real ledger, unless a write is scripted `{:ledger, name}` to answer
    # something else (a timeout, say) without touching the row.

    alias FermixTestSupport.PhoneCallFakes

    @real FermixCore.PhoneCalls.Ledger

    def claim_dispatch(id, now, opts), do: through(:claim_dispatch, [id, now, opts])

    def record_session(id, session, now, opts),
      do: through(:record_session, [id, session, now, opts])

    def advance(id, step, now, opts), do: through(:advance, [id, step, now, opts])
    def consume(id, counter, opts), do: through({:consume, counter}, [id, counter, opts])

    def record_usage(id, usage, seconds, opts),
      do: through(:record_usage, [id, usage, seconds, opts])

    def record_closure(id, closure, opts), do: through(:record_closure, [id, closure, opts])

    defp through(name, args) do
      case PhoneCallFakes.scripted({:ledger, name}, :real) do
        :real -> apply(@real, real_name(name), args)
        {:result, result} -> result
      end
    end

    defp real_name({:consume, _counter}), do: :consume
    defp real_name(name), do: name
  end

  defmodule Outcome do
    @moduledoc false

    alias FermixCore.PhoneCalls.Outcome, as: Real
    alias FermixTestSupport.PhoneCallFakes

    def extract(_brief, entries, facts, opts) do
      PhoneCallFakes.notify({:extract, entries, facts, opts})
      PhoneCallFakes.answered(:extract, {:result, {:ok, %Real{}}}, facts)
    end

    defdelegate to_report(outcome), to: Real
  end
end
