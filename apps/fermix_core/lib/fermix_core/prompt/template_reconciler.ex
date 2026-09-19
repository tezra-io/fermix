defmodule FermixCore.Prompt.TemplateReconciler do
  @moduledoc """
  Deterministic reconciliation of installed bootstrap prompts against the
  templates the running binary ships (M43 §9.3).

  `Prompt.SetupSeeder` writes `bootstrap/<agent>/{SOUL,FERMIX,REALTIME,LIVE}.md`
  once and skips anything that already exists, and `Prompt.BootstrapLoader`
  always prefers the installed file — so a `brew upgrade` or a macOS app update
  ships new template text that an install which never touched its defaults would
  otherwise never run. This module closes that gap without ever overwriting an
  operator's own words.

  Exactly four resources are reconciled: `soul_md`, `fermix_md`, `realtime_md`
  and `live_md`. `identity_md`, `user_md` and `memory_md` are **never** touched
  here — IDENTITY keeps its own name reconciliation (`Prompt.IdentityName`) and
  USER/MEMORY are rebuilt from durable memory (`Memory.PromptFiles`). That
  exclusion is the §9.4 hard invariant.

  ## State table

  One state per resource, decided in this order. Both sides of every comparison
  are `String.trim_trailing/1`-normalised, the same tolerance the doctor row has
  always used.

  | State | Meaning | Behaviour |
  | --- | --- | --- |
  | `:current` | installed bytes equal the shipped default | nothing to do |
  | `:untouched` | installed bytes equal a known baseline, default differs | adopt the default through the versioned writer |
  | `:customized` | installed bytes match no known baseline | preserve; report whether the shipped template moved |
  | `:unknown` | no baseline at all and the bytes differ from the default | preserve; never guess it is an untouched default |
  | `:absent` | no file on disk | leave absent; do not recreate a persona |
  | `:empty` | present but blank or whitespace-only | leave exactly as is |
  | `:skipped` | the resource registry is not available | do nothing at all |

  A **known baseline** is any revision of that resource whose `mutation_source`
  is `"seed"` or `"template_adopt"`, plus a `"rollback"` revision whose
  provenance carries `"reset" => true` — the marker `SoulCuration.reset/2`
  writes when it restores the shipped SOUL. A *plain* rollback is not a
  baseline: it may have restored a hand-written file, and treating that as a
  default would overwrite operator content on the next upgrade.

  ## Known limitation

  An operator who pastes the exact new template into a file whose registry head
  already carries those bytes gets no `template_adopt` marker, because the
  registry dedupes a same-content commit as `:unchanged`. A later upgrade then
  reports that file as `:customized` rather than adopting it. It is preserved,
  never overwritten — the failure mode is a redundant review prompt, not lost
  content.

  ## Boot

  The module is also the supervision-tree child that performs the one
  reconciliation pass per daemon start. `init/1` runs `run/1` synchronously and
  keeps the result, so no prompt is composed against a half-migrated set, and
  `report/1` hands an in-tree reader what happened. `Fermix.CLI.Doctor.Checks`
  renders `classify/2` — detection and execution share this one classifier.
  """

  use GenServer

  alias FermixCore.Memory.Config
  alias FermixCore.Prompt.BootstrapFile
  alias FermixCore.Prompt.BootstrapPaths
  alias FermixCore.Prompt.TemplateRenderer
  alias FermixCore.Resource.Registry
  alias FermixCore.Resource.Revision

  require Logger

  @scope_id "global"

  # Rendered in this order; the doctor row lists files in it too.
  @resources [fermix: :fermix_md, soul: :soul_md, realtime: :realtime_md, live: :live_md]

  @baseline_sources ["seed", "template_adopt"]

  # Bound on the revision history one classification reads (Rule #2). A
  # baseline older than the newest this many revisions is not seen, so the
  # resource classifies as `:unknown` and is preserved — the cap can only make
  # the reconciler more conservative, never more destructive.
  @revision_scan_limit 500

  @type name :: :fermix | :soul | :realtime | :live
  @type resource_type :: :fermix_md | :soul_md | :realtime_md | :live_md

  @type state ::
          :current | :untouched | :customized | :unknown | :absent | :empty | :skipped

  @type outcome ::
          :adopted
          | :current
          | :customized
          | :unknown
          | :absent
          | :empty
          | :skipped
          | {:error, term()}

  @type entry :: %{
          name: name(),
          resource_type: resource_type(),
          path: String.t(),
          state: state(),
          installed_hash: String.t() | nil,
          default_hash: String.t(),
          default_content: String.t(),
          baseline_revision: pos_integer() | nil,
          default_moved?: boolean()
        }

  @type resource_report :: %{
          name: name(),
          resource_type: resource_type(),
          path: String.t(),
          state: state(),
          installed_hash: String.t() | nil,
          default_hash: String.t(),
          default_content: String.t(),
          baseline_revision: pos_integer() | nil,
          default_moved?: boolean(),
          outcome: outcome()
        }

  @type report :: %{agent_id: String.t(), resources: [resource_report()]}

  @doc """
  Classify every reconciled resource for `agent_id` without writing anything.

  Pure detection: reads each installed file, renders the current shipped
  default, lists the resource's revisions, and returns one `entry/0` per
  resource in `@resources` order. A registry that is switched off yields
  `:skipped` for every resource; any other registry or file-read failure is
  returned as `{:error, reason}` rather than guessed at.

  `opts`: `:repo`/`:server` (registry repo), `:bootstrap_dir` (home override).
  """
  @spec classify(String.t(), keyword()) :: {:ok, [entry()]} | {:error, term()}
  def classify(agent_id, opts \\ []) when is_binary(agent_id) and is_list(opts) do
    with :ok <- BootstrapPaths.validate_agent_id(agent_id),
         :ok <- persistence_ready(agent_id, opts) do
      classify_resources(agent_id, opts)
    else
      {:error, :disabled} -> {:ok, skipped_entries(agent_id, opts)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Classify, then adopt the shipped default for every `:untouched` resource.

  Reconciles the configured agent only (`Memory.Config.agent_id/1`). Each
  adoption goes through `Resource.Registry.commit_and_write/5` with
  `mutation_source: :template_adopt` and the classified bytes as
  `:expected_hash`, so an edit landing between classification and write is
  refused as `:stale_base` instead of clobbered. One failed adoption is carried
  as `{:error, reason}` on that resource's `:outcome` and never aborts the
  others: the report's per-resource outcome is the explicit result the design
  demands.

  `opts`: `:agent_id`, `:repo`/`:server`, `:bootstrap_dir`.
  """
  @spec run(keyword()) :: {:ok, report()} | {:error, term()}
  def run(opts \\ []) when is_list(opts) do
    agent_id = Config.agent_id(opts)

    with {:ok, entries} <- classify(agent_id, opts) do
      {:ok, settle(agent_id, entries, opts)}
    end
  end

  @doc """
  The report the boot pass produced, or the error that stopped it.
  """
  @spec report(GenServer.server()) :: {:ok, report()} | {:error, term()}
  def report(server \\ __MODULE__) do
    GenServer.call(server, :report)
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, run_opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, run_opts, name: name)
  end

  @impl true
  def init(opts) do
    {:ok, boot_result(run(opts))}
  end

  @impl true
  def handle_call(:report, _from, state), do: {:reply, state, state}

  defp boot_result({:ok, report}), do: {:ok, report}

  defp boot_result({:error, reason} = result) do
    Logger.warning("prompt template reconciliation did not run: #{inspect(reason)}")
    result
  end

  # A registry that answers is the design's "persistence dependencies are
  # ready" gate, probed once against the same repo the writes will use.
  defp persistence_ready(agent_id, opts) do
    case Registry.list_resources(agent_id, registry_opts(opts)) do
      {:ok, _rows} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp classify_resources(agent_id, opts) do
    @resources
    |> Enum.reduce_while([], fn {name, type}, acc ->
      case classify_resource(agent_id, name, type, opts) do
        {:ok, entry} -> {:cont, [entry | acc]}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      entries when is_list(entries) -> {:ok, Enum.reverse(entries)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp classify_resource(agent_id, name, type, opts) do
    spec = %{name: name, resource_type: type, path: resource_path(name, agent_id, opts)}

    with {:ok, default} <- TemplateRenderer.render(name, %{}) do
      read_and_classify(agent_id, spec, default, opts)
    end
  end

  defp read_and_classify(agent_id, spec, default, opts) do
    case BootstrapFile.read_present(spec.path) do
      {:ok, installed} -> compare(agent_id, spec, default, installed, opts)
      {:missing, :enoent} -> {:ok, inert_entry(spec, default, :absent)}
      {:missing, :empty} -> {:ok, inert_entry(spec, default, :empty)}
      {:error, reason} -> {:error, {:read_failed, spec.path, reason}}
    end
  end

  defp compare(agent_id, spec, default, installed, opts) do
    with {:ok, baselines} <- baselines(agent_id, spec.resource_type, opts) do
      {:ok,
       present_entry(spec, default, installed, classify_state(default, installed, baselines))}
    end
  end

  defp present_entry(spec, default, installed, {state, baseline_revision, moved?}) do
    %{
      name: spec.name,
      resource_type: spec.resource_type,
      path: spec.path,
      state: state,
      installed_hash: Registry.content_hash(installed),
      default_hash: Registry.content_hash(default),
      default_content: default,
      baseline_revision: baseline_revision,
      default_moved?: moved?
    }
  end

  defp classify_state(default, installed, baselines) do
    if same?(installed, default) do
      {:current, nil, false}
    else
      classify_divergent(default, installed, baselines)
    end
  end

  defp classify_divergent(default, installed, baselines) do
    case Enum.find(baselines, &same?(&1.content, installed)) do
      %Revision{revision: revision} -> {:untouched, revision, true}
      nil -> classify_without_match(default, baselines)
    end
  end

  defp classify_without_match(_default, []), do: {:unknown, nil, false}

  # `baselines/3` preserves the registry's newest-first order, so the head is
  # the most recent baseline — the one an upstream change is measured against.
  defp classify_without_match(default, [newest | _older]) do
    {:customized, newest.revision, not same?(newest.content, default)}
  end

  defp inert_entry(spec, default, state) do
    %{
      name: spec.name,
      resource_type: spec.resource_type,
      path: spec.path,
      state: state,
      installed_hash: nil,
      default_hash: Registry.content_hash(default),
      default_content: default,
      baseline_revision: nil,
      default_moved?: false
    }
  end

  defp skipped_entries(agent_id, opts) do
    Enum.map(@resources, fn {name, type} ->
      {:ok, default} = TemplateRenderer.render(name, %{})
      spec = %{name: name, resource_type: type, path: resource_path(name, agent_id, opts)}
      inert_entry(spec, default, :skipped)
    end)
  end

  defp baselines(agent_id, resource_type, opts) do
    list_opts = Keyword.put(registry_opts(opts), :limit, @revision_scan_limit)

    with {:ok, revisions} <-
           Registry.list_revisions(agent_id, resource_type, @scope_id, list_opts) do
      {:ok, Enum.filter(revisions, &baseline?/1)}
    end
  end

  defp baseline?(%Revision{mutation_source: source}) when source in @baseline_sources, do: true

  defp baseline?(%Revision{mutation_source: "rollback", provenance: %{"reset" => true}}), do: true

  defp baseline?(%Revision{}), do: false

  defp settle(agent_id, entries, opts) do
    report = %{
      agent_id: agent_id,
      resources: Enum.map(entries, &settle_resource(agent_id, &1, opts))
    }

    log_skipped(report)
    log_adopted(report)
    log_preserved(report)
    report
  end

  defp settle_resource(agent_id, %{state: :untouched} = entry, opts) do
    Map.put(entry, :outcome, adopt(agent_id, entry, opts))
  end

  defp settle_resource(_agent_id, entry, _opts), do: Map.put(entry, :outcome, entry.state)

  defp adopt(agent_id, entry, opts) do
    commit_opts =
      opts
      |> registry_opts()
      |> Keyword.merge(
        mutation_source: :template_adopt,
        resource_path: entry.path,
        provenance: adopt_provenance(entry),
        expected_hash: entry.installed_hash
      )

    case Registry.commit_and_write(
           agent_id,
           entry.resource_type,
           @scope_id,
           entry.default_content,
           commit_opts
         ) do
      {:ok, _revision_or_unchanged} -> :adopted
      {:error, reason} -> adopt_failed(entry, reason)
    end
  end

  # The writer restores the prior bytes itself on a post-write commit failure,
  # and logs an error of its own if even that restore fails, so this line
  # reports the refusal without claiming an outcome it did not observe.
  defp adopt_failed(entry, reason) do
    Logger.warning(
      "prompt template adoption failed for #{entry.path}: #{inspect(reason)} — " <>
        "the shipped template was not adopted"
    )

    {:error, reason}
  end

  defp adopt_provenance(entry) do
    %{
      trigger: "template_adopt",
      from_hash: entry.installed_hash,
      to_hash: entry.default_hash,
      description:
        "Adopted the shipped #{Path.basename(entry.path)} template; " <>
          "previous content kept as revision #{entry.baseline_revision}"
    }
  end

  defp log_skipped(%{resources: resources}) do
    if Enum.all?(resources, &(&1.outcome == :skipped)) do
      Logger.info(
        "prompt template reconciliation skipped: the resource registry is not available"
      )
    end

    :ok
  end

  defp log_adopted(%{resources: resources}) do
    resources
    |> Enum.filter(&(&1.outcome == :adopted))
    |> Enum.each(fn entry ->
      Logger.info("adopted the shipped #{Path.basename(entry.path)} template at #{entry.path}")
    end)
  end

  # Preserved files are the operator's choice, so this is information, not a
  # warning: the doctor row is where the review lives.
  defp log_preserved(%{resources: resources}) do
    preserved = Enum.filter(resources, &preserved_with_moved_default?/1)

    if preserved != [] do
      Logger.info(
        "kept the installed #{file_list(preserved)} while the shipped template moved; " <>
          "review them with `fermix doctor`"
      )
    end

    :ok
  end

  defp preserved_with_moved_default?(%{outcome: :unknown}), do: true
  defp preserved_with_moved_default?(%{outcome: :customized, default_moved?: moved?}), do: moved?
  defp preserved_with_moved_default?(_entry), do: false

  defp file_list(entries), do: Enum.map_join(entries, ", ", &Path.basename(&1.path))

  defp resource_path(:fermix, agent_id, opts), do: BootstrapPaths.fermix_path(agent_id, opts)
  defp resource_path(:soul, agent_id, opts), do: BootstrapPaths.soul_path(agent_id, opts)
  defp resource_path(:realtime, agent_id, opts), do: BootstrapPaths.realtime_path(agent_id, opts)
  defp resource_path(:live, agent_id, opts), do: BootstrapPaths.live_path(agent_id, opts)

  defp same?(left, right), do: String.trim_trailing(left) == String.trim_trailing(right)

  defp registry_opts(opts), do: Keyword.take(opts, [:repo, :server, :bootstrap_dir])
end
