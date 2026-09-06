defmodule FermixCore.Management.Detect do
  @moduledoc """
  `setup.detect`: what this Mac already has that onboarding can adopt
  (M34 native setup §7.3).

  Only the targets asked for, with no credentials or local paths in replies.
  Nothing here is on a report rebuild: the answer changes when the operator
  installs something, so it is asked when a surface needs it rather than cached
  into a boot artifact.

  Every probe is individually bounded. Harness vendors reuse the browser
  setup's network-free version and auth-state detector; version subprocesses
  time out after two seconds each. Ollama has its own loopback HTTP timeout.
  The `claude_code` probe asks the macOS keychain whether
  an item exists — a bounded `security` call with no `-w`, so it reads no value
  and cannot raise the allow dialog.
  """

  alias FermixCore.Auth.AnthropicLogin
  alias FermixCore.Auth.CodexImport
  alias FermixCore.Harness.Vendors
  alias FermixCore.Providers.ModelListing
  alias FermixCore.Providers.PrimaryConfig

  @targets ~w(existing_primary claude_code codex_cli ollama harness_vendors)

  @doc "Every detection target this daemon answers, ordered."
  @spec targets() :: [String.t()]
  def targets, do: @targets

  @doc "Whether the named target is one this daemon answers."
  @spec target?(term()) :: boolean()
  def target?(target), do: is_binary(target) and target in @targets

  @doc """
  Runs the named targets in the order asked and answers one row each.

  Every probe is injectable so the projection can be driven without a home, a
  vendor CLI or a loopback server; each seam injects a *probe*, never a
  rendered row.
  """
  @spec run([String.t()], keyword()) :: %{String.t() => [map()]}
  def run(targets, opts \\ []) when is_list(targets) and is_list(opts) do
    %{"results" => Enum.map(targets, &row(&1, opts))}
  end

  defp row("harness_vendors", opts) do
    detections = source(opts, :harness_vendors, &harness_detections/0)

    vendors =
      Vendors.vendors()
      |> Enum.sort()
      |> Enum.map(&vendor_row(Map.fetch!(detections, &1)))

    installed = vendors |> Enum.filter(& &1["installed"]) |> Enum.map(& &1["vendor"])

    %{
      "target" => "harness_vendors",
      "present" => installed != [],
      "detail" => if(installed == [], do: nil, else: Enum.join(installed, ", ")),
      "vendors" => vendors,
      "guidance" => harness_guidance(installed)
    }
  end

  defp row(target, opts) do
    {present?, detail} = probe(target, opts)

    %{"target" => target, "present" => present?, "detail" => detail}
  end

  defp probe("existing_primary", opts) do
    chosen = source(opts, :existing_primary, &chosen_primary/0)

    case chosen do
      {:ok, nil} -> {false, nil}
      {:ok, provider} -> {true, Atom.to_string(provider)}
      # Two blocks flagged primary is a configuration that exists and is
      # ambiguous, not an absent one. Readiness is what refuses it; this row
      # only says onboarding has something to reconcile.
      {:error, :multiple_primary} -> {true, nil}
    end
  end

  defp probe("claude_code", opts) do
    {source(opts, :claude_code, &AnthropicLogin.claude_code_present?/0), nil}
  end

  defp probe("codex_cli", opts) do
    {source(opts, :codex_cli, &CodexImport.codex_available?/0), nil}
  end

  defp probe("ollama", opts) do
    case source(opts, :ollama, &ollama_models/0) do
      {:ok, models} -> {true, model_count(models)}
      {:error, _reason} -> {false, nil}
    end
  end

  defp chosen_primary do
    PrimaryConfig.chosen_in(
      Application.get_env(:fermix_core, :providers, []),
      Application.get_env(:fermix_core, :agent, [])
    )
  end

  defp ollama_models, do: ModelListing.live_models(:ollama, [])

  defp harness_detections do
    detector =
      Application.get_env(:fermix_core, :harness_vendor_detector, fn ->
        Vendors.detect_all(version_timeout_ms: 2_000)
      end)

    detector.()
  end

  defp vendor_row(%{vendor: vendor, available?: installed, version: version, auth: auth})
       when vendor in ["claude", "codex"] and is_boolean(installed) and
              auth in [:authenticated, :unverified, :absent] do
    %{
      "vendor" => vendor,
      "installed" => installed,
      "version" => bounded_version(version),
      "auth" => Atom.to_string(auth)
    }
  end

  defp bounded_version(nil), do: nil
  defp bounded_version(version) when is_binary(version), do: String.slice(version, 0, 512)

  defp harness_guidance([]) do
    "No coding CLI detected. Install the Codex or Claude Code CLI, then restart Fermix to enable coding agents."
  end

  defp harness_guidance(_installed), do: nil

  defp model_count([_single]), do: "1 model"
  defp model_count(models), do: "#{length(models)} models"

  defp source(opts, key, default) when is_atom(key) do
    opts |> Keyword.get(:probes, []) |> Keyword.get(key, default) |> then(& &1.())
  end
end
