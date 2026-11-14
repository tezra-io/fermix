defmodule FermixChannels.Desktop.UploadsTest do
  @moduledoc """
  The files a computer's app attaches, carried to its server (M97 §9.3,
  D22), over the real link: this computer's `Desktop.Uploads` and
  `Desktop.Relay`, the rail's Noise session to the server's real
  `Mobile.Session`, and the server's real `Mobile.MediaStore`. A stand-in
  relay covers what the real one cannot be made to do on cue: a server that
  takes no upload, and one that never answers.

  async: false: the relay's dial names are VM-wide.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias FermixChannels.Desktop.Uploads
  alias FermixChannels.Mobile.MediaStore
  alias FermixChannels.Test.DesktopRail
  alias FermixTestSupport.SafeRm

  @arrival_ms 10_000
  @bytes String.duplicate("a page of the lease ", 6_000)

  defmodule QuietRelay do
    @moduledoc false
    # A relay whose server takes uploads and never answers one.
    use GenServer

    def start_link(test), do: GenServer.start_link(__MODULE__, test)

    @impl true
    def init(test), do: {:ok, test}

    @impl true
    def handle_call(:upload_bound, _from, test), do: {:reply, {:ok, 1_048_576}, test}

    def handle_call({:send, type, fields, _payload}, _from, test) do
      send(test, {:sent, type, fields})
      {:reply, :ok, test}
    end
  end

  setup do
    dir = SafeRm.make_tmp_dir!("desktop-uploads")
    on_exit(fn -> SafeRm.rm_rf!(dir) end)
    %{dir: dir, inbox: Path.join(dir, "inbox")}
  end

  describe "over the link" do
    setup ctx do
      store =
        start_supervised!(
          {MediaStore,
           name: nil,
           root: Path.join(ctx.dir, "server"),
           max_media_bytes: 262_144,
           max_store_bytes: 1_048_576},
          id: :server_store
        )

      primary = DesktopRail.primary!(media_store: store)
      root = DesktopRail.desktop_home!(primary)
      # The relay hands the server's answers to this computer's uploads.
      relay = :"uploads_relay_#{System.unique_integer([:positive])}"
      uploads = start_uploads!(ctx.inbox, relay)
      DesktopRail.start_relay!(root, primary, name: relay, families: %{attach: uploads})
      DesktopRail.await_connected(relay)
      %{store: store, relay: relay, uploads: uploads}
    end

    test "a file the app attached lands in the server's store with its SHA-256, the inbox " <>
           "emptied before the answer",
         ctx do
      attachment = attach!(ctx.inbox, "mac-att-1", @bytes, "lease.pdf")

      assert {:ok, %{"dir" => dir, "max_bytes" => max}} = Uploads.offer(ctx.uploads)
      assert dir == ctx.inbox
      assert is_integer(max) and max > 0

      :ok = Uploads.take(ctx.uploads, attachment, self())
      assert_receive {:upload_done, "mac-att-1", :present}, @arrival_ms
      refute File.exists?(Path.join(ctx.inbox, "mac-att-1"))

      assert {:ok, stored} = MediaStore.attachment(ctx.store, "mac-att-1")
      assert stored.ref == sha256(@bytes)

      # The same bytes under another id are present at once: the digest goes
      # first, and the server already holds it.
      again = attach!(ctx.inbox, "mac-att-2", @bytes, "lease copy.pdf")
      :ok = Uploads.take(ctx.uploads, again, self())
      assert_receive {:upload_done, "mac-att-2", :present}, @arrival_ms
      assert {:ok, %{ref: ref}} = MediaStore.attachment(ctx.store, "mac-att-2")
      assert ref == sha256(@bytes)
    end

    test "a file the server refuses says why, in the words a primary uses", ctx do
      big = :binary.copy("x", 300_000)
      attachment = attach!(ctx.inbox, "mac-att-big", big, "scan.tiff")

      :ok = Uploads.take(ctx.uploads, attachment, self())
      assert_receive {:upload_done, "mac-att-big", {:error, sentence}}, @arrival_ms
      assert sentence =~ "This file is too large"
      assert MediaStore.attachment(ctx.store, "mac-att-big") == {:error, :unknown_attachment}
    end

    test "a file that changed after the app announced it is refused before it is sent", ctx do
      attachment = %{
        attach!(ctx.inbox, "mac-att-3", @bytes, "notes.txt")
        | "sha256" => sha256("x")
      }

      :ok = Uploads.take(ctx.uploads, attachment, self())
      assert_receive {:upload_done, "mac-att-3", {:error, sentence}}, @arrival_ms
      assert sentence == "This file changed before Fermix could read it. Attach it again."
      refute File.exists?(Path.join(ctx.inbox, "mac-att-3"))
    end
  end

  # M97 §9.3: a move back to this computer drops every upload still under
  # way, each told why, naming its file.
  test "a move back drops an upload under way and the ones waiting, each named", ctx do
    relay = start_supervised!({QuietRelay, self()})
    uploads = start_uploads!(ctx.inbox, relay)

    running = attach!(ctx.inbox, "mac-att-4", @bytes, "IMG_0412.jpg")
    waiting = attach!(ctx.inbox, "mac-att-5", @bytes, "IMG_0413.jpg")
    :ok = Uploads.take(uploads, running, self())
    :ok = Uploads.take(uploads, waiting, self())
    assert_receive {:sent, "attach_begin", %{"attach_id" => "mac-att-4"}}, @arrival_ms

    why = "Fermix is moving back to this Mac. Attach it again once the move is done."
    assert Uploads.drop_all(uploads, why) == :ok

    assert_received {:upload_done, "mac-att-4", {:error, first}}
    assert first == "IMG_0412.jpg was not sent: " <> why
    assert_received {:upload_done, "mac-att-5", {:error, second}}
    assert second == "IMG_0413.jpg was not sent: " <> why
    refute File.exists?(Path.join(ctx.inbox, "mac-att-5"))
    refute_received {:sent, "attach_begin", %{"attach_id" => "mac-att-5"}}
  end

  test "the session ending under an upload says the relay's sentence", ctx do
    relay = start_supervised!({QuietRelay, self()})
    uploads = start_uploads!(ctx.inbox, relay)
    :ok = Uploads.take(uploads, attach!(ctx.inbox, "mac-att-6", @bytes, "a.pdf"), self())
    assert_receive {:sent, "attach_begin", _fields}, @arrival_ms

    said = "The server garden server is unreachable. Fermix keeps your message until it is back."
    :ok = Uploads.link_down(uploads, said)
    assert_receive {:upload_done, "mac-att-6", {:error, ^said}}, @arrival_ms
  end

  # -- helpers ----------------------------------------------------------------------

  defp start_uploads!(inbox, relay),
    do: start_supervised!({Uploads, name: nil, dir: inbox, relay: relay}, id: :uploads)

  defp attach!(inbox, attach_id, bytes, name) do
    path = Path.join(inbox, attach_id)
    File.write!(path, bytes)
    File.chmod!(path, 0o600)

    %{
      "attach_id" => attach_id,
      "kind" => "document",
      "mime" => "application/pdf",
      "size_bytes" => byte_size(bytes),
      "sha256" => sha256(bytes),
      "name" => name
    }
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
