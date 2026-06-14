defmodule FermixCore.Memory.AdmissionTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Admission

  describe "category_allowed?/2" do
    test "accepts known categories for operator/nil trust" do
      assert Admission.category_allowed?("preference", :operator)
      assert Admission.category_allowed?("instruction", nil)
      assert Admission.category_allowed?("correction", :operator)
    end

    test "rejects unknown categories regardless of trust" do
      refute Admission.category_allowed?("rumor", :operator)
      refute Admission.category_allowed?("", nil)
    end

    test "guest trust cannot promote instruction or correction" do
      refute Admission.category_allowed?("instruction", :guest)
      refute Admission.category_allowed?("correction", :guest)
    end

    test "guest trust keeps the rest of the category surface" do
      assert Admission.category_allowed?("preference", :guest)
      assert Admission.category_allowed?("identity", :guest)
      assert Admission.category_allowed?("project", :guest)
    end
  end

  describe "prompt_target/1" do
    test "owner scope routes identity/preference/goal to USER.md" do
      assert prompt_target("identity", "owner") == "user_md"
      assert prompt_target("preference", "owner") == "user_md"
      assert prompt_target("goal", "owner") == "user_md"
    end

    test "owner scope routes project/environment/instruction to MEMORY.md" do
      assert prompt_target("project", "owner") == "memory_md"
      assert prompt_target("environment", "owner") == "memory_md"
      assert prompt_target("instruction", "owner") == "memory_md"
    end

    test "agent scope routes only memory-promoted categories" do
      assert prompt_target("project", "agent") == "memory_md"
      assert prompt_target("instruction", "agent") == "memory_md"
      assert prompt_target("preference", "agent") == "none"
    end

    test "conversation scope promotes memory categories except correction" do
      assert prompt_target("project", "conversation") == "memory_md"
      assert prompt_target("correction", "conversation") == "none"
      assert prompt_target("preference", "conversation") == "none"
    end

    test "job scope never promotes" do
      assert prompt_target("project", "job") == "none"
      assert prompt_target("identity", "job") == "none"
    end
  end

  defp prompt_target(category, scope_type) do
    Admission.prompt_target(%{category: category, scope_type: scope_type})
  end
end
