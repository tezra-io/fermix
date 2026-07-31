defmodule FermixCore.Harness.IdentityTest do
  # async: false — the resolution order is defined against the daemon's own USER,
  # so these tests mutate it and restore it (env_test.exs idiom).
  use ExUnit.Case, async: false

  alias FermixCore.Harness.Identity

  setup do
    saved =
      Map.new(["USER", "CLAUDE_CONFIG_DIR", "CODEX_HOME"], &{&1, System.get_env(&1)})

    harness = Application.get_env(:fermix_core, :harness, [])

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      Application.put_env(:fermix_core, :harness, harness)
    end)

    # These assert what happens when nothing is configured, so they must establish
    # that baseline themselves rather than inherit whatever leaked into app env.
    Application.put_env(:fermix_core, :harness, [])
    System.delete_env("CLAUDE_CONFIG_DIR")
    System.delete_env("CODEX_HOME")

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

  # Both ship-time conditions, which break symmetrically and silently: whichever
  # config-dir context the operator logged in under, the child has to run in the
  # same one, or the vendor reads an empty store and reports itself logged out.
  describe "vendor_config_dir/1 + vendor_config_env/1" do
    test "nothing configured anywhere leaves the vendor its own default" do
      assert Identity.vendor_config_dir("claude") == nil
      assert Identity.vendor_config_env("claude") == %{}
      assert Identity.vendor_config_env("codex") == %{}
    end

    test "Fermix's explicit key wins — an operator who set it meant it" do
      Application.put_env(:fermix_core, :harness, claude_config_dir: "/cfg/claude")
      System.put_env("CLAUDE_CONFIG_DIR", "/env/claude")

      assert Identity.vendor_config_dir("claude") == "/cfg/claude"
      assert Identity.vendor_config_env("claude") == %{"CLAUDE_CONFIG_DIR" => "/cfg/claude"}
    end

    # The dangerous condition: this operator never sets a Fermix key, so without
    # inheriting the daemon's own variable the child silently reads the wrong store.
    test "the daemon's own environment is inherited when Fermix has no key" do
      System.put_env("CLAUDE_CONFIG_DIR", "/env/claude")
      System.put_env("CODEX_HOME", "/env/codex")

      assert Identity.vendor_config_env("claude") == %{"CLAUDE_CONFIG_DIR" => "/env/claude"}
      assert Identity.vendor_config_env("codex") == %{"CODEX_HOME" => "/env/codex"}
    end

    test "an empty value is not a config dir" do
      System.put_env("CLAUDE_CONFIG_DIR", "")

      assert Identity.vendor_config_dir("claude") == nil
    end

    test "an unknown vendor gets no overlay" do
      assert Identity.vendor_config_dir("codex_cloud") == nil
      assert Identity.vendor_config_env("codex_cloud") == %{}
    end
  end
end
