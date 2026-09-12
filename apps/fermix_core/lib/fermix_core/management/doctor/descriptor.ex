defmodule FermixCore.Management.Doctor.Descriptor do
  @moduledoc """
  Adapts `Fermix.CLI.Doctor.Checks` results into the stable typed descriptors
  the management protocol publishes (M34 §5 "Doctor").

  `Checks` stays the sole source of truth for what a check *is*: this module
  only declares each check's identity (id, category, severity, applicability,
  origin) and renders its `%{name, status, detail}` result into the wire shape
  with a redacted bounded summary, evidence, remediation code, duration, and
  finish timestamp. No check logic is duplicated or reimplemented here.

  Two CLI checks are deliberately absent from the engine catalog:

  - `computer_use_permissions` probes the compux sidecar, which can raise a
    macOS TCC prompt. M34 requires the local scope to raise no permission
    prompts, and it is not a network check either, so it has no scope to live in.
  - `place_probe` is a metered live probe. M34 forbids network checks from
    performing "unrelated metered probes", so it stays a `fermix doctor --full`
    operator action.

  Both remain reachable through `fermix doctor`; the management surface simply
  does not advertise them.
  """

  alias Fermix.CLI.Doctor.Checks
  alias FermixCore.BuildInfo
  alias FermixCore.Management.Doctor.Remediation
  alias FermixCore.Management.Text

  @max_summary_bytes 256

  @categories [:runtime, :configuration, :security, :capability, :connectivity, :distribution]
  @severities [:critical, :warning, :info]
  @applicabilities [:always, :configured, :platform]
  # `not_applicable` is distinct from `unavailable` on purpose: the first means
  # this distribution does not have the check, the second means the check broke.
  # Folding them tells an operator with a correct install that a check failed.
  @statuses ~w(passed warning failed not_applicable unavailable skipped cancelled timed_out)

  @type spec :: %{
          id: String.t(),
          category: atom(),
          severity: atom(),
          applicability: atom(),
          origin: :engine,
          run: (-> Checks.result() | nil)
        }
  @type result :: %{String.t() => term()}

  @spec categories() :: [atom()]
  def categories, do: @categories

  @spec severities() :: [atom()]
  def severities, do: @severities

  @spec applicabilities() :: [atom()]
  def applicabilities, do: @applicabilities

  @doc "The M34 status vocabulary a descriptor can finish in."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc """
  The engine check catalog for one scope.

  `:local` is offline and prompt-free; `:network` reaches configured
  capabilities only, sends no messages, and runs no harness, browser, or
  computer task.

  The two distribution rows follow the engine rather than the scope. Under
  `macos_app` they answer `not_applicable` immediately and offline, so they
  belong in the local catalog that plain `fermix doctor` runs; on a standalone
  engine they fetch the release feed and hash the binary, so they belong in the
  network catalog `--full` opts into. One row per engine, never both.
  """
  @spec catalog(:local | :network, keyword()) :: [spec()]
  def catalog(scope, opts \\ [])

  def catalog(:local, opts) do
    check_opts = check_opts(opts)

    local_checks(check_opts) ++
      if(app_engine?(opts), do: distribution_checks(check_opts), else: [])
  end

  def catalog(:network, opts) do
    check_opts = check_opts(opts)

    network_checks() ++
      if(app_engine?(opts), do: [], else: distribution_checks(check_opts))
  end

  defp app_engine?(opts), do: Keyword.get(opts, :build_info, BuildInfo).app_engine?()

  # Every engine-varying check reads the same identity the catalog decided on,
  # so a spec cannot be placed by one answer and evaluated against another.
  defp check_opts(opts), do: Keyword.take(opts, [:build_info])

  defp distribution_checks(check_opts) do
    [
      spec("binary_integrity", :distribution, :critical, :platform, fn ->
        Checks.binary_integrity(check_opts)
      end),
      spec("upgrade_available", :distribution, :info, :platform, fn ->
        Checks.upgrade_available?(check_opts)
      end)
    ]
  end

  defp local_checks(check_opts) do
    [
      spec("readiness", :runtime, :critical, :always, &Checks.readiness/0),
      spec("fallback_providers", :configuration, :warning, :always, &Checks.fallback_providers/0),
      spec("workspace_layout", :runtime, :critical, :always, &Checks.workspace_layout/0),
      spec("service_unit", :runtime, :critical, :platform, fn ->
        Checks.service_unit(check_opts)
      end),
      spec("daemon_socket", :runtime, :critical, :always, &Checks.daemon_socket/0),
      spec("opik_readiness", :configuration, :info, :configured, &Checks.opik_readiness/0),
      spec("recent_log_activity", :runtime, :info, :always, &Checks.recent_log_activity/0),
      spec("compaction_config", :configuration, :warning, :always, &Checks.compaction_config/0),
      spec(
        "bootstrap_template_drift",
        :configuration,
        :warning,
        :always,
        &Checks.bootstrap_template_drift/0
      ),
      spec("routing_overrides", :configuration, :warning, :always, &Checks.routing_overrides/0),
      spec(
        "command_owner_config",
        :configuration,
        :warning,
        :always,
        &Checks.command_owner_config/0
      ),
      spec("streaming_config", :configuration, :info, :always, &Checks.streaming_config/0),
      spec("sandbox_config", :security, :warning, :always, &Checks.sandbox_config/0),
      spec(
        "sandbox_trace_suggestions",
        :security,
        :info,
        :always,
        &Checks.sandbox_trace_suggestions/0
      ),
      spec(
        "auth_file_permissions",
        :security,
        :critical,
        :always,
        &Checks.auth_file_permissions/0
      ),
      spec("home_permissions", :security, :critical, :always, &Checks.home_permissions/0),
      spec("cosign", :security, :warning, :always, &Checks.cosign/0),
      spec("auth_token_expiry", :security, :warning, :always, &Checks.auth_token_expiry/0),
      spec("plaintext_secrets", :security, :critical, :always, &Checks.plaintext_secrets/0),
      spec("linger", :runtime, :info, :platform, &Checks.linger/0),
      spec("place_search", :capability, :info, :configured, &Checks.place_search/0),
      spec("image_generation", :capability, :info, :configured, &Checks.image_generation/0),
      spec("transcription", :capability, :info, :configured, &Checks.transcription/0),
      spec("meetings", :capability, :info, :configured, &Checks.meetings/0),
      spec("realtime", :capability, :info, :configured, &Checks.realtime/0),
      spec("acp", :capability, :info, :configured, &Checks.acp/0),
      spec("computer_history", :capability, :info, :configured, &Checks.computer_history/0),
      spec("browser_disclaim", :security, :warning, :platform, &Checks.browser_disclaim/0),
      spec("harness", :capability, :warning, :configured, &Checks.harness/0),
      spec("skill_curation", :capability, :info, :configured, &Checks.skill_curation/0),
      spec("plugins", :capability, :warning, :always, &Checks.plugins/0),
      spec("web_search_config", :capability, :info, :configured, fn ->
        Checks.web_search(false)
      end),
      # The five coexistence and restart rows. Offline and prompt-free, so they
      # belong in the local catalog plain `fermix doctor` runs, and each is the
      # Doctor face of a fact `setup.state.get` already publishes.
      spec("restart_pending", :runtime, :warning, :always, &Checks.restart_pending/0),
      spec("external_config_change", :configuration, :warning, :always, fn ->
        Checks.external_config_change()
      end),
      spec("legacy_service_unit", :distribution, :warning, :always, fn ->
        Checks.legacy_service_unit()
      end),
      spec("secret_acl_restricted", :security, :warning, :always, fn ->
        Checks.secret_acl_restricted()
      end),
      spec("engine_path_baseline", :runtime, :warning, :always, &Checks.engine_path_baseline/0)
    ]
  end

  defp network_checks do
    [
      spec("auth_probe", :connectivity, :critical, :configured, &Checks.auth_probe/0),
      spec("channel_health", :connectivity, :warning, :configured, &Checks.channel_health/0),
      spec("mobile", :connectivity, :warning, :configured, &Checks.mobile/0),
      spec("web_search_probe", :connectivity, :info, :configured, fn ->
        Checks.web_search(true)
      end)
    ]
  end

  @doc """
  Runs one descriptor and renders its typed result.

  A raising check becomes an `unavailable` descriptor rather than a crashed
  session: the run is the unit the operator asked for, and one broken check
  must not erase the other thirty results.
  """
  @spec run(spec(), keyword()) :: result()
  def run(spec, opts \\ []) when is_map(spec) and is_list(opts) do
    clock = Keyword.get(opts, :clock, &monotonic_ms/0)
    started_ms = clock.()
    outcome = invoke(spec)

    spec
    |> identity()
    |> Map.merge(outcome)
    |> Map.put("duration_ms", max(clock.() - started_ms, 0))
    |> Map.put("finished_at", now_iso8601())
  end

  @doc """
  Renders a descriptor that never ran, in the terminal state the session ended
  in (`cancelled` or `timed_out`), or that its source declined (`skipped`).
  """
  @spec pending(spec(), :cancelled | :timed_out | :skipped) :: result()
  def pending(spec, status) when is_map(spec) and status in [:cancelled, :timed_out, :skipped] do
    spec
    |> identity()
    |> Map.merge(pending_outcome(spec, status))
    |> Map.put("duration_ms", 0)
    |> Map.put("finished_at", now_iso8601())
  end

  defp identity(spec) do
    %{
      "id" => spec.id,
      "category" => Atom.to_string(spec.category),
      "severity" => Atom.to_string(spec.severity),
      "applicability" => Atom.to_string(spec.applicability),
      "origin" => Atom.to_string(spec.origin)
    }
  end

  defp invoke(spec) do
    render(spec, spec.run.())
  rescue
    exception -> unavailable(spec, Exception.message(exception), %{})
  catch
    # An exit reason routinely embeds the call arguments — a GenServer timeout
    # carries the message it timed out on. M34 §2 forbids `inspect(reason)`
    # crossing the boundary, so the descriptor names the kind and stops there.
    kind, _reason ->
      unavailable(spec, "The check exited before it answered.", %{
        "exit_kind" => Atom.to_string(kind)
      })
  end

  # A `Checks` function that returns nil declares itself inapplicable to this
  # host (`linger` off Linux, `harness` when disabled) — that is `skipped`, not
  # a pass.
  defp render(spec, nil), do: pending_outcome(spec, :skipped)

  defp render(spec, %{name: name, status: status, detail: detail}) do
    word = status_word(status)

    %{
      "status" => word,
      "summary" => summary(detail),
      "evidence" => %{"source_name" => name, "source_status" => Atom.to_string(status)},
      "remediation_code" => remediation_code(spec.id, word),
      "remediation" => Remediation.fetch(spec.id, word)
    }
  end

  defp pending_outcome(spec, status) do
    word = Atom.to_string(status)

    %{
      "status" => word,
      "summary" => pending_summary(status),
      "evidence" => %{},
      "remediation_code" => remediation_code(spec.id, word),
      "remediation" => Remediation.fetch(spec.id, word)
    }
  end

  defp unavailable(spec, message, evidence) do
    %{
      "status" => "unavailable",
      "summary" => summary(message),
      "evidence" => evidence,
      "remediation_code" => remediation_code(spec.id, "unavailable"),
      "remediation" => Remediation.fetch(spec.id, "unavailable")
    }
  end

  defp status_word(:ok), do: "passed"
  defp status_word(:warn), do: "warning"
  defp status_word(:fail), do: "failed"
  defp status_word(:not_applicable), do: "not_applicable"

  # A code only exists where remediation does. `passed`, `skipped`,
  # `cancelled`, and `not_applicable` name no action, so they carry none rather
  # than a dead code the app would have to special-case.
  defp remediation_code(_id, word)
       when word in ["passed", "skipped", "cancelled", "not_applicable"],
       do: nil

  defp remediation_code(id, word), do: "#{id}.#{word}"

  defp pending_summary(:cancelled), do: "Cancelled before this check ran."
  defp pending_summary(:timed_out), do: "The run budget elapsed before this check ran."
  defp pending_summary(:skipped), do: "Not applicable on this host."

  @doc """
  Redacts and bounds one operator-visible detail string.

  Check details routinely name absolute paths under the operator's home and can
  quote a vendor error containing a credential. Every class `diagnostics.build`
  excludes (M34 §6) is removed here — at the point the descriptor is created —
  through the same scrubber the export uses, because `doctor.get` hands these
  summaries to the application directly.
  """
  @spec summary(String.t()) :: String.t()
  def summary(detail) when is_binary(detail) do
    detail
    |> Text.scrub()
    |> Text.truncate(@max_summary_bytes)
  end

  defp spec(id, category, severity, applicability, run) do
    %{
      id: id,
      category: category,
      severity: severity,
      applicability: applicability,
      origin: :engine,
      run: run
    }
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
  defp now_iso8601, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
