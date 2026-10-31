defmodule FermixCore.Home.Provision.Ledger do
  @moduledoc """
  The provisioner's one file for a host (M75 lean v1 §4.3):
  `<home>/device/provision/<host>.json`, holding the host's API token and the
  ledger of what Fermix created there.

  The token lives here and nowhere else: never a `config.toml` reference and
  never the keyring, because a move carries every keyring reference to the
  server and this credential must never go there. `device/` stays on this
  machine (`FermixCore.Home.DeviceLocal`: no archive, snapshot or move takes
  it) and the sandbox denies it to commands on both systems. The file is
  `0600` in a `0700` folder, written whole to a temporary file that is made
  owner-only before anything is written into it, then renamed, so a reader
  never sees half of one and the token is never readable by anyone else.
  The owner can remove it.

      {
        "v": 1,
        "token": "<the API token>",
        "token_state": "accepted",
        "connected_at": "2031-05-04T10:00:00Z",
        "ref": "a3f9",
        "server": {"name": "fermix-general-a3f9", "id": 61839204, "status": "created",
                   "type": "cpx22", "location": "fsn1", "ipv4": "203.0.113.7",
                   "power": "running", "created_at": "...", "seen_at": "..."},
        "firewall": {"name": "fermix-general-a3f9", "id": 1203, "status": "created"},
        "primary_ips": [{"id": 91, "type": "ipv4", "ip": "203.0.113.7"}],
        "failure": {"reason": "resource_unavailable", "sentence": "...",
                    "next_location": "nbg1", "at": "..."}
      }

  - `token_state` is `accepted` once the host accepted the token, `refused`
    once a later call was refused for it (the token stopped working).
  - `ref` is the short id (four hex digits) a create mints and every resource
    it makes is named and labelled by, so a lost create is found again by its
    labels; null when nothing was created.
  - A resource's `status` is `requested` (written before the call that
    creates it, with no id yet), `creating` (the host answered with an id and
    its action runs), `created`, `deleting` (written before the call that
    deletes it) or `gone` (deleted outside Fermix). A resource Fermix deleted
    leaves the ledger.
  - `failure` is why the last create stopped, in the daemon's words; null
    when nothing failed.

  The ledger is written before each call that creates or deletes and updated
  after it (`update/3`). Updates are serialised per file (a lock held only
  while reading and writing it, never across a call to the host), so two
  writers never lose each other's change.

  `state/1` is what `home.status`'s summary reads: one of `none`,
  `connected`, `creating`, `created` (the server exists and waits for its
  enrollment and move, which the summary reads elsewhere), `deleting`,
  `gone`, `failed` (with the failure) and `unreadable`, beside whether the
  token is accepted, and the server's facts. It never answers the token.
  """

  require Logger

  @version 1
  @dir_mode 0o700
  @file_mode 0o600
  # The lock is held only while one small file is read and written, so a few
  # tries are plenty; past them the update fails by name.
  @lock_retries 20
  @statuses ~w(requested creating created deleting gone)a
  @status_words Map.new(@statuses, &{Atom.to_string(&1), &1})
  @unreadable_sentence "Fermix could not read its Hetzner file, so it shows nothing it " <>
                         "created there; the daemon log says why."

  @type status :: :requested | :creating | :created | :deleting | :gone
  @type server :: %{
          name: String.t(),
          id: pos_integer() | nil,
          status: status(),
          type: String.t(),
          location: String.t(),
          ipv4: String.t() | nil,
          power: String.t() | nil,
          created_at: DateTime.t() | nil,
          seen_at: DateTime.t() | nil
        }
  @type firewall :: %{name: String.t(), id: pos_integer() | nil, status: status()}
  @type primary_ip :: %{id: pos_integer(), type: String.t(), ip: String.t() | nil}
  @type failure :: %{
          reason: String.t(),
          sentence: String.t(),
          next_location: String.t() | nil,
          at: DateTime.t()
        }
  @type t :: %{
          token: String.t() | nil,
          token_state: :accepted | :refused | nil,
          connected_at: DateTime.t() | nil,
          ref: String.t() | nil,
          server: server() | nil,
          firewall: firewall() | nil,
          primary_ips: [primary_ip()],
          failure: failure() | nil
        }
  @type state_view :: %{
          state:
            :none | :connected | :creating | :created | :deleting | :gone | :failed | :unreadable,
          token: :none | :accepted | :refused,
          server: map() | nil,
          failure: failure() | nil,
          sentence: String.t() | nil
        }

  @doc "Where the file for `host` lives under `home`."
  @spec path(Path.t(), String.t()) :: Path.t()
  def path(home, host) when is_binary(home) and home != "" and is_binary(host),
    do: Path.join([home, "device", "provision", host <> ".json"])

  @doc "A ledger with nothing in it: no token, nothing created."
  @spec empty() :: t()
  def empty do
    %{
      token: nil,
      token_state: nil,
      connected_at: nil,
      ref: nil,
      server: nil,
      firewall: nil,
      primary_ips: [],
      failure: nil
    }
  end

  @doc "The ledger for `host`: an empty one when the file is absent."
  @spec read(Path.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def read(home, host) when is_binary(home) and is_binary(host) do
    file = path(home, host)

    case File.read(file) do
      {:ok, json} -> decode(json, file)
      {:error, :enoent} -> {:ok, empty()}
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  @doc """
  Reads the ledger, hands it to `fun`, and writes what `fun` answers
  (`{:ok, ledger}`), all under the file's lock; `{:error, _}` from `fun` is
  answered as it is and writes nothing.
  """
  @spec update(Path.t(), String.t(), (t() -> {:ok, t()} | {:error, term()})) ::
          {:ok, t()} | {:error, term()}
  def update(home, host, fun) when is_binary(home) and is_binary(host) and is_function(fun, 1) do
    file = path(home, host)

    case :global.trans(
           {{__MODULE__, file}, self()},
           fn -> read_apply_write(home, host, fun) end,
           [node()],
           @lock_retries
         ) do
      :aborted -> {:error, {:locked, file}}
      result -> result
    end
  end

  defp read_apply_write(home, host, fun) do
    with {:ok, ledger} <- read(home, host),
         {:ok, changed} <- fun.(ledger),
         :ok <- write(path(home, host), changed) do
      {:ok, changed}
    end
  end

  # -- the transforms the provisioner writes through `update/3` ---------------

  @doc "The token the host just accepted, with when."
  @spec connect(t(), String.t(), DateTime.t()) :: t()
  def connect(ledger, token, %DateTime{} = now) when is_binary(token) and token != "",
    do: %{ledger | token: token, token_state: :accepted, connected_at: now}

  @doc "The host refused a call for the token it accepted before."
  @spec token_refused(t()) :: t()
  def token_refused(%{token: token} = ledger) when is_binary(token),
    do: %{ledger | token_state: :refused}

  @doc """
  A create begins under the short id `ref`: the last failure is dropped and
  the firewall, named for the server, is `requested`.
  """
  @spec begin_create(t(), String.t(), %{name: String.t()}) :: t()
  def begin_create(ledger, ref, %{name: name}) when is_binary(ref) and is_binary(name) do
    %{
      ledger
      | ref: ref,
        failure: nil,
        server: nil,
        firewall: %{name: name, id: nil, status: :requested},
        primary_ips: []
    }
  end

  @doc "Merges `attrs` into the server (one is made from them when there is none)."
  @spec put_server(t(), map()) :: t()
  def put_server(ledger, attrs) when is_map(attrs) do
    blank = %{id: nil, ipv4: nil, power: nil, created_at: nil, seen_at: nil}
    %{ledger | server: blank |> Map.merge(ledger.server || %{}) |> Map.merge(attrs)}
  end

  @doc "Merges `attrs` into the firewall (one is made from them when there is none)."
  @spec put_firewall(t(), map()) :: t()
  def put_firewall(ledger, attrs) when is_map(attrs),
    do: %{ledger | firewall: %{id: nil} |> Map.merge(ledger.firewall || %{}) |> Map.merge(attrs)}

  @doc "The primary addresses the server was given."
  @spec put_primary_ips(t(), [primary_ip()]) :: t()
  def put_primary_ips(ledger, ips) when is_list(ips), do: %{ledger | primary_ips: ips}

  @doc "Why the last create stopped, or nil."
  @spec put_failure(t(), failure() | nil) :: t()
  def put_failure(ledger, failure) when is_map(failure) or is_nil(failure),
    do: %{ledger | failure: failure}

  @doc "Removes a resource Fermix deleted (`:server` or `:firewall`)."
  @spec remove(t(), :server | :firewall) :: t()
  def remove(ledger, kind) when kind in [:server, :firewall], do: Map.put(ledger, kind, nil)

  @doc "Everything Fermix created is deleted: the token stays."
  @spec clear(t()) :: t()
  def clear(ledger),
    do: %{ledger | ref: nil, server: nil, firewall: nil, primary_ips: [], failure: nil}

  # -- the summary --------------------------------------------------------------

  @doc """
  What the summary reads for `host` (`"hetzner"` unless named): the state,
  whether the token is accepted, the server's facts and the last failure.
  An unreadable file is logged and answered `unreadable` with its sentence.
  """
  @spec state(Path.t(), String.t()) :: state_view()
  def state(home, host \\ "hetzner") when is_binary(home) and is_binary(host) do
    case read(home, host) do
      {:ok, ledger} ->
        %{
          state: derive(ledger),
          token: token_word(ledger),
          server: ledger.server,
          failure: ledger.failure,
          sentence: nil
        }

      {:error, reason} ->
        Logger.error("provision: #{path(home, host)} could not be read: #{inspect(reason)}")

        %{
          state: :unreadable,
          token: :none,
          server: nil,
          failure: nil,
          sentence: @unreadable_sentence
        }
    end
  end

  defp derive(%{token: nil}), do: :none

  defp derive(ledger) do
    cond do
      deleting?(ledger) -> :deleting
      ledger.failure != nil -> :failed
      creating?(ledger) -> :creating
      match?(%{status: :created}, ledger.server) -> :created
      match?(%{status: :gone}, ledger.server) -> :gone
      true -> :connected
    end
  end

  defp deleting?(ledger),
    do: Enum.any?([ledger.server, ledger.firewall], &match?(%{status: :deleting}, &1))

  defp creating?(%{ref: nil}), do: false
  defp creating?(%{server: nil}), do: true
  defp creating?(%{server: %{status: status}}), do: status in [:requested, :creating]

  defp token_word(%{token: nil}), do: :none
  defp token_word(%{token_state: :refused}), do: :refused
  defp token_word(_ledger), do: :accepted

  # -- the file ---------------------------------------------------------------

  defp write(file, ledger) do
    tmp = file <> ".tmp"

    with :ok <- mkdir_private(Path.dirname(file)),
         :ok <- write_private(tmp, Jason.encode!(encode(ledger))),
         :ok <- rename(tmp, file) do
      :ok
    else
      {:error, _reason} = error ->
        _ = File.rm(tmp)
        error
    end
  end

  defp mkdir_private(dir) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(Path.dirname(dir), @dir_mode),
         :ok <- File.chmod(dir, @dir_mode) do
      :ok
    else
      {:error, reason} -> {:error, {:file, dir, reason}}
    end
  end

  # Owner-only before the token is written into it.
  defp write_private(tmp, contents) do
    _ = File.rm(tmp)

    case File.open(tmp, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        result = chmod_and_write(io, tmp, contents)
        :ok = File.close(io)
        result

      {:error, reason} ->
        {:error, {:file, tmp, reason}}
    end
  end

  defp chmod_and_write(io, tmp, contents) do
    with :ok <- File.chmod(tmp, @file_mode),
         :ok <- IO.binwrite(io, contents) do
      :ok
    else
      {:error, reason} -> {:error, {:file, tmp, reason}}
    end
  end

  defp rename(tmp, file) do
    case File.rename(tmp, file) do
      :ok -> :ok
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  defp encode(ledger) do
    %{
      "v" => @version,
      "token" => ledger.token,
      "token_state" => ledger.token_state && Atom.to_string(ledger.token_state),
      "connected_at" => iso(ledger.connected_at),
      "ref" => ledger.ref,
      "server" => ledger.server && encode_server(ledger.server),
      "firewall" => ledger.firewall && encode_firewall(ledger.firewall),
      "primary_ips" => Enum.map(ledger.primary_ips, &encode_ip/1),
      "failure" => ledger.failure && encode_failure(ledger.failure)
    }
  end

  defp encode_server(server) do
    %{
      "name" => server.name,
      "id" => server.id,
      "status" => Atom.to_string(server.status),
      "type" => server.type,
      "location" => server.location,
      "ipv4" => server.ipv4,
      "power" => server.power,
      "created_at" => iso(server.created_at),
      "seen_at" => iso(server.seen_at)
    }
  end

  defp encode_firewall(firewall),
    do: %{
      "name" => firewall.name,
      "id" => firewall.id,
      "status" => Atom.to_string(firewall.status)
    }

  defp encode_ip(ip), do: %{"id" => ip.id, "type" => ip.type, "ip" => ip.ip}

  defp encode_failure(failure) do
    %{
      "reason" => failure.reason,
      "sentence" => failure.sentence,
      "next_location" => failure.next_location,
      "at" => iso(failure.at)
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp decode(json, file) do
    with {:ok, %{"v" => @version} = map} <- Jason.decode(json),
         {:ok, ledger} <- decode_map(map) do
      {:ok, ledger}
    else
      _invalid -> {:error, {:invalid_ledger, file}}
    end
  end

  defp decode_map(map) do
    with {:ok, token} <- optional_text(map["token"]),
         {:ok, token_state} <- optional_word(map["token_state"], ~w(accepted refused)),
         {:ok, connected_at} <- optional_time(map["connected_at"]),
         {:ok, ref} <- optional_text(map["ref"]),
         {:ok, server} <- optional(map["server"], &decode_server/1),
         {:ok, firewall} <- optional(map["firewall"], &decode_firewall/1),
         {:ok, ips} <- decode_ips(map["primary_ips"]),
         {:ok, failure} <- optional(map["failure"], &decode_failure/1) do
      {:ok,
       %{
         token: token,
         token_state: token_state,
         connected_at: connected_at,
         ref: ref,
         server: server,
         firewall: firewall,
         primary_ips: ips,
         failure: failure
       }}
    end
  end

  defp decode_server(%{"name" => name, "status" => status} = map) when is_binary(name) do
    with {:ok, status} <- status(status),
         {:ok, id} <- optional_id(map["id"]),
         {:ok, type} <- text(map["type"]),
         {:ok, location} <- text(map["location"]),
         {:ok, ipv4} <- optional_text(map["ipv4"]),
         {:ok, power} <- optional_text(map["power"]),
         {:ok, created_at} <- optional_time(map["created_at"]),
         {:ok, seen_at} <- optional_time(map["seen_at"]) do
      {:ok,
       %{
         name: name,
         id: id,
         status: status,
         type: type,
         location: location,
         ipv4: ipv4,
         power: power,
         created_at: created_at,
         seen_at: seen_at
       }}
    end
  end

  defp decode_server(_map), do: :error

  defp decode_firewall(%{"name" => name, "status" => status} = map) when is_binary(name) do
    with {:ok, status} <- status(status),
         {:ok, id} <- optional_id(map["id"]) do
      {:ok, %{name: name, id: id, status: status}}
    end
  end

  defp decode_firewall(_map), do: :error

  defp decode_ips(ips) when is_list(ips) do
    decoded = Enum.map(ips, &decode_ip/1)

    if Enum.all?(decoded, &match?({:ok, _ip}, &1)),
      do: {:ok, Enum.map(decoded, fn {:ok, ip} -> ip end)},
      else: :error
  end

  defp decode_ips(_ips), do: :error

  defp decode_ip(%{"id" => id, "type" => type} = map)
       when is_integer(id) and id > 0 and type in ["ipv4", "ipv6"] do
    with {:ok, ip} <- optional_text(map["ip"]), do: {:ok, %{id: id, type: type, ip: ip}}
  end

  defp decode_ip(_map), do: :error

  defp decode_failure(%{"reason" => reason, "sentence" => sentence} = map)
       when is_binary(reason) and is_binary(sentence) do
    with {:ok, next} <- optional_text(map["next_location"]),
         {:ok, %DateTime{} = at} <- optional_time(map["at"]) do
      {:ok, %{reason: reason, sentence: sentence, next_location: next, at: at}}
    end
  end

  defp decode_failure(_map), do: :error

  defp optional(nil, _decode), do: {:ok, nil}
  defp optional(value, decode), do: decode.(value)

  defp status(word) do
    case Map.fetch(@status_words, word) do
      {:ok, status} -> {:ok, status}
      :error -> :error
    end
  end

  defp text(value) when is_binary(value) and value != "", do: {:ok, value}
  defp text(_value), do: :error

  defp optional_text(nil), do: {:ok, nil}
  defp optional_text(value), do: text(value)

  defp optional_word(nil, _words), do: {:ok, nil}

  defp optional_word(word, words) when is_binary(word),
    do: if(word in words, do: {:ok, String.to_existing_atom(word)}, else: :error)

  defp optional_word(_word, _words), do: :error

  defp optional_id(nil), do: {:ok, nil}
  defp optional_id(id) when is_integer(id) and id > 0, do: {:ok, id}
  defp optional_id(_id), do: :error

  defp optional_time(nil), do: {:ok, nil}

  defp optional_time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, 0} -> {:ok, at}
      _invalid -> :error
    end
  end

  defp optional_time(_text), do: :error
end
