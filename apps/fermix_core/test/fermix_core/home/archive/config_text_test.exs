defmodule FermixCore.Home.Archive.ConfigTextTest do
  use ExUnit.Case, async: true

  alias FermixCore.Home.Archive.ConfigText

  @old "/home/invented/.fermix"
  @new "/srv/fermix-home"

  @config """
  # Written by an invented operator; comments survive.
  [fermix_core]
  secret_store = "file"

  [sandbox]
  workspace_root = "/home/invented/.fermix/workspace"  # trailing comment
  helper = "/opt/invented/tool"
  sibling = "/home/invented/.fermixer/elsewhere"
  exact = '/home/invented/.fermix'
  quoted = "/home/invented/.fermix/with \\"quotes\\""

  [mcp.servers.notes]
  command = "/home/invented/.fermix/plugins/installed/notes/current/bin/notes"
  args = ["--vault", "/home/invented/.fermix/workspace/vault", "/tmp/invented"]
  """

  test "rewrites only string values that begin with the old root at a path boundary" do
    assert {:ok, rebased, keys} = ConfigText.rebase(@config, @old, @new)

    assert keys == [
             "sandbox.workspace_root",
             "sandbox.exact",
             "sandbox.quoted",
             "mcp.servers.notes.command",
             "mcp.servers.notes.args"
           ]

    assert rebased =~ ~s(workspace_root = "/srv/fermix-home/workspace"  # trailing comment)
    assert rebased =~ ~s(helper = "/opt/invented/tool")
    assert rebased =~ ~s(sibling = "/home/invented/.fermixer/elsewhere")
    assert rebased =~ ~s(exact = '/srv/fermix-home')
    assert rebased =~ ~s(quoted = "/srv/fermix-home/with \\"quotes\\"")

    assert rebased =~
             ~s(args = ["--vault", "/srv/fermix-home/workspace/vault", "/tmp/invented"])

    assert rebased =~ "# Written by an invented operator; comments survive."
    assert String.split(rebased, "\n") |> length() == String.split(@config, "\n") |> length()
  end

  test "the same root rewrites nothing and returns the text unchanged" do
    assert ConfigText.rebase(@config, @old, @old) == {:ok, @config, []}
  end

  test "a path inside a comment or a key is left alone" do
    config = ~s(# see "/home/invented/.fermix/notes"\n"/home/invented/.fermix" = 1\n)
    assert ConfigText.rebase(config, @old, @new) == {:ok, config, []}
  end

  test "a multi-line string is refused rather than guessed at" do
    config = ~s([fermix_core]\nprompt = """\n/home/invented/.fermix/x\n"""\n)
    assert ConfigText.rebase(config, @old, @new) == {:error, :multiline_string}
  end

  test "reads a key's raw value in its section, without its comment" do
    assert ConfigText.value(@config, "sandbox", "helper") == {:ok, ~s("/opt/invented/tool")}

    assert ConfigText.value(@config, "sandbox", "workspace_root") ==
             {:ok, ~s("/home/invented/.fermix/workspace")}

    assert ConfigText.value(@config, "fermix_core", "helper") == :absent
    assert ConfigText.value(@config, "fermix_core.harness", "approved") == :absent
  end

  test "puts a key in place, after its section header, or in a new section" do
    replaced = ConfigText.put(@config, "fermix_core", "secret_store", ~s("keyring"))

    assert replaced ==
             String.replace(@config, ~s(secret_store = "file"), ~s(secret_store = "keyring"))

    with_comment = ConfigText.put(@config, "sandbox", "workspace_root", ~s("/x"))
    assert with_comment =~ ~s(workspace_root = "/x" # trailing comment)

    inserted = ConfigText.put(@config, "sandbox", "approved", "false")
    assert inserted =~ "[sandbox]\napproved = false\nworkspace_root ="

    appended = ConfigText.put(@config, "fermix_core.harness", "approved", "false")
    assert String.ends_with?(appended, "\n\n[fermix_core.harness]\napproved = false\n")
    assert ConfigText.value(appended, "fermix_core.harness", "approved") == {:ok, "false"}
  end

  test "decodes a raw string value and refuses anything else" do
    assert ConfigText.string(~s("keyring")) == {:ok, "keyring"}
    assert ConfigText.string("'file'") == {:ok, "file"}
    assert ConfigText.string(~s("a \\"b\\"")) == {:ok, ~s(a "b")}
    assert ConfigText.string("true") == :error
    assert ConfigText.string(~s("a" "b")) == :error
  end

  test "names the keys that hold absolute paths outside the home, once each" do
    assert ConfigText.paths_outside(@config, @old) == [
             "sandbox.helper",
             "sandbox.sibling",
             "mcp.servers.notes.args"
           ]
  end

  test "counts the secrets the file keeps as keyring references" do
    config = """
    [fermix_core.providers.openai]
    api_key = "@keyring"

    [fermix_channels.telegram]
    bot_token = "@keyring"
    webhook_secret = "@file"
    note = "@keyring is a word here"
    """

    assert ConfigText.keyring_references(config) == 2
    assert ConfigText.keyring_references(@config) == 0
  end
end
