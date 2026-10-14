defmodule FermixChannels.Mobile.AttestationTest do
  # M51 D3 and §6.2: a phone pairs only with a Google-rooted key attestation
  # binding the very key it handshook with, generated in its secure hardware
  # for key agreement, by the official app on a locked, verified-boot phone,
  # for this pairing window, with no revoked certificate. Every refusal below
  # is one check failing on an otherwise genuine chain.
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Attestation
  alias FermixChannels.Test.AttestationChain, as: Chain

  @google_sample Path.expand("../../fixtures/mobile_attestation/google_ec_tee", __DIR__)
  @keyattestation Path.expand("../../fixtures/mobile_attestation/keyattestation", __DIR__)
  # The status list bound PROTOCOL.md states.
  @max_status_list_bytes 2 * 1_024 * 1_024

  setup do
    pairing = Chain.pairing()
    %{pairing: pairing, now: DateTime.utc_now()}
  end

  describe "a genuine chain" do
    test "verifies and yields the facts the owner is shown", %{pairing: pairing, now: now} do
      chain = Chain.chain(pairing)

      assert {:ok, facts} =
               Attestation.verify(Chain.evidence(chain, pairing), Chain.trust(chain), now)

      assert facts == %{
               platform: "android",
               security_level: :trusted_environment,
               signer_role: :development,
               version_code: 42,
               boot_state: :verified,
               device_locked: true
             }
    end

    test "a remotely provisioned phone's four certificates verify", %{pairing: pairing, now: now} do
      chain = Chain.chain(pairing, rkp: true)
      assert length(chain.certs) == 4

      assert {:ok, %{signer_role: :development}} =
               Attestation.verify(Chain.evidence(chain, pairing), Chain.trust(chain), now)
    end

    test "a chain that leaves its root out still chains to the pinned one", ctx do
      chain = Chain.chain(ctx.pairing, include_root: false)

      assert {:ok, _facts} =
               Attestation.verify(Chain.evidence(chain, ctx.pairing), Chain.trust(chain), ctx.now)
    end

    test "a StrongBox key and any attestation version from 100 verify", ctx do
      for {level, version} <- [{2, 100}, {1, 400}] do
        opts = [attestation_level: level, keymint_level: level, attestation_version: version]
        chain = Chain.chain(ctx.pairing, opts)

        assert {:ok, %{security_level: expected}} =
                 Attestation.verify(
                   Chain.evidence(chain, ctx.pairing),
                   Chain.trust(chain),
                   ctx.now
                 )

        assert expected == if(level == 2, do: :strongbox, else: :trusted_environment)
      end
    end

    test "the root is trusted by its key: an older certificate of it may have expired", ctx do
      pinned = Chain.root()

      expired = %{
        pinned
        | der: reissue(pinned, {~U[2016-01-01 00:00:00Z], ~U[2020-01-01 00:00:00Z]})
      }

      chain = Chain.chain(ctx.pairing, root: expired)
      trust = Chain.trust(%{chain | root: pinned})

      assert {:ok, _facts} =
               Attestation.verify(Chain.evidence(chain, ctx.pairing), trust, ctx.now)
    end
  end

  describe "check 1: the attested key is the handshake key" do
    test "a leaf key other than the handshake static is refused", ctx do
      {other, _private} = :crypto.generate_key(:ecdh, :x25519)
      chain = Chain.chain(ctx.pairing, noise_pk: other)
      assert_refused(chain, ctx, :key)
    end

    test "a leaf key that is not X25519 is refused", ctx do
      chain = Chain.chain(ctx.pairing, leaf_spki: Chain.ec_spki(Chain.ec_key()))
      assert_refused(chain, ctx, :key)
    end
  end

  describe "check 2: the chain leads to a pinned Google root" do
    test "random DER is refused, never raised", ctx do
      bytes = :crypto.strong_rand_bytes(700)

      evidence =
        Chain.evidence(%{lengths: [700], bytes: bytes}, ctx.pairing)

      chain = Chain.chain(ctx.pairing)
      assert {:error, refusal} = Attestation.verify(evidence, Chain.trust(chain), ctx.now)
      assert %{reason: :attestation, check: :chain} = refusal
      assert {:malformed_certificate, failure} = refusal.detail

      assert failure in [
               ArgumentError,
               CaseClauseError,
               FunctionClauseError,
               MatchError,
               :if_clause,
               :asn1_exit
             ]
    end

    # Two of :public_key's own failures on a phone's bytes, found by fuzzing
    # one certificate at a time: its decoder's case_clause on an empty named
    # BIT STRING, and calendar's if_clause on a day its path validation cannot
    # read. Each is a refusal naming the failure, not a crash of the socket.
    test "a key usage :public_key cannot decode is refused, not raised", ctx do
      chain = Chain.chain(ctx.pairing)
      [leaf | issuers] = chain.certs
      broken = replace_extension(leaf, {2, 5, 29, 15}, <<3, 0>>)

      assert {:error, %{check: :chain, detail: {:malformed_certificate, CaseClauseError}}} =
               verify(with_certs(chain, [broken | issuers]), ctx)
    end

    test "a validity day :public_key cannot read is refused, not raised", ctx do
      chain = Chain.chain(ctx.pairing)
      [leaf, intermediate, root] = chain.certs
      tbs = intermediate |> :public_key.pkix_decode_cert(:otp) |> elem(1)
      validity = {:Validity, {:utcTime, ~c"260132000000Z"}, {:utcTime, ~c"360101000000Z"}}
      broken = :public_key.pkix_sign(put_elem(tbs, 5, validity), chain.root.key)

      assert {:error, %{check: :chain, detail: {:malformed_certificate, :if_clause}}} =
               verify(with_certs(chain, [leaf, broken, root]), ctx)
    end

    test "a chain to a root that is not pinned is refused", ctx do
      chain = Chain.chain(ctx.pairing)
      stranger = Chain.chain(ctx.pairing, root: Chain.root(name: "Someone Else's Root"))
      assert_refused(stranger, ctx, :chain, Chain.trust(chain))
    end

    test "a root with the pinned root's name but another key is refused", ctx do
      chain = Chain.chain(ctx.pairing)
      impostor = Chain.chain(ctx.pairing)
      assert_refused(impostor, ctx, :chain, Chain.trust(chain))
    end

    # What an emulator presents: a software-level key under the AOSP software
    # attestation root. The real AOSP certificate is not carried here; a root
    # under its name stands in, and it is not a root this daemon pins.
    test "a software attestation root, as an emulator presents, is refused", ctx do
      genuine = Chain.chain(ctx.pairing)
      software_root = Chain.root(name: "Android Software Attestation Root")

      emulator =
        Chain.chain(ctx.pairing, root: software_root, attestation_level: 0, keymint_level: 0)

      assert_refused(emulator, ctx, :chain, Chain.trust(genuine))
    end

    test "cert_lengths that do not cut the tail into certificates are refused", ctx do
      chain = Chain.chain(ctx.pairing)
      [leaf | rest] = chain.lengths
      evidence = Chain.evidence(chain, ctx.pairing, %{cert_lengths: [leaf - 1, 1 | rest]})

      assert {:error, %{reason: :attestation, check: :chain}} =
               Attestation.verify(evidence, Chain.trust(chain), ctx.now)
    end
  end

  describe "check 3: a hardware key generated for key agreement" do
    test "a software security level is refused", ctx do
      chain = Chain.chain(ctx.pairing, attestation_level: 0, keymint_level: 0)
      assert_refused(chain, ctx, :key_properties)
    end

    test "attestation and KeyMint levels that differ are refused", ctx do
      chain = Chain.chain(ctx.pairing, attestation_level: 1, keymint_level: 2)
      assert_refused(chain, ctx, :key_properties)
    end

    test "an imported key is refused, securely imported too", ctx do
      for origin <- [2, 4] do
        assert_refused(Chain.chain(ctx.pairing, origin: origin), ctx, :key_properties)
      end
    end

    test "any purpose but exactly AGREE_KEY is refused", ctx do
      for purposes <- [[6, 2], [2], [], [6, 6]] do
        assert_refused(Chain.chain(ctx.pairing, purposes: purposes), ctx, :key_properties)
      end
    end

    test "an algorithm other than EC, or a curve other than 25519, is refused", ctx do
      assert_refused(Chain.chain(ctx.pairing, algorithm: 1), ctx, :key_properties)
      assert_refused(Chain.chain(ctx.pairing, ec_curve: 1), ctx, :key_properties)
    end

    test "a Keymaster-era attestation, before KeyMint, is refused", ctx do
      assert_refused(Chain.chain(ctx.pairing, attestation_version: 4), ctx, :key_properties)
    end

    test "a leaf without the KeyMint extension, or with two, is refused", ctx do
      assert_refused(Chain.chain(ctx.pairing, key_description: []), ctx, :key_properties)
      description = Chain.key_description(ctx.pairing)

      assert_refused(
        Chain.chain(ctx.pairing, key_description: [description, description]),
        ctx,
        :key_properties
      )
    end
  end

  describe "check 4: the challenge binds this pairing window" do
    test "a challenge from another secret is refused", ctx do
      other = :crypto.hash(:sha256, "fermix-mobile-attest-v1" <> :crypto.strong_rand_bytes(32))
      assert_refused(Chain.chain(ctx.pairing, challenge: other), ctx, :challenge)
    end

    test "the challenge is SHA-256 of the label and the secret", %{pairing: pairing} do
      assert Attestation.challenge(pairing.secret) == pairing.challenge
    end
  end

  describe "check 5: a locked phone with verified boot" do
    test "a boot state other than Verified is refused", ctx do
      for state <- [1, 2, 3] do
        assert_refused(Chain.chain(ctx.pairing, boot_state: state), ctx, :root_of_trust)
      end
    end

    test "an unlocked bootloader is refused", ctx do
      assert_refused(Chain.chain(ctx.pairing, device_locked: false), ctx, :root_of_trust)
    end
  end

  describe "check 6: the official app" do
    test "another package is refused", ctx do
      chain = Chain.chain(ctx.pairing, packages: [{"io.tezra.fermix.evil", 42}])
      assert_refused(chain, ctx, :application)
    end

    test "a signing certificate not in the pinned list is refused", ctx do
      stranger = :crypto.hash(:sha256, "a rebuilt app")

      for digests <- [[stranger], [Chain.signer_digest(), stranger], []] do
        chain = Chain.chain(ctx.pairing, signature_digests: digests)
        assert_refused(chain, ctx, :application)
      end
    end
  end

  describe "check 7: revocation and certificate validity" do
    test "a certificate on Google's status list is refused", ctx do
      chain = Chain.chain(ctx.pairing)

      for serial <- ["2c8cdddfd5e03bfc", "1"] do
        trust = Chain.trust(chain, %{statuses: {:ok, MapSet.new([serial])}})
        assert_refused(chain, ctx, :revocation, trust)
      end
    end

    test "an expired intermediate is refused at the given time", ctx do
      expired = {DateTime.add(ctx.now, -400 * 86_400), DateTime.add(ctx.now, -60)}
      assert_refused(Chain.chain(ctx.pairing, intermediate_validity: expired), ctx, :revocation)
    end

    test "validity is judged at the given time, not the host clock", ctx do
      chain = Chain.chain(ctx.pairing)
      later = DateTime.add(ctx.now, 10 * 365 * 86_400)

      assert {:error, %{check: :revocation}} =
               Attestation.verify(Chain.evidence(chain, ctx.pairing), Chain.trust(chain), later)
    end

    # Only :public_key's failures on a phone's bytes are refusals: a fault in
    # the verifier's own judgement of dates raises.
    test "a fault in judging validity raises, it is no malformed certificate", ctx do
      chain = Chain.chain(ctx.pairing)
      broken = %{ctx.now | year: nil}

      assert_raise FunctionClauseError, fn ->
        Attestation.verify(Chain.evidence(chain, ctx.pairing), Chain.trust(chain), broken)
      end
    end

    test "a status list that cannot be used is attestation_unavailable", ctx do
      chain = Chain.chain(ctx.pairing)

      for reason <- [:status_list_missing, :status_list_stale, :status_list_wait_timeout] do
        trust = Chain.trust(chain, %{statuses: {:error, reason}})

        assert {:error, %{reason: :attestation_unavailable, detail: ^reason}} =
                 Attestation.verify(Chain.evidence(chain, ctx.pairing), trust, ctx.now)
      end
    end
  end

  describe "the platform" do
    test "an iPhone cannot pair: its key is not attested", ctx do
      chain = Chain.chain(ctx.pairing)
      evidence = Chain.evidence(chain, ctx.pairing, %{platform: "ios", kind: "apple_app_attest"})

      assert {:error, %{reason: :platform_unsupported, check: :platform}} =
               Attestation.verify(evidence, Chain.trust(chain), ctx.now)
    end

    test "a platform that disagrees with its attestation's kind is refused", ctx do
      chain = Chain.chain(ctx.pairing)

      for {platform, kind} <- [{"android", "apple_app_attest"}, {"ios", "android_keymint"}] do
        evidence = Chain.evidence(chain, ctx.pairing, %{platform: platform, kind: kind})

        assert {:error, %{reason: :platform_unsupported}} =
                 Attestation.verify(evidence, Chain.trust(chain), ctx.now)
      end
    end
  end

  describe "the KeyDescription reader refuses malformed input" do
    test "a high tag number is read and an entry it does not use is skipped", ctx do
      extra = [Chain.explicit(1_000, Chain.octet("future")), Chain.explicit(40_000, <<5, 0>>)]
      chain = Chain.chain(ctx.pairing, extra_hardware: extra)
      assert {:ok, _facts} = verify(chain, ctx)
    end

    test "a duplicated tag in an authorization list is refused", ctx do
      duplicate = Chain.hardware() ++ [Chain.explicit(702, Chain.integer(0))]
      description = Chain.key_description(ctx.pairing, hardware: duplicate)
      assert {:error, {:duplicate_tag, 702}} = Attestation.decode_key_description(description)
      chain = Chain.chain(ctx.pairing, key_description: description)

      assert {:error, %{check: :key_properties, detail: detail}} = verify(chain, ctx)
      assert detail == {:malformed_key_description, {:duplicate_tag, 702}}
    end

    test "a refusal names the reader's reason: an indefinite length", ctx do
      description = <<0x30, 0x80, 0x02, 0x01, 0x01, 0x00, 0x00>>
      chain = Chain.chain(ctx.pairing, key_description: description)

      assert {:error, %{check: :key_properties, detail: detail}} = verify(chain, ctx)
      assert detail == {:malformed_key_description, :indefinite_length}
    end

    test "truncated input is refused at every length", ctx do
      description = Chain.key_description(ctx.pairing)

      for size <- 0..(byte_size(description) - 1) do
        assert {:error, _reason} =
                 Attestation.decode_key_description(binary_part(description, 0, size))
      end
    end

    test "absurd and indefinite lengths are refused" do
      for bytes <- [
            <<0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF>>,
            <<0x30, 0x89, 1, 2, 3, 4, 5, 6, 7, 8, 9>>,
            <<0x30, 0x80, 0x02, 0x01, 0x01, 0x00, 0x00>>,
            <<0x30, 0x02, 0x9F, 0xFF>>,
            <<0x30, 0x07, 0xBF, 0x80, 0x80, 0x80, 0x80, 0x01, 0x00>>
          ] do
        assert {:error, _reason} = Attestation.decode_key_description(bytes)
      end
    end

    test "trailing bytes after the description are refused", ctx do
      description = Chain.key_description(ctx.pairing)
      assert {:error, _reason} = Attestation.decode_key_description(description <> <<0>>)
    end

    # The root is trusted by its key and never re-verified, so the mutated
    # chain leaves it out: every byte left is signed by the byte before it.
    test "a thousand seeded mutations of a genuine chain refuse without raising", ctx do
      chain = Chain.chain(ctx.pairing, include_root: false)
      trust = Chain.trust(chain)
      :rand.seed(:exsss, {11, 10, 2026})

      for _round <- 1..1_000 do
        mutated = mutate(chain.bytes)
        evidence = Chain.evidence(%{chain | bytes: mutated}, ctx.pairing)
        assert {:error, %{reason: :attestation}} = Attestation.verify(evidence, trust, ctx.now)
      end
    end

    test "a thousand seeded mutations of a description refuse or decode, never raise", ctx do
      description = Chain.key_description(ctx.pairing)
      :rand.seed(:exsss, {10, 11, 2026})

      for _round <- 1..1_000 do
        assert {tag, _value} = Attestation.decode_key_description(mutate(description))
        assert tag in [:ok, :error]
      end
    end
  end

  # attestationVersion 3: a Keymaster 3 extension, recorded before KeyMint
  # (version 100 and later), in the format KeyMint kept.
  describe "a real Keymaster chain recorded by Google" do
    setup do
      certs = for i <- 0..3, do: File.read!(Path.join(@google_sample, "cert#{i}.der"))
      %{certs: certs}
    end

    test "its extension decodes, high tags and the software-enforced app id included", %{
      certs: [leaf | _rest]
    } do
      assert {:ok, description} =
               leaf |> Chain.key_description_bytes() |> Attestation.decode_key_description()

      assert description.attestation_version == 3
      assert description.attestation_security_level == 1
      assert description.keymint_security_level == 1
      assert description.challenge == "abc"
      assert description.hardware.purposes == [2, 3]
      assert description.hardware.algorithm == 3
      assert description.hardware.ec_curve == 1
      assert description.hardware.origin == 0

      assert description.hardware.root_of_trust == %{
               device_locked: false,
               verified_boot_state: 2
             }

      assert {"android", 29} in description.software.application.packages
      assert [<<_::256>>] = description.software.application.signature_digests
    end

    test "it chains to the pinned Google root, then fails the key check", %{certs: certs} do
      assert {:error, %{reason: :attestation, check: :key}} =
               verify_recorded(certs, ~U[2026-10-11 00:00:00Z])
    end
  end

  # Real phones' chains from Google's keyattestation library (SOURCE.md in
  # keyattestation/). Each passes the chain check against the pinned roots at
  # a time inside its certificates' validity, decodes to what its .json
  # records, and is refused at the next check: its key is EC P-256, not the
  # X25519 key a pairing attests.
  describe "real phones' chains from Google's keyattestation library" do
    test "a Pixel 9 Pro's remotely provisioned chain, to the RSA root" do
      certs = recorded_chain("caiman/sdk36/TEE_EC_RKP")
      assert length(certs) == 5
      assert_recorded(certs, "caiman/sdk36/TEE_EC_RKP")
      [rsa_root, ec_root] = Attestation.roots()
      at = ~U[2025-09-28 00:00:00Z]

      assert {:error, %{reason: :attestation, check: :key, detail: :not_x25519}} =
               verify_recorded(certs, at)

      assert {:error, %{check: :key}} = verify_recorded(certs, at, [rsa_root])

      assert {:error, %{check: :chain, detail: :untrusted_root}} =
               verify_recorded(certs, at, [ec_root])
    end

    test "a 2026 chain, to Key Attestation CA1" do
      certs = recorded_chain("frankel/sdk37/TEE_EC_2026")
      assert length(certs) == 5
      assert_recorded(certs, "frankel/sdk37/TEE_EC_2026")
      [rsa_root, ec_root] = Attestation.roots()
      at = ~U[2026-09-10 00:00:00Z]

      assert {:error, %{reason: :attestation, check: :key, detail: :not_x25519}} =
               verify_recorded(certs, at)

      assert {:error, %{check: :key}} = verify_recorded(certs, at, [ec_root])

      assert {:error, %{check: :chain, detail: :untrusted_root}} =
               verify_recorded(certs, at, [rsa_root])
    end

    test "past its device certificate's days, the remotely provisioned chain is expired" do
      certs = recorded_chain("caiman/sdk36/TEE_EC_RKP")

      assert {:error, %{check: :revocation, detail: :certificate_expired}} =
               verify_recorded(certs, ~U[2026-10-11 00:00:00Z])
    end

    # deviceLocked is BOOLEAN 0x01, not DER's 0xFF. Google's verifier reads it
    # as true and logs it; so does this one: any non-zero byte is TRUE in BER,
    # and the byte is the secure hardware's own, signed. The sample is
    # Keymaster 3, so it could not pair anyway.
    test "a deviceLocked written 0x01 reads as true" do
      certs = recorded_chain("invalid/malformed_rot_device_locked")
      description = decode_leaf(certs)
      assert description.attestation_version == 3
      assert description.attestation_security_level == 1

      assert description.hardware.root_of_trust == %{
               device_locked: true,
               verified_boot_state: 0
             }

      assert description.software.application.packages == [
               {"com.google.android.apps.photos", 51_193_451}
             ]

      assert {:error, %{check: :key}} =
               verify_recorded(certs, ~U[2026-10-11 00:00:00Z])
    end

    # Its hardware list puts tag 2 before tag 1. Google enforces tag order only
    # when asked (its TagOrderConstraint.STRICT is not a default); this reader
    # takes each entry by its tag, so the order changes nothing it reads. The
    # leaf was edited after it was signed (openssl agrees its signature fails),
    # so the chain itself is refused, as Google's own CLI refuses it.
    test "an authorization list out of tag order is read by tag" do
      certs = recorded_chain("invalid/tags_not_in_ascending_order")
      description = decode_leaf(certs)
      assert description.attestation_version == 300
      assert description.challenge == "challenge"
      assert description.hardware.purposes == [2]
      assert description.hardware.algorithm == 3
      assert description.hardware.ec_curve == 1
      assert description.hardware.origin == 0

      assert description.hardware.root_of_trust == %{
               device_locked: false,
               verified_boot_state: 2
             }

      assert description.software.application.packages == [
               {"com.example.attestationcollector", 1}
             ]

      assert {:error, %{check: :chain, detail: :invalid_signature}} =
               verify_recorded(certs, ~U[2026-10-11 00:00:00Z])
    end
  end

  describe "the pinned trust inputs" do
    test "the roots are Google's two, by certificate digest" do
      roots = Attestation.roots()

      assert Enum.map(roots, &Base.encode16(:crypto.hash(:sha256, &1.der), case: :lower)) == [
               "cedb1cb6dc896ae5ec797348bce9286753c2b38ee71ce0fbe34a9a1248800dfc",
               "6d9db4ce6c5c0b293166d08986e05774a8776ceb525d9e4329520de12ba4bcc0"
             ]
    end

    test "the signers are the app's package and its development key" do
      assert %{package: "io.tezra.fermix", signers: signers} = Attestation.signers()

      digest =
        Base.decode16!("d56b2c45e652da4e9c9970879fdc49cb38a59609a4908053fcb51265dfa12da9",
          case: :lower
        )

      assert signers == %{digest => :development}
    end
  end

  describe "the status list" do
    @example ~s({"entries": {"2c8cdddfd5e03bfc": {"status": "REVOKED", "expires": "2020-11-13", ) <>
               ~s("reason": "KEY_COMPROMISE", "comment": "Key stored on unsecure system"}, ) <>
               ~s("c8966fcb2fbb0d7a": {"status": "SUSPENDED", "reason": "SOFTWARE_FLAW"}}})

    test "Google's published example parses to the serials it lists" do
      assert {:ok, serials} = Attestation.parse_status_list(@example)
      assert serials == MapSet.new(["2c8cdddfd5e03bfc", "c8966fcb2fbb0d7a"])
    end

    test "a list of exactly the bound parses" do
      body = ~s({"entries": {}})
      at_bound = body <> String.duplicate(" ", @max_status_list_bytes - byte_size(body))
      assert {:ok, serials} = Attestation.parse_status_list(at_bound)
      assert serials == MapSet.new()
    end

    test "an unparseable, oversized or off-format list is refused" do
      oversized = ~s({"entries": {}}) <> String.duplicate(" ", @max_status_list_bytes)

      for body <- [
            "not json",
            ~s({"entries": []}),
            ~s({"entries": {"0abc": {"status": "REVOKED"}}}),
            ~s({"entries": {"ABC": {"status": "REVOKED"}}}),
            ~s({"entries": {"abc": {"reason": "KEY_COMPROMISE"}}}),
            ~s({"entries": {"abc": {"status": "MAYBE"}}}),
            oversized
          ] do
        assert {:error, _reason} = Attestation.parse_status_list(body)
      end
    end

    test "a fetch through the guarded client keeps its max-age, capped at a day" do
      for {header, max_age_ms} <- [
            {"public, max-age=86400", 86_400_000},
            {"max-age=600", 600_000},
            {"max-age=999999", 86_400_000}
          ] do
        assert {:ok, %{serials: serials, max_age_ms: ^max_age_ms}} =
                 Attestation.fetch_status_list(fetch_opts(200, @example, header))

        assert MapSet.member?(serials, "c8966fcb2fbb0d7a")
      end
    end

    test "a fetch that fails, is not cacheable or is too large is an error" do
      too_large = String.duplicate(" ", @max_status_list_bytes + 1)

      for {status, body, header} <- [
            {503, @example, "max-age=60"},
            {200, @example, nil},
            {200, @example, "no-store"},
            {200, too_large, "max-age=60"}
          ] do
        assert {:error, _reason} = Attestation.fetch_status_list(fetch_opts(status, body, header))
      end

      failing =
        Keyword.put(fetch_opts(200, @example, "max-age=60"), :request, fn _pinned, _opts ->
          {:error, %Req.TransportError{reason: :timeout}}
        end)

      assert {:error, _reason} = Attestation.fetch_status_list(failing)
    end
  end

  defp verify(chain, ctx, trust \\ nil) do
    Attestation.verify(Chain.evidence(chain, ctx.pairing), trust || Chain.trust(chain), ctx.now)
  end

  defp assert_refused(chain, ctx, check, trust \\ nil) do
    assert {:error, %{reason: :attestation, check: ^check, detail: detail}} =
             verify(chain, ctx, trust)

    refute holds_bytes?(detail)
  end

  # A refusal's detail is logged: it names a reason, never the phone's bytes.
  defp holds_bytes?(term) when is_binary(term), do: true

  defp holds_bytes?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&holds_bytes?/1)

  defp holds_bytes?(_term), do: false

  defp with_certs(chain, certs) do
    lengths = Enum.map(certs, &byte_size/1)
    %{chain | certs: certs, bytes: IO.iodata_to_binary(certs), lengths: lengths}
  end

  # The certificate with one extension's DER value replaced and its old
  # signature kept: :public_key decodes it before any signature is checked.
  defp replace_extension(der, oid, value) do
    {:Certificate, tbs, algorithm, signature} = :public_key.pkix_decode_cert(der, :plain)

    extensions =
      for {:Extension, id, critical, old} <- elem(tbs, 10),
          do: {:Extension, id, critical, if(id == oid, do: value, else: old)}

    tbs = put_elem(tbs, 10, extensions)
    :public_key.der_encode(:Certificate, {:Certificate, tbs, algorithm, signature})
  end

  defp recorded_chain(name) do
    @keyattestation
    |> Path.join(name <> ".pem")
    |> File.read!()
    |> :public_key.pem_decode()
    |> Enum.map(fn {:Certificate, der, :not_encrypted} -> der end)
  end

  defp decode_leaf([leaf | _issuers]) do
    {:ok, description} =
      leaf |> Chain.key_description_bytes() |> Attestation.decode_key_description()

    description
  end

  defp recorded_evidence(certs) do
    pairing = Chain.pairing()

    %{
      platform: "android",
      kind: "android_keymint",
      cert_lengths: Enum.map(certs, &byte_size/1),
      chain: IO.iodata_to_binary(certs),
      noise_pk: pairing.noise_pk,
      challenge: pairing.challenge
    }
  end

  defp verify_recorded(certs, at, roots \\ Attestation.roots()),
    do: Attestation.verify(recorded_evidence(certs), %{pinned_trust() | roots: roots}, at)

  defp pinned_trust do
    Map.merge(Attestation.signers(), %{roots: Attestation.roots(), statuses: {:ok, MapSet.new()}})
  end

  @levels %{"TRUSTED_ENVIRONMENT" => 1, "STRONG_BOX" => 2}
  @boot_states %{"VERIFIED" => 0, "SELF_SIGNED" => 1, "UNVERIFIED" => 2, "FAILED" => 3}

  # The values the library's .json records beside the chain, as this reader
  # names them.
  defp assert_recorded(certs, name) do
    recorded = @keyattestation |> Path.join(name <> ".json") |> File.read!() |> Jason.decode!()
    description = decode_leaf(certs)
    hardware = recorded["hardwareEnforced"]
    root_of_trust = hardware["rootOfTrust"]
    application = recorded["softwareEnforced"]["attestationApplicationId"]

    assert description.attestation_version == String.to_integer(recorded["attestationVersion"])
    assert description.keymint_version == String.to_integer(recorded["keyMintVersion"])
    assert description.attestation_security_level == @levels[recorded["attestationSecurityLevel"]]
    assert description.keymint_security_level == @levels[recorded["keyMintSecurityLevel"]]
    assert description.challenge == Base.decode64!(recorded["attestationChallenge"])
    assert description.hardware.purposes == Enum.map(hardware["purposes"], &String.to_integer/1)
    assert description.hardware.algorithm == String.to_integer(hardware["algorithms"])
    assert description.hardware.ec_curve == String.to_integer(hardware["ecCurve"])
    assert hardware["origin"] == "GENERATED" and description.hardware.origin == 0

    assert description.hardware.root_of_trust == %{
             device_locked: root_of_trust["deviceLocked"],
             verified_boot_state: @boot_states[root_of_trust["verifiedBootState"]]
           }

    assert description.software.application == %{
             packages:
               Enum.map(application["packages"], &{&1["name"], String.to_integer(&1["version"])}),
             signature_digests: Enum.map(application["signatures"], &Base.decode64!/1)
           }
  end

  defp reissue(root, validity) do
    tbs = root.der |> :public_key.pkix_decode_cert(:otp) |> elem(1)
    validity_record = {:Validity, time(elem(validity, 0)), time(elem(validity, 1))}
    tbs = put_elem(tbs, 5, validity_record)
    :public_key.pkix_sign(tbs, root.key)
  end

  defp time(value),
    do: {:generalTime, value |> Calendar.strftime("%Y%m%d%H%M%SZ") |> String.to_charlist()}

  # One of four damages at a seeded position: a flipped byte, a cut, a byte
  # dropped, or a byte inserted.
  defp mutate(bytes) do
    at = :rand.uniform(byte_size(bytes)) - 1
    <<head::binary-size(at), byte, tail::binary>> = bytes

    case :rand.uniform(4) do
      1 -> head <> <<Bitwise.bxor(byte, :rand.uniform(255))>> <> tail
      2 -> head
      3 -> head <> tail
      4 -> head <> <<:rand.uniform(256) - 1, byte>> <> tail
    end
  end

  defp fetch_opts(status, body, cache_control) do
    headers = if cache_control, do: %{"cache-control" => [cache_control]}, else: %{}

    [
      resolver: fn _host -> {:ok, [{142, 250, 80, 46}]} end,
      request: fn _pinned, _options ->
        {:ok, %Req.Response{status: status, body: body, headers: headers}}
      end
    ]
  end
end
