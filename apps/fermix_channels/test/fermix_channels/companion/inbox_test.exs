defmodule FermixChannels.Companion.InboxTest do
  @moduledoc """
  The attachment inbox's own rules (companion protocol 7): it makes its
  directory owner-only and empties it as it starts, never recursively and
  never through a link; a name that is not an attach id never reaches the
  file system; and every refusal has a sentence a person reads.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixChannels.Companion.Inbox
  alias FermixChannels.Mobile.MediaStore
  alias FermixTestSupport.SafeRm

  setup do
    root = SafeRm.make_tmp_dir!("companion-inbox")
    on_exit(fn -> SafeRm.rm_rf!(root) end)
    %{root: root, dir: Path.join(root, "inbox")}
  end

  test "it makes the directory owner-only and empties it as it starts", ctx do
    File.mkdir_p!(ctx.dir)
    File.chmod!(ctx.dir, 0o755)
    outside = Path.join(ctx.root, "outside.txt")
    File.write!(outside, "kept")
    File.write!(Path.join(ctx.dir, "left-by-a-crash"), "bytes")
    :ok = File.ln_s(outside, Path.join(ctx.dir, "a-link"))
    File.mkdir_p!(Path.join([ctx.dir, "a-directory"]))
    File.write!(Path.join([ctx.dir, "a-directory", "inside"]), "kept")

    log =
      capture_log(fn ->
        start_supervised!({Inbox, name: nil, dir: ctx.dir, store: nil})
      end)

    assert File.ls!(ctx.dir) == ["a-directory"]
    assert File.read!(Path.join([ctx.dir, "a-directory", "inside"])) == "kept"
    assert File.read!(outside) == "kept"
    assert Bitwise.band(File.stat!(ctx.dir).mode, 0o777) == 0o700
    assert log =~ "companion inbox entry left alone"
  end

  test "a directory that is not absolute starts nothing", ctx do
    Process.flag(:trap_exit, true)
    assert {:error, {:invalid_dir, "inbox"}} = Inbox.start_link(name: nil, dir: "inbox")
    refute File.exists?(ctx.dir)
  end

  test "a name that is not an attach id never reaches the file system", ctx do
    store =
      start_supervised!(
        {MediaStore, name: nil, root: Path.join(ctx.root, "mobile"), max_media_bytes: 64}
      )

    inbox = start_supervised!({Inbox, name: nil, dir: ctx.dir, store: store})
    beside = Path.join(ctx.root, "beside")
    File.write!(beside, "kept")

    assert {:error, {:invalid_field, :attach_id}} =
             Inbox.take(inbox, %{"attach_id" => "../beside", "kind" => "file"})

    assert :ok = Inbox.discard(inbox, "../beside")
    assert File.read!(beside) == "kept"
  end

  test "the offer is the directory and the store's bound, and nothing while it is down", ctx do
    store =
      start_supervised!(
        {MediaStore, name: nil, root: Path.join(ctx.root, "mobile"), max_media_bytes: 64},
        id: :store
      )

    inbox = start_supervised!({Inbox, name: nil, dir: ctx.dir, store: store})
    assert Inbox.offer(inbox) == {:ok, %{"dir" => ctx.dir, "max_bytes" => 64}}

    :ok = stop_supervised(:store)
    assert Inbox.offer(inbox) == {:error, :store_not_running}
  end

  test "every refusal has its sentence, sentence case with no exclamation or em dash" do
    sentences = %{
      :not_owner => "Only the owner's own Fermix app can attach files.",
      :no_inbox =>
        "Files cannot be attached from this computer while Fermix runs on another one.",
      :store_not_running => "Fermix cannot take files right now. Try again later.",
      :file_missing => "Fermix found no file to take. Attach it again.",
      {:not_regular_file, :symlink} =>
        "Fermix takes only a plain file the app saved for it. Attach it again.",
      {:media_too_large, 30_000_000, 20_971_520} =>
        "This file is too large: Fermix takes files of up to 20 MB.",
      {:media_too_large, 2_000, 1_536} =>
        "This file is too large: Fermix takes files of up to 1536 bytes.",
      {:store_quota_exceeded, 600} =>
        "Fermix has no room for this file right now. Try a smaller one.",
      :upload_limit_reached =>
        "Fermix is already taking in as many files as it can. Try again in a moment.",
      :store_upload_limit_reached =>
        "Fermix is already taking in as many files as it can. Try again in a moment.",
      :attachment_exists => "Fermix already has a file under this name. Attach it again.",
      :upload_exists => "Fermix already has a file under this name. Attach it again.",
      {:size_exceeded, 18, 17} =>
        "This file changed before Fermix could read it. Attach it again.",
      {:size_mismatch, 17, 9} =>
        "This file changed before Fermix could read it. Attach it again.",
      {:sha256_mismatch, expected: "a", actual: "b"} =>
        "This file changed before Fermix could read it. Attach it again.",
      {:file_unreadable, :eacces} => "Fermix could not read this file.",
      {:read_failed, :eio} => "Fermix could not read this file.",
      {:commit_failed, :enospc} => "Fermix could not store this file."
    }

    for {reason, sentence} <- sentences do
      described = Inbox.describe_error(reason)
      assert described == sentence, inspect(reason)
      refute described =~ ~r/[!—]/u
      assert described =~ ~r/\A[A-Z]/
    end
  end
end
