defmodule FermixCore.Browser.Handoff.Ledger do
  @moduledoc """
  The primary's record of the cookies hand-offs stored in its owner profile
  (M75 D18): `<home>/browser/handoffs.json`, device-local like the profile it
  describes.

      {"version": 1,
       "handoffs": [
         {"handoff_id": "ho-5d2e", "from": "Studio Mac",
          "sites": ["news.example.org"],
          "stored_at": "2026-10-21T09:00:00Z", "expires_at": "2026-10-28T09:00:00Z",
          "cookies": [{"site": "news.example.org", "domain": ".news.example.org",
                       "name": "sid", "path": "/"}]}],
       "purge": [{"site": "mail.example.net", "domain": "mail.example.net",
                  "name": "pref", "path": "/"}]}

  Each cookie is kept by its key (domain, name and path) and the site it was
  handed off for; **never its value**: `record/2` refuses an entry carrying
  anything else. A cookie handed off again belongs to the newer hand-off, so
  the older one's expiry never deletes it.

  `purge` holds the keys of cookies already deleted (an expired or wiped
  hand-off's), to delete once more as the profile's next Chrome starts: a
  Chrome that was running when they were deleted may be stopped before it
  wrote the deletion to its profile (`Handoff.DevTools`). A key handed off
  again leaves it.

  Pure but for `read/1` and `write/2`, which keep the file `0600` and replace
  it whole (a temp file renamed into place).
  """

  @file_name "handoffs.json"
  @version 1
  @max_bytes 8_388_608
  @key_fields ~w(domain name path site)

  @type cookie_key :: %{String.t() => String.t()}
  @type entry :: %{
          handoff_id: String.t(),
          from: String.t(),
          sites: [String.t()],
          stored_at: DateTime.t(),
          expires_at: DateTime.t(),
          cookies: [cookie_key()]
        }
  @type t :: %{handoffs: [entry()], purge: [cookie_key()]}

  @doc "Where the ledger lives under `home`."
  @spec path(Path.t()) :: Path.t()
  def path(home) when is_binary(home), do: Path.join([home, "browser", @file_name])

  @doc "The ledger before any hand-off."
  @spec empty() :: t()
  def empty, do: %{handoffs: [], purge: []}

  @doc "The ledger under `home`; `empty/0` when no hand-off was ever stored."
  @spec read(Path.t()) :: {:ok, t()} | {:error, {:ledger_unreadable, term()}}
  def read(home) when is_binary(home) do
    file = path(home)

    case File.stat(file) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_bytes ->
        decode(File.read(file))

      {:ok, %File.Stat{}} ->
        {:error, {:ledger_unreadable, :not_a_ledger}}

      {:error, :enoent} ->
        {:ok, empty()}

      {:error, reason} ->
        {:error, {:ledger_unreadable, reason}}
    end
  end

  @doc "Writes `ledger` under `home`, mode `0600`."
  @spec write(Path.t(), t()) :: :ok | {:error, {:file, Path.t(), term()}}
  def write(home, %{handoffs: handoffs} = ledger) when is_binary(home) and is_list(handoffs) do
    file = path(home)
    tmp = file <> ".tmp"

    with :ok <- file_op(File.mkdir_p(Path.dirname(file)), Path.dirname(file)),
         :ok <- file_op(File.write(tmp, Jason.encode_to_iodata!(encode(ledger))), tmp),
         :ok <- file_op(File.chmod(tmp, 0o600), tmp) do
      file_op(File.rename(tmp, file), file)
    end
  end

  @doc """
  Records one stored hand-off. The cookies it carries leave every older
  entry, and an older entry left with none goes.
  """
  @spec record(t(), entry()) :: t()
  def record(%{handoffs: handoffs, purge: purge}, %{cookies: cookies} = entry)
      when is_list(cookies) do
    :ok = Enum.each(cookies, &key!/1)
    taken = MapSet.new(cookies, &identity/1)

    older =
      handoffs
      |> Enum.map(fn old ->
        %{old | cookies: Enum.reject(old.cookies, &(identity(&1) in taken))}
      end)
      |> Enum.reject(&(&1.cookies == []))

    %{handoffs: older ++ [entry], purge: Enum.reject(purge, &(identity(&1) in taken))}
  end

  @doc "Adds `keys` to the ones deleted again at the next Chrome start, each once."
  @spec retire(t(), [cookie_key()]) :: t()
  def retire(%{purge: purge} = ledger, keys) when is_list(keys) do
    :ok = Enum.each(keys, &key!/1)
    %{ledger | purge: Enum.uniq_by(purge ++ keys, &identity/1)}
  end

  @doc "The ledger with nothing left to delete again."
  @spec purged(t()) :: t()
  def purged(ledger), do: %{ledger | purge: []}

  @doc "The entries whose expiry is at or before `now`."
  @spec expired(t(), DateTime.t()) :: [entry()]
  def expired(%{handoffs: handoffs}, %DateTime{} = now),
    do: Enum.filter(handoffs, &(DateTime.compare(&1.expires_at, now) != :gt))

  @doc "The ledger without the entries `handoff_ids` names."
  @spec drop(t(), [String.t()]) :: t()
  def drop(%{handoffs: handoffs} = ledger, handoff_ids) when is_list(handoff_ids),
    do: %{ledger | handoffs: Enum.reject(handoffs, &(&1.handoff_id in handoff_ids))}

  @doc """
  Takes the cookies of `sites` (or of every hand-off, `:all`) out of the
  ledger: the keys taken, and the ledger left. An entry left with no cookie
  goes.
  """
  @spec take(t(), [String.t()] | :all) :: {[cookie_key()], t()}
  def take(%{handoffs: handoffs} = ledger, :all),
    do: {Enum.flat_map(handoffs, & &1.cookies), %{ledger | handoffs: []}}

  def take(%{handoffs: handoffs} = ledger, sites) when is_list(sites) do
    {taken, kept} =
      Enum.reduce(handoffs, {[], []}, fn entry, {taken, kept} ->
        {gone, stay} = Enum.split_with(entry.cookies, &(&1["site"] in sites))
        kept = if stay == [], do: kept, else: [%{entry | cookies: stay} | kept]
        {taken ++ gone, kept}
      end)

    {taken, %{ledger | handoffs: Enum.reverse(kept)}}
  end

  defp identity(key), do: {key["domain"], key["name"], key["path"]}

  defp key!(key) do
    if key?(key),
      do: :ok,
      else:
        raise(ArgumentError, "a ledger cookie is its domain, name, path and site, nothing else")
  end

  defp encode(%{handoffs: handoffs, purge: purge}) do
    %{
      "version" => @version,
      "purge" => purge,
      "handoffs" =>
        Enum.map(handoffs, fn entry ->
          %{
            "handoff_id" => entry.handoff_id,
            "from" => entry.from,
            "sites" => entry.sites,
            "stored_at" => iso(entry.stored_at),
            "expires_at" => iso(entry.expires_at),
            "cookies" => entry.cookies
          }
        end)
    }
  end

  defp decode({:ok, json}) do
    with {:ok, %{"version" => @version, "handoffs" => handoffs} = map} when is_list(handoffs) <-
           Jason.decode(json),
         {:ok, entries} <- decode_entries(handoffs),
         purge when is_list(purge) <- Map.get(map, "purge", []),
         true <- Enum.all?(purge, &key?/1) do
      {:ok, %{handoffs: entries, purge: purge}}
    else
      _invalid -> {:error, {:ledger_unreadable, :invalid}}
    end
  end

  defp decode({:error, reason}), do: {:error, {:ledger_unreadable, reason}}

  defp decode_entries(handoffs) do
    entries = Enum.map(handoffs, &decode_entry/1)
    if Enum.all?(entries, &is_map/1), do: {:ok, entries}, else: :error
  end

  defp decode_entry(%{
         "handoff_id" => id,
         "from" => from,
         "sites" => sites,
         "stored_at" => stored_at,
         "expires_at" => expires_at,
         "cookies" => cookies
       })
       when is_binary(id) and is_binary(from) and is_list(sites) and is_list(cookies) do
    with {:ok, stored_at, 0} <- DateTime.from_iso8601(stored_at),
         {:ok, expires_at, 0} <- DateTime.from_iso8601(expires_at),
         true <- Enum.all?(cookies, &key?/1) do
      %{
        handoff_id: id,
        from: from,
        sites: sites,
        stored_at: stored_at,
        expires_at: expires_at,
        cookies: cookies
      }
    else
      _invalid -> :error
    end
  end

  defp decode_entry(_entry), do: :error

  defp key?(key),
    do:
      is_map(key) and Enum.sort(Map.keys(key)) == Enum.sort(@key_fields) and
        Enum.all?(Map.values(key), &is_binary/1)

  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp file_op(:ok, _path), do: :ok
  defp file_op({:error, reason}, path), do: {:error, {:file, path, reason}}
end
