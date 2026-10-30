defmodule FermixCore.Home.Candidate do
  @moduledoc """
  A candidate primary's own files (M75 §2, §7.1, B4): `<home>/candidate/`,
  device-local, `0700`, every file in it `0600`.

  `fermix home enroll` (`enroll/3`) makes a fresh home a candidate: it writes

    * `code`: the enrollment code, until the enrollment is accepted;
    * `destination.json`: the snapshot bucket and region the new primary
      writes to (`{}` when none was named);
    * `instance.json`: what the host says of itself (`{}` when nothing was
      given), sent unverified (B6);
    * `noise_key`: the candidate's X25519 Noise static key (32 raw bytes), its
      key in the enrollment handshake and the move's responder key;
    * `recipient_key`: the one-time snapshot recipient (`Snapshot.Recipient`)
      the move's stream is encrypted to;
    * `mobile/iroh_key`: its own iroh secret key (`FermixChannels.Mobile.Iroh.Key`'s
      format), with which its helper listens for the move under this directory
      as its root;
    * `state.json`: the phase and what it learned;

  and `config.toml` with `[fermix_core.engine] role = "candidate"`.

  **Phases** (`state.json`): `enrolling` (the code is held), `enrolled` (the
  primary accepted it; waiting for the move up to 24 hours), `receiving` (a
  move's stream is arriving), `staged` (restored into `staging/`, `move_ready`
  sent), `activating` (`move_commit` arrived; the staged home is being renamed
  into place), and the ends `expired` and `failed`. The candidate process
  (`FermixChannels.Home.Candidate`) is the one writer after enrollment.

  `enroll/3` refuses a home that holds a primary epoch, a moved marker, a
  candidate that enrolled already, or anything a fresh install does not write
  (any path outside `FermixCore.Home.DeviceLocal`), and leaves nothing behind
  when it fails part-way: it removes exactly what it wrote. A candidate that
  never enrolled (`enrolling`, `failed`) is replaced, while the engine of
  this home is stopped (`FermixCore.Home.DaemonProbe`, `:daemon_running`
  otherwise): the new one is built beside it and swapped in, and a failure
  part-way puts the old one back. Activation is
  `FermixCore.Home.Candidate.Activation`.
  """

  alias FermixCore.Home.Candidate.Activation
  alias FermixCore.Home.DaemonProbe
  alias FermixCore.Home.DeviceLocal
  alias FermixCore.Home.EnrollmentCode
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Moved
  alias FermixCore.Home.Snapshot.Recipient

  @dir "candidate"
  @version 1
  @dir_mode 0o700
  @file_mode 0o600
  @phases ~w(enrolling enrolled receiving staged activating expired failed)
  @config_text ~s([fermix_core.engine]\nrole = "candidate"\n)
  @instance_fields ~w(provider instance_id region)
  @optional_instance_fields ~w(account_id)

  @type phase :: String.t()
  @type state :: %{required(String.t()) => term()}
  @type keypair :: %{private: <<_::256>>, public: <<_::256>>}

  @doc "The candidate's directory under `home`."
  @spec dir(Path.t()) :: Path.t()
  def dir(home) when is_binary(home) and home != "", do: Path.join(home, @dir)

  @doc "A file of the candidate's under `home`."
  @spec path(Path.t(), String.t()) :: Path.t()
  def path(home, name) when is_binary(name), do: Path.join(dir(home), name)

  @doc "Where a move's stream is written while it arrives."
  @spec incoming_path(Path.t()) :: Path.t()
  def incoming_path(home), do: path(home, "incoming.fxsnap")

  @doc "Where the move's home is restored before it is renamed into place."
  @spec staging_path(Path.t()) :: Path.t()
  def staging_path(home), do: path(home, "staging")

  @doc "Every phase `state.json` may hold."
  @spec phases() :: [phase()]
  def phases, do: @phases

  @doc "Whether `home` holds a candidate (its `candidate/` directory)."
  @spec present?(Path.t()) :: boolean()
  def present?(home), do: File.dir?(dir(home))

  @doc """
  Makes `home` a candidate from `code_text` (see the moduledoc). `opts`:
  `:destination` (`%{"s3_bucket" => b, "s3_region" => r}` or nil),
  `:instance` (the instance facts or nil), `:now` (a `DateTime`),
  `:consume` (a 0-arity function run last, such as removing the code file
  the code came from; its `{:error, reason}` undoes the enrollment too), and
  `:hello` (`DaemonProbe.stopped/2`'s seam).
  """
  @spec enroll(Path.t(), String.t(), keyword()) :: {:ok, EnrollmentCode.t()} | {:error, term()}
  def enroll(home, code_text, opts \\ [])
      when is_binary(home) and home != "" and is_binary(code_text) and is_list(opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with {:ok, code} <- EnrollmentCode.decode(code_text),
         :ok <- not_expired(code, now),
         {:ok, destination} <- given_destination(Keyword.get(opts, :destination)),
         {:ok, instance} <- given_instance(Keyword.get(opts, :instance)),
         {:ok, found} <- fresh(home, Keyword.take(opts, [:hello])) do
      consume = Keyword.get(opts, :consume, fn -> :ok end)
      enroll_into(found, home, {code, code_text}, destination, instance, now, consume)
    end
  end

  defp enroll_into(:replace, home, code, destination, instance, now, consume),
    do: replace_all(home, code, destination, instance, now, consume)

  defp enroll_into(created_home?, home, code, destination, instance, now, consume) do
    write_all(home, code, destination, instance, now, consume)
    |> undo_on_error(home, created_home?)
  end

  @doc "Reads `state.json`."
  @spec read_state(Path.t()) :: {:ok, state()} | {:error, term()}
  def read_state(home) do
    file = path(home, "state.json")

    with {:ok, contents} <- read_file(file),
         {:ok, %{"v" => @version, "phase" => phase} = state} when phase in @phases <-
           Jason.decode(contents) do
      {:ok, state}
    else
      {:error, {:file, _path, _reason}} = error -> error
      _invalid -> {:error, {:invalid_state, file}}
    end
  end

  @doc "Writes `state.json` whole (`0600`, renamed into place), with `updated_at`."
  @spec put_state(Path.t(), state(), DateTime.t()) :: :ok | {:error, term()}
  def put_state(home, %{"phase" => phase} = state, %DateTime{} = now) when phase in @phases do
    state =
      state
      |> Map.put("v", @version)
      |> Map.put("updated_at", now |> DateTime.truncate(:second) |> DateTime.to_iso8601())

    write_private(path(home, "state.json"), Jason.encode!(state))
  end

  @doc "The enrollment code the candidate holds until it is accepted."
  @spec read_code(Path.t()) :: {:ok, EnrollmentCode.t()} | {:error, term()}
  def read_code(home) do
    with {:ok, text} <- read_file(path(home, "code")), do: EnrollmentCode.decode(text)
  end

  @doc "Removes the code once the primary accepted the enrollment."
  @spec drop_code(Path.t()) :: :ok | {:error, term()}
  def drop_code(home) do
    case File.rm(path(home, "code")) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:file, path(home, "code"), reason}}
    end
  end

  @doc "The candidate's Noise static keypair."
  @spec noise_keypair(Path.t()) :: {:ok, keypair()} | {:error, term()}
  def noise_keypair(home) do
    with {:ok, <<_::256>> = private} <- read_file(path(home, "noise_key")) do
      {public, ^private} = :crypto.generate_key(:ecdh, :x25519, private)
      {:ok, %{private: private, public: public}}
    else
      {:ok, _other} -> {:error, {:invalid_key, path(home, "noise_key")}}
      {:error, _reason} = error -> error
    end
  end

  @doc "The one-time snapshot recipient, with its private half."
  @spec recipient_pair(Path.t()) :: {:ok, Recipient.pair()} | {:error, term()}
  def recipient_pair(home) do
    file = path(home, "recipient_key")

    with {:ok, <<salt::binary-size(16), secret::binary-size(32)>>} <- read_file(file) do
      {public, ^secret} = :crypto.generate_key(:ecdh, :x25519, secret)
      {:ok, %{salt: salt, public_key: public, secret_key: secret}}
    else
      {:ok, _other} -> {:error, {:invalid_key, file}}
      {:error, _reason} = error -> error
    end
  end

  @doc "The destination facts (`destination.json`): `%{}` or the bucket and region."
  @spec destination(Path.t()) :: {:ok, map()} | {:error, term()}
  def destination(home) when is_binary(home), do: read_json(path(home, "destination.json"))

  @doc "The instance facts (`instance.json`): `%{}` or what the host said of itself."
  @spec instance(Path.t()) :: {:ok, map()} | {:error, term()}
  def instance(home) when is_binary(home), do: read_json(path(home, "instance.json"))

  @doc "See `FermixCore.Home.Candidate.Activation.finish_activation/1`."
  @spec finish_activation(Path.t()) :: :ok | {:error, term()}
  def finish_activation(home), do: Activation.finish_activation(home)

  @doc "The sentence a person is shown for a refusal of this module."
  @spec error_sentence(term()) :: String.t()
  def error_sentence({:invalid_code, what}),
    do: "That is not an enrollment code Fermix opened (#{what}). Copy the code again."

  def error_sentence({:code_expired, at}),
    do:
      "The enrollment code expired at #{DateTime.to_iso8601(at)}. Get a new code from the " <>
        "primary's Always On and enroll with it."

  def error_sentence(:primary_epoch),
    do:
      "This home has run as a primary (it holds a primary epoch), so it cannot become a candidate."

  def error_sentence(:moved),
    do: "This home carries a moved marker, so it cannot become a candidate."

  def error_sentence(:already_candidate),
    do:
      "This home is a candidate that enrolled already and waits for its move. A candidate " <>
        "that never enrolled is replaced by enrolling again; this one is not."

  def error_sentence(:daemon_running),
    do:
      "Fermix is running in this home: stop it first (fermix service stop), then enroll " <>
        "again with the new code."

  def error_sentence({:daemon_probe_failed, reason}),
    do:
      "Fermix could not tell whether it runs in this home (#{inspect(reason)}), so it enrolled nothing."

  def error_sentence({:not_fresh, entry}),
    do:
      "This home already holds #{entry}, more than a fresh install writes. A candidate " <>
        "starts from an empty home."

  def error_sentence({:invalid_destination, sentence}), do: sentence
  def error_sentence({:invalid_instance, sentence}), do: sentence
  def error_sentence({:invalid_state, file}), do: "#{file} is not a candidate state Fermix wrote."
  def error_sentence({:invalid_key, file}), do: "#{file} is not a key Fermix wrote."

  def error_sentence(:activation_unfinished),
    do:
      "This home was becoming the primary from a move, and its restored settings are not " <>
        "in place yet. Start it in the candidate role to finish the move."

  def error_sentence({:code_file, file, reason}),
    do:
      "The code file #{file} could not be removed (#{:file.format_error(reason)}), so " <>
        "nothing was enrolled."

  def error_sentence({:file, file, reason}),
    do: "#{file}: #{:file.format_error(reason)}."

  def error_sentence(other), do: "The candidate's files could not be used: #{inspect(other)}."

  # -- enroll -----------------------------------------------------------------

  defp not_expired(%{expires_at: at}, now) do
    if DateTime.compare(at, now) == :gt, do: :ok, else: {:error, {:code_expired, at}}
  end

  defp given_destination(nil), do: {:ok, %{}}

  defp given_destination(%{"s3_bucket" => bucket, "s3_region" => region} = facts) do
    if EnrollmentCode.printable?(bucket) and EnrollmentCode.printable?(region),
      do: {:ok, Map.take(facts, ["s3_bucket", "s3_region"])},
      else:
        {:error,
         {:invalid_destination, "The snapshot bucket and region are text of 1 to 128 bytes."}}
  end

  defp given_instance(nil), do: {:ok, %{}}

  defp given_instance(%{} = facts) do
    optional = Map.take(facts, @optional_instance_fields)

    if Enum.all?(@instance_fields, &EnrollmentCode.printable?(Map.get(facts, &1))) and
         Enum.all?(Map.values(optional), &EnrollmentCode.printable?/1),
       do: {:ok, Map.merge(Map.take(facts, @instance_fields), optional)},
       else:
         {:error,
          {:invalid_instance,
           "The instance file must hold provider, instance_id and region, and may hold " <>
             "account_id, each text of 1 to 128 bytes."}}
  end

  # A fresh install writes nothing a move would carry: every top-level entry
  # must be device-local. The primary epoch, the marker and an existing
  # candidate are named on their own, before the general rule.
  defp fresh(home, probe) do
    case File.ls(home) do
      {:ok, entries} -> fresh_entries(home, Enum.sort(entries), probe)
      {:error, :enoent} -> {:ok, true}
      {:error, reason} -> {:error, {:file, home, reason}}
    end
  end

  defp fresh_entries(home, entries, probe) do
    cond do
      Epoch.read(home) != :absent -> {:error, :primary_epoch}
      Moved.read(home) != :absent -> {:error, :moved}
      @dir in entries -> replaceable(home, entries, probe)
      true -> device_local_only(entries)
    end
  end

  # A candidate that never enrolled holds nothing a primary knows of: no
  # primary lists it, and its code is spent or was refused. It is replaced
  # only while no engine runs in the home, whose candidate process would
  # otherwise go on writing the old one's state.
  defp replaceable(home, entries, probe) do
    with {:ok, %{"phase" => phase}} when phase in ~w(enrolling failed) <- read_state(home),
         {:ok, _found} <- device_local_only(entries -- [@dir, "config.toml"]),
         :ok <- DaemonProbe.stopped(home, probe) do
      {:ok, :replace}
    else
      {:ok, %{"phase" => _enrolled}} -> {:error, :already_candidate}
      {:error, _reason} = error -> error
    end
  end

  defp device_local_only(entries) do
    case Enum.reject(entries, &DeviceLocal.excluded?/1) do
      [] -> {:ok, false}
      [entry | _rest] -> {:error, {:not_fresh, entry}}
    end
  end

  # Everything goes into a private sibling directory first and is renamed into
  # place whole, then the settings file is created; a failure removes what was
  # written (`undo_on_error/3`).
  defp write_all(home, {code, code_text}, destination, instance, now, consume) do
    building = Path.join(home, ".candidate-#{Base.encode16(:crypto.strong_rand_bytes(4))}")

    with :ok <- make_dir(home),
         :ok <- make_dir(building),
         :ok <- write_files(building, code, code_text, destination, instance, now),
         :ok <- rename(building, dir(home)),
         :ok <- create_config(home),
         :ok <- consume.() do
      {:ok, code}
    else
      {:error, reason} -> {:error, reason, building}
    end
  end

  # The new candidate is built beside the old, then swapped in; the old one is
  # put back if the swap or the last step fails, and removed once it held.
  defp replace_all(home, {code, code_text}, destination, instance, now, consume) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(4))
    building = Path.join(home, ".candidate-#{suffix}")
    aside = Path.join(home, ".candidate-replaced-#{suffix}")

    with :ok <- make_dir(building),
         :ok <- write_files(building, code, code_text, destination, instance, now),
         :ok <- rename(dir(home), aside),
         :ok <- swap_in(building, home, aside),
         :ok <- consumed(consume.(), home, aside) do
      _ = File.rm_rf(aside)
      {:ok, code}
    else
      {:error, _reason} = error ->
        _ = File.rm_rf(building)
        error
    end
  end

  defp swap_in(building, home, aside) do
    case rename(building, dir(home)) do
      :ok -> :ok
      {:error, _reason} = error -> put_back(home, aside, error)
    end
  end

  defp consumed(:ok, _home, _aside), do: :ok

  defp consumed({:error, _reason} = error, home, aside) do
    _ = File.rm_rf(dir(home))
    put_back(home, aside, error)
  end

  defp put_back(home, aside, error) do
    case rename(aside, dir(home)) do
      :ok ->
        error

      {:error, reason} ->
        raise "the candidate could not be put back from #{aside}: #{inspect(reason)}"
    end
  end

  defp write_files(building, code, code_text, destination, instance, now) do
    {_public, noise_private} = :crypto.generate_key(:ecdh, :x25519)
    recipient = Recipient.generate()

    state = %{
      "v" => @version,
      "phase" => "enrolling",
      "primary" => %{
        "name" => code.name,
        "gateway_pk" => Base.encode64(code.gateway_pk),
        "node_id" => code.node_id
      },
      "updated_at" => now |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    with :ok <- write_private(Path.join(building, "code"), String.trim(code_text)),
         :ok <- write_private(Path.join(building, "destination.json"), Jason.encode!(destination)),
         :ok <- write_private(Path.join(building, "instance.json"), Jason.encode!(instance)),
         :ok <- write_private(Path.join(building, "noise_key"), noise_private),
         :ok <-
           write_private(
             Path.join(building, "recipient_key"),
             recipient.salt <> recipient.secret_key
           ),
         :ok <- make_dir(Path.join(building, "mobile")),
         :ok <-
           write_private(
             Path.join([building, "mobile", "iroh_key"]),
             :crypto.strong_rand_bytes(32)
           ) do
      write_private(Path.join(building, "state.json"), Jason.encode!(state))
    end
  end

  defp create_config(home) do
    file = Path.join(home, "config.toml")

    with {:ok, io} <- open_exclusive(file) do
      written = IO.binwrite(io, @config_text)
      closed = File.close(io)

      with :ok <- written, :ok <- closed, do: file_op(File.chmod(file, @file_mode), file)
    end
  end

  defp open_exclusive(file) do
    case File.open(file, [:write, :exclusive, :binary]) do
      {:ok, io} -> {:ok, io}
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  defp undo_on_error({:ok, code}, _home, _created?), do: {:ok, code}

  defp undo_on_error({:error, reason, building}, home, created_home?) do
    _ = File.rm_rf(building)
    _ = File.rm_rf(dir(home))
    _ = File.rm(Path.join(home, "config.toml"))
    if created_home?, do: File.rmdir(home)
    {:error, reason}
  end

  defp make_dir(dir) do
    case File.mkdir(dir) do
      :ok -> file_op(File.chmod(dir, @dir_mode), dir)
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, {:file, dir, reason}}
    end
  end

  defp rename(from, to), do: file_op(File.rename(from, to), to)

  @doc false
  @spec write_private(Path.t(), iodata()) :: :ok | {:error, term()}
  def write_private(file, contents) do
    tmp = file <> ".tmp"

    with :ok <- file_op(File.write(tmp, contents), tmp),
         :ok <- file_op(File.chmod(tmp, @file_mode), tmp),
         :ok <- file_op(File.rename(tmp, file), file) do
      :ok
    else
      {:error, _reason} = error ->
        _ = File.rm(tmp)
        error
    end
  end

  defp read_file(file) do
    case File.read(file) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  defp read_json(file) do
    with {:ok, contents} <- read_file(file) do
      case Jason.decode(contents) do
        {:ok, %{} = map} -> {:ok, map}
        _other -> {:error, {:invalid_state, file}}
      end
    end
  end

  defp file_op(:ok, _path), do: :ok
  defp file_op({:error, reason}, path), do: {:error, {:file, path, reason}}
end
