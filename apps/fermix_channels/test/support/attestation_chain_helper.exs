defmodule FermixChannels.Test.AttestationChain do
  @moduledoc """
  Synthesized Android key attestation chains for the pairing verifier's tests:
  a test root, an intermediate and a leaf carrying an X25519 key and a KeyMint
  KeyDescription extension (OID 1.3.6.1.4.1.11129.2.1.17), each signed with
  `:public_key`. Every field the verifier reads can be overridden, so each test
  builds exactly the chain it refuses. The test's root goes to the verifier as
  its trust input; production roots are never involved.
  """

  require Record

  @hrl "public_key/include/public_key.hrl"
  Record.defrecordp(
    :tbs,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: @hrl)
  )

  Record.defrecordp(
    :spki,
    :OTPSubjectPublicKeyInfo,
    Record.extract(:OTPSubjectPublicKeyInfo, from_lib: @hrl)
  )

  Record.defrecordp(:ext, :Extension, Record.extract(:Extension, from_lib: @hrl))

  @key_description_oid {1, 3, 6, 1, 4, 1, 11_129, 2, 1, 17}
  @ecdsa_sha256 {1, 2, 840, 10_045, 4, 3, 2}
  @package "io.tezra.fermix"

  @doc "The package the verifier accepts in these tests, as production does."
  def package, do: @package

  @doc "A signing-certificate digest the tests pin as the development key."
  def signer_digest, do: :crypto.hash(:sha256, "fermix test signer")

  @doc "A pairing secret, its challenge and a handshake static key."
  def pairing do
    secret = :crypto.strong_rand_bytes(32)
    {noise_pk, _private} = :crypto.generate_key(:ecdh, :x25519)

    %{
      secret: secret,
      challenge: :crypto.hash(:sha256, "fermix-mobile-attest-v1" <> secret),
      noise_pk: noise_pk
    }
  end

  @doc "A self-signed CA: its key, certificate DER and subject name."
  def root(opts \\ []) do
    key = ec_key()
    name = Keyword.get(opts, :name, "Fermix Test Attestation Root")
    validity = Keyword.get(opts, :validity, default_validity())
    der = sign(name, name, ec_spki(key), key, 1, validity, ca_extensions())
    %{key: key, der: der, name: name}
  end

  @doc """
  A chain, leaf first: leaf, intermediate, and the root unless
  `include_root: false`. Options override the leaf's key (`:noise_pk`), the
  extension (`:key_description`, or the fields `key_description/1` takes),
  the intermediate's validity and serial, and the issuing root. `rkp: true`
  adds the short-lived device certificate a remotely provisioned phone
  presents between its leaf and the Droid CA intermediate: four certificates.
  """
  def chain(pairing, opts \\ []) do
    root = Keyword.get_lazy(opts, :root, fn -> root() end)
    inter_key = ec_key()
    inter_validity = Keyword.get(opts, :intermediate_validity, default_validity())

    inter =
      sign(
        "Fermix Test Droid CA",
        root.name,
        ec_spki(inter_key),
        root.key,
        Keyword.get(opts, :intermediate_serial, 0x2C8CDDDFD5E03BFC),
        inter_validity,
        ca_extensions()
      )

    {issuers, issuer_key} = device_certificate(inter_key, opts)
    leaf = leaf(pairing, issuer_key, opts)
    tail = if Keyword.get(opts, :include_root, true), do: [root.der], else: []
    certs = [leaf | issuers] ++ [inter | tail]
    %{root: root, certs: certs, bytes: IO.iodata_to_binary(certs), lengths: lengths(certs)}
  end

  # The certificates between the leaf and the Droid CA, and the key that signs
  # the leaf: none for a factory-provisioned shape, one for a remotely
  # provisioned one (validity of days, P-256).
  defp device_certificate(inter_key, opts) do
    if Keyword.get(opts, :rkp, false) do
      device_key = ec_key()
      now = DateTime.utc_now()
      validity = {DateTime.add(now, -86_400), DateTime.add(now, 30 * 86_400)}

      device =
        sign(
          "Fermix Test Attestation Key",
          "Fermix Test Droid CA",
          ec_spki(device_key),
          inter_key,
          0x5EED,
          validity,
          ca_extensions()
        )

      {[device], device_key}
    else
      {[], inter_key}
    end
  end

  @doc "The bytes of the KeyDescription extension in a leaf certificate's DER."
  def key_description_bytes(der) do
    tbs(extensions: extensions) = der |> :public_key.pkix_decode_cert(:otp) |> elem(1)

    [value] =
      for ext(extnID: @key_description_oid, extnValue: value) <- extensions, do: value

    value
  end

  @doc "The evidence a socket hands the verifier for `chain` and `pairing`."
  def evidence(chain, pairing, overrides \\ %{}) do
    Map.merge(
      %{
        platform: "android",
        kind: "android_keymint",
        cert_lengths: chain.lengths,
        chain: chain.bytes,
        noise_pk: pairing.noise_pk,
        challenge: pairing.challenge
      },
      overrides
    )
  end

  @doc "Trust inputs naming the chain's root, the test signer and an empty status list."
  def trust(chain, overrides \\ %{}) do
    root = %{der: chain.root.der, otp: :public_key.pkix_decode_cert(chain.root.der, :otp)}

    Map.merge(
      %{
        roots: [root],
        package: @package,
        signers: %{signer_digest() => :development},
        statuses: {:ok, MapSet.new()}
      },
      overrides
    )
  end

  @doc """
  A KeyDescription as a KeyMint 3 TEE writes it for the app's agreement key:
  every field can be overridden, `:extra_hardware` appends further tagged
  entries and `:hardware`/`:software` replace the lists outright.
  """
  def key_description(pairing, opts \\ []) do
    sequence([
      integer(Keyword.get(opts, :attestation_version, 300)),
      enumerated(Keyword.get(opts, :attestation_level, 1)),
      integer(Keyword.get(opts, :keymint_version, 300)),
      enumerated(Keyword.get(opts, :keymint_level, 1)),
      octet(Keyword.get(opts, :challenge, pairing.challenge)),
      octet(<<>>),
      sequence(Keyword.get_lazy(opts, :software, fn -> software(opts) end)),
      sequence(Keyword.get_lazy(opts, :hardware, fn -> hardware(opts) end))
    ])
  end

  @doc "The software-enforced list: creation time and the application id."
  def software(opts \\ []) do
    [
      explicit(701, integer(1_760_000_000_000)),
      explicit(709, octet(application_id(opts)))
    ]
  end

  @doc "The hardware-enforced list a genuine phone's agreement key carries."
  def hardware(opts \\ []) do
    [
      explicit(1, set(Enum.map(Keyword.get(opts, :purposes, [6]), &integer/1))),
      explicit(2, integer(Keyword.get(opts, :algorithm, 3))),
      explicit(3, integer(256)),
      explicit(10, integer(Keyword.get(opts, :ec_curve, 4))),
      explicit(503, <<0x05, 0x00>>),
      explicit(702, integer(Keyword.get(opts, :origin, 0))),
      explicit(704, root_of_trust(opts)),
      explicit(705, integer(150_000)),
      explicit(706, integer(202_510)),
      explicit(724, octet(:crypto.hash(:sha256, "module")))
    ] ++ Keyword.get(opts, :extra_hardware, [])
  end

  @doc "RootOfTrust: boot key, locked, boot state, boot hash."
  def root_of_trust(opts \\ []) do
    sequence([
      octet(:binary.copy(<<7>>, 32)),
      boolean(Keyword.get(opts, :device_locked, true)),
      enumerated(Keyword.get(opts, :boot_state, 0)),
      octet(:binary.copy(<<9>>, 32))
    ])
  end

  @doc "AttestationApplicationId: package infos and signature digests."
  def application_id(opts \\ []) do
    packages = Keyword.get(opts, :packages, [{@package, 42}])
    digests = Keyword.get(opts, :signature_digests, [signer_digest()])

    sequence([
      set(
        Enum.map(packages, fn {name, version} -> sequence([octet(name), integer(version)]) end)
      ),
      set(Enum.map(digests, &octet/1))
    ])
  end

  @doc "One DER element. Tag numbers past 30 use the high-tag form."
  def der(class, constructed?, number, content) when is_binary(content) do
    class_bits = %{universal: 0, context: 2}[class]
    form = if constructed?, do: 1, else: 0
    tag(class_bits, form, number) <> der_length(byte_size(content)) <> content
  end

  def integer(value), do: der(:universal, false, 2, signed(value))
  def enumerated(value), do: der(:universal, false, 10, signed(value))
  def octet(bytes), do: der(:universal, false, 4, bytes)
  def boolean(true), do: der(:universal, false, 1, <<0xFF>>)
  def boolean(false), do: der(:universal, false, 1, <<0>>)
  def sequence(items), do: der(:universal, true, 16, IO.iodata_to_binary(items))
  def set(items), do: der(:universal, true, 17, IO.iodata_to_binary(items))
  def explicit(number, inner), do: der(:context, true, number, inner)

  defp leaf(pairing, issuer_key, opts) do
    noise_pk = Keyword.get(opts, :noise_pk, pairing.noise_pk)

    description =
      Keyword.get_lazy(opts, :key_description, fn -> key_description(pairing, opts) end)

    extensions =
      [ext(extnID: {2, 5, 29, 15}, critical: true, extnValue: [:keyAgreement])] ++
        Enum.map(
          List.wrap(description),
          &ext(extnID: @key_description_oid, critical: false, extnValue: &1)
        )

    issuer =
      if Keyword.get(opts, :rkp, false),
        do: "Fermix Test Attestation Key",
        else: "Fermix Test Droid CA"

    sign(
      "Android Keystore Key",
      issuer,
      Keyword.get(opts, :leaf_spki, x25519_spki(noise_pk)),
      issuer_key,
      Keyword.get(opts, :leaf_serial, 1),
      {~U[1970-01-01 00:00:00Z], ~U[2048-01-01 00:00:00Z]},
      extensions
    )
  end

  defp sign(subject, issuer, subject_key_info, issuer_key, serial, {not_before, not_after}, exts) do
    tbs(
      version: :v3,
      serialNumber: serial,
      signature: {:SignatureAlgorithm, @ecdsa_sha256, :asn1_NOVALUE},
      issuer: name(issuer),
      validity: {:Validity, time(not_before), time(not_after)},
      subject: name(subject),
      subjectPublicKeyInfo: subject_key_info,
      extensions: exts
    )
    |> :public_key.pkix_sign(issuer_key)
  end

  @doc "An EC P-256 key."
  def ec_key, do: :public_key.generate_key({:namedCurve, :secp256r1})

  @doc "The SubjectPublicKeyInfo of an EC key, for a leaf that is not X25519."
  def ec_spki({:ECPrivateKey, _version, _private, params, public, _attributes}) do
    spki(
      algorithm: {:PublicKeyAlgorithm, {1, 2, 840, 10_045, 2, 1}, params},
      subjectPublicKey: {:ECPoint, public}
    )
  end

  defp x25519_spki(public) do
    spki(
      algorithm: {:PublicKeyAlgorithm, {1, 3, 101, 110}, :asn1_NOVALUE},
      subjectPublicKey: {:ECPoint, public}
    )
  end

  defp ca_extensions do
    [
      ext(
        extnID: {2, 5, 29, 19},
        critical: true,
        extnValue: {:BasicConstraints, true, :asn1_NOVALUE}
      ),
      ext(extnID: {2, 5, 29, 15}, critical: true, extnValue: [:keyCertSign])
    ]
  end

  defp default_validity do
    now = DateTime.utc_now()
    {DateTime.add(now, -365 * 86_400), DateTime.add(now, 5 * 365 * 86_400)}
  end

  defp name(common_name),
    do: {:rdnSequence, [[{:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, common_name}}]]}

  defp time(%DateTime{} = value),
    do: {:generalTime, value |> Calendar.strftime("%Y%m%d%H%M%SZ") |> String.to_charlist()}

  defp lengths(certs), do: Enum.map(certs, &byte_size/1)

  defp tag(class_bits, form, number) when number < 31,
    do: <<class_bits::2, form::1, number::5>>

  defp tag(class_bits, form, number),
    do: <<class_bits::2, form::1, 31::5>> <> base128(number)

  defp base128(number) when number < 128, do: <<number>>

  defp base128(number) do
    groups = Integer.digits(number, 128)
    {init, [last]} = Enum.split(groups, -1)
    IO.iodata_to_binary(Enum.map(init, &(&1 + 128)) ++ [last])
  end

  defp der_length(size) when size < 128, do: <<size>>

  defp der_length(size) do
    bytes = :binary.encode_unsigned(size)
    <<0x80 + byte_size(bytes)>> <> bytes
  end

  defp signed(value) when value >= 0 do
    bytes = :binary.encode_unsigned(value)
    if :binary.first(bytes) >= 0x80, do: <<0>> <> bytes, else: bytes
  end
end
