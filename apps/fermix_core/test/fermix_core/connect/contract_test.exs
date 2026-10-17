defmodule FermixCore.Connect.ContractTest do
  @moduledoc """
  Holds the Fermix Connect contract under `priv/connect/` to itself: every
  fixture to the schema, the schema to `PROTOCOL.md`, and every digest, key id
  and signature in the fixtures to the exact bytes the document names.

  `fermix-connect` vendors this folder byte for byte, and installed engines are
  the side that cannot change after release, so a fixture that drifted from the
  schema, or a frame the document names with no fixture, is a contract the
  service is held to that nobody checked. The document is parsed rather than
  hand-listed here, so a frame, reason or close code added to it fails this test
  until the schema and a fixture carry it too.
  """

  use ExUnit.Case, async: true

  alias FermixTestSupport.WireSchema

  @priv_dir Application.app_dir(:fermix_core, "priv/connect")
  @schema_path Path.join(@priv_dir, "protocol.schema.json")
  @protocol_path Path.join(@priv_dir, "PROTOCOL.md")
  @fixture_files ~w(enrollment frames assignment result)
  @discriminators %{"server" => "serverFrame", "client" => "clientFrame"}
  @number_words %{"five" => 5, "ten" => 10}
  # Every installation signature in the fixtures is made with this seed's key,
  # so a change to a signed string re-signs the examples rather than inventing
  # a new key (the original fixture key's seed was never kept).
  @example_instance_seed :crypto.hash(:sha256, "fermix-connect contract example instance key")

  setup_all do
    raw = File.read!(@schema_path)
    doc = File.read!(@protocol_path)

    fixtures =
      for file <- @fixture_files,
          line <- jsonl(Path.join([@priv_dir, "fixtures", file <> ".jsonl"])),
          do: Map.put(line, "file", file)

    %{raw: raw, schema: Jason.decode!(raw), doc: doc, fixtures: fixtures}
  end

  describe "the fixtures against the schema" do
    test "every fixture is the contract's own example and validates against its def", ctx do
      names = Enum.map(ctx.fixtures, & &1["name"])
      assert names == Enum.uniq(names), "fixture names repeat"

      for line <- ctx.fixtures do
        assert line["source"] == "contract_example", "#{line["name"]} is not marked an example"
        assert Map.has_key?(ctx.schema["$defs"], line["def"]), "#{line["name"]} names no def"
        assert_valid(line["value"], line["def"], ctx.schema, line["name"])
      end
    end

    test "every frame fixture validates against its direction's discriminator", ctx do
      frames = Enum.filter(ctx.fixtures, &Map.has_key?(&1, "direction"))
      assert frames != []

      for line <- frames do
        assert line["def"] == line["value"]["t"], "#{line["name"]}'s def is not its t"
        assert_valid(line["value"], Map.fetch!(@discriminators, line["direction"]), ctx.schema)
      end
    end

    # The mobile export's rule: an optional field is absent, never null, so a
    # client never has to tell "null" from "not sent".
    test "no exported field accepts or carries an explicit null", ctx do
      assert WireSchema.null_typed_paths(ctx.schema, "#") == []

      for line <- ctx.fixtures do
        assert WireSchema.null_values(line["value"], "#") == [], "#{line["name"]} carries a null"
      end
    end

    test "every reference resolves and every def is used", ctx do
      defined = ctx.schema["$defs"] |> Map.keys() |> MapSet.new()

      referenced =
        ~r{\#/\$defs/([A-Za-z0-9_]+)}
        |> Regex.scan(ctx.raw)
        |> MapSet.new(fn [_match, name] -> name end)

      used =
        ctx.fixtures
        |> MapSet.new(& &1["def"])
        |> MapSet.union(referenced)
        |> MapSet.union(MapSet.new(Map.values(@discriminators)))

      assert MapSet.to_list(MapSet.difference(referenced, defined)) == []
      assert MapSet.to_list(MapSet.difference(defined, used)) == []
    end
  end

  describe "the schema against PROTOCOL.md" do
    test "every frame the document names has a def, a discriminator branch and a fixture", ctx do
      for {direction, named} <- doc_frames(ctx.doc) do
        discriminator = ctx.schema["$defs"][Map.fetch!(@discriminators, direction)]

        assert Enum.sort(discriminator["properties"]["t"]["enum"]) == Enum.sort(named),
               "the #{direction} frames in the schema are not the document's"

        for t <- named do
          assert %{"if" => _, "then" => %{"$ref" => "#/$defs/" <> ^t}} =
                   Enum.find(
                     discriminator["allOf"],
                     &(get_in(&1, ~w(if properties t const)) == t)
                   )

          assert Enum.any?(ctx.fixtures, &(&1["direction"] == direction and &1["def"] == t)),
                 "no #{direction} fixture for #{t}"
        end
      end
    end

    test "every reason and outcome the frame tables name appears in a fixture", ctx do
      frame_names = ctx.doc |> doc_frames() |> Map.values() |> List.flatten()
      rows = doc_frame_words(ctx.doc)

      # A parse that found nothing would pass every loop below.
      assert length(rows) >= 4
      assert Enum.all?(rows, fn {_t, words} -> words != [] end)

      for {t, words} <- rows, word <- words, word not in frame_names do
        assert Enum.any?(ctx.fixtures, &frame_carries?(&1, t, word)),
               "no #{t} fixture carries #{word}"
      end
    end

    test "every close code the document names has a fixture", ctx do
      codes =
        ~r/`(\d{4})`/
        |> Regex.scan(section(ctx.doc, "### 3.4"))
        |> Enum.map(fn [_match, code] -> String.to_integer(code) end)

      assert codes != []

      assert Enum.sort(ctx.schema["$defs"]["close"]["properties"]["code"]["enum"]) ==
               Enum.sort(codes)

      for code <- codes do
        assert Enum.any?(ctx.fixtures, &(&1["def"] == "close" and &1["value"]["code"] == code)),
               "no close fixture for #{code}"
      end
    end

    test "every result decision the document names has a fixture", ctx do
      [_match, sentence] =
        Regex.run(~r/`decision` is (.+?)\(the others/, flat(section(ctx.doc, "## 5.")))

      decisions = backticked(sentence) -- ["public_text"]

      assert Enum.sort(ctx.schema["$defs"]["result"]["properties"]["decision"]["enum"]) ==
               Enum.sort(decisions)

      for decision <- decisions do
        assert Enum.any?(
                 ctx.fixtures,
                 &(&1["def"] == "result" and &1["value"]["decision"] == decision)
               )
      end
    end

    test "every HTTP error the document names has a fixture", ctx do
      errors = Regex.scan(~r/`(\d{3}) ([a-z_]+)`/, section(ctx.doc, "## 2."))
      # The error table and the signed requests name eleven between them.
      assert length(Enum.uniq(errors)) >= 11

      for [_match, status, code] <- errors do
        assert Enum.any?(ctx.fixtures, &http_error?(&1, String.to_integer(status), code)),
               "no #{status} #{code} fixture"
      end
    end

    test "the authorization request carries exactly the parameters the document names", ctx do
      params = ctx.doc |> section("### 2.1") |> parameter_rows()
      request = ctx.schema["$defs"]["authorizationRequest"]

      assert length(params) == 7
      assert Enum.sort(Map.keys(request["properties"])) == Enum.sort(params)
      assert Enum.sort(request["required"]) == Enum.sort(params)
      assert request["additionalProperties"] == false

      assert ctx.fixtures |> value("authorization_request") |> Map.keys() |> Enum.sort() ==
               Enum.sort(params)
    end

    test "both callbacks the document names have a fixture", ctx do
      callbacks =
        ~r/`<redirect_uri>\?([^`]+)`/
        |> Regex.scan(section(ctx.doc, "### 2.1"))
        |> Enum.map(fn [_match, query] -> URI.decode_query(query) end)

      assert length(callbacks) == 2
      examples = values_of(ctx.fixtures, "authorizationCallback")

      for callback <- callbacks do
        assert Enum.any?(examples, &same_callback?(&1, callback)),
               "no callback fixture carries #{inspect(callback)}"
      end
    end

    test "the schema publishes the document's numbers, and its bounds use them", ctx do
      limits = ctx.schema["x-limits"]
      text = flat(ctx.doc)
      defs = ctx.schema["$defs"]

      assert ctx.schema["x-protocol-version"] == number(text, ~r/Protocol version: \*\*(\d+)\*\*/)
      assert limits["session_ttl_s"] == number(text, ~r/"session_ttl_s": (\d+)/)
      assert limits["max_assignment_bytes"] == number(text, ~r/"max_assignment_bytes": (\d+)/)
      assert limits["hello_deadline_s"] == number(text, ~r/Client, within (\w+) seconds/)

      assert limits["enrollment_ttl_s"] ==
               number(text, ~r/good for the enrollment's (\w+) minutes/) * 60

      assert limits["signed_request_skew_s"] == number(text, ~r/more than (\d+) seconds from/)
      assert limits["issued_at_skew_s"] == number(text, ~r/`issued_at` at most (\d+) seconds/)
      assert limits["max_context_posts"] == number(text, ~r/At most (\d+) posts/)
      assert limits["max_context_text_chars"] == number(text, ~r/posts and ([\d,]+) characters/)

      assert limits["max_public_text_weighted_chars"] ==
               number(text, ~r/`public_text` is at most (\d+) weighted/)

      for [_match, value] <- Regex.scan(~r/"max_result_bytes": (\d+)/, text),
          do: assert(limits["max_result_bytes"] == String.to_integer(value))

      context = defs["assignmentPayload"]["properties"]["context"]

      assert defs["assignment"]["properties"]["jws"]["x-max-bytes"] ==
               limits["max_assignment_bytes"]

      assert defs["result"]["x-max-frame-bytes"] == limits["max_result_bytes"]
      assert context["properties"]["posts"]["maxItems"] == limits["max_context_posts"]
      assert context["x-max-total-text-chars"] == limits["max_context_text_chars"]

      assert defs["result"]["properties"]["public_text"]["x-max-weighted-characters"] ==
               limits["max_public_text_weighted_chars"]
    end
  end

  describe "the fixtures against the bytes the document names" do
    test "an assignment's request_sha256 is the SHA-256 of its request_text", ctx do
      payloads = values_of(ctx.fixtures, "assignmentPayload")
      assert length(payloads) >= 2

      for payload <- payloads,
          do: assert(payload["request_sha256"] == sha256_hex(payload["request_text"]))

      example = value(ctx.fixtures, "assignment_payload")

      for result <- values_of(ctx.fixtures, "result") do
        assert result["assignment_id"] == example["assignment_id"]
        assert result["request_sha256"] == example["request_sha256"]
      end
    end

    test "a result's result_sha256 is the SHA-256 of its decision and text", ctx do
      for result <- values_of(ctx.fixtures, "result") do
        body = result["decision"] <> "\n" <> Map.get(result, "public_text", "")
        assert result["result_sha256"] == sha256_hex(body), "#{result["decision"]} digest"
      end
    end

    test "the example instance key is the contract example seed's", ctx do
      {public_key, _seed} = :crypto.generate_key(:eddsa, :ed25519, @example_instance_seed)

      assert value(ctx.fixtures, "enrollment_create_request")["public_key"] ==
               Base.url_encode64(public_key, padding: false)
    end

    test "the browser round trip names this enrollment's link, key, challenge and state", ctx do
      record = value(ctx.fixtures, "pairing_record")
      request = value(ctx.fixtures, "authorization_request")
      proof = value(ctx.fixtures, "enrollment_prove_request")
      approved = value(ctx.fixtures, "authorization_callback_approved")
      denied = value(ctx.fixtures, "authorization_callback_denied")

      confirm_url = value(ctx.fixtures, "enrollment_create_answer")["confirm_url"]
      assert String.starts_with?(confirm_url, record["origin"] <> "/confirm/")

      assert request["client_id"] == value(ctx.fixtures, "enrollment_create_request")["key_id"]

      assert request["code_challenge"] ==
               :sha256
               |> :crypto.hash(proof["code_verifier"])
               |> Base.url_encode64(padding: false)

      assert approved["state"] == request["state"]
      assert denied["state"] == request["state"]
      assert approved["code"] == proof["code"]
    end

    test "the key id and fingerprint derive from the instance public key", ctx do
      request = value(ctx.fixtures, "enrollment_create_request")
      digest = request["public_key"] |> decode64() |> sha256_hex()
      key_id = "k" <> binary_part(digest, 0, 16)

      assert request["key_id"] == key_id
      assert value(ctx.fixtures, "pairing_record")["key_id"] == key_id
      assert value(ctx.fixtures, "instance_delete_headers")["X-Fermix-Key-Id"] == key_id
      assert value(ctx.fixtures, "socket_upgrade_headers")["X-Fermix-Key-Id"] == key_id
      assert value(ctx.fixtures, "instance_key_fingerprint") == group_hex(digest)
    end

    test "every installation signature verifies over the exact string the document names", ctx do
      templates = signing_templates(ctx.doc)
      record = value(ctx.fixtures, "pairing_record")
      public_key = value(ctx.fixtures, "enrollment_create_request")["public_key"]

      for {kind, signature, values} <- signed_examples(ctx.fixtures, record) do
        message = fill(Map.fetch!(templates, kind), values)

        assert :crypto.verify(:eddsa, :none, message, decode64(signature), [
                 decode64(public_key),
                 :ed25519
               ]),
               "the #{kind} signature does not verify over #{message}"
      end
    end

    test "the assignment JWS carries the payload, signed by the paired Connect key", ctx do
      record = value(ctx.fixtures, "pairing_record")
      frame = value(ctx.fixtures, "assignment_frame")
      [header, payload, signature] = String.split(frame["jws"], ".")

      assert byte_size(frame["jws"]) <= ctx.schema["x-limits"]["max_assignment_bytes"]
      assert decode_json(header) == value(ctx.fixtures, "jws_header")
      assert decode_json(header)["kid"] == record["connect_key_id"]
      assert decode_json(payload) == value(ctx.fixtures, "assignment_payload")

      assert :crypto.verify(:eddsa, :none, header <> "." <> payload, decode64(signature), [
               decode64(record["connect_public_key"]),
               :ed25519
             ])

      claims = decode_json(payload)

      for field <- ~w(instance_id tenant_id tenant_generation key_generation),
          do: assert(claims[field] == record[field], "#{field} is not the record's")
    end

    test "the example frames and payloads sit inside the published caps", ctx do
      limits = ctx.schema["x-limits"]

      for payload <- values_of(ctx.fixtures, "assignmentPayload") do
        posts = payload["context"]["posts"]
        assert length(posts) <= limits["max_context_posts"]
        chars = posts |> Enum.map(&String.length(Map.get(&1, "text", ""))) |> Enum.sum()
        assert chars <= limits["max_context_text_chars"]
      end

      for result <- values_of(ctx.fixtures, "result") do
        assert byte_size(Jason.encode!(result)) <= limits["max_result_bytes"]
        text = Map.get(result, "public_text", "")
        assert String.length(text) <= limits["max_public_text_weighted_chars"]
      end

      ready = value(ctx.fixtures, "ready")
      hello = value(ctx.fixtures, "hello")

      for key <- ~w(session_ttl_s max_assignment_bytes max_result_bytes),
          do: assert(ready[key] == limits[key])

      assert hello["capabilities"]["max_result_bytes"] == limits["max_result_bytes"]
    end
  end

  describe "the schema refuses drift" do
    test "a client frame or signed claim with a field the contract does not name", ctx do
      hello = Map.put(value(ctx.fixtures, "hello"), "debug", true)
      refute_valid(hello, "hello", ctx.schema)
      refute_valid(hello, "clientFrame", ctx.schema)

      refute_valid(
        Map.put(value(ctx.fixtures, "assignment_payload"), "tools", ["shell"]),
        "assignmentPayload",
        ctx.schema
      )

      refute_valid(
        Map.put(value(ctx.fixtures, "jws_header"), "jku", "https://example.invalid/keys"),
        "jwsHeader",
        ctx.schema
      )
    end

    test "a header naming another algorithm", ctx do
      refute_valid(
        Map.put(value(ctx.fixtures, "jws_header"), "alg", "HS256"),
        "jwsHeader",
        ctx.schema
      )

      refute_valid(
        Map.put(value(ctx.fixtures, "jws_header"), "alg", "none"),
        "jwsHeader",
        ctx.schema
      )
    end

    test "a result whose text does not follow its decision", ctx do
      no_reply = Map.put(value(ctx.fixtures, "result_no_reply"), "public_text", "Hello.")
      refute_valid(no_reply, "result", ctx.schema)
      refute_valid(no_reply, "clientFrame", ctx.schema)

      reply = Map.delete(value(ctx.fixtures, "result_public_reply"), "public_text")
      refute_valid(reply, "result", ctx.schema)
    end

    test "a receipt whose reason does not follow its outcome", ctx do
      rejected = Map.delete(value(ctx.fixtures, "receipt_rejected_bad_signature"), "reason")
      refute_valid(rejected, "receipt", ctx.schema)

      accepted = Map.put(value(ctx.fixtures, "receipt_accepted"), "reason", "expired")
      refute_valid(accepted, "receipt", ctx.schema)
    end

    test "a context post that is missing and read at once, or neither", ctx do
      [post | _rest] = value(ctx.fixtures, "assignment_payload")["context"]["posts"]

      refute_valid(Map.put(post, "missing", true), "contextPost", ctx.schema)
      refute_valid(Map.delete(post, "text"), "contextPost", ctx.schema)
      refute_valid(Map.delete(post, "author_id"), "contextPost", ctx.schema)
    end

    test "an enrollment, record or proof that drifted from its shape", ctx do
      answer = value(ctx.fixtures, "enrollment_create_answer")

      for url <- [answer["confirm_url"] <> "?next=1", answer["confirm_url"] <> "#top"],
          do:
            refute_valid(
              Map.put(answer, "confirm_url", url),
              "enrollmentCreateAnswer",
              ctx.schema
            )

      record = value(ctx.fixtures, "pairing_record")

      refute_valid(
        Map.put(record, "origin", record["origin"] <> "/"),
        "pairingRecord",
        ctx.schema
      )

      refute_valid(
        Map.put(record, "origin", "http://connect.fermix.ai"),
        "pairingRecord",
        ctx.schema
      )

      refute_valid(Map.put(record, "tenant_generation", 0), "pairingRecord", ctx.schema)

      prove = value(ctx.fixtures, "enrollment_prove_request")
      refute_valid(Map.put(prove, "nonce", "x"), "proveRequest", ctx.schema)
      refute_valid(Map.delete(prove, "code_verifier"), "proveRequest", ctx.schema)

      refute_valid(
        Map.put(prove, "code", binary_part(prove["code"], 0, 42)),
        "proveRequest",
        ctx.schema
      )

      for verifier <- [
            String.duplicate("a", 42),
            String.duplicate("a", 129),
            String.duplicate("+", 43)
          ],
          do: refute_valid(Map.put(prove, "code_verifier", verifier), "proveRequest", ctx.schema)

      for verifier <- [String.duplicate("a", 43), String.duplicate("-._~", 32)],
          do: assert_valid(Map.put(prove, "code_verifier", verifier), "proveRequest", ctx.schema)
    end

    test "an authorization request or callback that drifted from its shape", ctx do
      request = value(ctx.fixtures, "authorization_request")

      for uri <- [
            "http://localhost:53682/callback",
            "https://127.0.0.1:53682/callback",
            "http://127.0.0.1/callback",
            "http://127.0.0.1:0/callback",
            "http://127.0.0.1:65536/callback",
            "http://127.0.0.1:053682/callback",
            "http://127.0.0.1:53682/callback/",
            "http://127.0.0.1:53682/callback?x=1"
          ],
          do:
            refute_valid(
              Map.put(request, "redirect_uri", uri),
              "authorizationRequest",
              ctx.schema
            )

      for port <- [1, 80, 65_535],
          do:
            assert_valid(
              Map.put(request, "redirect_uri", "http://127.0.0.1:#{port}/callback"),
              "authorizationRequest",
              ctx.schema
            )

      refute_valid(
        Map.put(request, "code_challenge_method", "plain"),
        "authorizationRequest",
        ctx.schema
      )

      refute_valid(
        Map.put(request, "state", String.duplicate("s", 15)),
        "authorizationRequest",
        ctx.schema
      )

      refute_valid(Map.put(request, "scope", "openid"), "authorizationRequest", ctx.schema)

      # The verifier stays on the machine that minted it; a browser only ever
      # carries its challenge.
      verifier = value(ctx.fixtures, "enrollment_prove_request")["code_verifier"]

      refute_valid(
        Map.put(request, "code_verifier", verifier),
        "authorizationRequest",
        ctx.schema
      )

      approved = value(ctx.fixtures, "authorization_callback_approved")

      refute_valid(
        Map.put(approved, "error", "access_denied"),
        "authorizationCallback",
        ctx.schema
      )

      refute_valid(Map.delete(approved, "code"), "authorizationCallback", ctx.schema)
      refute_valid(Map.delete(approved, "state"), "authorizationCallback", ctx.schema)

      denied = value(ctx.fixtures, "authorization_callback_denied")
      refute_valid(Map.put(denied, "error", "server_error"), "authorizationCallback", ctx.schema)

      # A callback is Connect's answer, open to a parameter the contract adds.
      assert_valid(
        Map.put(approved, "iss", "https://connect.fermix.ai"),
        "authorizationCallback",
        ctx.schema
      )
    end
  end

  # --- assertions ---

  defp assert_valid(value, def_name, schema, name \\ nil) do
    errors = WireSchema.errors(value, WireSchema.ref(def_name), schema)

    assert errors == [],
           "#{name || def_name} does not validate as #{def_name}: #{inspect(errors)}"
  end

  defp refute_valid(value, def_name, schema) do
    assert WireSchema.errors(value, WireSchema.ref(def_name), schema) != [],
           "#{def_name} accepted a drifted instance: #{inspect(value)}"
  end

  # Only a frame has a direction; the other fixtures are bodies, headers and a
  # fingerprint, and the last of those is a bare string.
  defp frame_carries?(line, t, word) do
    Map.has_key?(line, "direction") and line["value"]["t"] == t and
      word in Map.values(line["value"])
  end

  defp http_error?(line, status, code),
    do: line["status"] == status and get_in(line, ~w(value error code)) == code

  # A callback the document names, `<placeholder>` values standing for any.
  defp same_callback?(example, named) do
    Enum.sort(Map.keys(example)) == Enum.sort(Map.keys(named)) and
      Enum.all?(named, fn {key, value} ->
        String.starts_with?(value, "<") or example[key] == value
      end)
  end

  # --- the document ---

  # The frames §3.1 introduces in prose, by the direction named before each,
  # plus the rows of the two frame tables.
  defp doc_frames(doc) do
    handshake =
      ~r/(Server|Client)|"t": "([a-z_]+)"/
      |> Regex.scan(section(doc, "### 3.1"))
      |> Enum.reduce({nil, []}, &handshake_frame/2)
      |> elem(1)

    tables = %{"server" => table_frames(doc, "### 3.2"), "client" => table_frames(doc, "### 3.3")}

    Enum.reduce(handshake, tables, fn {direction, t}, acc ->
      Map.update!(acc, direction, &Enum.uniq([t | &1]))
    end)
  end

  defp handshake_frame([_match, "Server"], {_direction, found}), do: {"server", found}
  defp handshake_frame([_match, "Client"], {_direction, found}), do: {"client", found}

  defp handshake_frame([_match, "", t], {direction, found}),
    do: {direction, [{direction, t} | found]}

  # The first column of a table whose rows each lead with a backticked name.
  defp parameter_rows(text) do
    for "| `" <> rest <- String.split(text, "\n"),
        do: rest |> String.split("`", parts: 2) |> hd()
  end

  defp table_frames(doc, heading),
    do: doc |> section(heading) |> table_rows() |> Enum.map(&elem(&1, 0))

  # Each table row whose fields carry a reason or an outcome, with the words its
  # meaning column names for them.
  defp doc_frame_words(doc) do
    for heading <- ["### 3.2", "### 3.3"],
        {t, fields, meaning} <- doc |> section(heading) |> table_rows(),
        fields =~ "`reason" or fields =~ "`outcome",
        do: {t, backticked(meaning) -- ["reason", "outcome"]}
  end

  defp table_rows(text) do
    for line <- String.split(text, "\n"),
        String.starts_with?(line, "| `"),
        # The header row names its columns in plain words; every frame row's
        # fields are backticked.
        line |> String.split("|") |> Enum.at(2, "") |> String.contains?("`") do
      [_lead, t, fields, meaning | _rest] =
        line |> String.replace("\\|", "¦") |> String.split("|")

      {t |> String.trim() |> String.trim("`"), fields, meaning}
    end
  end

  defp signing_templates(doc) do
    ~r/fermix-connect-([a-z]+)\|[^"\n`]+/
    |> Regex.scan(doc)
    |> Map.new(fn [template, kind] -> {kind, String.trim(template)} end)
  end

  defp signed_examples(fixtures, record) do
    headers = value(fixtures, "instance_delete_headers")
    hello = value(fixtures, "hello")

    [
      {"enroll", value(fixtures, "enrollment_prove_request")["signature"],
       %{
         "origin" => record["origin"],
         "enrollment_id" => value(fixtures, "enrollment_create_answer")["enrollment_id"],
         "code" => value(fixtures, "enrollment_prove_request")["code"]
       }},
      {"session", hello["signature"],
       %{
         "origin" => record["origin"],
         "instance_id" => record["instance_id"],
         "nonce" => value(fixtures, "challenge")["nonce"],
         "protocol_version" => Integer.to_string(hello["protocol_version"])
       }},
      {"request", headers["X-Fermix-Signature"],
       %{
         "origin" => record["origin"],
         "instance_id" => headers["X-Fermix-Instance"],
         "timestamp" => headers["X-Fermix-Timestamp"]
       }}
    ]
  end

  defp fill(template, values),
    do: Regex.replace(~r/<([a-z_]+)>/, template, fn _match, name -> Map.fetch!(values, name) end)

  # From a heading to the next heading of the same or a higher level.
  defp section(doc, heading) do
    level = heading |> String.split(" ") |> hd() |> String.length()

    doc
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, heading)))
    |> tl()
    |> Enum.take_while(&(heading_level(&1) not in 1..level))
    |> Enum.join("\n")
  end

  defp heading_level(line) do
    case Regex.run(~r/^(#+) /, line) do
      [_match, hashes] -> String.length(hashes)
      nil -> 0
    end
  end

  defp number(text, pattern) do
    [_match, raw] = Regex.run(pattern, text)

    Map.get_lazy(@number_words, raw, fn ->
      raw |> String.replace(",", "") |> String.to_integer()
    end)
  end

  defp backticked(text), do: ~r/`([a-z_]+)`/ |> Regex.scan(text) |> Enum.map(&List.last/1)

  defp flat(text), do: String.replace(text, ~r/\s+/, " ")

  # --- fixtures and bytes ---

  defp value(fixtures, name) do
    fixtures |> Enum.find(&(&1["name"] == name)) |> Map.fetch!("value")
  end

  defp values_of(fixtures, def_name) do
    for line <- fixtures, line["def"] == def_name, do: line["value"]
  end

  defp jsonl(path) do
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  defp sha256_hex(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp group_hex(hex),
    do: hex |> String.graphemes() |> Enum.chunk_every(4) |> Enum.map_join(" ", &Enum.join/1)

  defp decode64(text), do: Base.url_decode64!(text, padding: false)
  defp decode_json(segment), do: segment |> decode64() |> Jason.decode!()
end
