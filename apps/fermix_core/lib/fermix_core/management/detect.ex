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
  time out after two seconds each. Each vendor also says whether a run failed
  to sign in (`signed_out`, from this machine's coding store through
  `Harness.SignIn`, read on a connection of its own on any role), and
  `coding_agents.check` clears those marks first (`check_agents/2`). Ollama
  has its own loopback HTTP timeout. The `claude_code` probe asks the macOS
  keychain whether
  an item exists — a bounded `security` call with no `-w`, so it reads no value
  and cannot raise the allow dialog. The `meetbot` probe is three local reads —
  the sidecar binary, the browser marker and the sign-in marker — and never
  reads inside the notetaker's browser profile. Its row also says whether
  Google Meet can run on the machine that answers (`available`,
  `Meetings.meet_here/1`): not on an Always On server (M97 D24), whose row's
  `detail` is then the sentence every surface says.
  """

  require Logger

  alias FermixCore.Auth.AnthropicLogin
  alias FermixCore.Harness.SignIn
  alias FermixCore.Harness.Vendors
  alias FermixCore.Home.Role
  alias FermixCore.Meetings
  alias FermixCore.Meetings.SidecarInstaller
  alias FermixCore.Providers.ModelListing
  alias FermixCore.Providers.PrimaryConfig

  @targets ~w(existing_primary claude_code codex_cli ollama harness_vendors meetbot)
  @no_cli "No coding CLI detected. Install the Codex or Claude Code CLI, then restart Fermix " <>
            "to enable coding agents."
  @not_cleared "Fermix could not read the coding agents' sign-in marks here, so none was " <>
                 "cleared."

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

  @doc """
  `coding_agents.check` (M98 G1b-3): the owner pressed Check again, their word
  that `vendors` are signed in again. Their sign-in marks are cleared in this
  machine's coding store, on a connection of its own (any role), and the
  answer is `run(["harness_vendors"], opts)`, this machine's agents read
  again. A store that cannot be cleared is refused with a sentence and
  nothing read. `opts[:sign_in]` is `Harness.SignIn`'s options.
  """
  @spec check_agents([String.t()], keyword()) ::
          {:ok, %{String.t() => [map()]}} | {:error, {:unavailable, String.t(), String.t()}}
  def check_agents(vendors, opts) when is_list(vendors) and is_list(opts) do
    case SignIn.clear(vendors, sign_in_opts(opts)) do
      :ok ->
        {:ok, run(["harness_vendors"], opts)}

      {:error, reason} ->
        Logger.warning("coding_agents.check: sign-in marks not cleared: #{inspect(reason)}")
        {:error, {:unavailable, "coding_agents", @not_cleared}}
    end
  end

  # This machine's agents (M98): each with its sign-in mark beside its
  # published `auth` (a closed set released apps decode), and the sentences
  # the apps already draw as `guidance`: how to install one, which agent a run
  # failed to sign in, and on a computer whose home is on a server, whose
  # agents these are.
  defp row("harness_vendors", opts) do
    detections = source(opts, :harness_vendors, &harness_detections/0)
    marks = sign_in_marks(opts)
    machine = source(opts, :machine, fn -> SignIn.machine_word(sign_in_opts(opts)) end)

    vendors =
      Vendors.vendors()
      |> Enum.sort()
      |> Enum.map(&vendor_row(Map.fetch!(detections, &1), marks))

    installed = vendors |> Enum.filter(& &1["installed"]) |> Enum.map(& &1["vendor"])
    marked = for %{"installed" => true, "signed_out" => true} = row <- vendors, do: row["vendor"]

    %{
      "target" => "harness_vendors",
      "present" => installed != [],
      "detail" => if(installed == [], do: nil, else: Enum.join(installed, ", ")),
      "vendors" => vendors,
      "guidance" => harness_guidance(installed, marked, machine, engine_role(opts))
    }
  end

  # The sign-in is published as a fact beside its sentence: a client that hides
  # the sign-in control once the account is in place switches on the boolean,
  # never on the words of the sentence it renders. So is whether Google Meet
  # can run here at all, before anything is pressed (M97 D24).
  defp row("meetbot", opts) do
    {present?, signed_in?} = probe("meetbot", opts)
    available? = meet_available?(source(opts, :meet_here, &Meetings.meet_here/0))

    %{
      "target" => "meetbot",
      "present" => present?,
      "detail" => meetbot_detail(available?, signed_in?),
      "signed_in" => signed_in?,
      "available" => available?
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
    {source(opts, :codex_cli, &codex_cli_signed_in?/0), nil}
  end

  defp probe("ollama", opts) do
    case source(opts, :ollama, &ollama_models/0) do
      {:ok, models} -> {true, model_count(models)}
      {:error, _reason} -> {false, nil}
    end
  end

  # Both halves or nothing: a sidecar with no browser cannot sign in and cannot
  # join a meeting, so half an install is not the notetaker being present.
  defp probe("meetbot", opts) do
    present? =
      source(opts, :meetbot_installed, &SidecarInstaller.installed?/0) and
        source(opts, :meetbot_browser_installed, &SidecarInstaller.browser_installed?/0)

    {present?, meetbot_signed_in(present?, opts)}
  end

  defp chosen_primary do
    PrimaryConfig.chosen_in(
      Application.get_env(:fermix_core, :providers, []),
      Application.get_env(:fermix_core, :agent, [])
    )
  end

  defp ollama_models, do: ModelListing.live_models(:ollama, [])

  defp codex_cli_signed_in?,
    do: Vendors.codex_chatgpt_signed_in?(Path.join(System.user_home!(), ".codex/auth.json"))

  defp harness_detections do
    detector =
      Application.get_env(:fermix_core, :harness_vendor_detector, fn ->
        Vendors.detect_all(version_timeout_ms: 2_000)
      end)

    detector.()
  end

  # Marks that cannot be read leave `signed_out` out of every row rather than
  # guess it; the reason is logged.
  defp sign_in_marks(opts) do
    case source(opts, :sign_in_marks, fn -> SignIn.marks(sign_in_opts(opts)) end) do
      {:ok, marks} ->
        {:ok, marks}

      {:error, reason} ->
        Logger.warning("setup.detect: sign-in marks could not be read: #{inspect(reason)}")
        :unknown
    end
  end

  defp engine_role(opts), do: source(opts, :engine_role, fn -> Role.recorded().role end)

  defp sign_in_opts(opts), do: Keyword.get(opts, :sign_in, [])

  defp vendor_row(%{vendor: vendor, available?: installed, version: version, auth: auth}, marks)
       when vendor in ["claude", "codex"] and is_boolean(installed) and
              auth in [:authenticated, :unverified, :absent] do
    %{
      "vendor" => vendor,
      "installed" => installed,
      "version" => bounded_version(version),
      "auth" => Atom.to_string(auth)
    }
    |> put_signed_out(auth, marks)
  end

  defp put_signed_out(row, _auth, :unknown), do: row

  defp put_signed_out(%{"vendor" => vendor} = row, auth, {:ok, marks}),
    do: Map.put(row, "signed_out", SignIn.view(auth, Map.get(marks, vendor)) == :signed_out)

  defp bounded_version(nil), do: nil
  defp bounded_version(version) when is_binary(version), do: String.slice(version, 0, 512)

  defp harness_guidance(installed, marked, machine, role) do
    [
      if(installed == [], do: @no_cli),
      Enum.map(marked, &SignIn.marked_sentence(&1, machine)),
      if(role == :device, do: on_a_computer(machine))
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      sentences -> Enum.join(sentences, " ")
    end
  end

  defp on_a_computer(machine) do
    "These are #{machine}'s coding agents. While your home is on your server, Fermix runs " <>
      "coding agents there, approved and signed in there."
  end

  @doc "Every sentence `setup.detect` and `coding_agents.check` can say, for `Management.CopyTest`."
  @spec sentences() :: [String.t()]
  def sentences do
    [@no_cli, @not_cleared | Enum.map(["this Mac", "this computer"], &on_a_computer/1)] ++
      SignIn.sentences()
  end

  defp model_count([_single]), do: "1 model"
  defp model_count(models), do: "#{length(models)} models"

  # The sign-in is the one notetaker fact a client cannot see for itself: the
  # marker lives beside a browser profile nothing on the wire exposes, and the
  # pane draws the idle sign-in control until it is told otherwise. Absent the
  # notetaker there is nothing to be signed in to, so the row says nothing
  # rather than "not signed in".
  # Absent the notetaker there is nothing to be signed in to, so the marker is
  # never read and the fact is null rather than false.
  defp meetbot_signed_in(false, _opts), do: nil

  defp meetbot_signed_in(true, opts),
    do: source(opts, :meetbot_signed_in, &SidecarInstaller.signed_in?/0)

  defp meet_available?(:ok), do: true
  defp meet_available?({:error, :meet_unavailable_on_server}), do: false

  # Where Google Meet cannot run, the detail says so rather than the sign-in.
  defp meetbot_detail(false, _signed_in?), do: Meetings.meet_unavailable_sentence()
  defp meetbot_detail(true, nil), do: nil
  defp meetbot_detail(true, true), do: "Signed in to Google"
  defp meetbot_detail(true, false), do: "Not signed in to Google"

  defp source(opts, key, default) when is_atom(key) do
    opts |> Keyword.get(:probes, []) |> Keyword.get(key, default) |> then(& &1.())
  end
end
