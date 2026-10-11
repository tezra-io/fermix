defmodule FermixChannels.Mobile.Attestation do
  @moduledoc """
  Verifies the Android key attestation a phone presents with its
  `pair_request` (M51 D3, section 6.2), before the owner is asked.

  `verify/3` is pure: it takes the evidence, the trust inputs and the time, and
  returns the facts the owner is shown or the one check that failed. The checks
  run in order: the platform; the chain to a pinned Google root, every other
  certificate valid at the given time; the attested key is the handshake key; a
  KeyMint key generated in secure hardware for key agreement; the challenge of
  this pairing window; a locked bootloader with verified boot; the official
  app; no certificate on Google's status list.

  The trust inputs live in the export directory,
  `fermix_core/priv/mobile/attestation_roots.json` and `android_signers.json`,
  and are embedded when this module compiles (`roots/0`, `signers/0`): a
  daemon never reads them, and a file that does not parse or a root that does
  not hash to its digest fails the build. Google's status list is fetched by
  `fetch_status_list/1` through the guarded client; the pairing manager owns
  when it is fetched and how long it is used.
  """

  require Record

  alias FermixCore.Net.Egress
  alias FermixCore.Net.Guard
  alias FermixCore.Net.TimeoutPolicy

  @hrl "public_key/include/public_key.hrl"
  Record.defrecordp(:cert, :OTPCertificate, Record.extract(:OTPCertificate, from_lib: @hrl))
  Record.defrecordp(:tbs, :OTPTBSCertificate, Record.extract(:OTPTBSCertificate, from_lib: @hrl))

  Record.defrecordp(
    :spki,
    :OTPSubjectPublicKeyInfo,
    Record.extract(:OTPSubjectPublicKeyInfo, from_lib: @hrl)
  )

  @challenge_label "fermix-mobile-attest-v1"
  @key_description_oid {1, 3, 6, 1, 4, 1, 11_129, 2, 1, 17}
  @x25519 {1, 3, 101, 110}
  @max_certificates 6
  @first_keymint_version 100
  @security_levels %{1 => :trusted_environment, 2 => :strongbox}
  # KeyMint's values: origin GENERATED, purpose AGREE_KEY, algorithm EC,
  # curve CURVE_25519, boot state Verified.
  @origin_generated 0
  @purpose_agree_key 6
  @algorithm_ec 3
  @curve_25519 4
  @boot_verified 0

  # The tags of an AuthorizationList this verifier reads; every other tag is
  # skipped.
  @authorizations [
    purposes: 1,
    algorithm: 2,
    ec_curve: 10,
    origin: 702,
    root_of_trust: 704,
    application: 709
  ]
  @universal 0
  @context 2
  @max_elements 128
  @max_tag_bytes 4
  @max_length_bytes 4
  @max_integer_bytes 9

  @status_host "android.googleapis.com"
  @status_url "https://#{@status_host}/attestation/status"
  @status_errors [:status_list_missing, :status_list_stale, :status_list_wait_timeout]
  @max_status_list_bytes 2 * 1_024 * 1_024
  @max_status_age_ms 86_400_000
  @serial_format ~r/\A[a-f1-9][a-f0-9]*\z/
  @listed_statuses ~w(REVOKED SUSPENDED)
  @roles %{"development" => :development, "release" => :release}

  # The trust files, read here at compile time only. A root's certificate must
  # hash to the digest written beside it, and every signer is a SHA-256 digest
  # with a known role; anything else raises and fails the build.
  @trust_dir Path.expand("../../../../fermix_core/priv/mobile", __DIR__)
  @roots_path Path.join(@trust_dir, "attestation_roots.json")
  @signers_path Path.join(@trust_dir, "android_signers.json")
  @external_resource @roots_path
  @external_resource @signers_path

  %{"roots" => [_first_root | _other_roots] = root_entries} =
    @roots_path |> File.read!() |> Jason.decode!()

  @roots Enum.map(root_entries, fn %{"pem" => pem, "sha256" => digest} ->
           [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(pem)

           if Base.encode16(:crypto.hash(:sha256, der), case: :lower) != digest,
             do: raise("attestation_roots.json: a root does not hash to #{digest}")

           %{der: der, otp: :public_key.pkix_decode_cert(der, :otp)}
         end)

  %{"package" => <<_::binary>> = package, "signers" => [_first | _rest] = signer_entries} =
    @signers_path |> File.read!() |> Jason.decode!()

  @signers %{
    package: package,
    signers:
      Map.new(signer_entries, fn %{"role" => role, "sha256" => digest} ->
        <<_::256>> = bytes = Base.decode16!(digest, case: :lower)
        {bytes, Map.fetch!(@roles, role)}
      end)
  }

  @type role :: :development | :release
  @type check ::
          :platform
          | :chain
          | :key
          | :key_properties
          | :challenge
          | :root_of_trust
          | :application
          | :revocation
  @type reason :: :attestation | :attestation_unavailable | :platform_unsupported
  @typedoc "Why a check refused, for the log: a reason, never the phone's bytes."
  @type detail :: atom() | {atom(), term()}
  @type refusal :: %{reason: reason(), check: check(), detail: detail()}
  @type status_error :: :status_list_missing | :status_list_stale | :status_list_wait_timeout
  @type root :: %{der: binary(), otp: tuple()}

  @type evidence :: %{
          platform: String.t(),
          kind: String.t(),
          cert_lengths: [pos_integer()],
          chain: binary(),
          noise_pk: binary(),
          challenge: binary()
        }

  @type trust :: %{
          roots: [root()],
          package: String.t(),
          signers: %{binary() => role()},
          statuses: {:ok, MapSet.t(String.t())} | {:error, status_error()}
        }

  @type facts :: %{
          platform: String.t(),
          security_level: :trusted_environment | :strongbox,
          signer_role: role(),
          version_code: integer(),
          boot_state: :verified,
          device_locked: true
        }

  @doc "The challenge a phone's key must attest: SHA-256 of the label and the pairing secret."
  @spec challenge(binary()) :: binary()
  def challenge(secret) when is_binary(secret) and byte_size(secret) == 32,
    do: :crypto.hash(:sha256, @challenge_label <> secret)

  @doc """
  Verifies `evidence` against `trust` at `now`. A refusal names the check that
  failed and a detail for the log: the reader's own reason, or what
  `:public_key` raised (the exception's module, `:if_clause`, or `:asn1_exit`
  for its ASN.1 runtime's exit). A
  status list that cannot be used is `attestation_unavailable`, an iPhone or a
  mismatched kind `platform_unsupported`.
  """
  @spec verify(evidence(), trust(), DateTime.t()) :: {:ok, facts()} | {:error, refusal()}
  def verify(
        %{platform: platform, kind: kind, cert_lengths: lengths, chain: chain} = evidence,
        %{roots: roots, package: package, signers: signers} = trust,
        %DateTime{} = now
      )
      when is_binary(platform) and is_binary(kind) and is_list(lengths) and is_binary(chain) and
             is_binary(evidence.noise_pk) and is_binary(evidence.challenge) and is_list(roots) and
             is_binary(package) and is_map(signers) do
    with :ok <- check_platform(platform, kind),
         {:ok, [{_leaf_der, leaf} | _issuers] = certs} <- split_chain(lengths, chain),
         :ok <- check_chain(certs, roots, now),
         :ok <- check_key(leaf, evidence.noise_pk),
         {:ok, description} <- check_key_properties(leaf),
         :ok <- check_challenge(description, evidence.challenge),
         :ok <- check_root_of_trust(description),
         {:ok, role, version_code} <- check_application(description, package, signers),
         :ok <- check_revocation(certs, trust.statuses) do
      {:ok, facts(description, role, version_code)}
    end
  end

  @doc """
  Decodes a KeyMint KeyDescription. Fields are read by position; in an
  AuthorizationList only the tags this verifier uses are decoded, others are
  skipped, and a tag given twice is refused. Truncated, indefinite, oversized
  or non-minimal lengths and trailing bytes are refused.
  """
  @spec decode_key_description(binary()) :: {:ok, map()} | {:error, term()}
  def decode_key_description(bytes) when is_binary(bytes) do
    with {:ok, element} <- read_one(bytes),
         {:ok, fields} <- read_constructed(element, 16, 8) do
      description_fields(fields)
    end
  end

  @doc "Google's attestation roots, embedded from `attestation_roots.json`."
  @spec roots() :: [root(), ...]
  def roots, do: @roots

  @doc "The app's package and its signers' digests and roles, from `android_signers.json`."
  @spec signers() :: %{package: String.t(), signers: %{binary() => role()}}
  def signers, do: @signers

  @doc """
  The serials Google's status list names, lowercase hex. Every entry must be
  REVOKED or SUSPENDED (both refuse a pairing); a list off that format is
  refused whole.
  """
  @spec parse_status_list(binary()) :: {:ok, MapSet.t(String.t())} | {:error, term()}
  def parse_status_list(body) when is_binary(body) do
    with :ok <- within_status_list_size(body),
         {:ok, %{"entries" => entries}} when is_map(entries) <- Jason.decode(body),
         {:ok, serials} <- map_all(Map.to_list(entries), &listed_serial/1) do
      {:ok, MapSet.new(serials)}
    else
      {:ok, _other} -> {:error, :unexpected_status_list}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetches Google's status list through the guarded client, with the max-age
  its response allows (capped at a day). `:resolver` and `:request` stand in
  for DNS and the HTTP request.
  """
  @spec fetch_status_list(keyword()) ::
          {:ok, %{serials: MapSet.t(String.t()), max_age_ms: pos_integer()}} | {:error, term()}
  def fetch_status_list(opts \\ []) when is_list(opts) do
    with {:ok, pinned} <- pin_status_url(opts),
         {:ok, response} <- request_status_list(pinned, opts),
         {:ok, body} <- status_list_body(response),
         {:ok, max_age_ms} <- max_age(response),
         {:ok, serials} <- parse_status_list(body) do
      {:ok, %{serials: serials, max_age_ms: max_age_ms}}
    end
  end

  # -- checks ---------------------------------------------------------------

  defp check_platform("android", "android_keymint"), do: :ok

  defp check_platform(_platform, _kind),
    do: {:error, %{reason: :platform_unsupported, check: :platform, detail: :not_android}}

  defp split_chain(lengths, chain) do
    if length(lengths) in 1..@max_certificates and
         Enum.all?(lengths, &(is_integer(&1) and &1 > 0)) and
         Enum.sum(lengths) == byte_size(chain) do
      {ders, <<>>} = Enum.map_reduce(lengths, chain, &cut/2)
      decode_chain(ders)
    else
      refuse(:chain, :malformed_chain)
    end
  end

  defp cut(size, bytes) do
    <<der::binary-size(size), rest::binary>> = bytes
    {der, rest}
  end

  defp decode_chain(ders) do
    case map_all(ders, &decoded_pair/1) do
      {:ok, certs} -> {:ok, certs}
      {:error, failure} -> refuse(:chain, {:malformed_certificate, failure})
    end
  end

  defp decoded_pair(der) do
    with {:ok, otp} <- decode_certificate(der), do: {:ok, {der, otp}}
  end

  # A presented certificate with a pinned root's key is that root, perhaps an
  # older certificate of it: it is dropped and the pinned one anchors the path.
  defp check_chain(certs, roots, now) do
    pinned_keys = MapSet.new(roots, &public_key_info(&1.otp))

    presented =
      certs
      |> Enum.reverse()
      |> Enum.drop_while(fn {_der, otp} -> MapSet.member?(pinned_keys, public_key_info(otp)) end)
      |> Enum.reverse()

    with {:ok, anchor} <- anchor(presented, roots),
         :ok <- validate_path(anchor, presented) do
      check_validity(presented, now)
    end
  end

  defp anchor([], _roots), do: refuse(:chain, :only_roots)

  defp anchor(presented, roots) do
    {_der, top} = List.last(presented)

    case public_key(fn -> Enum.find(roots, &:public_key.pkix_is_issuer(top, &1.otp)) end) do
      {:ok, nil} -> refuse(:chain, :untrusted_root)
      {:ok, root} -> {:ok, root}
      {:error, failure} -> refuse(:chain, {:malformed_certificate, failure})
    end
  end

  defp validate_path(anchor, presented) do
    path = presented |> Enum.reverse() |> Enum.map(fn {der, _otp} -> der end)
    options = [verify_fun: {&path_event/3, nil}]

    case public_key(fn -> :public_key.pkix_path_validation(anchor.der, path, options) end) do
      {:ok, {:ok, _result}} -> :ok
      {:ok, {:error, {:bad_cert, reason}}} when is_atom(reason) -> refuse(:chain, reason)
      {:ok, {:error, {:bad_cert, _reason}}} -> refuse(:chain, :invalid_path)
      {:error, failure} -> refuse(:chain, {:malformed_certificate, failure})
    end
  end

  # :public_key judges dates by the host clock, so its expiry verdict is passed
  # over and check_validity/2 judges every certificate at `now` instead,
  # outside :public_key. These clauses are the events it documents; they hold
  # no logic of the verifier's.
  defp path_event(_cert, {:extension, _extension}, state), do: {:unknown, state}
  defp path_event(_cert, {:bad_cert, :cert_expired}, state), do: {:valid, state}
  defp path_event(_cert, {:bad_cert, reason}, _state), do: {:fail, reason}
  defp path_event(_cert, event, state) when event in [:valid, :valid_peer], do: {:valid, state}

  # Every presented certificate must be valid at `now`; the anchor is trusted
  # by its key, not its dates.
  defp check_validity(presented, now) do
    case map_all(presented, fn {_der, otp} -> valid_at(otp, now) end) do
      {:ok, _valid} -> :ok
      {:error, :not_valid_at_time} -> refuse(:revocation, :certificate_expired)
      {:error, reason} -> refuse(:chain, reason)
    end
  end

  defp valid_at(cert(tbsCertificate: tbs(validity: {:Validity, from, to})), now) do
    with {:ok, not_before} <- certificate_time(from),
         {:ok, not_after} <- certificate_time(to) do
      if DateTime.compare(now, not_before) != :lt and DateTime.compare(now, not_after) != :gt,
        do: {:ok, :valid},
        else: {:error, :not_valid_at_time}
    end
  end

  defp check_key(leaf, noise_pk) do
    case public_key_info(leaf) do
      spki(
        algorithm: {:PublicKeyAlgorithm, @x25519, _params},
        subjectPublicKey: {:ECPoint, ^noise_pk}
      ) ->
        :ok

      spki(algorithm: {:PublicKeyAlgorithm, @x25519, _params}) ->
        refuse(:key, :not_handshake_key)

      _other ->
        refuse(:key, :not_x25519)
    end
  end

  defp check_key_properties(leaf) do
    with {:ok, description} <- leaf_description(leaf),
         :ok <- keymint_version(description),
         :ok <- secure_hardware(description),
         :ok <- agreement_key(description.hardware) do
      {:ok, description}
    end
  end

  defp leaf_description(leaf) do
    case key_description(leaf) do
      {:ok, description} -> {:ok, description}
      {:error, :no_key_description} -> refuse(:key_properties, :no_key_description)
      {:error, :two_key_descriptions} -> refuse(:key_properties, :two_key_descriptions)
      {:error, malformed} -> refuse(:key_properties, {:malformed_key_description, malformed})
    end
  end

  defp keymint_version(%{attestation_version: version}) when version >= @first_keymint_version,
    do: :ok

  defp keymint_version(_description), do: refuse(:key_properties, :not_keymint)

  defp secure_hardware(%{attestation_security_level: level, keymint_security_level: level})
       when is_map_key(@security_levels, level),
       do: :ok

  defp secure_hardware(_description), do: refuse(:key_properties, :not_secure_hardware)

  defp agreement_key(%{origin: @origin_generated, purposes: [@purpose_agree_key]} = hardware) do
    if hardware.algorithm == @algorithm_ec and hardware.ec_curve == @curve_25519,
      do: :ok,
      else: refuse(:key_properties, :not_x25519_agreement)
  end

  defp agreement_key(%{origin: @origin_generated}),
    do: refuse(:key_properties, :not_agreement_only)

  defp agreement_key(_hardware), do: refuse(:key_properties, :not_generated)

  defp check_challenge(%{challenge: challenge}, challenge), do: :ok
  defp check_challenge(_description, _challenge), do: refuse(:challenge, :other_window)

  defp check_root_of_trust(%{hardware: %{root_of_trust: root_of_trust}}) do
    case root_of_trust do
      %{verified_boot_state: @boot_verified, device_locked: true} -> :ok
      %{device_locked: false} -> refuse(:root_of_trust, :unlocked)
      %{verified_boot_state: _state} -> refuse(:root_of_trust, :boot_not_verified)
      nil -> refuse(:root_of_trust, :no_root_of_trust)
    end
  end

  # The application id is software-enforced: KeyMint writes it from the
  # package manager's record of the app that made the key.
  defp check_application(%{software: %{application: %{} = application}}, package, signers) do
    with {:ok, version_code} <- package_version(application.packages, package),
         {:ok, role} <- signer_role(application.signature_digests, signers) do
      {:ok, role, version_code}
    end
  end

  defp check_application(_description, _package, _signers),
    do: refuse(:application, :no_application_id)

  defp package_version(packages, package) do
    case for({^package, version} <- packages, do: version) do
      [version] -> {:ok, version}
      [] -> refuse(:application, :other_package)
      _versions -> refuse(:application, :package_listed_twice)
    end
  end

  # Every signing certificate the app is signed with must be pinned, all under
  # one role.
  defp signer_role(digests, signers) do
    roles = digests |> Enum.map(&Map.get(signers, &1)) |> Enum.uniq()

    cond do
      roles == [] -> refuse(:application, :no_signer)
      nil in roles -> refuse(:application, :unknown_signer)
      length(roles) > 1 -> refuse(:application, :mixed_signers)
      true -> {:ok, hd(roles)}
    end
  end

  # Every presented certificate, root included, is looked up by its serial.
  defp check_revocation(certs, {:ok, serials}) do
    if Enum.any?(certs, fn {_der, otp} -> MapSet.member?(serials, serial_hex(otp)) end),
      do: refuse(:revocation, :revoked),
      else: :ok
  end

  defp check_revocation(_certs, {:error, reason}) when reason in @status_errors,
    do: {:error, %{reason: :attestation_unavailable, check: :revocation, detail: reason}}

  defp facts(description, role, version_code) do
    %{
      platform: "android",
      security_level: Map.fetch!(@security_levels, description.attestation_security_level),
      signer_role: role,
      version_code: version_code,
      boot_state: :verified,
      device_locked: true
    }
  end

  defp refuse(check, detail), do: {:error, %{reason: :attestation, check: check, detail: detail}}

  # -- certificates ---------------------------------------------------------

  defp decode_certificate(der), do: public_key(fn -> :public_key.pkix_decode_cert(der, :otp) end)

  # The one place :public_key reads a phone's bytes. What it raises on bytes
  # that are not a certificate, or on a decoded certificate it cannot handle,
  # is what mutated chains made it raise: MatchError, FunctionClauseError,
  # ArgumentError, CaseClauseError (its decoder on an empty named BIT STRING),
  # calendar's raw `:if_clause` (path validation on a day that does not
  # exist), and its ASN.1 runtime's exit `{:error, {:asn1, _}}`. The failure is
  # named by the exception's module, `:if_clause` or `:asn1_exit`, never by
  # the bytes.
  defp public_key(call) do
    {:ok, call.()}
  rescue
    error in [ArgumentError, CaseClauseError, FunctionClauseError, MatchError] ->
      {:error, error.__struct__}
  catch
    :error, :if_clause -> {:error, :if_clause}
    :exit, {:error, {:asn1, _reason}} -> {:error, :asn1_exit}
  end

  defp public_key_info(cert(tbsCertificate: tbs(subjectPublicKeyInfo: info))), do: info

  defp serial_hex(cert(tbsCertificate: tbs(serialNumber: serial))),
    do: serial |> Integer.to_string(16) |> String.downcase()

  defp key_description(cert(tbsCertificate: tbs(extensions: extensions))) do
    case for(
           {:Extension, @key_description_oid, _critical, value} <- List.wrap(extensions),
           do: value
         ) do
      [value] when is_binary(value) -> decode_key_description(value)
      [] -> {:error, :no_key_description}
      _values -> {:error, :two_key_descriptions}
    end
  end

  defp certificate_time({:utcTime, chars}) when is_list(chars) do
    case List.to_string(chars) do
      <<year::binary-size(2), _rest::binary>> = text when year >= "50" ->
        generalized_time("19" <> text)

      text ->
        generalized_time("20" <> text)
    end
  end

  defp certificate_time({:generalTime, chars}) when is_list(chars),
    do: generalized_time(List.to_string(chars))

  defp generalized_time(
         <<year::binary-4, month::binary-2, day::binary-2, hour::binary-2, minute::binary-2,
           second::binary-2, "Z">>
       ) do
    case NaiveDateTime.from_iso8601("#{year}-#{month}-#{day}T#{hour}:#{minute}:#{second}") do
      {:ok, naive} -> {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
      {:error, _reason} -> {:error, :malformed_validity}
    end
  end

  defp generalized_time(_text), do: {:error, :malformed_validity}

  # -- KeyDescription -------------------------------------------------------

  defp description_fields([
         version,
         level,
         keymint_version,
         keymint_level,
         challenge,
         _unique,
         software,
         hardware
       ]) do
    with {:ok, version} <- read_integer(version, 2),
         {:ok, level} <- read_integer(level, 10),
         {:ok, keymint_version} <- read_integer(keymint_version, 2),
         {:ok, keymint_level} <- read_integer(keymint_level, 10),
         {:ok, challenge} <- read_octets(challenge),
         {:ok, software} <- authorization_list(software),
         {:ok, hardware} <- authorization_list(hardware) do
      {:ok,
       %{
         attestation_version: version,
         attestation_security_level: level,
         keymint_version: keymint_version,
         keymint_security_level: keymint_level,
         challenge: challenge,
         software: software,
         hardware: hardware
       }}
    end
  end

  defp description_fields(_fields), do: {:error, :key_description_shape}

  defp authorization_list(element) do
    with {:ok, entries} <- read_constructed(element, 16, @max_elements),
         {:ok, tagged} <- tagged_entries(entries),
         {:ok, fields} <- map_all(@authorizations, &authorization(&1, tagged)) do
      {:ok, Map.new(fields)}
    end
  end

  defp tagged_entries(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn
      {@context, true, number, _content}, {:ok, tagged} when is_map_key(tagged, number) ->
        {:halt, {:error, {:duplicate_tag, number}}}

      {@context, true, number, content}, {:ok, tagged} ->
        {:cont, {:ok, Map.put(tagged, number, content)}}

      _entry, {:ok, _tagged} ->
        {:halt, {:error, :untagged_entry}}
    end)
  end

  defp authorization({field, tag}, tagged) when is_map_key(tagged, tag) do
    with {:ok, inner} <- read_one(Map.fetch!(tagged, tag)),
         {:ok, value} <- authorization_value(field, inner) do
      {:ok, {field, value}}
    else
      {:error, reason} -> {:error, {tag, reason}}
    end
  end

  defp authorization({field, _tag}, _tagged), do: {:ok, {field, nil}}

  defp authorization_value(:purposes, element) do
    with {:ok, values} <- read_constructed(element, 17, @max_elements) do
      map_all(values, &read_integer(&1, 2))
    end
  end

  defp authorization_value(:root_of_trust, element) do
    with {:ok, [_key, locked, state, _hash]} <- read_constructed(element, 16, 4),
         {:ok, locked} <- read_boolean(locked),
         {:ok, state} <- read_integer(state, 10) do
      {:ok, %{device_locked: locked, verified_boot_state: state}}
    else
      {:ok, _fields} -> {:error, :root_of_trust_shape}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorization_value(:application, element) do
    with {:ok, bytes} <- read_octets(element),
         {:ok, inner} <- read_one(bytes),
         {:ok, [packages, digests]} <- read_constructed(inner, 16, 2),
         {:ok, packages} <- read_constructed(packages, 17, @max_elements),
         {:ok, packages} <- map_all(packages, &package_info/1),
         {:ok, digests} <- read_constructed(digests, 17, @max_elements),
         {:ok, digests} <- map_all(digests, &read_octets/1) do
      {:ok, %{packages: packages, signature_digests: digests}}
    else
      {:ok, _fields} -> {:error, :application_shape}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorization_value(_integer_field, element), do: read_integer(element, 2)

  defp package_info(element) do
    with {:ok, [name, version]} <- read_constructed(element, 16, 2),
         {:ok, name} <- read_octets(name),
         {:ok, version} <- read_integer(version, 2) do
      {:ok, {name, version}}
    else
      {:ok, _fields} -> {:error, :package_info_shape}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- DER reader -----------------------------------------------------------
  #
  # An element is {class, constructed?, tag number, content}. Every read is
  # bounded by its input and by an element count.

  defp read_constructed({@universal, true, number, content}, number, max),
    do: read_elements(content, max)

  defp read_constructed(_element, _number, _max), do: {:error, :unexpected_element}

  defp read_integer({@universal, false, number, content}, number)
       when byte_size(content) in 1..@max_integer_bytes do
    size = bit_size(content)
    <<value::signed-size(size)>> = content
    {:ok, value}
  end

  defp read_integer(_element, _number), do: {:error, :unexpected_element}

  defp read_octets({@universal, false, 4, content}), do: {:ok, content}
  defp read_octets(_element), do: {:error, :unexpected_element}

  # DER writes TRUE as 0xFF; Keymaster on some phones wrote 0x01. Any other
  # byte is TRUE in BER, as Google's own verifier reads it.
  defp read_boolean({@universal, false, 1, <<0>>}), do: {:ok, false}
  defp read_boolean({@universal, false, 1, <<_true>>}), do: {:ok, true}
  defp read_boolean(_element), do: {:error, :unexpected_element}

  defp read_one(bytes) do
    case read_elements(bytes, 1) do
      {:ok, [element]} -> {:ok, element}
      {:ok, []} -> {:error, :truncated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_elements(bytes, max), do: read_elements(bytes, max, [])

  defp read_elements(<<>>, _max, elements), do: {:ok, Enum.reverse(elements)}
  defp read_elements(_bytes, 0, _elements), do: {:error, :too_many_elements}

  defp read_elements(bytes, max, elements) do
    case read_element(bytes) do
      {:ok, element, rest} -> read_elements(rest, max - 1, [element | elements])
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_element(<<class::2, constructed::1, 31::5, rest::binary>>) do
    with {:ok, number, rest} <- read_high_tag(rest, 0, 0),
         {:ok, content, rest} <- read_content(rest) do
      {:ok, {class, constructed == 1, number, content}, rest}
    end
  end

  defp read_element(<<class::2, constructed::1, number::5, rest::binary>>) do
    with {:ok, content, rest} <- read_content(rest) do
      {:ok, {class, constructed == 1, number, content}, rest}
    end
  end

  defp read_element(<<>>), do: {:error, :truncated}

  defp read_high_tag(<<0x80, _rest::binary>>, 0, _number), do: {:error, :non_minimal_tag}
  defp read_high_tag(_bytes, @max_tag_bytes, _number), do: {:error, :tag_too_large}

  defp read_high_tag(<<1::1, group::7, rest::binary>>, count, number),
    do: read_high_tag(rest, count + 1, number * 128 + group)

  defp read_high_tag(<<0::1, group::7, rest::binary>>, _count, number) do
    case number * 128 + group do
      tag when tag < 31 -> {:error, :non_minimal_tag}
      tag -> {:ok, tag, rest}
    end
  end

  defp read_high_tag(<<>>, _count, _number), do: {:error, :truncated}

  defp read_content(<<0::1, size::7, rest::binary>>), do: take(rest, size)
  defp read_content(<<0x80, _rest::binary>>), do: {:error, :indefinite_length}

  defp read_content(<<1::1, count::7, rest::binary>>) when count <= @max_length_bytes do
    case rest do
      <<first, _tail::binary>> when first == 0 -> {:error, :non_minimal_length}
      <<size::size(count)-unit(8), rest::binary>> when size >= 128 -> take(rest, size)
      <<_size::size(count)-unit(8), _rest::binary>> -> {:error, :non_minimal_length}
      _short -> {:error, :truncated}
    end
  end

  defp read_content(<<1::1, _count::7, _rest::binary>>), do: {:error, :length_too_large}
  defp read_content(<<>>), do: {:error, :truncated}

  defp take(bytes, size) when byte_size(bytes) >= size do
    <<content::binary-size(size), rest::binary>> = bytes
    {:ok, content, rest}
  end

  defp take(_bytes, _size), do: {:error, :truncated}

  # -- status list ----------------------------------------------------------

  defp within_status_list_size(body) when byte_size(body) <= @max_status_list_bytes, do: :ok
  defp within_status_list_size(_body), do: {:error, :status_list_too_large}

  defp listed_serial({serial, %{"status" => status}}) when status in @listed_statuses do
    if Regex.match?(@serial_format, serial),
      do: {:ok, serial},
      else: {:error, :malformed_serial}
  end

  defp listed_serial(_entry), do: {:error, :malformed_status_entry}

  # Resolved once and pinned: the connection goes to the validated address,
  # with the name kept for Host and TLS SNI.
  defp pin_status_url(opts) do
    case Guard.resolve_and_validate(@status_url, resolver: Keyword.get(opts, :resolver)) do
      {:ok, ip} -> {:ok, %{url: URI.to_string(%{URI.parse(@status_url) | host: ip_string(ip)})}}
      {:error, reason} -> {:error, {:status_list_unresolved, reason}}
    end
  end

  defp request_status_list(pinned, opts) do
    request = Keyword.get(opts, :request, &default_request/2)

    case request.(pinned, request_options()) do
      {:ok, %Req.Response{} = response} -> {:ok, response}
      {:error, error} -> {:error, {:status_list_request_failed, error}}
    end
  end

  defp default_request(pinned, options) do
    [method: :get, url: pinned.url]
    |> Keyword.merge(options)
    |> Req.new()
    |> Egress.attach(:direct)
    |> Req.request()
  end

  defp request_options do
    [
      redirect: false,
      retry: false,
      decode_body: false,
      receive_timeout: TimeoutPolicy.receive_timeout_for(:attestation_status),
      connect_options: [
        timeout: 3_000,
        transport_opts: [server_name_indication: String.to_charlist(@status_host)]
      ],
      headers: [{"host", @status_host}],
      into: &collect_status_chunk/2
    ]
  end

  defp collect_status_chunk({:data, data}, {request, %{body: body} = response}) do
    received = IO.iodata_length(body) + byte_size(data)

    if received > @max_status_list_bytes,
      do: {:halt, {request, Req.Response.put_private(response, :fermix_body_cap, received)}},
      else: {:cont, {request, %{response | body: IO.iodata_to_binary([body, data])}}}
  end

  defp status_list_body(%Req.Response{private: %{fermix_body_cap: _received}}),
    do: {:error, :status_list_too_large}

  defp status_list_body(%Req.Response{status: 200, body: body}) when is_binary(body),
    do: {:ok, body}

  defp status_list_body(%Req.Response{status: status}), do: {:error, {:status_list_http, status}}

  # The list is used for as long as Google's response says it may be cached,
  # and never longer than a day.
  defp max_age(response) do
    directives =
      response
      |> Req.Response.get_header("cache-control")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))

    if "no-store" in directives or "no-cache" in directives,
      do: {:error, :status_list_not_cacheable},
      else: max_age_directive(directives)
  end

  defp max_age_directive(directives) do
    case Enum.find_value(directives, &max_age_seconds/1) do
      nil -> {:error, :status_list_without_max_age}
      0 -> {:error, :status_list_not_cacheable}
      seconds -> {:ok, min(seconds * 1_000, @max_status_age_ms)}
    end
  end

  defp max_age_seconds("max-age=" <> seconds) do
    case Integer.parse(seconds) do
      {value, ""} when value >= 0 -> value
      _invalid -> nil
    end
  end

  defp max_age_seconds(_directive), do: nil

  defp ip_string({_a, _b, _c, _d} = ip), do: ip |> :inet.ntoa() |> to_string()

  defp ip_string({_a, _b, _c, _d, _e, _f, _g, _h} = ip),
    do: "[" <> (ip |> :inet.ntoa() |> to_string()) <> "]"

  # -- helpers --------------------------------------------------------------

  defp map_all(items, fun) do
    result =
      Enum.reduce_while(items, {:ok, []}, fn item, {:ok, values} ->
        case fun.(item) do
          {:ok, value} -> {:cont, {:ok, [value | values]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with {:ok, values} <- result, do: {:ok, Enum.reverse(values)}
  end
end
