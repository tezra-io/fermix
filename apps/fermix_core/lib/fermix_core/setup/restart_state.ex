defmodule FermixCore.Setup.RestartState do
  @moduledoc """
  The one source of restart truth for both setup doors (M34 native setup §7.5).

  **Two named baselines, not one**, because the two comparisons this module
  serves need different operands:

    * `booted_live` — the `persistable_snapshot` of application environment
      captured once at boot and never updated. It is the operand for
      `restart/0`, and the boot-bound comparison never reads the file.
    * `persisted_baseline` — the `persistable_snapshot` of the parsed
      `config.toml` (or of `empty_runtime_config/0` when no file exists). It is
      the operand for `config_state/0`, and the external-change comparison never
      reads application environment.

  One value cannot serve both. `ConfigStore.current_snapshot/0` is live env and
  carries the compiled `telegram: [enabled: true]` default, while a parsed file
  with no telegram block carries `telegram: []`. With the parsed document as the
  only baseline every fresh install reports a phantom `channels` restart reason;
  with live env as the only baseline every fresh install reports
  `external_change`.

  **`persisted_baseline` has three writers**, and the third is what makes the
  refusal escapable: it is recorded at boot, replaced on every successful save
  by this VM, and replaced again on every successful reload. Without the third,
  the one action offered to clear an external change would leave the baseline
  where it was and the refusal would stand until a daemon restart.

  A boot-bound **secret** replaced since boot is the fourth input, and it is the
  one the two baselines cannot see: a rotation writes the same `@keyring`
  sentinel over the same sentinel, so both operands are unchanged. It is read
  from `Setup.SecretWriteLog`, the one path every secret write takes.

  **The boot baseline resets by restarting.** `lifecycle.commit` runs the
  daemon's shutdown path, so this process dies with the VM and `init/1`
  re-captures live env as `booted_live`; there is no separate reset call,
  because a reset that did not also restart the daemon would report "no restart
  needed" for changes that had still not taken effect.

  Reads are cached for one second: the external-change comparison is a full
  parse plus normalization, and `overview.get` and `/health` are polled.
  Sentinels are never resolved, so a read costs no `security` subprocess.
  """

  use GenServer

  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.SecretPaths
  alias FermixCore.Setup.SecretWriteLog

  require Logger

  @cache_ttl_ms 1_000

  # Sections whose values are read at boot and cannot take effect until the
  # daemon restarts. Each carries the sentence the daemon publishes for it: the
  # app renders these verbatim and never composes its own.
  @boot_bound [
    {:providers, "Provider settings changed since Fermix started."},
    {:routing, "Model routing changed since Fermix started."},
    {:realtime, "Voice settings changed since Fermix started."},
    {:channels, "Channel settings changed since Fermix started."},
    {:acp, "The coding agent connection changed since Fermix started."},
    {:sandbox, "Sandbox settings changed since Fermix started."},
    {:harness, "Coding agent settings changed since Fermix started."},
    {:skill_curation, "Skill curation settings changed since Fermix started."},
    {:meetings, "Meeting settings changed since Fermix started."},
    {:computer_use, "Computer control settings changed since Fermix started."},
    {:computer_history, "Computer history settings changed since Fermix started."}
  ]
  @wrong_shape_sentence "The settings file could not be read: a value in it is not the shape Fermix expects."
  @external_change_section "settings_file"
  @external_change_sentence "The settings file changed outside Fermix."

  @type config_state ::
          :clear | {:external_change, [String.t()]} | {:config_unreadable, String.t()}
  @type reason :: %{section: String.t(), sentence: String.t()}
  @type restart :: %{required: boolean(), reasons: [reason()]}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Every boot-bound section, with the sentence published when it changed."
  @spec boot_bound_sections() :: [{atom(), String.t()}]
  def boot_bound_sections, do: @boot_bound

  @doc """
  Whether a restart is needed, and the daemon's own sentence for every reason.

  Answered `%{required: false, reasons: []}` when no server is running: a
  tree-less verb has read nothing and started nothing, which is the truthful
  answer rather than a guess. That is two declared configurations of one read,
  not a fallback chain.
  """
  @spec restart(keyword()) :: restart()
  def restart(opts \\ []) when is_list(opts) do
    call(opts, :restart, %{required: false, reasons: []})
  end

  @doc """
  The persisted file's relationship to the baseline this VM recorded.

  `:clear` when the file parses and equals the baseline, or when no file exists.
  `{:external_change, sections}` when it parses and differs — the one state that
  refuses writes. `{:config_unreadable, sentence}` when the read or the parse
  failed, carrying the parser's own sentence.
  """
  @spec config_state(keyword()) :: config_state()
  def config_state(opts \\ []) when is_list(opts), do: call(opts, :config_state, :clear)

  @doc """
  Whether a write of the whole document may go ahead, and why not when it may not.

  The one predicate both write tails consult. A write persists the whole
  document, so it would revert anything written to `config.toml` outside this
  VM; it refuses while an outside change stands and names the sections that
  changed. An unreadable file refuses with the parser's own sentence, never with
  a reload the operator cannot escape.
  """
  @spec writable(keyword()) ::
          :ok | {:error, {:external_change, [String.t()]} | {:config_unreadable, String.t()}}
  def writable(opts \\ []) when is_list(opts) do
    case config_state(opts) do
      :clear -> :ok
      {:external_change, sections} -> {:error, {:external_change, sections}}
      {:config_unreadable, sentence} -> {:error, {:config_unreadable, sentence}}
    end
  end

  @doc "The path of the previous config file, when one was kept beside the current one."
  @spec previous_config_path() :: String.t() | nil
  def previous_config_path do
    path = ConfigStore.path() <> ".previous"
    if File.regular?(path), do: path, else: nil
  end

  @doc """
  Re-reads the persisted file and records it as the baseline.

  Called after every successful write by this VM and after every successful
  reload, so the external-change state clears exactly when the file and this
  VM's idea of it agree again. It re-reads rather than recording the snapshot
  the caller held, because the file is written through the secret securer: a
  snapshot carrying a plaintext value is persisted as the keyring sentinel, and
  recording the caller's copy would make the very next read report a change this
  VM had just made itself.
  """
  @spec record_persisted_baseline(keyword()) :: :ok
  def record_persisted_baseline(opts \\ []) when is_list(opts) do
    call(opts, :record_persisted_baseline, :ok)
  end

  @doc """
  Loads the persisted config, distinguishing unreadable from absent.

  `load_runtime_config/1` raises rather than returns for a poisoned file, in
  three named classes and no others: the normalizers raise `ArgumentError`, the
  legacy provider layout raises a bare `RuntimeError`, and a value of the wrong
  *shape* reaches a function clause that does not match. Only those three are
  rescued. A `KeyError` or a `Protocol.UndefinedError` out of the same call is a
  defect in the parser, not a statement about the operator's file, and it
  propagates and fails loud rather than being reported as "the settings file
  could not be read".

  The first two carry the parser's own operator sentence and it is published
  verbatim. A `FunctionClauseError` message names an internal function
  ("no function clause matching in ...validate_provider_section_keys!/2"), which
  is not copy: it is logged and the published sentence is the daemon's own.
  Nothing is swallowed on any path.
  """
  @spec load_persisted() :: {:ok, map()} | {:error, String.t()}
  def load_persisted do
    case ConfigStore.load_runtime_config(resolve_secrets: false) do
      {:ok, persisted} -> {:ok, persisted}
      {:error, reason} -> {:error, read_sentence(reason)}
    end
  rescue
    exception in [ArgumentError, RuntimeError] ->
      {:error, logged_parse_failure(exception, Exception.message(exception))}

    exception in [FunctionClauseError] ->
      {:error, logged_parse_failure(exception, @wrong_shape_sentence)}
  end

  defp logged_parse_failure(exception, sentence) do
    Logger.warning(
      "settings file could not be parsed (#{inspect(exception.__struct__)}): " <>
        Exception.message(exception)
    )

    sentence
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       booted_live: ConfigStore.current_snapshot(),
       booted_at_ms: System.monotonic_time(:millisecond),
       write_log: Keyword.get(opts, :write_log, SecretWriteLog),
       baseline_path: ConfigStore.path(),
       persisted_baseline: initial_baseline(opts),
       cache_ttl_ms: Keyword.get(opts, :cache_ttl_ms, @cache_ttl_ms),
       cache: nil
     }}
  end

  @impl true
  def handle_call(:restart, _from, state) do
    {answer, state} = refresh(state)
    {:reply, %{required: answer.required, reasons: answer.reasons}, state}
  end

  def handle_call(:config_state, _from, state) do
    {answer, state} = refresh(state)
    {:reply, answer.config_state, state}
  end

  def handle_call(:record_persisted_baseline, _from, state) do
    {:reply, :ok, record(state)}
  end

  defp record(state) do
    %{
      state
      | baseline_path: ConfigStore.path(),
        persisted_baseline: baseline_or_nil(),
        cache: nil
    }
  end

  defp initial_baseline(opts) do
    case Keyword.fetch(opts, :persisted_baseline) do
      {:ok, baseline} when is_map(baseline) -> ConfigStore.persistable_snapshot(baseline)
      :error -> baseline_or_nil()
    end
  end

  defp baseline_or_nil do
    case load_persisted() do
      {:ok, persisted} -> ConfigStore.persistable_snapshot(persisted)
      # A file this VM cannot parse has no baseline to compare against. The
      # state that reports it is `config_unreadable`, computed on every read.
      {:error, _sentence} -> nil
    end
  end

  # The home is checked BEFORE the cache, not after: a cached answer computed
  # against another file would otherwise be served for up to the cache window,
  # which is long enough for the answer to be about a file nobody asked about.
  #
  # A baseline describes one file. In a daemon the home never changes, so the
  # re-record never fires; a process that outlives a home change has no baseline
  # for the new file, and reporting every section of a freshly pointed-at home as
  # an outside change would invent a fact rather than admit there is none.
  defp refresh(state) do
    state = if ConfigStore.path() == state.baseline_path, do: state, else: record(state)
    answer_or_compute(state)
  end

  defp answer_or_compute(%{cache: {answer, recorded_ms}} = state) do
    if monotonic_ms() - recorded_ms < state.cache_ttl_ms do
      {answer, state}
    else
      compute(state)
    end
  end

  defp answer_or_compute(state), do: compute(state)

  defp compute(state) do
    config_state = compute_config_state(state)

    # One reason per section: a rotated provider key and a changed provider
    # block are the same restart, and a banner listing one sentence twice reads
    # as two problems.
    reasons =
      (boot_bound_reasons(state.booted_live) ++
         rotated_secret_reasons(state) ++ external_reason(config_state))
      |> Enum.uniq_by(& &1.section)

    answer = %{
      required: reasons != [],
      reasons: reasons,
      config_state: config_state
    }

    {answer, %{state | cache: {answer, monotonic_ms()}}}
  end

  defp compute_config_state(state) do
    case load_persisted() do
      {:ok, persisted} -> compare_persisted(state.persisted_baseline, persisted)
      {:error, sentence} -> {:config_unreadable, sentence}
    end
  end

  # No recorded baseline means the file could not be parsed at boot; a file that
  # parses now is the operator repairing it, which is a change this VM did not
  # make and must not silently adopt.
  defp compare_persisted(nil, persisted),
    do: {:external_change, changed_sections(%{}, ConfigStore.persistable_snapshot(persisted))}

  defp compare_persisted(baseline, persisted) do
    current = ConfigStore.persistable_snapshot(persisted)

    case changed_sections(baseline, current) do
      [] -> :clear
      sections -> {:external_change, sections}
    end
  end

  # Both operands are `ConfigStore.current_snapshot/0`, i.e. live application
  # environment in the same shape, so no secret masking is needed and no
  # sentinel is resolved: a rotation reaches application environment through
  # `apply_snapshot/2` and is visible as an ordinary value difference.
  defp boot_bound_reasons(booted_live) do
    current = ConfigStore.current_snapshot()

    Enum.flat_map(@boot_bound, fn {section, sentence} ->
      if section_value(current, section) == section_value(booted_live, section) do
        []
      else
        [%{section: Atom.to_string(section), sentence: sentence}]
      end
    end)
  end

  # The fourth restart input, and the one no snapshot comparison can see: a
  # rotation writes the same `@keyring` sentinel over the same sentinel, so the
  # document and application environment are identical before and after. The
  # rotation is only observable at the moment it happens, which is what
  # `SecretWriteLog` records.
  #
  # A rotated secret is a restart reason only when its own section is boot-bound.
  # The section is the key's `SecretPaths` path, not a second table: a provider
  # key lands under `providers`, a channel token under `channels`, and a search
  # or transcription key under a section this daemon re-reads per call.
  defp rotated_secret_reasons(state) do
    state.write_log
    |> keys_since(state.booted_at_ms)
    |> Enum.map(&secret_section/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn section ->
      case List.keyfind(@boot_bound, section, 0) do
        {^section, sentence} -> [%{section: Atom.to_string(section), sentence: sentence}]
        nil -> []
      end
    end)
  end

  defp keys_since(write_log, since_ms),
    do: SecretWriteLog.keys_since(since_ms, write_log: write_log)

  # `[:fermix_channels, :telegram, :bot_token]` is the `channels` section, which
  # is the aggregate the restart reason names; every other path names its own
  # section under `fermix_core`.
  defp secret_section(key) do
    case SecretPaths.fetch!(key).path do
      [:fermix_channels | _rest] -> :channels
      [:fermix_core, section | _rest] -> section
      _other -> nil
    end
  end

  defp external_reason({:external_change, _sections}),
    do: [%{section: @external_change_section, sentence: @external_change_sentence}]

  defp external_reason(_config_state), do: []

  # Every persisted section, not only the boot-bound ones: an outside edit to a
  # section that takes effect without a restart is still an outside edit, and a
  # gate that only watched the boot-bound set would let the next save revert it
  # silently.
  defp changed_sections(baseline, current) do
    sections = section_names(baseline) ++ section_names(current)

    sections
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reject(fn section ->
      section_value(baseline, section) == section_value(current, section)
    end)
    |> Enum.map(&Atom.to_string/1)
  end

  defp section_names(snapshot) do
    core = snapshot |> Map.get(:fermix_core, []) |> Keyword.keys()
    channels = snapshot |> Map.get(:fermix_channels, []) |> Keyword.keys()
    core ++ channels ++ [:sandbox]
  end

  # Sections live under either top-level app key, and `sandbox` is its own root.
  # `channels` is the aggregate the restart reason names; the individual channel
  # keys are what the external-change diff names.
  defp section_value(snapshot, :sandbox), do: Map.get(snapshot, :sandbox)

  defp section_value(snapshot, :channels) do
    snapshot |> Map.get(:fermix_channels, []) |> Keyword.delete(:acp)
  end

  defp section_value(snapshot, section) do
    core = Map.get(snapshot, :fermix_core, [])

    case Keyword.fetch(core, section) do
      {:ok, value} -> value
      :error -> snapshot |> Map.get(:fermix_channels, []) |> Keyword.get(section, [])
    end
  end

  defp read_sentence(:enoent), do: "The settings file could not be read."

  defp read_sentence(reason) when is_atom(reason),
    do: "The settings file could not be read: #{:file.format_error(reason)}."

  defp read_sentence(_reason), do: "The settings file could not be read."

  # Only the absent process answers the absent answer. A call timeout is a
  # wedged server, and reporting that as "clear, no restart needed" would hide
  # the one condition an operator most needs to see.
  defp call(opts, message, absent_answer) do
    case Process.whereis(Keyword.get(opts, :server, __MODULE__)) do
      nil -> absent_answer
      pid -> GenServer.call(pid, message)
    end
  catch
    :exit, {:noproc, _call} -> absent_answer
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
