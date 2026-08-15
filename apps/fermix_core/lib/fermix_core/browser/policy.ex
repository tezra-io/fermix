defmodule FermixCore.Browser.Policy do
  @moduledoc false

  alias FermixCore.Browser.Config
  alias FermixCore.Browser.Error

  @unsafe_schemes ~w(file ftp data javascript)

  # Suffix blocks, deliberately DNS-free. `.internal` alone kills
  # metadata.google.internal — the highest-value target on the list — without
  # making URL validation depend on a resolver, which would make this suite
  # host-dependent and turn a DNS-less runner red. An operator who genuinely
  # needs one of these names lists it in `allowed_hosts`, which is matched first.
  @internal_suffixes ~w(.internal .local .localhost)

  # Canonical or refused — there is no third answer. Fermix vets the host
  # `URI.parse/1` produced; Chrome fetches the host the WHATWG parser produced.
  # Those two agree only over ASCII letters, digits, `-`, `.` and `_`, plus an
  # address literal (which `:inet.parse_address/1` validates itself). Outside
  # that alphabet they name different machines: `%69` decodes to `i`, UTS-46 maps
  # U+FF0E / fullwidth / circled / ligatures and DELETES soft hyphen, and `\`
  # ends the authority for a special scheme, so `169.254.169.254\.example.com`
  # reads as a subdomain of example.com here and reaches the metadata endpoint
  # there. Replicating those rules needs IDNA, which is not in OTP and is not a
  # dependency we will take; approximating them is how `.internal.` got in.
  #
  # `_` stays IN the alphabet: Chrome preserves it verbatim, it appears in real
  # service names, and a verbatim character creates no aliasing.
  @host_chars ~c"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"

  # The read allow-list, in the words the model reads. `read_blocked` says the
  # host is refused and "navigate somewhere allowed" is the fix; this says the
  # document is not the kind of thing this tool reads at all, and the fix is a
  # different tool entirely. Telling the model the wrong recovery is how it burns
  # iterations against a `file://` tab.
  @read_origin_message "for the browser tool, which reads http and https pages (and " <>
                         "about:blank). Read local files with the file tools instead."

  @spec validate_url(String.t(), Config.t()) :: {:ok, URI.t()} | {:error, Error.t()}
  def validate_url("about:blank", %Config{}), do: {:ok, URI.parse("about:blank")}

  def validate_url(url, %Config{} = config) when is_binary(url) do
    uri = URI.parse(url)

    with :ok <- validate_scheme(uri),
         :ok <- validate_authority(uri),
         :ok <- validate_host(uri, config) do
      {:ok, uri}
    end
  rescue
    _error -> blocked(url, "Invalid URL")
  end

  def validate_url(_url, _config), do: blocked("", "url must be a string")

  # The one canonical spelling of a host, or a refusal — computed once, before
  # anything classifies it. The alphabet check runs on the RAW host, BEFORE
  # `String.downcase/1`: casing a string we are about to refuse invites Unicode
  # case-folding surprises, and once it passes, downcasing is pure ASCII and
  # total.
  #
  # A trailing dot is the DNS root anchor: `metadata.google.internal.` and
  # `169.254.169.254.` name exactly the hosts their undotted spellings name, and
  # Chrome reaches both — the WHATWG parser drops the empty final label. Left in
  # place it defeated every control here at once. An address LITERAL is not
  # root-anchorable — `:inet.parse_address/1` rejects the dot and so does Chrome
  # — so it is answered by the parser alone and never trimmed.
  @spec canonical_host(String.t()) :: {:ok, String.t()} | :error
  def canonical_host(host) when is_binary(host) do
    cond do
      String.contains?(host, ":") -> ip_literal(host)
      ascii_host?(host) -> trimmed(String.downcase(host))
      true -> :error
    end
  end

  # THE host rules, on a host STRING: canonical gate, `allowed_hosts`, localhost,
  # the `.internal` suffixes, IPv4-in-IPv6 folding, the private ranges. No URL is
  # built. A read gate already holds the host, and a parse → serialise → reparse
  # round trip is exactly where the next bypass lives.
  #
  # Ordering is load-bearing: canonicalise → refuse-or-classify → `allowed_hosts`
  # → localhost → literal/name. The canonical gate is upstream of `allowed_hosts`
  # because that membership test is string equality, which is only sound when
  # both sides live in one alphabet.
  @spec host_verdict(String.t(), Config.t()) :: :ok | {:error, Error.t()}
  def host_verdict(host, %Config{} = config) when is_binary(host) do
    case canonical_host(host) do
      {:ok, canonical} -> classify_host(canonical, config)
      :error -> non_canonical(host)
    end
  end

  # THE read question, on a document URL: the scheme allow-list first, the host
  # rules second. Written as an allow-list on purpose — the shipped gate asked
  # "does this URL have a host?" and allowed everything that did not, which is a
  # deny-list on the host dimension with no opinion at all on the scheme
  # dimension, so `file:`, `view-source:`, `filesystem:`, `data:` and
  # `blob:null/` all read.
  #
  # `about:blank` is allowed: a managed profile opens on it, so refusing it
  # breaks the first `snapshot` after `start`. `about:srcdoc` is not path `blank`
  # and is refused.
  @spec read_verdict(String.t(), Config.t()) :: :ok | {:error, Error.t()}
  def read_verdict("blob:" <> inner, %Config{} = config) when is_binary(inner) do
    # A blob URL carries its creator's origin immediately after the scheme, so it
    # is unwrapped EXACTLY once — the URL spec nests exactly one level, and
    # `blob:blob:…` is therefore not a nesting but an unbounded recursion invite.
    # The inner URL faces this same allow-list, so `blob:file:///…` and
    # `blob:null/…` are refused by the rows that refuse their inner documents.
    scheme_verdict(inner, config)
  end

  def read_verdict(url, %Config{} = config) when is_binary(url) do
    scheme_verdict(url, config)
  end

  defp scheme_verdict(url, %Config{} = config) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] ->
        read_host(host, config)

      %URI{scheme: "about", path: "blank"} ->
        :ok

      %URI{scheme: scheme} ->
        read_origin_blocked(scheme)
    end
  end

  defp read_host(host, %Config{} = config) when is_binary(host) and host != "" do
    case host_verdict(host, config) do
      :ok -> :ok
      {:error, %Error{} = error} -> read_blocked(host, error)
    end
  end

  defp read_host(_host, _config), do: read_origin_blocked(nil)

  defp read_blocked(host, %Error{} = error) do
    {:error,
     Error.new(
       "read_blocked",
       "Refused to return page content: the page is on #{host}, which the browser " <>
         "policy blocks (#{error.message}). Navigate somewhere allowed and read again.",
       error.details
     )}
  end

  defp read_origin_blocked(scheme) do
    {:error,
     Error.new(
       "read_origin_blocked",
       "Refused to return page content: #{origin_label(scheme)} is not a readable origin " <>
         @read_origin_message,
       %{"value" => scheme || "", "reason" => "scheme_not_readable"}
     )}
  end

  defp origin_label(nil), do: "a document with no scheme"
  defp origin_label(scheme), do: "a #{scheme}: document"

  defp ip_literal(host) do
    case parse_ip(host) do
      {:ok, _ip} -> {:ok, String.downcase(host)}
      :error -> :error
    end
  end

  defp ascii_host?(host) do
    host |> :binary.bin_to_list() |> Enum.all?(&(&1 in @host_chars))
  end

  defp trimmed(host) do
    case String.trim_trailing(host, ".") do
      "" -> :error
      canonical -> {:ok, canonical}
    end
  end

  defp validate_scheme(%URI{scheme: scheme}) when scheme in ["http", "https"], do: :ok
  defp validate_scheme(%URI{scheme: scheme}) when scheme in @unsafe_schemes, do: blocked(scheme)

  defp validate_scheme(%URI{scheme: nil}),
    do: blocked("", "URL must include http or https scheme")

  defp validate_scheme(%URI{scheme: scheme}),
    do: blocked(scheme, "Unsupported URL scheme: #{scheme}")

  # The alphabet gate is only as good as the bytes it is handed, and the host is
  # a SLICE of the authority — so the two parsers must first agree on where that
  # slice starts. They do not: `URI.parse/1` splits `userinfo` at the LAST `@`,
  # while WHATWG ends the authority at the FIRST `\` for a special scheme, before
  # any `@` is read. So `http://169.254.169.254\@example.com/` hands this module
  # host `example.com` — canonical, public, allowed — while Chrome fetches
  # `169.254.169.254`. The host alphabet cannot see it, because by then the
  # private host is sitting in `userinfo`.
  #
  # `\` is the WHOLE divergence here, not a sample of one: the other three bytes
  # that end a WHATWG authority (`/`, `?`, `#`) all end `URI.parse/1`'s authority
  # too, so none of them can survive into `uri.authority` to disagree about.
  # A URL carrying one is refused before any host is classified — the authority
  # names two machines, and there is no third answer for that either.
  defp validate_authority(%URI{authority: authority}) when is_binary(authority) do
    if String.contains?(authority, "\\"), do: non_canonical(authority), else: :ok
  end

  defp validate_authority(%URI{}), do: :ok

  defp validate_host(%URI{host: host}, _config) when host in [nil, ""] do
    blocked("", "URL must include a host")
  end

  defp validate_host(%URI{host: host}, %Config{} = config) do
    host_verdict(host, config)
  end

  # `allowed_hosts` is canonicalized by the same function as the URL's host —
  # both sides of a membership test must be spelled the same way. An entry that
  # is not canonical can never match anything, and `Config.validate/1` refuses
  # such an entry by name, so the drop here is unreachable through
  # `Config.current/0` and exists only for a hand-built struct.
  defp classify_host(host, %Config{} = config) when is_binary(host) do
    cond do
      host in canonical_allowed_hosts(config) -> :ok
      host == "localhost" -> :ok
      true -> classify_literal_or_name(host, config)
    end
  end

  defp canonical_allowed_hosts(%Config{allowed_hosts: allowed}) do
    Enum.flat_map(allowed, fn host ->
      case canonical_host(host) do
        {:ok, canonical} -> [canonical]
        :error -> []
      end
    end)
  end

  # An address literal is answered by the address rules and a name by the name
  # rules, never the other way round. Parsing first is what keeps the two
  # loopbacks symmetric: `::1` carries no dot, so under a name-first ordering
  # `internal_hostname?/1` refused it as a single-label name before the loopback
  # clause could speak, and an operator who set their own `allowed_hosts` lost
  # IPv6 loopback while keeping `127.0.0.1`.
  defp classify_literal_or_name(host, %Config{} = config) do
    case parse_ip(host) do
      {:ok, ip} -> validate_ip(host, fold_embedded_ipv4(ip), config)
      :error -> validate_name(host)
    end
  end

  defp validate_name(host) do
    if internal_hostname?(host),
      do: blocked(host, "Blocked internal hostname by browser policy"),
      else: :ok
  end

  # Fold every IPv4-in-IPv6 representation to its embedded IPv4 BEFORE policy
  # checks, otherwise the IPv4-mapped (::ffff:a.b.c.d), IPv4-compatible
  # (::a.b.c.d) and NAT64 (64:ff9b::a.b.c.d) forms of metadata/private hosts
  # slip past every IPv4 rule. Genuine IPv6 — including :: (unspecified) and
  # ::1 (loopback) — is left untouched.
  defp fold_embedded_ipv4({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: embedded_ipv4(hi, lo)
  defp fold_embedded_ipv4({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}), do: embedded_ipv4(hi, lo)
  defp fold_embedded_ipv4({0, 0, 0, 0, 0, 0, 0, 0} = ip), do: ip
  defp fold_embedded_ipv4({0, 0, 0, 0, 0, 0, 0, 1} = ip), do: ip
  defp fold_embedded_ipv4({0, 0, 0, 0, 0, 0, hi, lo}), do: embedded_ipv4(hi, lo)
  defp fold_embedded_ipv4(ip), do: ip

  defp embedded_ipv4(hi, lo) do
    {Bitwise.bsr(hi, 8), Bitwise.band(hi, 0xFF), Bitwise.bsr(lo, 8), Bitwise.band(lo, 0xFF)}
  end

  defp validate_ip(_host, {127, _, _, _}, _config), do: :ok
  defp validate_ip(_host, {0, 0, 0, 0, 0, 0, 0, 1}, _config), do: :ok

  defp validate_ip(host, ip, %Config{allow_private_network: false}) do
    if private_ip?(ip),
      do: blocked(host, "Blocked private network URL by browser policy"),
      else: :ok
  end

  defp validate_ip(_host, _ip, %Config{allow_private_network: true}), do: :ok

  defp parse_ip(host) do
    host
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, ip} -> {:ok, ip}
      {:error, _reason} -> :error
    end
  end

  # The unspecified address is a loopback alias on every stack that accepts it —
  # `http://[::]:11434` reaches a local Ollama — so it is blocked here even
  # though `fold_embedded_ipv4/1` leaves it intact. Genuine `::1` never reaches
  # this function: it is an address literal, so `validate_ip/3` answers it first
  # and allows it — deliberately, and under every `allowed_hosts` setting,
  # because looking at your own dev server is the point of the browser tool.
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b in 16..31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({100, b, _, _}) when b in 64..127, do: true
  defp private_ip?({0, _, _, _}), do: true
  defp private_ip?({a, _, _, _}) when a >= 224, do: true
  defp private_ip?({a, _, _, _, _, _, _, _}) when Bitwise.band(a, 0xFE00) == 0xFC00, do: true
  defp private_ip?({a, _, _, _, _, _, _, _}) when Bitwise.band(a, 0xFFC0) == 0xFE80, do: true
  # Deprecated site-local fec0::/10. The 0xFE80 test above misses it entirely.
  defp private_ip?({a, _, _, _, _, _, _, _}) when Bitwise.band(a, 0xFFC0) == 0xFEC0, do: true
  defp private_ip?(_ip), do: false

  defp internal_hostname?(host) do
    not String.contains?(host, ".") or String.ends_with?(host, @internal_suffixes)
  end

  defp blocked(value, message \\ "Blocked URL by browser policy") do
    {:error, Error.new("navigation_blocked", message, %{"value" => value})}
  end

  # The message is the whole user-facing surface of the canonical rule and the
  # model is its primary reader, so it names the fix. It also repairs an
  # incoherence: `http://example%2ecom/` used to be refused as "Blocked internal
  # hostname", which is false.
  defp non_canonical(host) do
    {:error,
     Error.new(
       "navigation_blocked",
       "Refused an ambiguous host spelling: \"#{host}\". The browser policy accepts hosts " <>
         "spelled with ASCII letters, digits, '-', '.' and '_', or an IP address, because " <>
         "any other spelling is rewritten by the browser before the request is made and " <>
         "would be checked against the wrong host. Percent-escapes and non-ASCII characters " <>
         "are not accepted here — for an internationalised domain, use its punycode " <>
         "('xn--') spelling.",
       %{"value" => host, "reason" => "non_canonical_host"}
     )}
  end
end
