defmodule Fermix.CLI.Service.Status do
  @moduledoc """
  The pure half of `fermix service status` (M38 §4.4.1, §9.2).

  `Fermix.CLI.Service` gathers the evidence — the binding, the unit properties
  systemd reports, the user unit's own bytes, the linger property, the installed
  manifest and one `hello` — and this module turns it into the published result.
  Nothing here runs a command or opens a file, so every state the interface has
  to render is reachable from a fixture.

  **The alignment verdict is not decided here.** `Fermix.CLI.VersionSkew` owns
  the one typed comparison of installed and running identity, because `fermix
  status`, Doctor and this result must never disagree about it; `alignment/2`
  only spells its verdict for the wire.

  **A unit this binary did not write is never rewritten as drift.** The only
  recognised shape is the unit `Fermix.CLI.Service` used to generate; anything
  else at that path is `foreign`, which refuses the mutation rather than
  overwriting somebody's own configuration.
  """

  alias Fermix.CLI.VersionSkew

  # The vendor unit the Linux distribution package installs. An effective unit
  # at any other path is shadowing it, which is the state migration exists for.
  @vendor_unit_path "/usr/lib/systemd/user/fermix.service"

  # The same allowlist `Fermix.CLI.Service` writes into a unit: the activation
  # switch plus three overrides with working defaults, and never a secret.
  @observability_env ~w(
    FERMIX_OPIK_ENABLED
    FERMIX_OPIK_BASE_URL
    FERMIX_OPIK_PROJECT
    FERMIX_TRACE_CONTENT
  )

  @home_key "FERMIX_HOME"

  @type user_unit :: :absent | :legacy_generated | :foreign

  # What "which engine is this" means on the wire, in one place.
  @identity_keys ["build_id", "product_version", "distribution_identity", "architecture"]

  @doc "The vendor unit path the Linux package owns."
  @spec vendor_unit_path() :: Path.t()
  def vendor_unit_path, do: @vendor_unit_path

  @doc """
  The published spelling of the typed comparison in `Fermix.CLI.VersionSkew`.

  The comparison itself lives there, because `fermix status`, Doctor and this
  result must never disagree about whether the running engine is the installed
  one; this function only turns its verdict into the wire's string.
  """
  @spec alignment(map(), map() | nil) :: String.t()
  def alignment(installed, running) when is_map(installed) do
    installed |> VersionSkew.compare(running) |> Atom.to_string()
  end

  @doc """
  The installed identity, with the verdict on its own installed manifest.

  What is INSTALLED is what the package put on disk, so the manifest is the
  identity and the compiled constants are only the fallback for a manifest that
  cannot be read. Publishing the compiled ones made a stale engine describe
  itself as the install: the code answering had been extracted from an earlier
  package, so `integrity` said "mismatched" while alignment — comparing that
  same stale identity against itself — said "aligned", and no surface could
  tell the owner they were running an engine they had already replaced.
  """
  @spec installed(map(), {:ok, map()} | {:error, term()}) :: map()
  def installed(compiled, manifest) when is_map(compiled) do
    compiled
    |> published_identity(manifest)
    |> Map.put("integrity", integrity(compiled, manifest))
  end

  # Only the four identity keys are taken from the manifest, and only when it
  # carries them: everything else a caller publishes about the install stays as
  # the build reported it.
  defp published_identity(compiled, {:ok, manifest}) when is_map(manifest) do
    Enum.reduce(@identity_keys, compiled, fn key, acc ->
      case Map.get(manifest, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp published_identity(compiled, _unreadable), do: compiled

  @doc "Whether a user unit is absent, the unit this binary used to write, or foreign."
  @spec classify_unit(String.t() | nil) :: user_unit()
  def classify_unit(nil), do: :absent

  def classify_unit(contents) when is_binary(contents) do
    generated? =
      String.contains?(contents, "ExecStart=") and
        String.contains?(contents, "fermix run") and
        (String.contains?(contents, "Environment=#{@home_key}=") or
           String.contains?(contents, ~s(Environment="#{@home_key}=)))

    if generated?, do: :legacy_generated, else: :foreign
  end

  @doc "The home a recognised legacy generated unit names."
  @spec legacy_home(String.t()) :: {:ok, Path.t()} | :error
  def legacy_home(contents) when is_binary(contents) do
    case Map.fetch(unit_environment(contents), @home_key) do
      {:ok, home} -> {:ok, home}
      :error -> :error
    end
  end

  @doc "The observability assignments a legacy generated unit carries."
  @spec legacy_observability(String.t()) :: %{optional(String.t()) => String.t()}
  def legacy_observability(contents) when is_binary(contents) do
    contents |> unit_environment() |> Map.take(@observability_env)
  end

  @doc """
  The published status result.

  Every input is already-gathered evidence; an unreachable user manager never
  reaches here, because that is a structured error rather than an inactive unit.
  """
  @spec build(map()) :: map()
  def build(
        %{
          binding: binding,
          properties: properties,
          user_unit: user_unit,
          linger: linger,
          installed: installed,
          hello: hello
        } = evidence
      ) do
    running = running_identity(hello)

    %{
      "binding" => binding_row(binding),
      "unit" => unit(properties, user_unit),
      "enabled" => properties["UnitFileState"] == "enabled",
      "active" => properties["ActiveState"] == "active",
      "sub_state" => properties["SubState"],
      "pid" => pid(properties["MainPID"]),
      "invocation_id" => presence(properties["InvocationID"]),
      "restart_count" => integer(properties["NRestarts"]),
      "linger" => linger(linger),
      # The vendor unit pins no PATH: the packaged engine applies the shared
      # baseline itself, so there is one answer for the service and the CLI.
      "path_source" => "engine_baseline",
      "listener" => listener(hello, Map.get(evidence, :configured_listener)),
      "installed" => installed,
      "running" => running,
      "alignment" => alignment(installed, running)
    }
  end

  defp binding_row({:ok, %{home: home}}),
    do: %{"state" => "bound", "home" => home, "reason" => nil}

  defp binding_row({:error, :missing}),
    do: %{"state" => "unbound", "home" => nil, "reason" => nil}

  defp binding_row({:error, {:invalid, sentence}}),
    do: %{"state" => "invalid", "home" => nil, "reason" => sentence}

  defp unit(properties, user_unit) do
    effective = presence(properties["FragmentPath"])

    %{
      "effective_path" => effective,
      "vendor" => effective == @vendor_unit_path,
      "legacy_generated" => user_unit == :legacy_generated,
      "foreign" => user_unit == :foreign,
      "need_daemon_reload" => properties["NeedDaemonReload"] == "yes"
    }
  end

  # Three sources, strongest first. A running daemon's own published origin is
  # the port something is actually listening on; with nothing running, the bound
  # home's settings are what the next start will use, and `default` says the
  # setting is absent rather than that the answer is unknown.
  defp listener(hello, configured) do
    case daemon_listener(hello) do
      nil -> configured_listener(configured)
      listener -> listener
    end
  end

  defp daemon_listener(nil), do: nil

  defp daemon_listener(hello) do
    origin = get_in(hello, ["setup", "origin"])

    case origin && URI.parse(origin) do
      %URI{port: port} when is_integer(port) ->
        %{"port" => port, "origin" => origin, "source" => "daemon"}

      _absent ->
        nil
    end
  end

  defp configured_listener({:ok, %{port: port, source: source}}) do
    %{
      "port" => port,
      "origin" => "http://127.0.0.1:#{port}",
      "source" => Atom.to_string(source)
    }
  end

  defp configured_listener(_absent_or_unreadable),
    do: %{"port" => nil, "origin" => nil, "source" => "unknown"}

  defp running_identity(nil), do: nil

  defp running_identity(hello) do
    case Map.get(hello, "engine") do
      engine when is_map(engine) -> engine
      _absent -> nil
    end
  end

  defp integrity(_compiled, {:error, _reason}), do: "unreadable"

  defp integrity(compiled, {:ok, manifest}) when is_map(manifest) do
    matching? =
      Enum.all?(@identity_keys, fn key ->
        Map.get(manifest, key) == Map.get(compiled, key)
      end)

    if matching?, do: "verified", else: "mismatched"
  end

  defp integrity(_compiled, {:ok, _shape}), do: "unreadable"

  defp linger({:ok, true}), do: "enabled"
  defp linger({:ok, false}), do: "disabled"
  defp linger({:error, _reason}), do: "unknown"

  defp pid(value) do
    case integer(value) do
      0 -> nil
      pid -> pid
    end
  end

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      :error -> 0
    end
  end

  defp integer(_absent), do: 0

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_absent_or_empty), do: nil

  # One `Environment=` assignment per line, in either spelling the unit may
  # carry: the plain `KEY=value` this binary wrote before, and the quoted,
  # escaped `"KEY=value"` the shared serializer writes now.
  defp unit_environment(contents) do
    contents
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "Environment="))
    |> Enum.map(&String.replace_prefix(&1, "Environment=", ""))
    |> Enum.reduce(%{}, &put_assignment/2)
  end

  defp put_assignment(assignment, acc) do
    case parse_assignment(assignment) do
      {:ok, key, value} -> Map.put(acc, key, value)
      :error -> acc
    end
  end

  defp parse_assignment(<<?", rest::binary>>) do
    case String.split(rest, ~r/"\s*$/, parts: 2) do
      [quoted, _tail] -> split_assignment(unescape(quoted))
      _unterminated -> :error
    end
  end

  defp parse_assignment(assignment), do: split_assignment(assignment)

  defp split_assignment(assignment) do
    case String.split(assignment, "=", parts: 2) do
      [key, value] when key != "" -> {:ok, key, value}
      _malformed -> :error
    end
  end

  # The inverse of `Templates.systemd_environment/2`, in the inverse order:
  # doubled percent first, then the escaped quote and backslash.
  defp unescape(value) do
    value
    |> String.replace("%%", "%")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end
end
