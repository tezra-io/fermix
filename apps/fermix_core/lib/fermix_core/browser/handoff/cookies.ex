defmodule FermixCore.Browser.Handoff.Cookies do
  @moduledoc """
  The cookies a browser hand-off carries (M75 D18, B10), in the DevTools
  protocol's own shape (`Storage.getCookies` on the desktop,
  `Storage.setCookies` on the primary), so no Chrome file format is read or
  written on either side.

  **Selection** (`select/2`): each cookie whose domain one of the named sites
  covers (`Handoff.Sites`), tagged with that site. A partitioned cookie (one
  set inside another site's frame) stays: it is not the named site's own
  session.

  **The payload** (`encode/1`, `decode/3`): `{"cookies": [...]}`, each cookie
  its `site`, `name`, `value`, `domain`, `path`, `expires` (seconds since the
  epoch, `-1` for a session cookie), `httpOnly`, `secure` and, when Chrome
  named them, `sameSite`, `priority`, `sourceScheme` and `sourcePort`. The
  primary decodes it against the hand-off's own sites and count, so a cookie
  for a site the owner did not name is refused, not stored.

  **Expiry.** A stored cookie never outlives its hand-off: `set_params/2` caps
  its expiry at the hand-off's, and gives a session cookie that expiry, so it
  survives a browser restart until then and no longer. The sweeper deletes
  each one by its key at the hand-off's expiry whatever the site set since
  (`delete_params/1`).

  Pure.
  """

  alias FermixCore.Browser.Handoff.Sites

  @copied ~w(name value domain path expires httpOnly secure sameSite priority sourceScheme
             sourcePort)
  @same_site ~w(Strict Lax None)
  @priorities ~w(Low Medium High)
  @source_schemes ~w(Unset NonSecure Secure)
  # A cookie's name and value together are at most 4,096 bytes in Chrome.
  @max_cookie_bytes 4_096
  @max_path_bytes 1_024
  @max_cookies 10_000

  @typedoc "One cookie as the payload carries it (string keys, DevTools names, and `site`)."
  @type t :: %{String.t() => term()}

  @typedoc "What identifies a stored cookie: never its value."
  @type key :: %{String.t() => String.t()}

  @doc "The most cookies one hand-off carries."
  @spec max_cookies() :: pos_integer()
  def max_cookies, do: @max_cookies

  @doc "The cookies among `cookies` (as `Storage.getCookies` answers) that `sites` cover."
  @spec select([map()], [String.t()]) :: [t()]
  def select(cookies, sites) when is_list(cookies) and is_list(sites) do
    for %{"domain" => domain} = cookie when is_binary(domain) <- cookies,
        not partitioned?(cookie),
        site = Sites.site_for(sites, domain),
        is_binary(site),
        do: cookie |> Map.take(@copied) |> Map.put("site", site)
  end

  @doc "The payload of `cookies`."
  @spec encode([t()]) :: binary()
  def encode(cookies) when is_list(cookies), do: Jason.encode!(%{"cookies" => cookies})

  @doc """
  The cookies of `payload`, checked against the hand-off: exactly `count` of
  them, each well formed and belonging to one of `sites`.
  """
  @spec decode(binary(), [String.t()], pos_integer()) :: {:ok, [t()]} | {:error, term()}
  def decode(payload, sites, count)
      when is_binary(payload) and is_list(sites) and is_integer(count) and count > 0 and
             count <= @max_cookies do
    with {:ok, %{"cookies" => cookies}} when is_list(cookies) <- Jason.decode(payload),
         :ok <- same_count(length(cookies), count) do
      check_all(cookies, sites)
    else
      {:error, {:count_mismatch, _got, _declared}} = error -> error
      _invalid -> {:error, :invalid_payload}
    end
  end

  @doc "What the ledger keeps of a cookie: its site, domain, name and path."
  @spec key(t()) :: key()
  def key(cookie) when is_map(cookie), do: Map.take(cookie, ~w(site domain name path))

  @doc """
  The `Storage.setCookies` entry that stores `cookie` until at most
  `expires_at` (seconds since the epoch). A host-only cookie (a domain with no
  leading dot) is set by its address alone, so it stays host-only.
  """
  @spec set_params(t(), integer()) :: map()
  def set_params(cookie, expires_at) when is_map(cookie) and is_integer(expires_at) do
    cookie
    |> Map.take(~w(name value path httpOnly secure sameSite priority sourceScheme sourcePort))
    |> Map.merge(address(cookie["domain"], cookie["path"], cookie["secure"] == true))
    |> Map.put("expires", capped(cookie["expires"], expires_at))
  end

  @doc """
  The `Storage.setCookies` entry that deletes the cookie `key` identifies: the
  same name, domain and path, expired, from a secure address so a secure
  cookie is deleted too.
  """
  @spec delete_params(key()) :: map()
  def delete_params(%{"domain" => domain, "name" => name, "path" => path})
      when is_binary(domain) and is_binary(name) and is_binary(path) do
    %{"name" => name, "value" => "", "path" => path, "secure" => true, "expires" => 1}
    |> Map.merge(address(domain, path, true))
  end

  defp partitioned?(cookie), do: not is_nil(Map.get(cookie, "partitionKey"))

  defp same_count(count, count), do: :ok
  defp same_count(got, declared), do: {:error, {:count_mismatch, got, declared}}

  defp check_all(cookies, sites) do
    case Enum.find(cookies, &(not valid?(&1, sites))) do
      nil -> {:ok, Enum.map(cookies, &Map.take(&1, ["site" | @copied]))}
      cookie -> {:error, {:invalid_cookie, cookie_label(cookie)}}
    end
  end

  defp valid?(%{"site" => site, "domain" => domain} = cookie, sites)
       when is_binary(site) and is_binary(domain) do
    site in sites and Sites.covers?(site, domain) and name_and_value?(cookie) and
      attributes?(cookie) and optional_ok?(cookie)
  end

  defp valid?(_cookie, _sites), do: false

  defp name_and_value?(%{"name" => name, "value" => value}) do
    text?(name) and text?(value) and byte_size(name) + byte_size(value) <= @max_cookie_bytes
  end

  defp name_and_value?(_cookie), do: false

  defp attributes?(cookie) do
    path?(cookie["path"]) and is_number(cookie["expires"]) and is_boolean(cookie["httpOnly"]) and
      is_boolean(cookie["secure"])
  end

  defp optional_ok?(cookie) do
    optional?(cookie, "sameSite", &(&1 in @same_site)) and
      optional?(cookie, "priority", &(&1 in @priorities)) and
      optional?(cookie, "sourceScheme", &(&1 in @source_schemes)) and
      optional?(cookie, "sourcePort", &(is_integer(&1) and &1 >= -1 and &1 <= 65_535))
  end

  defp optional?(cookie, field, check) do
    case Map.fetch(cookie, field) do
      :error -> true
      {:ok, value} -> check.(value)
    end
  end

  defp text?(value), do: is_binary(value) and String.valid?(value)

  defp path?("/" <> _rest = path), do: byte_size(path) <= @max_path_bytes and String.valid?(path)
  defp path?(_path), do: false

  # Never the value: a refusal names the cookie by where it is from.
  defp cookie_label(%{"domain" => domain, "name" => name})
       when is_binary(domain) and is_binary(name),
       do: "#{name} for #{domain}"

  defp cookie_label(_cookie), do: "a cookie with no name or domain"

  defp address(domain, path, secure?) do
    host = String.trim_leading(domain, ".")
    url = %{"url" => "#{if secure?, do: "https", else: "http"}://#{host}#{path}"}
    if String.starts_with?(domain, "."), do: Map.put(url, "domain", domain), else: url
  end

  defp capped(expires, cap) when is_number(expires) and expires > 0, do: min(expires, cap)
  defp capped(_session, cap), do: cap
end
