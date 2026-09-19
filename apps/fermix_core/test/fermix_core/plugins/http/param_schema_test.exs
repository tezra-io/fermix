defmodule FermixCore.Plugins.Http.ParamSchemaTest do
  use ExUnit.Case, async: true

  alias FermixCore.Plugins.Http.ParamSchema

  defp schema(properties, required \\ []) do
    %{"type" => "object", "properties" => properties, "required" => required}
  end

  describe "validate/2" do
    test "passes declared args and drops undeclared ones" do
      s = schema(%{"q" => %{"type" => "string"}})
      assert {:ok, %{"q" => "hi"}} = ParamSchema.validate(s, %{"q" => "hi", "extra" => "dropped"})
    end

    test "materializes defaults for absent optionals" do
      s =
        schema(%{
          "max_results" => %{"type" => "integer", "default" => 10},
          "calendar_id" => %{"type" => "string", "default" => "primary"}
        })

      assert {:ok, %{"max_results" => 10, "calendar_id" => "primary"}} =
               ParamSchema.validate(s, %{})
    end

    test "omits absent optionals without a default" do
      s = schema(%{"q" => %{"type" => "string"}})
      assert {:ok, normalized} = ParamSchema.validate(s, %{})
      refute Map.has_key?(normalized, "q")
    end

    test "rejects a missing required param" do
      s = schema(%{"q" => %{"type" => "string"}}, ["q"])
      assert {:error, {:missing_param, "q"}} = ParamSchema.validate(s, %{})
    end

    test "rejects a wrong type" do
      s = schema(%{"n" => %{"type" => "integer"}})

      assert {:error, {:invalid_param, "n", {:expected_type, "integer", "not-an-int"}}} =
               ParamSchema.validate(s, %{"n" => "not-an-int"})
    end

    test "accepts each supported type" do
      s =
        schema(%{
          "s" => %{"type" => "string"},
          "i" => %{"type" => "integer"},
          "n" => %{"type" => "number"},
          "b" => %{"type" => "boolean"},
          "a" => %{"type" => "array"},
          "o" => %{"type" => "object"}
        })

      args = %{"s" => "x", "i" => 1, "n" => 1.5, "b" => true, "a" => [1], "o" => %{"k" => 1}}
      assert {:ok, ^args} = ParamSchema.validate(s, args)
    end

    test "enforces enum membership" do
      s = schema(%{"state" => %{"type" => "string", "enum" => ["open", "closed"]}})
      assert {:ok, %{"state" => "open"}} = ParamSchema.validate(s, %{"state" => "open"})

      assert {:error, {:invalid_param, "state", {:not_in_enum, ["open", "closed"]}}} =
               ParamSchema.validate(s, %{"state" => "merged"})
    end

    test "a default that violates the schema is itself validated" do
      s = schema(%{"n" => %{"type" => "integer", "default" => "bad"}})

      assert {:error, {:invalid_param, "n", {:expected_type, "integer", "bad"}}} =
               ParamSchema.validate(s, %{})
    end

    test "object/array params pass through opaquely (no nested validation)" do
      s = schema(%{"filter" => %{"type" => "object"}})
      nested = %{"deeply" => %{"nested" => [1, 2, 3]}}
      assert {:ok, %{"filter" => ^nested}} = ParamSchema.validate(s, %{"filter" => nested})
    end
  end

  # Models routinely stringify a freeform `{"type":"object"}`/`array` param that
  # carries no inner schema to guide them (provider-wide). The validator decodes
  # that encoding to the native shape so the request body gets a real object —
  # without weakening the type check for malformed input.
  describe "validate/2 structured-param coercion" do
    test "coerces a JSON-encoded string for a declared object param into a map" do
      s = schema(%{"parent" => %{"type" => "object"}}, ["parent"])

      assert {:ok, %{"parent" => %{"page_id" => "abc"}}} =
               ParamSchema.validate(s, %{"parent" => ~s({"page_id":"abc"})})
    end

    test "coerces a JSON-encoded string for a declared array param into a list" do
      s = schema(%{"children" => %{"type" => "array"}})

      assert {:ok, %{"children" => [%{"type" => "paragraph"}]}} =
               ParamSchema.validate(s, %{"children" => ~s([{"type":"paragraph"}])})
    end

    test "leaves a native object/array untouched" do
      s = schema(%{"o" => %{"type" => "object"}, "a" => %{"type" => "array"}})
      args = %{"o" => %{"k" => 1}, "a" => [1, 2]}
      assert {:ok, ^args} = ParamSchema.validate(s, args)
    end

    test "a string that decodes to the wrong structured type still fails loud" do
      s = schema(%{"parent" => %{"type" => "object"}})

      assert {:error, {:invalid_param, "parent", {:expected_type, "object", "[1,2,3]"}}} =
               ParamSchema.validate(s, %{"parent" => "[1,2,3]"})
    end

    test "a non-JSON string for a structured param still fails loud" do
      s = schema(%{"parent" => %{"type" => "object"}})

      assert {:error, {:invalid_param, "parent", {:expected_type, "object", "not json"}}} =
               ParamSchema.validate(s, %{"parent" => "not json"})
    end

    test "does not coerce scalar params from strings (object/array only)" do
      s = schema(%{"n" => %{"type" => "integer"}})

      assert {:error, {:invalid_param, "n", {:expected_type, "integer", "5"}}} =
               ParamSchema.validate(s, %{"n" => "5"})
    end
  end

  # --- M40 §3.2: enforced scalar bounds ------------------------------------
  #
  # The manifest may declare `minimum`/`maximum` on an integer or number and
  # `minLength`/`maxLength` on a string, at the top level only. Before M40 the
  # validator read them as description and let any value through.
  describe "validate/2 scalar bounds" do
    test "enforces minimum and maximum on an integer, inclusive at both ends" do
      s = schema(%{"n" => %{"type" => "integer", "minimum" => 1, "maximum" => 10}})

      assert {:ok, %{"n" => 1}} = ParamSchema.validate(s, %{"n" => 1})
      assert {:ok, %{"n" => 10}} = ParamSchema.validate(s, %{"n" => 10})

      assert {:error, {:invalid_param, "n", {:below_minimum, 1}}} =
               ParamSchema.validate(s, %{"n" => 0})

      assert {:error, {:invalid_param, "n", {:above_maximum, 10}}} =
               ParamSchema.validate(s, %{"n" => 11})
    end

    test "enforces minimum and maximum on a number" do
      s = schema(%{"pct" => %{"type" => "number", "minimum" => 0.5, "maximum" => 99.5}})

      assert {:ok, %{"pct" => 0.5}} = ParamSchema.validate(s, %{"pct" => 0.5})

      assert {:error, {:invalid_param, "pct", {:below_minimum, 0.5}}} =
               ParamSchema.validate(s, %{"pct" => 0.25})

      assert {:error, {:invalid_param, "pct", {:above_maximum, 99.5}}} =
               ParamSchema.validate(s, %{"pct" => 99.6})
    end

    test "enforces minLength and maxLength on a string, inclusive at both ends" do
      s = schema(%{"vin" => %{"type" => "string", "minLength" => 17, "maxLength" => 17}})
      vin = "5YJ3E1EA7JF000316"

      assert {:ok, %{"vin" => ^vin}} = ParamSchema.validate(s, %{"vin" => vin})

      assert {:error, {:invalid_param, "vin", {:below_min_length, 17}}} =
               ParamSchema.validate(s, %{"vin" => String.slice(vin, 0, 16)})

      assert {:error, {:invalid_param, "vin", {:above_max_length, 17}}} =
               ParamSchema.validate(s, %{"vin" => vin <> "X"})
    end

    # A combining sequence is one grapheme and two codepoints; the bound is
    # counted in codepoints, so `String.length/1` is the wrong ruler here.
    test "counts minLength and maxLength in codepoints, not graphemes" do
      s = schema(%{"s" => %{"type" => "string", "maxLength" => 1}})
      combining = "e\u0301"

      assert String.length(combining) == 1

      assert {:error, {:invalid_param, "s", {:above_max_length, 1}}} =
               ParamSchema.validate(s, %{"s" => combining})
    end

    test "a param that declares no bounds is unaffected" do
      s = schema(%{"n" => %{"type" => "integer"}, "s" => %{"type" => "string"}})

      assert {:ok, %{"n" => 100_000, "s" => "anything at all"}} =
               ParamSchema.validate(s, %{"n" => 100_000, "s" => "anything at all"})
    end

    test "a default that violates a bound is itself refused" do
      s = schema(%{"n" => %{"type" => "integer", "minimum" => 5, "default" => 1}})

      assert {:error, {:invalid_param, "n", {:below_minimum, 5}}} =
               ParamSchema.validate(s, %{})
    end

    test "type and enum still run before bounds" do
      s = schema(%{"n" => %{"type" => "integer", "minimum" => 5}})

      assert {:error, {:invalid_param, "n", {:expected_type, "integer", "3"}}} =
               ParamSchema.validate(s, %{"n" => "3"})
    end

    # A bound is consulted only for the type it can describe: `minimum` says
    # nothing about a string and `minLength` says nothing about an integer.
    test "a bound is not consulted for a type it cannot describe" do
      numeric_on_string = schema(%{"s" => %{"type" => "string", "minimum" => 5}})
      assert {:ok, %{"s" => "ab"}} = ParamSchema.validate(numeric_on_string, %{"s" => "ab"})

      length_on_integer = schema(%{"n" => %{"type" => "integer", "minLength" => 5}})
      assert {:ok, %{"n" => 1}} = ParamSchema.validate(length_on_integer, %{"n" => 1})
    end

    # A declared bound that is not a number is a broken manifest; it fails loud
    # at the first call rather than being silently skipped.
    test "a bound that is not a number is refused rather than skipped" do
      s = schema(%{"n" => %{"type" => "integer", "minimum" => "5"}})

      assert {:error, {:invalid_param, "n", {:invalid_bound, "minimum", "5"}}} =
               ParamSchema.validate(s, %{"n" => 9})
    end

    test "unknown arguments are still dropped, bounds or not" do
      s = schema(%{"n" => %{"type" => "integer", "minimum" => 1}})

      assert {:ok, normalized} = ParamSchema.validate(s, %{"n" => 2, "extra" => "dropped"})
      assert normalized == %{"n" => 2}
    end
  end
end
