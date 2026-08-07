defmodule FermixCore.Plugins.CanonicalJsonTest do
  use ExUnit.Case, async: true

  alias FermixCore.Plugins.CanonicalJson

  # The golden fixtures live in the sibling `fermix-plugins` checkout, which is
  # where `pluginlib.py` runs against the same files. When it is absent (CI for
  # this repo alone, a fresh clone) the cross-language cases are skipped rather
  # than silently passing — but the hand-written cases below still run, so the
  # algorithm is never entirely unguarded.
  @fixture_dir Path.expand("../../../../../../fermix-plugins/scripts/fixtures/jcs", __DIR__)

  defp fixtures do
    case File.ls(@fixture_dir) do
      {:ok, files} -> files |> Enum.filter(&String.ends_with?(&1, ".json")) |> Enum.sort()
      {:error, _reason} -> []
    end
  end

  defp load(file), do: @fixture_dir |> Path.join(file) |> File.read!() |> Jason.decode!()

  describe "cross-language golden fixtures" do
    test "the fixture directory is present" do
      if fixtures() == [] do
        IO.puts(
          :stderr,
          "\n  SKIPPED: #{@fixture_dir} not found — clone tezra-io/fermix-plugins " <>
            "beside this repo to run the cross-language JCS contract.\n"
        )
      end

      assert true
    end

    for file <-
          File.ls(@fixture_dir)
          |> (case do
                {:ok, files} ->
                  files |> Enum.filter(&String.ends_with?(&1, ".json")) |> Enum.sort()

                {:error, _} ->
                  []
              end) do
      @file_name file

      test "#{file} canonicalizes byte-for-byte as pluginlib.py does" do
        fixture = load(@file_name)
        run_fixture(fixture)
      end
    end
  end

  defp run_fixture(%{"error" => _error} = fixture) do
    # A refusal fixture: parsing must fail BEFORE canonicalization.
    assert {:error, :duplicate_object_key} = CanonicalJson.decode(fixture["input_json"])
  end

  defp run_fixture(fixture) do
    assert {:ok, decoded} = CanonicalJson.decode(fixture["input_json"])
    assert {:ok, canonical} = CanonicalJson.encode(decoded)

    assert canonical == fixture["expected"],
           "#{fixture["name"]}: canonical bytes differ from the pluginlib.py fixture"

    assert {:ok, digest} = CanonicalJson.digest(decoded)
    assert digest == fixture["expected_sha256"]
  end

  describe "number formatting (ECMAScript Number::toString)" do
    # Float.to_string/1 renders every one of these differently.
    test "integral floats lose the fractional part" do
      assert canonical(%{"a" => 1.0}) == ~s({"a":1})
    end

    test "negative zero normalizes to 0, both integer and float" do
      assert canonical(%{"a" => -0.0}) == ~s({"a":0})
      assert canonical(%{"a" => -0}) == ~s({"a":0})
    end

    test "the exponent thresholds are 1e21 up and 1e-7 down" do
      assert canonical(%{"a" => 1.0e16}) == ~s({"a":10000000000000000})
      assert canonical(%{"a" => 1.0e21}) == ~s({"a":1e+21})
      assert canonical(%{"a" => 1.0e-6}) == ~s({"a":0.000001})
      assert canonical(%{"a" => 1.0e-7}) == ~s({"a":1e-7})
    end

    test "fractions keep their shortest round-trip form" do
      assert canonical(%{"a" => 0.1}) == ~s({"a":0.1})
      assert canonical(%{"a" => -1.5}) == ~s({"a":-1.5})
    end

    # A descriptor is a security boundary; silently rounding a number inside it
    # is worse than refusing to load the plugin.
    test "integers beyond the exactly-representable range are refused" do
      assert {:error, {:integer_out_of_range, _value}} =
               CanonicalJson.encode(%{"a" => 9_007_199_254_740_992})
    end
  end

  describe "key ordering" do
    # By code point U+1F600 > U+E000; by UTF-16 code unit its leading surrogate
    # D83D < E000. JCS inherits JavaScript's ordering, so the surrogate wins.
    test "sorts by UTF-16 code unit, not code point" do
      assert canonical(%{"\u{1F600}" => 1, "" => 2}) ==
               ~s({"\u{1F600}":1,"":2})
    end

    test "orders plain ASCII lexicographically" do
      assert canonical(%{"b" => 1, "a" => 2, "C" => 3}) == ~s({"C":3,"a":2,"b":1})
    end

    test "preserves array order while normalizing object order" do
      assert canonical(%{"z" => [3, 1, 2], "a" => 1}) == ~s({"a":1,"z":[3,1,2]})
    end
  end

  describe "escaping" do
    test "escapes only quote, backslash, and C0 controls" do
      assert canonical(%{"a" => "q\"b"}) == ~s({"a":"q\\"b"})
      assert canonical(%{"a" => "b\\c"}) == ~s({"a":"b\\\\c"})
      assert canonical(%{"a" => "\n\t\r\b\f"}) == ~s({"a":"\\n\\t\\r\\b\\f"})
    end

    test "uses lowercase \\u00xx for controls without a short form" do
      assert canonical(%{"a" => <<0, 0x1F>>}) == ~s({"a":"\\u0000\\u001f"})
    end

    # DEL is not a C0 control and is not escaped by RFC 8785.
    test "emits DEL and non-ASCII literally" do
      assert canonical(%{"a" => <<0x7F>>}) == ~s({"a":"#{<<0x7F>>}"})
      assert canonical(%{"a" => "é😀"}) == ~s({"a":"é😀"})
    end
  end

  describe "duplicate keys" do
    test "are refused at decode, not resolved last-wins" do
      assert {:error, :duplicate_object_key} = CanonicalJson.decode(~s({"a":1,"a":2}))
    end

    test "are refused when nested" do
      assert {:error, :duplicate_object_key} =
               CanonicalJson.decode(~s({"outer":{"a":1,"a":2}}))
    end

    test "are refused inside an array element" do
      assert {:error, :duplicate_object_key} = CanonicalJson.decode(~s([{"a":1,"a":2}]))
    end
  end

  describe "descriptor_digest/4" do
    # An absent outputSchema and an explicit null one must hash identically, or
    # a server that starts omitting the field would read as contract drift.
    test "always carries all four keys, so absent and null agree" do
      assert {:ok, digest} = CanonicalJson.descriptor_digest("eden_read_card", %{}, nil, nil)

      assert {:ok, ^digest} =
               CanonicalJson.digest(%{
                 "name" => "eden_read_card",
                 "inputSchema" => %{},
                 "outputSchema" => nil,
                 "annotations" => nil
               })
    end

    test "a changed input schema changes the digest" do
      {:ok, before} = CanonicalJson.descriptor_digest("t", %{"type" => "object"}, nil, nil)

      {:ok, changed} =
        CanonicalJson.descriptor_digest("t", %{"type" => "object", "x" => 1}, nil, nil)

      refute before == changed
    end
  end

  defp canonical(term) do
    {:ok, canonical} = CanonicalJson.encode(term)
    canonical
  end
end
