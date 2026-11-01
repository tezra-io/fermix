defmodule FermixCore.Home.Candidate do
  @moduledoc """
  A candidate primary's own files (M75 §2, §7.1, B4): `<home>/candidate/`,
  device-local, `0700`, every file in it `0600`.

  `fermix home enroll` (`enroll/3`) makes a fresh home a candidate: it writes

    * `code`: the enrollment code, until the enrollment is accepted;
    * `destination.json`: the snapshot bucket and region the new primary
      writes to (`{}` when none was named);
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

  **A return** (Always On's move back to the computer the home left) writes
  the candidate beside that computer's moved home instead
  (`prepare_return/3`), with `"kind"` in `state.json`: `return` for one the
  server's move fills over the rail (the files above but the settings file,
  and `destination.json` empty: the server's settings name its snapshots
  already), `local` for one restored from a copy this computer holds
  (`state.json` alone). The home keeps its settings and its moved marker
  until the return's activation. It is refused unless this engine runs in
  the device role as a service that restarts itself, the home carries the
  marker and, for `return`, its desktop link, no move is under way here, and
  no candidate is under way: one that ended (`failed`, `expired`) is
  replaced. It is built in a private sibling directory renamed into place,
  and a builder a crash left is removed first.
  """

  alias FermixCore.Home.Candidate.Activation
  alias FermixCore.Home.DaemonProbe
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.DeviceLocal
  alias FermixCore.Home.EnrollmentCode
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Move
  alias FermixCore.Home.Moved
  alias FermixCore.Home.Role
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Management.Lifecycle

  @dir "candidate"
  @version 1
  @dir_mode 0o700
  @file_mode 0o600
  @phases ~w(enrolling enrolled receiving staged activating expired failed)
  @config_text ~s([fermix_core.engine]\nrole = "candidate"\n)
  @builder_prefix ".candidate-"
  @ended ~w(failed expired)

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
  `:destination` (`%{"s3_bucket" => b, "s3_region" => r}` or nil), `:now` (a `DateTime`),
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
         {:ok, found} <- fresh(home, Keyword.take(opts, [:hello])) do
      consume = Keyword.get(opts, :consume, fn -> :ok end)
      enroll_into(found, home, {code, code_text}, destination, now, consume)
    end
  end

  defp enroll_into(:replace, home, code, destination, now, consume),
    do: replace_all(home, code, destination, now, consume)

  defp enroll_into(created_home?, home, code, destination, now, consume) do
    write_all(home, code, destination, now, consume)
    |> undo_on_error(home, created_home?)
  end

  @doc """
  Writes a return's candidate beside the moved home at `home` (see the
  moduledoc): `{:return, code_text}` for one the server's move fills, from the
  manual enrollment code the server opened, or `{:local, from}` for one
  restored from a copy this computer holds of the server named `from`.
  Answers the state written. `opts`: `:now`, and the seams `:role` (this
  engine's, `Role.current/0`) and `:restarts_itself?`
  (`Lifecycle.restarts_itself?/0`).
  """
  @spec prepare_return(Path.t(), {:return, String.t()} | {:local, String.t()}, keyword()) ::
          {:ok, state()} | {:error, term()}
  def prepare_return(home, source, opts \\ [])
      when is_binary(home) and home != "" and is_tuple(source) and is_list(opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with :ok <- returnable_engine(opts),
         :ok <- returnable_home(home, source),
         {:ok, found} <- replaceable_return(home),
         {:ok, state} <- return_state(source, now),
         :ok <- remove_builders(home) do
      build_return(home, source, state, found)
    end
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
  def error_sentence({:invalid_state, file}), do: "#{file} is not a candidate state Fermix wrote."
  def error_sentence({:invalid_key, file}), do: "#{file} is not a key Fermix wrote."

  def error_sentence(:activation_unfinished),
    do:
      "This home was becoming the primary from a move, and its restored settings are not " <>
        "in place yet. Start it in the candidate role to finish the move."

  def error_sentence(:not_device),
    do:
      "Fermix does not run as a desktop of a server here, so there is nothing to move back " <>
        "from."

  def error_sentence(:not_supervised),
    do:
      "Fermix runs from a terminal here, so it could not start again on its own after the " <>
        "move back. Install it as a service first."

  def error_sentence(:not_moved),
    do: "This home never moved to a server, so there is nothing to move back."

  def error_sentence(:not_linked),
    do: "This computer is not linked to a server any more, so Fermix cannot move back from one."

  def error_sentence(:move_pending),
    do: "A move is under way on this computer; move back once it is done."

  def error_sentence(:candidate_present),
    do: "Fermix is already getting ready to move back to this computer."

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

  # -- prepare_return ---------------------------------------------------------

  defp returnable_engine(opts) do
    cond do
      Keyword.get_lazy(opts, :role, &Role.current/0) != :device ->
        {:error, :not_device}

      not Keyword.get_lazy(opts, :restarts_itself?, &Lifecycle.restarts_itself?/0) ->
        {:error, :not_supervised}

      true ->
        :ok
    end
  end

  defp returnable_home(home, source) do
    case Moved.read(home) do
      {:ok, _marker} -> linked_and_still(home, source)
      :absent -> {:error, :not_moved}
      {:error, _reason} = error -> error
    end
  end

  defp linked_and_still(home, {:return, _code}) do
    if File.regular?(DesktopLink.path(home)),
      do: no_move_here(home),
      else: {:error, :not_linked}
  end

  defp linked_and_still(home, {:local, _from}), do: no_move_here(home)

  defp no_move_here(home) do
    case Move.moving_to(home) do
      :none -> :ok
      {:ok, _name} -> {:error, :move_pending}
    end
  end

  # A candidate that ended holds nothing anyone waits for, so it is replaced.
  defp replaceable_return(home) do
    case read_state(home) do
      {:ok, %{"phase" => phase}} when phase in @ended -> {:ok, :replace}
      {:ok, _under_way} -> {:error, :candidate_present}
      {:error, {:file, _path, :enoent}} -> absent_candidate(home)
      {:error, _reason} = error -> error
    end
  end

  defp absent_candidate(home) do
    if present?(home), do: {:error, {:invalid_state, path(home, "state.json")}}, else: {:ok, :new}
  end

  defp return_state({:return, code_text}, now) when is_binary(code_text) do
    with {:ok, code} <- EnrollmentCode.decode(code_text),
         :ok <- not_expired(code, now) do
      {:ok,
       %{
         "v" => @version,
         "phase" => "enrolling",
         "kind" => "return",
         "primary" => primary_facts(code),
         "updated_at" => iso(now)
       }}
    end
  end

  defp return_state({:local, from}, now) when is_binary(from) and from != "",
    do:
      {:ok,
       %{
         "v" => @version,
         "phase" => "receiving",
         "kind" => "local",
         "primary" => %{"name" => from},
         "updated_at" => iso(now)
       }}

  defp remove_builders(home) do
    with {:ok, names} <- list_home(home) do
      names
      |> Enum.filter(&String.starts_with?(&1, @builder_prefix))
      |> Enum.reduce_while(:ok, fn name, :ok -> remove_builder(Path.join(home, name)) end)
    end
  end

  defp remove_builder(builder) do
    case File.rm_rf(builder) do
      {:ok, _removed} -> {:cont, :ok}
      {:error, reason, file} -> {:halt, {:error, {:file, file, reason}}}
    end
  end

  defp list_home(home) do
    case File.ls(home) do
      {:ok, names} -> {:ok, names}
      {:error, reason} -> {:error, {:file, home, reason}}
    end
  end

  defp build_return(home, source, state, found) do
    building = Path.join(home, @builder_prefix <> Base.encode16(:crypto.strong_rand_bytes(4)))

    result =
      with :ok <- make_dir(building),
           :ok <- write_return_files(building, source, state),
           :ok <- drop_ended(home, found),
           :ok <- rename(building, dir(home)) do
        {:ok, state}
      end

    _ = File.rm_rf(building)
    result
  end

  defp write_return_files(building, {:return, code_text}, state) do
    with :ok <- write_keys(building, code_text, %{}) do
      write_private(Path.join(building, "state.json"), Jason.encode!(state))
    end
  end

  defp write_return_files(building, {:local, _from}, state),
    do: write_private(Path.join(building, "state.json"), Jason.encode!(state))

  defp drop_ended(_home, :new), do: :ok

  defp drop_ended(home, :replace) do
    case File.rm_rf(dir(home)) do
      {:ok, _removed} -> :ok
      {:error, reason, file} -> {:error, {:file, file, reason}}
    end
  end

  defp primary_facts(code),
    do: %{
      "name" => code.name,
      "gateway_pk" => Base.encode64(code.gateway_pk),
      "node_id" => code.node_id
    }

  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # Everything goes into a private sibling directory first and is renamed into
  # place whole, then the settings file is created; a failure removes what was
  # written (`undo_on_error/3`).
  defp write_all(home, {code, code_text}, destination, now, consume) do
    building = Path.join(home, ".candidate-#{Base.encode16(:crypto.strong_rand_bytes(4))}")

    with :ok <- make_dir(home),
         :ok <- make_dir(building),
         :ok <- write_files(building, code, code_text, destination, now),
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
  defp replace_all(home, {code, code_text}, destination, now, consume) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(4))
    building = Path.join(home, ".candidate-#{suffix}")
    aside = Path.join(home, ".candidate-replaced-#{suffix}")

    with :ok <- make_dir(building),
         :ok <- write_files(building, code, code_text, destination, now),
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

  defp write_files(building, code, code_text, destination, now) do
    state = %{
      "v" => @version,
      "phase" => "enrolling",
      "primary" => primary_facts(code),
      "updated_at" => iso(now)
    }

    with :ok <- write_keys(building, code_text, destination) do
      write_private(Path.join(building, "state.json"), Jason.encode!(state))
    end
  end

  # The code and every key a candidate enrolls and receives a move with.
  defp write_keys(building, code_text, destination) do
    {_public, noise_private} = :crypto.generate_key(:ecdh, :x25519)
    recipient = Recipient.generate()

    with :ok <- write_private(Path.join(building, "code"), String.trim(code_text)),
         :ok <- write_private(Path.join(building, "destination.json"), Jason.encode!(destination)),
         :ok <- write_private(Path.join(building, "noise_key"), noise_private),
         :ok <-
           write_private(
             Path.join(building, "recipient_key"),
             recipient.salt <> recipient.secret_key
           ),
         :ok <- make_dir(Path.join(building, "mobile")) do
      write_private(Path.join([building, "mobile", "iroh_key"]), :crypto.strong_rand_bytes(32))
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
