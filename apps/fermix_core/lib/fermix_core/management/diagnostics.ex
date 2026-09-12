defmodule FermixCore.Management.Diagnostics do
  @moduledoc """
  The bounded, field-allowlisted core diagnostic object behind
  `diagnostics.build` (M34 §2, §6).

  Two rules make this safe to hand a user for export:

  1. **Allowlist, not denylist.** The object is *constructed* from a fixed set
     of named fields drawn from named sources. A source that grows a new key
     does not grow the diagnostic — the key is simply never read. That is why
     message content, transcripts, databases, traces, audio, and browser data
     are excluded: they are not sources, so there is no path by which they
     could appear.
  2. **Every free-text leaf is scrubbed.** Only two allowlisted fields carry
     operator text — Doctor summaries and log messages — and both pass through
     `scrub/1`, which re-runs the shared log redactor and additionally removes
     absolute user paths, tokenized Setup and OAuth URLs, authorization
     headers, keyring references, and `key = value` secret assignments.

  Building never uploads: this module performs no network I/O, and the app is
  the only thing that writes the result, to a file the user selected.

  Migration and update state are app-owned (they live in the app's journal,
  outside the engine) and are merged by Swift into its own allowlisted fields.
  """

  alias Fermix.CLI.Service
  alias FermixCore.BuildInfo
  alias FermixCore.Management.Doctor
  alias FermixCore.Management.Logs
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Router
  alias FermixCore.Management.Text

  @schema_version 1
  @max_log_entries 500
  @engine_fields ~w(
    engine_id product_version build_id source_commit distribution_identity artifact_target
    architecture pid
  )
  @doctor_fields ~w(session_id scope status finished_at)
  @check_fields ~w(
    id category severity applicability origin status summary evidence remediation_code
    duration_ms finished_at
  )
  @entry_fields ~w(time level subsystem message)
  @text_fields ~w(summary message)

  @type report :: %{String.t() => term()}

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec max_log_entries() :: pos_integer()
  def max_log_entries, do: @max_log_entries

  @doc """
  Builds the core diagnostic object.

  A source that cannot answer fails the whole build — a diagnostic missing the
  half that explains the fault is worse than an explicit refusal. The one
  exception is Doctor history: "no session has run yet" is a fact, reported as
  a null field.
  """
  @spec build(keyword()) :: {:ok, report()} | {:error, :unavailable}
  def build(opts \\ []) when is_list(opts) do
    identity_provider = Keyword.get(opts, :identity_provider, &Router.engine_identity/0)
    service_provider = Keyword.get(opts, :service_provider, &default_service/0)
    logs_provider = Keyword.get(opts, :logs_provider, &default_logs/1)
    doctor_provider = Keyword.get(opts, :doctor_provider, doctor_provider(opts))

    with {:ok, identity} <- identity_provider.(),
         {:ok, service} <- service_provider.(),
         {:ok, logs} <- logs_provider.(%{"limit" => @max_log_entries}) do
      {:ok, assemble(identity, service, logs, doctor_provider.())}
    else
      _failure -> {:error, :unavailable}
    end
  end

  defp assemble(identity, service, logs, doctor) do
    %{
      "schema_version" => @schema_version,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "engine" => take(identity, @engine_fields),
      "protocol" => protocol(),
      "service" => service(service),
      "doctor" => doctor(doctor),
      "logs" => logs(logs)
    }
  end

  defp protocol do
    {minimum, maximum} = Protocol.supported_version_range()

    %{
      "current_version" => Protocol.protocol_version(),
      "minimum_version" => minimum,
      "maximum_version" => maximum
    }
  end

  defp service(state) do
    %{
      "scope" => scalar(value(state, :scope)),
      "state" => scalar(value(state, :state))
    }
  end

  defp doctor({:ok, session}) when is_map(session) do
    session
    |> take(@doctor_fields)
    |> Map.put("checks", Enum.map(Map.get(session, "checks", []), &take(&1, @check_fields)))
  end

  defp doctor(_absent), do: nil

  defp logs(result) do
    entries = result |> Map.get("entries", []) |> Enum.take(@max_log_entries)

    %{
      "count" => length(entries),
      "truncated" => Map.get(result, "truncated", false) == true,
      "entries" => Enum.map(entries, &take(&1, @entry_fields))
    }
  end

  # The allowlist itself: only named keys survive, and the two that carry
  # operator text are scrubbed on the way through.
  defp take(source, fields) when is_map(source) do
    Map.new(fields, fn field -> {field, field_value(source, field)} end)
  end

  defp take(_source, fields), do: Map.new(fields, &{&1, nil})

  defp field_value(source, field) when field in @text_fields do
    case Map.get(source, field) do
      text when is_binary(text) -> scrub(text)
      other -> scalar(other)
    end
  end

  defp field_value(source, "evidence"), do: scrub_map(Map.get(source, "evidence"))
  defp field_value(source, field), do: scalar(Map.get(source, field))

  defp scrub_map(evidence) when is_map(evidence) do
    Map.new(evidence, fn
      {key, value} when is_binary(value) -> {key, scrub(value)}
      {key, value} -> {key, scalar(value)}
    end)
  end

  defp scrub_map(_evidence), do: %{}

  @doc """
  Removes every secret class §6 excludes from one operator-visible string.

  Delegates to `FermixCore.Management.Text.scrub/1`, which is also what
  `doctor.get` runs on a summary before returning it. One scrubber, or the app
  reads raw through one surface what the other redacts.
  """
  @spec scrub(String.t()) :: String.t()
  defdelegate scrub(text), to: Text

  # Only what the engine itself can know. Under `macos_app` the background
  # service is `SMAppService` registration, which lives app-side — the engine
  # says so rather than reporting the absent legacy unit as "no service", and
  # Swift merges the real registration state into its own allowlisted fields.
  defp default_service do
    case BuildInfo.public_identity() do
      %{"distribution_identity" => "macos_app"} -> {:ok, %{scope: nil, state: :app_managed}}
      _standalone -> {:ok, standalone_service()}
    end
  end

  defp standalone_service do
    cond do
      Service.installed?(:system) -> %{scope: :system, state: :installed}
      Service.installed?(:user) -> %{scope: :user, state: :installed}
      true -> %{scope: nil, state: :absent}
    end
  end

  defp default_logs(params), do: Logs.query(params)

  defp doctor_provider(opts) do
    server = Keyword.get(opts, :doctor_server, Doctor)
    fn -> Doctor.latest(server: server) end
  end

  defp value(map, key, default \\ nil) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp scalar(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp scalar(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp scalar(nil), do: nil
  defp scalar(_value), do: nil
end
