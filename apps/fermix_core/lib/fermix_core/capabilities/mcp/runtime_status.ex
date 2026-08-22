defmodule FermixCore.Capabilities.MCP.RuntimeStatus do
  @moduledoc """
  Live, in-memory status for outbound MCP clients, keyed by the
  source-qualified identity `{:plugin, "eden"}` / `{:operator, "fs"}`
  (M27 §7.8).

  This process is deliberately **outside** every per-server subtree. A remote
  subtree is `:temporary`: when it gives up it disappears, and a status table
  living inside it would disappear with the only explanation the operator has.
  Here the terminal entry survives the subtree and stays visible until an
  explicit reconnect/reload installs a new owner. Nothing here is ever
  persisted as user configuration — a daemon restart starts over at
  `:connecting`, which is the truth after a restart.

  ## Generations

  Each start atomically installs a fresh opaque `generation_ref`, the owner
  pid, and a monitor for that source. Every write, `:DOWN`, waiter, and
  stop/restart acknowledgement carries that generation. A delayed event from a
  **replaced** owner cannot overwrite the replacement's status and cannot
  satisfy the replacement's waiter: credential rotation replaces the owner
  while the old one may still be mid-`initialize`, and a late `:ready` from the
  PAT that was just revoked is precisely the lie this guards against.

  Only the *current* monitor's unclassified `:DOWN` becomes
  `:remote_unreachable`. A classified terminal status the owner wrote before
  dying is the diagnosis; the death that follows it is a consequence, not a
  second, vaguer explanation.

  ## Why `detail` is an atom, and what `subject` may hold

  A crash reason can carry the crashing process's state, and a remote session's
  state holds a bearer credential. `put/6` therefore accepts only an atom
  class, so no reason term — however it was constructed — can reach a status a
  UI renders. Callers classify with `classify/1` first.

  `subject` is the one string this table holds, and it exists because the class
  alone cannot answer the only question a contract refusal raises: WHICH
  capability. One rule, no exceptions: it is a **capability name**, and it is
  set only where this build already holds one. Two producers qualify. Every kind
  in `@subject_kinds` is raised by `Contract.verify_one/2`, which reaches
  `Map.fetch!(contract.tools, name)` before any of them can fire, so the name is
  a key of the operator's own signed manifest. `Naming.reserve/3` refuses a
  collision with the name it was asked to reserve — a name this daemon already
  advertises as a tool. Neither can be a credential or a process state, which is
  what the atom rule above exists to keep out, and no crash term has either
  shape, so every unrecognized reason falls to the catch-all with a `nil`
  subject. `@subject_max_chars` bounds whatever arrives as defence-in-depth.

  A caller rendering an arbitrary reason must NOT hand it to `describe/1` on
  shape alone — gate on `statuses/0` membership first, or a peer-authored
  3-tuple renders in the capability slot.
  """

  use GenServer

  alias FermixCore.Capabilities.MCP.Telemetry

  @statuses [
    :needs_secret,
    :needs_workspace,
    :insufficient_credential_scope,
    :invalid_remote_config,
    :connecting,
    :ready,
    :remote_unreachable,
    :reauthorization_required,
    :upstream_contract_mismatch,
    :capability_conflict,
    :remote_security_blocked,
    :remote_protocol_error
  ]

  # The two non-terminal statuses: everything else is an end state that stays
  # visible until an explicit reconnect replaces it.
  @live [:connecting, :ready]

  @type source_id :: {atom(), String.t()}
  @type generation :: reference()
  @type status :: atom()

  @type entry :: %{
          status: status(),
          detail: atom() | nil,
          subject: subject(),
          generation: generation(),
          owner: pid() | nil,
          plugin: String.t() | nil,
          updated_at: integer()
        }

  @typedoc "The capability a refusal names, when it names one."
  @type subject :: String.t() | nil

  @typedoc "A status, its class, and the capability it names."
  @type classified :: {status(), atom() | nil, subject()}

  @typedoc "One element of a classified refusal, as an atom or as the wire's string."
  @type rendered :: atom() | String.t() | nil

  # Every refusal kind whose payload is a manifest key. The companion test
  # derives this set from the constructing sources rather than trusting the
  # list: `:schema_too_large` was missed here precisely because it is built
  # indirectly (`bound_schema/2` wraps whatever `walk_schema/3` returns), so a
  # grep for literal tuples does not find it.
  @subject_kinds [
    :descriptor_changed,
    :duplicate_name,
    :duplicate_tool,
    :invalid_schema,
    :missing_tool,
    :name_outside_namespace,
    :schema_too_deep,
    :schema_too_large,
    :skill_name_collision,
    :uncanonicalizable
  ]

  # Bounded in CHARACTERS, not bytes: a byte bound can split a multi-byte
  # grapheme, and the invalid UTF-8 that produces would make `Jason` refuse the
  # whole `plugins_runtime_status` reply — a truncation rule that breaks the one
  # report explaining the truncated thing.
  @subject_max_chars 128

  @type opt :: {:name, GenServer.name()}

  @doc "Every refusal kind whose payload this table will name (see the moduledoc)."
  @spec subject_kinds() :: [atom()]
  def subject_kinds, do: @subject_kinds

  @doc "Every status this table can hold."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "True for an end state — anything that is not `:connecting` or `:ready`."
  @spec terminal?(status()) :: boolean()
  def terminal?(status) when is_atom(status), do: status not in @live

  @spec start_link([opt()]) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Install a fresh generation, owner, and monitor for `source_id` and start it
  at `:connecting`. Any previous generation is retired: its waiters are
  released with `{:error, {:generation_replaced, source_id}}` and its monitor
  is dropped, so its late events can no longer be observed.
  """
  @spec register_owner(GenServer.server(), source_id(), pid(), keyword()) :: {:ok, generation()}
  def register_owner(server, {kind, name} = source_id, owner, opts \\ [])
      when is_atom(kind) and is_binary(name) and is_pid(owner) and is_list(opts) do
    GenServer.call(server, {:register_owner, source_id, owner, Keyword.get(opts, :plugin)})
  end

  @doc """
  Write a status for `source_id`, but only if `generation` is still the current
  one. A stale generation returns `{:error, :stale_generation}` and changes
  nothing.
  """
  @spec put(GenServer.server(), source_id(), generation(), status(), atom() | nil, subject()) ::
          :ok | {:error, :stale_generation}
  def put(server, {kind, name} = source_id, generation, status, detail \\ nil, subject \\ nil)
      when is_atom(kind) and is_binary(name) and is_reference(generation) and
             status in @statuses and is_atom(detail) and
             (is_nil(subject) or is_binary(subject)) do
    GenServer.call(server, {:put, source_id, generation, status, detail, bounded(subject)})
  end

  # The guard admits any binary so a caller cannot crash the daemon by passing a
  # long one; the bound is applied here, once, on the way in.
  defp bounded(nil), do: nil
  defp bounded(subject), do: String.slice(subject, 0, @subject_max_chars)

  @spec fetch(GenServer.server(), source_id()) :: {:ok, entry()} | :error
  def fetch(server, {kind, name} = source_id) when is_atom(kind) and is_binary(name) do
    GenServer.call(server, {:fetch, source_id})
  end

  @doc "The current owner pid and generation, or `:error` when none is installed."
  @spec owner(GenServer.server(), source_id()) :: {:ok, pid(), generation()} | :error
  def owner(server, {kind, name} = source_id) when is_atom(kind) and is_binary(name) do
    GenServer.call(server, {:owner, source_id})
  end

  @spec list(GenServer.server()) :: %{source_id() => entry()}
  def list(server), do: GenServer.call(server, :list)

  @doc """
  Drop the entry for `source_id` (the disable path) and release its waiters.
  """
  @spec clear(GenServer.server(), source_id()) :: :ok
  def clear(server, {kind, name} = source_id) when is_atom(kind) and is_binary(name) do
    GenServer.call(server, {:clear, source_id})
  end

  @doc """
  Wait for **this** generation to reach `:ready` or a terminal status.

  A `:ready` written by a generation that has since been replaced never
  satisfies this call; the replacement's own outcome does. Waiting for a
  generation that is already gone fails immediately rather than hanging.
  """
  @spec await(GenServer.server(), source_id(), generation(), pos_integer()) ::
          {:ok, :ready} | {:error, term()}
  def await(server, {kind, name} = source_id, generation, timeout_ms)
      when is_atom(kind) and is_binary(name) and is_reference(generation) and
             is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(server, {:await, source_id, generation, timeout_ms}, timeout_ms + 5_000)
  end

  @doc """
  Map a remote-rail failure reason onto `{status, detail, subject}` — the single
  resolver every operator surface reads (the terminal log line, this table, the
  daemon wire, `fermix doctor`, and the setup UI).

  Status and detail are atoms by construction (see the moduledoc): a reason's
  payload can embed the endpoint, a credential, or a whole process state, so
  only its class survives. `subject` is the one exception and it is populated
  for `@subject_kinds` alone. This is the runtime-status half of the §7.9
  classifier; the tool-result half lives with the call proxy.
  """
  @spec classify(term()) :: classified()
  def classify({:needs_secret, _plugin}), do: {:needs_secret, nil, nil}
  def classify({:needs_workspace, _plugin}), do: {:needs_workspace, nil, nil}

  def classify({:insufficient_credential_scope, _detail}),
    do: {:insufficient_credential_scope, nil, nil}

  def classify({:invalid_remote_config, detail}), do: {:invalid_remote_config, class(detail), nil}
  def classify({:reauthorization_required, _host}), do: {:reauthorization_required, nil, nil}

  def classify({:remote_security_blocked, detail}),
    do: {:remote_security_blocked, class(detail), nil}

  def classify({:remote_protocol_error, detail}), do: {:remote_protocol_error, class(detail), nil}
  def classify({:invalid_remote_result, detail}), do: {:remote_protocol_error, class(detail), nil}
  def classify(:session_expired), do: {:remote_protocol_error, :session_expired, nil}

  def classify({:upstream_contract_mismatch, detail}),
    do: {:upstream_contract_mismatch, class(detail), subject(detail)}

  # `Naming.reserve/3` refuses with the bare name it was asked to reserve, so a
  # conflict may carry no kind at all.
  def classify({:capability_conflict, name}) when is_binary(name),
    do: {:capability_conflict, nil, name}

  def classify({:capability_conflict, detail}),
    do: {:capability_conflict, class(detail), subject(detail)}

  def classify({:remote_jsonrpc_error, _code, _message}),
    do: {:remote_protocol_error, :jsonrpc_error, nil}

  def classify({:remote_http_error, _status}), do: {:remote_unreachable, :http_error, nil}
  def classify({:rate_limited, _ms}), do: {:remote_unreachable, :rate_limited, nil}

  # Everything the transport could not deliver — DNS, TLS, connect, timeout,
  # a closed socket — is unreachability. The class stays visible so an
  # unrecognized reason is never mistaken for a diagnosed one.
  def classify(reason), do: {:remote_unreachable, class(reason), nil}

  @doc """
  Render a classified refusal as the one sentence fragment every operator
  surface shows. Single renderer on purpose: the log line, `fermix doctor`, and
  the setup UI disagreeing about the same refusal is how an operator ends up
  probing a vendor for a fact the daemon already held.

  The daemon serializes the same triple to JSON, so each element arrives here as
  either an atom or the string the wire carried; both render identically.
  """
  @spec describe({rendered(), rendered(), rendered()}) :: String.t()
  def describe({status, nil, nil}), do: to_string(status)
  def describe({status, detail, nil}), do: "#{status}/#{detail}"
  def describe({status, nil, subject}), do: "#{status} (#{subject})"
  def describe({status, detail, subject}), do: "#{status}/#{detail} (#{subject})"

  # The ONLY path that puts a manifest key in this table. Deliberately has no
  # bare-binary clause: a `{class, binary}` shape this module does not recognise
  # must yield nil rather than be trusted for its shape alone.
  defp subject({kind, name}) when kind in @subject_kinds and is_binary(name), do: name
  defp subject(_detail), do: nil

  defp class(reason) when is_atom(reason), do: reason

  defp class(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      head when is_atom(head) -> head
      _other -> :unclassified
    end
  end

  defp class(_reason), do: :unclassified

  @impl true
  def init(_opts), do: {:ok, %{entries: %{}, monitors: %{}, waiters: %{}}}

  @impl true
  def handle_call({:register_owner, source_id, owner, plugin}, _from, state) do
    generation = make_ref()

    state =
      state
      |> retire(source_id, {:error, {:generation_replaced, source_id}})
      |> install(source_id, owner, plugin, generation)

    {:reply, {:ok, generation}, state}
  end

  def handle_call({:put, source_id, generation, status, detail, subject}, _from, state) do
    case Map.fetch(state.entries, source_id) do
      {:ok, %{generation: ^generation} = entry} ->
        {:reply, :ok, write(state, source_id, entry, status, detail, subject)}

      _replaced_or_absent ->
        {:reply, {:error, :stale_generation}, state}
    end
  end

  def handle_call({:fetch, source_id}, _from, state) do
    {:reply, Map.fetch(state.entries, source_id), state}
  end

  def handle_call({:owner, source_id}, _from, state) do
    {:reply, current_owner(Map.get(state.entries, source_id)), state}
  end

  def handle_call(:list, _from, state), do: {:reply, state.entries, state}

  def handle_call({:clear, source_id}, _from, state) do
    state = retire(state, source_id, {:error, {:cleared, source_id}})
    {:reply, :ok, %{state | entries: Map.delete(state.entries, source_id)}}
  end

  def handle_call({:await, source_id, generation, timeout_ms}, from, state) do
    case Map.fetch(state.entries, source_id) do
      {:ok, %{generation: ^generation} = entry} ->
        await_entry(state, source_id, entry, from, timeout_ms)

      _replaced_or_absent ->
        {:reply, {:error, {:generation_replaced, source_id}}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}

      {source_id, monitors} ->
        {:noreply, owner_down(%{state | monitors: monitors}, source_id, ref, reason)}
    end
  end

  def handle_info({:waiter_timeout, source_id, waiter_id}, state) do
    {:noreply, drop_waiter(state, source_id, waiter_id, {:error, :timeout})}
  end

  defp install(state, source_id, owner, plugin, generation) do
    ref = Process.monitor(owner)

    entry = %{
      status: :connecting,
      detail: nil,
      subject: nil,
      generation: generation,
      owner: owner,
      monitor: ref,
      plugin: plugin,
      updated_at: System.system_time(:millisecond)
    }

    %{
      state
      | entries: Map.put(state.entries, source_id, entry),
        monitors: Map.put(state.monitors, ref, source_id)
    }
  end

  defp write(state, source_id, entry, status, detail, subject) do
    entry = %{
      entry
      | status: status,
        detail: detail,
        subject: subject,
        updated_at: System.system_time(:millisecond)
    }

    %{state | entries: Map.put(state.entries, source_id, entry)}
    |> settle(source_id, entry)
  end

  # `:connecting` is the one status nobody waits on — it is the state a waiter
  # is waiting to leave.
  defp settle(state, _source_id, %{status: :connecting}), do: state

  defp settle(state, source_id, entry) do
    release_waiters(state, source_id, entry.generation, outcome(entry))
  end

  defp outcome(%{status: :ready}), do: {:ok, :ready}

  defp outcome(%{status: status, detail: detail, subject: subject}),
    do: {:error, {status, detail, subject}}

  defp await_entry(state, source_id, %{status: :connecting} = entry, from, timeout_ms) do
    waiter_id = make_ref()
    timer = Process.send_after(self(), {:waiter_timeout, source_id, waiter_id}, timeout_ms)
    {:noreply, add_waiter(state, source_id, waiter_id, from, entry.generation, timer)}
  end

  defp await_entry(state, _source_id, entry, _from, _timeout_ms) do
    {:reply, outcome(entry), state}
  end

  defp owner_down(state, source_id, ref, reason) do
    case Map.get(state.entries, source_id) do
      %{monitor: ^ref} = entry -> record_down(state, source_id, entry, reason)
      _replaced_or_absent -> state
    end
  end

  # A classified terminal status is the diagnosis the owner already wrote;
  # the death that followed must not overwrite it with a vaguer one.
  defp record_down(state, source_id, entry, reason) do
    {status, detail, subject} =
      if terminal?(entry.status),
        do: {entry.status, entry.detail, entry.subject},
        else: {:remote_unreachable, class(reason), nil}

    Telemetry.emit_lifecycle(
      :owner_down,
      %{source_id: source_id, plugin: entry.plugin},
      {:error, {status, detail}},
      0
    )

    write(state, source_id, %{entry | owner: nil, monitor: nil}, status, detail, subject)
  end

  defp retire(state, source_id, reply) do
    state
    |> demonitor_current(source_id)
    |> release_all_waiters(source_id, reply)
  end

  defp demonitor_current(state, source_id) do
    case Map.get(state.entries, source_id) do
      %{monitor: ref} when is_reference(ref) ->
        Process.demonitor(ref, [:flush])
        %{state | monitors: Map.delete(state.monitors, ref)}

      _none ->
        state
    end
  end

  defp add_waiter(state, source_id, waiter_id, from, generation, timer) do
    waiter = %{id: waiter_id, from: from, generation: generation, timer: timer}
    %{state | waiters: Map.update(state.waiters, source_id, [waiter], &[waiter | &1])}
  end

  defp release_waiters(state, source_id, generation, reply) do
    {matched, rest} =
      state.waiters
      |> Map.get(source_id, [])
      |> Enum.split_with(&(&1.generation == generation))

    Enum.each(matched, &reply_to_waiter(&1, reply))
    %{state | waiters: put_waiters(state.waiters, source_id, rest)}
  end

  defp release_all_waiters(state, source_id, reply) do
    state.waiters
    |> Map.get(source_id, [])
    |> Enum.each(&reply_to_waiter(&1, reply))

    %{state | waiters: Map.delete(state.waiters, source_id)}
  end

  defp drop_waiter(state, source_id, waiter_id, reply) do
    {matched, rest} =
      state.waiters
      |> Map.get(source_id, [])
      |> Enum.split_with(&(&1.id == waiter_id))

    Enum.each(matched, &reply_to_waiter(&1, reply))
    %{state | waiters: put_waiters(state.waiters, source_id, rest)}
  end

  defp put_waiters(waiters, source_id, []), do: Map.delete(waiters, source_id)
  defp put_waiters(waiters, source_id, rest), do: Map.put(waiters, source_id, rest)

  defp reply_to_waiter(waiter, reply) do
    _ = Process.cancel_timer(waiter.timer)
    GenServer.reply(waiter.from, reply)
  end

  defp current_owner(%{owner: owner, generation: generation}) when is_pid(owner),
    do: {:ok, owner, generation}

  defp current_owner(_entry), do: :error
end
