defmodule FermixCore.Home.Snapshot.Status do
  @moduledoc """
  What every surface reads about snapshots (M75 §8): `<home>/snapshots/status.json`,
  device-local, written only by the scheduler and read by `home.status`,
  `home.snapshots.status` and `fermix home status`, with or without a running
  engine.

      {"version": 1,
       "next_run_at": "2026-10-27T15:30:00Z",
       "run_at_boot": false,
       "targets": {
         "s3": {
           "last_attempt": {"at": "…", "result": "failed", "name": "…", "epoch": 4,
                            "size": 81234, "sha256": "…", "location": null,
                            "key_id": "0011223344556677", "note": null,
                            "error": "S3 refused the snapshot (403 AccessDenied): Access Denied"},
           "last_verified": {"at": "…", "name": "…", "epoch": 4, "size": 80990,
                             "sha256": "…", "location": "s3://bucket/fermix/general/…",
                             "key_id": "0011223344556677"},
           "last_error": "S3 refused the snapshot (403 AccessDenied): Access Denied"}}}

  Per target: the last attempt, the last verified point (kept through later
  failures, so the owner always knows the newest snapshot that is safe) and the
  last error sentence (cleared by the next verified or waiting attempt). Each
  attempt names the recovery key it was written for (`key_id`, the first 8
  bytes of the recipient's SHA-256, as `home.snapshots.passphrase` answers it),
  so an owner who changed the passphrase knows which one opens which point.

  An attempt is `verified`, `failed`, or `waiting`: a target that could not take
  the snapshot now and will at a later run (a desktop asleep or offline). A
  waiting attempt is no failure: its sentence is its `note`, the last error is
  cleared and the last verified point kept.

  `stale_notice` is the newest verified point the phones were told had grown
  a week old (the scheduler's notice, M75 lean v1 §7), so they are told once
  per occurrence; null until then.

  `run_at_boot` asks the scheduler's next start to run at once rather than
  after its boot delay: a move's activation writes it, so the new primary
  stores its first snapshot right away (`Snapshot.Scheduler`). A file that
  cannot be read is reported as such rather than read as "never ran".

  `view/2` is the one projection every surface draws, with one sentence
  (`sentence/1`) for the state as a whole.
  """

  alias FermixCore.Home.Snapshot.Capture
  alias FermixCore.Home.Snapshot.Config

  @file_name "status.json"
  @version 1
  @max_bytes 1_048_576
  @file_mode 0o600

  @type attempt :: %{
          required(:at) => DateTime.t(),
          required(:result) => :verified | :failed | :waiting,
          required(:name) => String.t() | nil,
          required(:epoch) => pos_integer() | nil,
          required(:size) => non_neg_integer() | nil,
          required(:sha256) => String.t() | nil,
          required(:location) => String.t() | nil,
          required(:error) => String.t() | nil,
          optional(:key_id) => String.t() | nil,
          optional(:note) => String.t() | nil
        }
  @type target_status :: %{
          last_attempt: attempt() | nil,
          last_verified: attempt() | nil,
          last_error: String.t() | nil
        }
  @type t :: %{
          next_run_at: DateTime.t() | nil,
          run_at_boot: boolean(),
          stale_notice: DateTime.t() | nil,
          targets: %{String.t() => target_status()}
        }

  @doc "Where the status lives under `root`."
  @spec path(Path.t()) :: Path.t()
  def path(root) when is_binary(root), do: Path.join(Capture.dir(root), @file_name)

  @doc "The status before any run."
  @spec empty() :: t()
  def empty, do: %{next_run_at: nil, run_at_boot: false, stale_notice: nil, targets: %{}}

  @doc "When the newest verified point of any target was made, or nil when none is."
  @spec newest_verified(t()) :: DateTime.t() | nil
  def newest_verified(%{targets: targets}) do
    targets
    |> Map.values()
    |> Enum.flat_map(fn entry -> List.wrap(entry.last_verified && entry.last_verified.at) end)
    |> Enum.max(DateTime, fn -> nil end)
  end

  @doc "The status under `root`; `empty/0` when no run has written one."
  @spec read(Path.t()) :: {:ok, t()} | {:error, {:status_unreadable, term()}}
  def read(root) when is_binary(root) do
    file = path(root)

    case File.stat(file) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_bytes ->
        decode(File.read(file))

      {:ok, %File.Stat{}} ->
        {:error, {:status_unreadable, :not_a_status_file}}

      {:error, :enoent} ->
        {:ok, empty()}

      {:error, reason} ->
        {:error, {:status_unreadable, reason}}
    end
  end

  @doc "Records one target's attempt into `status`."
  @spec record(t(), String.t(), attempt()) :: t()
  def record(%{targets: targets} = status, target, %{result: result} = attempt)
      when is_binary(target) and result in [:verified, :failed, :waiting] do
    previous = Map.get(targets, target, %{last_attempt: nil, last_verified: nil, last_error: nil})
    attempt = Map.merge(%{key_id: nil, note: nil}, attempt)

    current =
      case result do
        :verified -> %{previous | last_attempt: attempt, last_verified: attempt, last_error: nil}
        :failed -> %{previous | last_attempt: attempt, last_error: attempt.error}
        :waiting -> %{previous | last_attempt: attempt, last_error: nil}
      end

    %{status | targets: Map.put(targets, target, current)}
  end

  @doc "Writes `status` under `root`: a sibling temp file renamed into place, mode `0600`."
  @spec write(Path.t(), t()) :: :ok | {:error, term()}
  def write(root, status) when is_binary(root) and is_map(status) do
    file = path(root)
    tmp = file <> ".tmp"

    with :ok <- mkdir(Path.dirname(file)),
         :ok <- file_op(File.write(tmp, Jason.encode_to_iodata!(encode(status))), tmp),
         :ok <- file_op(File.chmod(tmp, @file_mode), tmp) do
      file_op(File.rename(tmp, file), file)
    end
  end

  @doc """
  The projection every surface draws. `facts` names the configuration
  (`config`), the targets the engine knows (`targets`, `Snapshot.Target`
  modules), whether a run is going (`running`) and the profile the S3 key
  names (`profile`).
  """
  @spec view(t(), %{
          config: keyword(),
          targets: [module()],
          running: boolean(),
          profile: String.t()
        }) ::
          map()
  def view(status, %{config: config, targets: targets, running: running} = facts) do
    target_views = Enum.map(targets, &target_view(&1, status, config, facts.profile))
    configured = Config.recipient?(config) and Enum.any?(target_views, & &1["configured"])

    view = %{
      "configured" => configured,
      "recipient_set" => Config.recipient?(config),
      "interval_hours" => Config.interval_hours(config),
      "running" => running,
      "next_run_at" => iso(if(configured, do: status.next_run_at)),
      "targets" => target_views
    }

    Map.put(view, "sentence", sentence(view))
  end

  @doc "The one sentence for a view's state as a whole."
  @spec sentence(map()) :: String.t()
  def sentence(%{"recipient_set" => false}),
    do: "Snapshots are off: set a recovery passphrase to turn them on."

  def sentence(%{"configured" => false}),
    do: "Snapshots are off: name an S3 bucket to keep them in."

  def sentence(%{"running" => true}), do: "A snapshot is being written now."

  def sentence(%{"targets" => targets} = view) do
    case Enum.find(targets, &(&1["configured"] and is_binary(&1["last_error"]))) do
      %{"label" => label, "last_error" => error} ->
        "The last snapshot to #{label} failed: #{terminated(error)} Fermix tries again at " <>
          "the next run."

      nil ->
        healthy_sentence(targets, view["next_run_at"]) <> waiting_sentence(targets)
    end
  end

  # A target left waiting says why after the healthy sentence: it is no
  # failure, and the owner still learns this copy did not land yet.
  defp waiting_sentence(targets) do
    case Enum.find(targets, &(&1["configured"] and is_binary(&1["waiting"]))) do
      %{"waiting" => note} -> " " <> terminated(note)
      nil -> ""
    end
  end

  defp healthy_sentence(targets, next_run_at) do
    verified =
      targets
      |> Enum.map(& &1["last_verified"])
      |> Enum.reject(&is_nil/1)
      |> Enum.max_by(& &1["at"], fn -> nil end)

    case {verified, next_run_at} do
      {nil, nil} -> "Snapshots are on; the first runs soon."
      {nil, at} -> "Snapshots are on; the first runs at #{clock(at)}."
      {%{"at" => at}, _next} -> "The last snapshot was stored at #{clock(at)}."
    end
  end

  defp terminated(text) do
    if String.ends_with?(text, [".", "?", "!"]), do: text, else: text <> "."
  end

  defp target_view(module, status, config, profile) do
    entry = Map.get(status.targets, module.id(), %{})
    attempt = Map.get(entry, :last_attempt)

    {configured, destination} =
      case module.configured(config) do
        {:ok, settings} -> {true, module.destination(settings, profile: profile)}
        :not_configured -> {false, nil}
      end

    %{
      "id" => module.id(),
      "label" => module.label(),
      "configured" => configured,
      "destination" => destination,
      "last_attempt_at" => attempt && iso(attempt.at),
      "last_result" => attempt && Atom.to_string(attempt.result),
      "last_verified" => point(Map.get(entry, :last_verified)),
      "last_error" => Map.get(entry, :last_error),
      "waiting" => waiting_note(attempt)
    }
  end

  defp waiting_note(%{result: :waiting} = attempt), do: Map.get(attempt, :note)
  defp waiting_note(_attempt), do: nil

  defp point(nil), do: nil

  defp point(attempt) do
    %{
      "at" => iso(attempt.at),
      "name" => attempt.name,
      "epoch" => attempt.epoch,
      "size" => attempt.size,
      "sha256" => attempt.sha256,
      "location" => attempt.location,
      "key_id" => Map.get(attempt, :key_id)
    }
  end

  # `2026-10-27 09:30 UTC`: the whole minute an owner reads, in the zone the
  # status is kept in.
  defp clock(iso_text) do
    {:ok, at, 0} = DateTime.from_iso8601(iso_text)
    Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
  end

  defp encode(status) do
    %{
      "version" => @version,
      "next_run_at" => iso(status.next_run_at),
      "run_at_boot" => Map.get(status, :run_at_boot, false),
      "stale_notice" => iso(Map.get(status, :stale_notice)),
      "targets" =>
        Map.new(status.targets, fn {id, entry} ->
          {id,
           %{
             "last_attempt" => encode_attempt(entry.last_attempt),
             "last_verified" => encode_attempt(entry.last_verified),
             "last_error" => entry.last_error
           }}
        end)
    }
  end

  defp encode_attempt(nil), do: nil

  defp encode_attempt(attempt) do
    attempt
    |> Map.take([:name, :epoch, :size, :sha256, :location, :error, :key_id, :note])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.merge(%{"at" => iso(attempt.at), "result" => Atom.to_string(attempt.result)})
  end

  defp decode({:ok, json}) do
    with {:ok, %{"version" => @version, "targets" => targets} = map} when is_map(targets) <-
           Jason.decode(json),
         {:ok, next_run_at} <- time(Map.get(map, "next_run_at")),
         run_at_boot when is_boolean(run_at_boot) <- Map.get(map, "run_at_boot", false),
         {:ok, stale_notice} <- time(Map.get(map, "stale_notice")),
         {:ok, decoded} <- decode_targets(targets) do
      {:ok,
       %{
         next_run_at: next_run_at,
         run_at_boot: run_at_boot,
         stale_notice: stale_notice,
         targets: decoded
       }}
    else
      _invalid -> {:error, {:status_unreadable, :invalid}}
    end
  end

  defp decode({:error, reason}), do: {:error, {:status_unreadable, reason}}

  defp decode_targets(targets) do
    Enum.reduce_while(targets, {:ok, %{}}, fn {id, entry}, {:ok, acc} ->
      case decode_target(entry) do
        {:ok, decoded} -> {:cont, {:ok, Map.put(acc, id, decoded)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp decode_target(%{"last_attempt" => attempt, "last_verified" => verified} = entry) do
    with {:ok, attempt} <- decode_attempt(attempt),
         {:ok, verified} <- decode_attempt(verified),
         error when is_binary(error) or is_nil(error) <- Map.get(entry, "last_error") do
      {:ok, %{last_attempt: attempt, last_verified: verified, last_error: error}}
    else
      _invalid -> :error
    end
  end

  defp decode_target(_entry), do: :error

  defp decode_attempt(nil), do: {:ok, nil}

  defp decode_attempt(%{"at" => at, "result" => result} = attempt)
       when result in ["verified", "failed", "waiting"] do
    case time(at) do
      {:ok, %DateTime{} = at} ->
        {:ok,
         %{
           at: at,
           result: String.to_existing_atom(result),
           name: attempt["name"],
           epoch: attempt["epoch"],
           size: attempt["size"],
           sha256: attempt["sha256"],
           location: attempt["location"],
           error: attempt["error"],
           key_id: attempt["key_id"],
           note: attempt["note"]
         }}

      _invalid ->
        :error
    end
  end

  defp decode_attempt(_attempt), do: :error

  defp time(nil), do: {:ok, nil}

  defp time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, 0} -> {:ok, at}
      _invalid -> :error
    end
  end

  defp time(_value), do: :error

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp mkdir(dir) do
    case File.mkdir(dir) do
      :ok -> file_op(File.chmod(dir, 0o700), dir)
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, {:file, dir, reason}}
    end
  end

  defp file_op(:ok, _path), do: :ok
  defp file_op({:error, reason}, path), do: {:error, {:file, path, reason}}
end
