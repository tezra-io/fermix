defmodule FermixCore.Harness.IdentityTest do
  # async: false — the resolution order is defined against the daemon's own USER,
  # so these tests mutate it and restore it (env_test.exs idiom).
  use ExUnit.Case, async: false

  alias FermixCore.Harness.Identity

  setup do
    original = System.get_env("USER")

    on_exit(fn ->
      case original do
        nil -> System.delete_env("USER")
        value -> System.put_env("USER", value)
      end
    end)

    :ok
  end

  describe "username/1" do
    test "uses the daemon's USER when it has one" do
      System.put_env("USER", "operator")

      assert Identity.username(resolver: fn -> "never-consulted" end) == "operator"
    end

    # The Linux/container case: a daemon with no USER still has a determinable
    # account name, so the run proceeds instead of being refused for a variable
    # its file-based vendor never reads.
    test "falls through to the passwd database when USER is absent" do
      System.delete_env("USER")

      assert Identity.username(resolver: fn -> "passwd-name" end) == "passwd-name"
    end

    test "treats an empty USER as absent" do
      System.put_env("USER", "")

      assert Identity.username(resolver: fn -> "passwd-name" end) == "passwd-name"
    end

    # Unresolvable must stay nil: `Harness.Env` turns it into a pre-spawn refusal
    # rather than inventing a placeholder, because a wrong account name spawns a
    # healthy CLI that reads an empty credential store and reports "not logged in".
    test "is nil when neither source answers" do
      System.delete_env("USER")

      assert Identity.username(resolver: fn -> nil end) == nil
      assert Identity.username(resolver: fn -> "" end) == nil
    end

    # The real resolver, exercised once so the seam cannot drift from the thing it
    # stands in for. `id -un` is POSIX; asserting the shape rather than the value
    # keeps it host-independent.
    test "the real passwd lookup returns a plausible account name" do
      System.delete_env("USER")

      name = Identity.username()

      assert is_binary(name)
      assert name != ""
      refute name =~ ~r/\s/
    end
  end
end
