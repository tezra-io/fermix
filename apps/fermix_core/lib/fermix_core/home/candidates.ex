defmodule FermixCore.Home.Candidates do
  @moduledoc """
  The candidate primaries a primary holds (M75 §7.1):
  `<home>/mobile/candidates.json`, device-local, mode `0600`.

  A candidate is a fresh engine that enrolled through an enrollment window
  (`FXM1 0x03`) and now waits for the move. Its record keeps what the move
  needs to reach it and what the owner reviews before moving: the host it
  describes, its iroh endpoint and relays, its Noise static key (the
  enrollment handshake's initiator key, the move's responder key), the
  one-time snapshot recipient it gave, and the instance facts it reported
  about itself, which nobody verified (B6). At most #{4} are held, each for
  24 hours after it enrolled; an expired one is dropped at the next read or
  write.

  One writer: the primary's enrollment window (`FermixChannels.Home.Enrollment`).
  Readers: `home.candidates.list`, `home.status` and `home.move.start`.
  Written whole to a temporary file and renamed.
  """

  @filename "candidates.json"
  @version 1
  @max_candidates 4
  @lifetime_s 24 * 3_600
  @file_mode 0o600
  @dir_mode 0o700

  @type record :: %{
          candidate_id: String.t(),
          name: String.t(),
          os: String.t(),
          arch: String.t(),
          version: String.t(),
          node_id: String.t(),
          relays: [map(), ...],
          noise_pk: <<_::256>>,
          recipient: <<_::256>>,
          instance: map() | nil,
          snapshots: map() | nil,
          enrolled_at: DateTime.t(),
          expires_at: DateTime.t()
        }

  @doc "Where the list lives under `home`."
  @spec path(Path.t()) :: Path.t()
  def path(home) when is_binary(home) and home != "", do: Path.join([home, "mobile", @filename])

  @doc "The most candidates held at once."
  @spec max_candidates() :: pos_integer()
  def max_candidates, do: @max_candidates

  @doc "How long a candidate is held after it enrolled, in seconds."
  @spec lifetime_s() :: pos_integer()
  def lifetime_s, do: @lifetime_s

  @doc "The candidates still held at `now`, oldest first."
  @spec list(Path.t(), DateTime.t()) :: {:ok, [record()]} | {:error, term()}
  def list(home, %DateTime{} = now) when is_binary(home) and home != "" do
    with {:ok, records} <- read(home), do: {:ok, live(records, now)}
  end

  @doc "The candidate `candidate_id` held at `now`, or `{:error, {:unknown_candidate, id}}`."
  @spec fetch(Path.t(), String.t(), DateTime.t()) :: {:ok, record()} | {:error, term()}
  def fetch(home, candidate_id, %DateTime{} = now)
      when is_binary(home) and is_binary(candidate_id) do
    with {:ok, records} <- list(home, now) do
      case Enum.find(records, &(&1.candidate_id == candidate_id)) do
        nil -> {:error, {:unknown_candidate, candidate_id}}
        record -> {:ok, record}
      end
    end
  end

  @doc """
  Holds a new candidate enrolled at `now`, under a fresh id: refused as
  `{:error, :limit}` while #{@max_candidates} are held. `attrs` is the
  record without its id and its times.
  """
  @spec add(Path.t(), map(), DateTime.t()) :: {:ok, record()} | {:error, term()}
  def add(home, attrs, %DateTime{} = now) when is_binary(home) and is_map(attrs) do
    with {:ok, held} <- list(home, now),
         :ok <- room(held) do
      record =
        Map.merge(attrs, %{
          candidate_id: "cand-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
          enrolled_at: DateTime.truncate(now, :second),
          expires_at: now |> DateTime.add(@lifetime_s, :second) |> DateTime.truncate(:second)
        })

      with :ok <- write(home, held ++ [record]), do: {:ok, record}
    end
  end

  @doc "The sentence a person is shown when the list cannot be read."
  @spec error_sentence(term()) :: String.t()
  def error_sentence({:invalid_candidates, file}),
    do: "#{file} is not a list of candidates Fermix wrote."

  def error_sentence({:file, file, reason}), do: "#{file}: #{:file.format_error(reason)}."

  @doc """
  The public view of a record, as `home.candidates.list` and `home.status`
  answer it: never the keys.
  """
  @spec view(record()) :: map()
  def view(record) do
    %{
      "candidate_id" => record.candidate_id,
      "name" => record.name,
      "os" => record.os,
      "arch" => record.arch,
      "version" => record.version,
      "node_id" => record.node_id,
      "instance" => record.instance,
      "snapshots" => record.snapshots,
      "enrolled_at" => DateTime.to_iso8601(record.enrolled_at),
      "expires_at" => DateTime.to_iso8601(record.expires_at)
    }
  end

  @doc "A record as the move request carries it: JSON-safe, keys in base64."
  @spec encode(record()) :: map()
  def encode(record) do
    record
    |> view()
    |> Map.merge(%{
      "relays" => record.relays,
      "noise_pk" => Base.encode64(record.noise_pk),
      "recipient" => Base.encode64(record.recipient)
    })
  end

  @doc "Reads what `encode/1` wrote, or `{:error, :invalid_candidate}`."
  @spec decode(term()) :: {:ok, record()} | {:error, :invalid_candidate}
  def decode(%{} = map) do
    with {:ok, noise_pk} <- key(map["noise_pk"]),
         {:ok, recipient} <- key(map["recipient"]),
         {:ok, enrolled_at, _offset} <- DateTime.from_iso8601(map["enrolled_at"] || ""),
         {:ok, expires_at, _offset} <- DateTime.from_iso8601(map["expires_at"] || ""),
         true <- Enum.all?(~w(candidate_id name os arch version node_id), &is_binary(map[&1])),
         [_ | _] = relays <- map["relays"] do
      {:ok,
       %{
         candidate_id: map["candidate_id"],
         name: map["name"],
         os: map["os"],
         arch: map["arch"],
         version: map["version"],
         node_id: map["node_id"],
         relays: relays,
         noise_pk: noise_pk,
         recipient: recipient,
         instance: map["instance"],
         snapshots: map["snapshots"],
         enrolled_at: enrolled_at,
         expires_at: expires_at
       }}
    else
      _invalid -> {:error, :invalid_candidate}
    end
  end

  def decode(_other), do: {:error, :invalid_candidate}

  defp key(text) when is_binary(text) do
    case Base.decode64(text) do
      {:ok, <<_::256>> = key} -> {:ok, key}
      _other -> :error
    end
  end

  defp key(_other), do: :error

  defp room(held) when length(held) < @max_candidates, do: :ok
  defp room(_held), do: {:error, :limit}

  defp live(records, now),
    do: Enum.filter(records, &(DateTime.compare(&1.expires_at, now) == :gt))

  defp read(home) do
    file = path(home)

    case File.read(file) do
      {:ok, contents} -> parse(contents, file)
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  defp parse(contents, file) do
    with {:ok, %{"v" => @version, "candidates" => entries}} when is_list(entries) <-
           Jason.decode(contents),
         decoded = Enum.map(entries, &decode/1),
         true <- Enum.all?(decoded, &match?({:ok, _record}, &1)) do
      {:ok, Enum.map(decoded, fn {:ok, record} -> record end)}
    else
      _invalid -> {:error, {:invalid_candidates, file}}
    end
  end

  defp write(home, records) do
    file = path(home)
    tmp = file <> ".tmp"
    contents = Jason.encode!(%{"v" => @version, "candidates" => Enum.map(records, &encode/1)})

    with :ok <- ensure_dir(Path.dirname(file)),
         :ok <- file_op(File.write(tmp, contents), tmp),
         :ok <- file_op(File.chmod(tmp, @file_mode), tmp),
         :ok <- file_op(File.rename(tmp, file), file) do
      :ok
    else
      {:error, _reason} = error ->
        _ = File.rm(tmp)
        error
    end
  end

  defp ensure_dir(dir) do
    case File.mkdir(dir) do
      :ok -> file_op(File.chmod(dir, @dir_mode), dir)
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, {:file, dir, reason}}
    end
  end

  defp file_op(:ok, _path), do: :ok
  defp file_op({:error, reason}, path), do: {:error, {:file, path, reason}}
end
