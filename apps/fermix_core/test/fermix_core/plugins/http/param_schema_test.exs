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
end
