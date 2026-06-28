defmodule FermixCore.Prompt.IdentityNameTest do
  # async: false — mutates the global `:fermix_core, :agent` app env, which many
  # modules read. Each test sets + restores it (see setup) to avoid the leaked
  # global-env flake class.
  use ExUnit.Case, async: false

  alias FermixCore.Prompt.IdentityName

  @identity """
  # IDENTITY.md — Who Am I?

  - **Name:** fermix
  - **Creature:** AI assistant running on Fermix — partner more than tool

  ## History
  operator notes preserved
  """

  setup do
    unique = System.unique_integer([:positive])
    base_dir = Path.join(System.tmp_dir!(), "fermix-identity-name-#{unique}")
    File.mkdir_p!(base_dir)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(base_dir) end)

    original_agent = Application.get_env(:fermix_core, :agent)
    on_exit(fn -> restore_agent(original_agent) end)

    %{base_dir: base_dir}
  end

  defp restore_agent(nil), do: Application.delete_env(:fermix_core, :agent)
  defp restore_agent(value), do: Application.put_env(:fermix_core, :agent, value)

  defp put_name(name), do: Application.put_env(:fermix_core, :agent, name: name)

  defp write_identity(base_dir, body) do
    agent_dir = Path.join(base_dir, "main")
    File.mkdir_p!(agent_dir)
    path = Path.join(agent_dir, "IDENTITY.md")
    File.write!(path, body)
    path
  end

  test "rewrites a stale Name line to the configured name, preserving the rest", %{
    base_dir: base_dir
  } do
    put_name("fermi")
    path = write_identity(base_dir, @identity)

    assert :ok = IdentityName.reconcile(bootstrap_dir: base_dir)

    updated = File.read!(path)
    assert updated =~ "- **Name:** fermi"
    refute updated =~ "**Name:** fermix"
    # The product name in the Creature line and operator history are untouched.
    assert updated =~ "running on Fermix"
    assert updated =~ "operator notes preserved"
  end

  test "is a no-op when the Name already matches the configured name", %{base_dir: base_dir} do
    put_name("fermix")
    path = write_identity(base_dir, @identity)

    assert :ok = IdentityName.reconcile(bootstrap_dir: base_dir)
    assert File.read!(path) == @identity
  end

  test "leaves the file untouched when no name is configured (no clobber of manual edits)", %{
    base_dir: base_dir
  } do
    Application.delete_env(:fermix_core, :agent)
    path = write_identity(base_dir, @identity)

    assert :ok = IdentityName.reconcile(bootstrap_dir: base_dir)
    assert File.read!(path) == @identity
  end

  test "treats a blank configured name as unset (no clobber)", %{base_dir: base_dir} do
    put_name("   ")
    path = write_identity(base_dir, @identity)

    assert :ok = IdentityName.reconcile(bootstrap_dir: base_dir)
    assert File.read!(path) == @identity
  end

  test "is a no-op when IDENTITY.md has no Name line", %{base_dir: base_dir} do
    put_name("fermi")
    body = "# IDENTITY.md\n\n- **Creature:** something\n"
    path = write_identity(base_dir, body)

    assert :ok = IdentityName.reconcile(bootstrap_dir: base_dir)
    assert File.read!(path) == body
  end

  test "is idempotent across repeated runs", %{base_dir: base_dir} do
    put_name("fermi")
    path = write_identity(base_dir, @identity)

    assert :ok = IdentityName.reconcile(bootstrap_dir: base_dir)
    first = File.read!(path)
    assert :ok = IdentityName.reconcile(bootstrap_dir: base_dir)
    assert File.read!(path) == first
    assert first =~ "- **Name:** fermi"
  end

  test "returns :ok when the bootstrap directory does not exist", %{base_dir: base_dir} do
    put_name("fermi")
    assert :ok = IdentityName.reconcile(bootstrap_dir: Path.join(base_dir, "nonexistent"))
  end
end
