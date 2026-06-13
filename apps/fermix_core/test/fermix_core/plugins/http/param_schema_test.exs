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
end
