defmodule FermixCore.Memory.AdmissionTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Admission

  describe "category_allowed?/2" do
    test "accepts known categories for operator/nil trust" do
      assert Admission.category_allowed?("preference", :operator)
      assert Admission.category_allowed?("interest", nil)
      assert Admission.category_allowed?("directive", :operator)
      assert Admission.category_allowed?("context", nil)
    end

    test "rejects unknown categories regardless of trust" do
      refute Admission.category_allowed?("rumor", :operator)
      refute Admission.category_allowed?("", nil)
    end

    test "rejects retired pre-taxonomy categories" do
      for stale <- ~w(project environment instruction correction episode) do
        refute Admission.category_allowed?(stale, :operator)
      end
    end

    test "guest trust cannot promote directive" do
      refute Admission.category_allowed?("directive", :guest)
    end

    test "guest trust keeps the rest of the category surface" do
      assert Admission.category_allowed?("preference", :guest)
      assert Admission.category_allowed?("identity", :guest)
      assert Admission.category_allowed?("interest", :guest)
      assert Admission.category_allowed?("goal", :guest)
      assert Admission.category_allowed?("context", :guest)
    end
  end

  describe "promotable_category?/2" do
    test "user bucket accepts only the USER.md spine" do
      for category <- ~w(identity preference interest goal) do
        assert Admission.promotable_category?(:user, category)
      end

      refute Admission.promotable_category?(:user, "context")
      refute Admission.promotable_category?(:user, "directive")
    end

    test "memory bucket accepts only context and directive" do
      assert Admission.promotable_category?(:memory, "context")
      assert Admission.promotable_category?(:memory, "directive")
      refute Admission.promotable_category?(:memory, "preference")
    end
  end

  describe "prompt_target/1" do
    test "owner scope routes identity/preference/interest/goal to USER.md" do
      assert prompt_target("identity", "owner") == "user_md"
      assert prompt_target("preference", "owner") == "user_md"
      assert prompt_target("interest", "owner") == "user_md"
      assert prompt_target("goal", "owner") == "user_md"
    end

    test "owner scope routes context/directive to MEMORY.md" do
      assert prompt_target("context", "owner") == "memory_md"
      assert prompt_target("directive", "owner") == "memory_md"
    end

    test "agent scope routes only memory-promoted categories" do
      assert prompt_target("context", "agent") == "memory_md"
      assert prompt_target("directive", "agent") == "memory_md"
      assert prompt_target("preference", "agent") == "none"
    end

    test "conversation scope promotes context but never directive" do
      assert prompt_target("context", "conversation") == "memory_md"
      assert prompt_target("directive", "conversation") == "none"
      assert prompt_target("preference", "conversation") == "none"
    end

    test "job scope never promotes" do
      assert prompt_target("context", "job") == "none"
      assert prompt_target("identity", "job") == "none"
    end
  end

  defp prompt_target(category, scope_type) do
    Admission.prompt_target(%{category: category, scope_type: scope_type})
  end
end
