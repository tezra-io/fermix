defmodule FermixChannels.Mobile.MediaStoreTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias FermixChannels.Mobile.MediaStore

  setup do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("mobile-media-store")

    store =
      start_supervised!(
        {MediaStore, name: nil, root: root, max_media_bytes: 64, max_store_bytes: 128}
      )

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)
    %{root: root, store: store}
  end

  test "streams ordered chunks into a verified content-addressed blob", %{store: store} do
    bytes = "hello mobile"
    digest = sha256(bytes)

    assert {:ok, :upload} = MediaStore.begin_upload(store, upload("a-1", bytes, digest))
    assert :ok = MediaStore.write_chunk(store, "a-1", 0, "hello ")
    assert :ok = MediaStore.write_chunk(store, "a-1", 1, "mobile")
    assert {:ok, ^digest} = MediaStore.finish_upload(store, "a-1", digest)

    assert {:ok, %{ref: ^digest, size_bytes: 12, path: path}} = MediaStore.fetch(store, digest)
    assert File.read!(path) == bytes
    assert file_mode(path) == 0o600
  end

  test "deduplicates at begin and preserves attachment metadata", %{store: store} do
    bytes = "same"
    digest = sha256(bytes)

    assert {:ok, ^digest} =
             MediaStore.put_bytes(store, bytes, %{kind: "image", mime: "image/jpeg"})

    assert {:ok, :present} =
             MediaStore.begin_upload(store, upload("a-2", bytes, digest, name: "photo.jpg"))

    assert {:ok, attachment} = MediaStore.attachment(store, "a-2")
    assert attachment.ref == digest
    assert attachment.kind == "image"
    assert attachment.mime_type == "image/jpeg"
    assert attachment.file_name == "photo.jpg"
  end

  test "rejects out-of-order chunks without advancing the upload", %{store: store} do
    bytes = "abcdef"
    digest = sha256(bytes)

    assert {:ok, :upload} = MediaStore.begin_upload(store, upload("a-3", bytes, digest))

    assert {:error, {:unexpected_chunk, expected: 0, got: 1}} =
             MediaStore.write_chunk(store, "a-3", 1, bytes)

    assert :ok = MediaStore.write_chunk(store, "a-3", 0, bytes)
    assert {:ok, ^digest} = MediaStore.finish_upload(store, "a-3", digest)
  end

  test "hash mismatch fails loudly and removes the partial upload", %{root: root, store: store} do
    bytes = "abcdef"
    announced = sha256("different")

    assert {:ok, :upload} = MediaStore.begin_upload(store, upload("a-4", bytes, announced))
    assert :ok = MediaStore.write_chunk(store, "a-4", 0, bytes)

    assert {:error, {:sha256_mismatch, expected: ^announced, actual: actual}} =
             MediaStore.finish_upload(store, "a-4", announced)

    assert actual == sha256(bytes)
    assert {:error, :unknown_upload} = MediaStore.write_chunk(store, "a-4", 1, "x")
    assert Path.wildcard(Path.join([root, "uploads", "*"])) == []
  end

  test "declared and streamed byte caps are enforced before persistence", %{store: store} do
    oversized = String.duplicate("x", 65)

    assert {:error, {:media_too_large, 65, 64}} =
             MediaStore.begin_upload(store, upload("a-5", oversized, sha256(oversized)))

    bytes = String.duplicate("x", 64)
    digest = sha256(bytes)
    assert {:ok, :upload} = MediaStore.begin_upload(store, upload("a-6", bytes, digest))

    assert {:error, {:size_exceeded, 65, 64}} =
             MediaStore.write_chunk(store, "a-6", 0, String.duplicate("x", 65))
  end

  test "materialize_attachment copies the durable blob to a disposable temp path", %{
    store: store
  } do
    bytes = "provider input"
    digest = sha256(bytes)
    assert {:ok, :upload} = MediaStore.begin_upload(store, upload("a-7", bytes, digest))
    assert :ok = MediaStore.write_chunk(store, "a-7", 0, bytes)
    assert {:ok, ^digest} = MediaStore.finish_upload(store, "a-7", digest)

    assert {:ok, %{path: temp_path, ref: ^digest}} =
             MediaStore.materialize_attachment(store, "a-7")

    assert File.read!(temp_path) == bytes
    assert {:ok, %{path: durable_path}} = MediaStore.fetch(store, digest)
    refute temp_path == durable_path

    assert :ok = FermixTestSupport.SafeRm.rm(temp_path)
    assert File.read!(durable_path) == bytes
  end

  test "a materialized copy is named for its mime type, which a provider reads the format from",
       %{store: store} do
    bytes = "OggS voice"
    digest = sha256(bytes)
    voice_note = %{upload("v-1", bytes, digest) | kind: "audio", mime: "audio/ogg"}

    assert {:ok, :upload} = MediaStore.begin_upload(store, voice_note)
    assert :ok = MediaStore.write_chunk(store, "v-1", 0, bytes)
    assert {:ok, ^digest} = MediaStore.finish_upload(store, "v-1", digest)

    assert {:ok, %{path: temp_path}} = MediaStore.materialize_attachment(store, "v-1")
    assert Path.extname(temp_path) == ".ogg"
    assert :ok = FermixTestSupport.SafeRm.rm(temp_path)
  end

  test "completed attachment metadata and materialization survive a store restart", %{
    root: root,
    store: store
  } do
    bytes = "restart-safe"
    digest = sha256(bytes)

    assert {:ok, :upload} =
             MediaStore.begin_upload(
               store,
               upload("restart-1", bytes, digest, name: "restart.jpg")
             )

    assert :ok = MediaStore.write_chunk(store, "restart-1", 0, bytes)
    assert {:ok, ^digest} = MediaStore.finish_upload(store, "restart-1", digest)

    restarted = restart_store(root)

    assert {:ok,
            %{
              ref: ^digest,
              kind: "image",
              mime_type: "image/jpeg",
              file_name: "restart.jpg",
              size_bytes: 12
            }} = MediaStore.attachment(restarted, "restart-1")

    assert {:ok, %{path: path, ref: ^digest}} =
             MediaStore.materialize_attachment(restarted, "restart-1")

    assert File.read!(path) == bytes
    assert :ok = FermixTestSupport.SafeRm.rm(path)
  end

  # M67: a still uploaded as a video's poster keeps naming that video across a
  # restart, so the message that names both can pair them.
  test "a poster's video survives a store restart; a blank one is refused", %{
    root: root,
    store: store
  } do
    bytes = "poster"
    digest = sha256(bytes)
    poster = Map.put(upload("poster-1", bytes, digest), :poster_of, "clip-1")

    assert {:ok, :upload} = MediaStore.begin_upload(store, poster)
    assert :ok = MediaStore.write_chunk(store, "poster-1", 0, bytes)
    assert {:ok, ^digest} = MediaStore.finish_upload(store, "poster-1", digest)
    assert {:ok, %{poster_of: "clip-1"}} = MediaStore.attachment(store, "poster-1")

    restarted = restart_store(root)
    assert {:ok, %{poster_of: "clip-1"}} = MediaStore.attachment(restarted, "poster-1")

    blank = Map.put(upload("poster-2", "x", sha256("x")), :poster_of, "")
    assert {:error, {:invalid_field, :poster_of}} = MediaStore.begin_upload(restarted, blank)
  end

  test "deduplicated begin persists its attachment mapping before replying present", %{
    root: root,
    store: store
  } do
    bytes = "already stored"
    digest = sha256(bytes)
    assert {:ok, ^digest} = MediaStore.put_bytes(store, bytes, %{})

    assert {:ok, :present} =
             MediaStore.begin_upload(
               store,
               upload("restart-2", bytes, digest, name: "present.jpg")
             )

    restarted = restart_store(root)

    assert {:ok, %{ref: ^digest, file_name: "present.jpg"}} =
             MediaStore.attachment(restarted, "restart-2")
  end

  test "LRU cap evicts the least recently accessed complete blob", %{root: root} do
    store =
      start_supervised!(
        {MediaStore,
         name: nil, root: Path.join(root, "small"), max_media_bytes: 8, max_store_bytes: 10}
      )

    assert {:ok, first} = MediaStore.put_bytes(store, "123456", %{})
    assert {:ok, second} = MediaStore.put_bytes(store, "abcdef", %{})

    assert {:error, :media_gone} = MediaStore.fetch(store, first)
    assert {:ok, %{ref: ^second}} = MediaStore.fetch(store, second)
  end

  test "LRU eviction invalidates attachment mappings durably", %{root: root} do
    small_root = Path.join(root, "eviction")

    store =
      start_supervised!(
        {MediaStore, name: nil, root: small_root, max_media_bytes: 8, max_store_bytes: 10}
      )

    first_bytes = "123456"
    first = sha256(first_bytes)
    assert {:ok, :upload} = MediaStore.begin_upload(store, upload("evicted", first_bytes, first))
    assert :ok = MediaStore.write_chunk(store, "evicted", 0, first_bytes)
    assert {:ok, ^first} = MediaStore.finish_upload(store, "evicted", first)

    assert {:ok, _second} = MediaStore.put_bytes(store, "abcdef", %{})
    assert {:error, :unknown_attachment} = MediaStore.attachment(store, "evicted")

    restarted = restart_store(small_root, max_media_bytes: 8, max_store_bytes: 10)
    assert {:error, :unknown_attachment} = MediaStore.attachment(restarted, "evicted")
  end

  test "manifest is private and normal writes leave no temporary files", %{
    root: root,
    store: store
  } do
    bytes = "private"
    digest = sha256(bytes)
    assert {:ok, :upload} = MediaStore.begin_upload(store, upload("private", bytes, digest))
    assert :ok = MediaStore.write_chunk(store, "private", 0, bytes)
    assert {:ok, ^digest} = MediaStore.finish_upload(store, "private", digest)

    manifest = Path.join(root, "attachments.json")
    assert file_mode(manifest) == 0o600
    assert Path.wildcard(Path.join(root, "*.part")) == []
  end

  test "corrupt and insecure manifests stop startup loudly", %{root: root} do
    assert :ok = stop_supervised({MediaStore, root})
    manifest = Path.join(root, "attachments.json")

    File.write!(manifest, "{")
    File.chmod!(manifest, 0o600)

    assert_start_failure(root, :invalid_attachment_manifest)

    File.write!(manifest, ~s({"version":1,"attachments":[]}))
    File.chmod!(manifest, 0o644)

    assert_start_failure(root, :insecure_attachment_manifest)
  end

  # M72: the channels application starts the store whether or not a phone is
  # paired, so a manifest it cannot read must start nothing rather than
  # restart under the application's own supervisor.
  test "an admitted start starts nothing on a manifest it cannot read, and says why", %{
    root: root
  } do
    assert :ok = stop_supervised({MediaStore, root})
    manifest = Path.join(root, "attachments.json")
    File.write!(manifest, "{")
    File.chmod!(manifest, 0o600)
    opts = [name: nil, root: root, max_media_bytes: 64, max_store_bytes: 128]

    {result, log} = with_log(fn -> MediaStore.start_admitted(opts) end)
    assert result == :ignore
    assert log =~ "invalid_attachment_manifest"

    File.write!(manifest, ~s({"version":1,"attachments":[]}))
    assert {:ok, store} = MediaStore.start_admitted(opts)
    GenServer.stop(store)
  end

  test "the application's store lives in the home's mobile folder, with the configured caps" do
    assert MediaStore.configured("/home/fermix", max_media_bytes: 10, media_store_max_bytes: 20) ==
             [
               root: "/home/fermix/mobile",
               name: MediaStore,
               max_media_bytes: 10,
               max_store_bytes: 20
             ]

    assert %{id: MediaStore, start: {MediaStore, :start_admitted, [opts]}} =
             MediaStore.boot_child(max_media_bytes: 10)

    assert opts[:name] == MediaStore
    assert opts[:max_media_bytes] == 10
    assert Path.basename(opts[:root]) == "mobile"
  end

  test "a foreign media entry is skipped loudly instead of refusing the boot", %{
    root: root,
    store: store
  } do
    bytes = "survives a finder visit"
    digest = sha256(bytes)
    assert {:ok, ^digest} = MediaStore.put_bytes(store, bytes, %{})

    assert :ok = stop_supervised({MediaStore, root})
    stray = Path.join([root, "media", ".DS_Store"])
    File.write!(stray, "finder junk")

    {restarted, log} = with_log(fn -> start_store(root) end)

    assert log =~ ".DS_Store"
    assert {:ok, %{ref: ^digest}} = MediaStore.fetch(restarted, digest)
    assert File.exists?(stray)
  end

  test "a blob restored with loose permissions is excluded, not repaired or refused", %{
    root: root,
    store: store
  } do
    bytes = "restored from backup"
    digest = sha256(bytes)
    assert {:ok, ^digest} = MediaStore.put_bytes(store, bytes, %{})

    assert :ok = stop_supervised({MediaStore, root})
    blob = Path.join([root, "media", digest])
    File.chmod!(blob, 0o644)

    {restarted, log} = with_log(fn -> start_store(root) end)

    assert log =~ digest
    assert log =~ "0644"
    assert {:error, :media_gone} = MediaStore.fetch(restarted, digest)
    assert file_mode(blob) == 0o644
  end

  # SEC-6: a reservation is bytes nobody has sent yet. It is bounded by the
  # quota but never evicts a committed blob; only committed bytes do.
  test "announced uploads never evict a committed blob", %{store: store} do
    kept = String.duplicate("k", 60)
    assert {:ok, kept_ref} = MediaStore.put_bytes(store, kept, %{})

    assert {:ok, :upload} = MediaStore.begin_upload(store, sized_upload("r-1", 60, "1"))
    assert {:ok, :upload} = MediaStore.begin_upload(store, sized_upload("r-2", 60, "2"))

    assert {:error, {:store_quota_exceeded, 60}} =
             MediaStore.begin_upload(store, sized_upload("r-3", 60, "3"))

    assert {:ok, %{ref: ^kept_ref}} = MediaStore.fetch(store, kept_ref)
  end

  test "a committed upload evicts the least recently used blob to fit", %{store: store} do
    old = String.duplicate("o", 60)
    assert {:ok, old_ref} = MediaStore.put_bytes(store, old, %{})
    bytes = String.duplicate("n", 60)
    assert {:ok, new_ref} = MediaStore.put_bytes(store, String.duplicate("m", 60), %{})
    assert {:ok, %{ref: ^new_ref}} = MediaStore.fetch(store, new_ref)

    digest = sha256(bytes)
    assert {:ok, :upload} = MediaStore.begin_upload(store, upload("c-1", bytes, digest))
    assert :ok = MediaStore.write_chunk(store, "c-1", 0, bytes)
    assert {:ok, ^digest} = MediaStore.finish_upload(store, "c-1", digest)

    assert {:error, :media_gone} = MediaStore.fetch(store, old_ref)
    assert {:ok, %{ref: ^new_ref}} = MediaStore.fetch(store, new_ref)
  end

  test "a zero-byte upload completes at once and opens no file", %{root: root, store: store} do
    assert {:ok, :present} = MediaStore.begin_upload(store, upload("empty-1", "", sha256("")))
    assert Path.wildcard(Path.join([root, "uploads", "*"])) == []
    assert {:ok, %{size_bytes: 0}} = MediaStore.attachment(store, "empty-1")

    assert {:error, {:sha256_mismatch, expected: _bad, actual: _empty}} =
             MediaStore.begin_upload(store, upload("empty-2", "", sha256("not empty")))

    assert Path.wildcard(Path.join([root, "uploads", "*"])) == []
  end

  test "one connection holds at most four uploads at once", %{store: store} do
    for index <- 1..4 do
      assert {:ok, :upload} =
               MediaStore.begin_upload(store, sized_upload("o-#{index}", 1, "#{index}"))
    end

    assert {:error, :upload_limit_reached} =
             MediaStore.begin_upload(store, sized_upload("o-5", 1, "5"))

    assert :ok = MediaStore.cancel_upload(store, "o-1")
    assert {:ok, :upload} = MediaStore.begin_upload(store, sized_upload("o-6", 1, "6"))
  end

  test "the store holds at most sixteen uploads at once", %{store: store} do
    uploaders =
      for connection <- 1..4 do
        uploader(
          store,
          for(
            index <- 1..4,
            do: sized_upload("g-#{connection}-#{index}", 1, "#{connection}#{index}")
          )
        )
      end

    assert Enum.all?(
             uploaders,
             &match?({_pid, [{:ok, :upload}, {:ok, :upload}, {:ok, :upload}, {:ok, :upload}]}, &1)
           )

    assert {:error, :store_upload_limit_reached} =
             MediaStore.begin_upload(store, sized_upload("g-17", 1, "17"))
  end

  test "an uploader that goes away takes its partial uploads with it", %{root: root, store: store} do
    {pid, [{:ok, :upload}]} = uploader(store, [sized_upload("gone-1", 4, "gone")])
    assert [_part] = Path.wildcard(Path.join([root, "uploads", "*.part"]))

    ref = Process.monitor(pid)
    send(pid, :exit)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

    assert_eventually(fn -> Path.wildcard(Path.join([root, "uploads", "*.part"])) == [] end)
    assert {:error, :unknown_upload} = MediaStore.write_chunk(store, "gone-1", 0, "data")
  end

  # SEC-7: an attach id is a handle for the message that follows its upload,
  # not a record kept for ever: it expires, and a blob re-sent many times keeps
  # only its newest handles.
  test "an attach id expires after its lifetime", %{root: root} do
    now = System.os_time(:second)
    clock = fn -> now end
    later = fn -> now + 48 * 3_600 + 1 end
    dir = Path.join(root, "ttl")
    store = start_supervised!({MediaStore, name: nil, root: dir, clock: clock}, id: :ttl_store)

    assert {:ok, digest} = MediaStore.put_bytes(store, "photo", %{})
    assert {:ok, :present} = MediaStore.begin_upload(store, upload("ttl-1", "photo", digest))
    assert {:ok, _attachment} = MediaStore.attachment(store, "ttl-1")

    assert :ok = stop_supervised(:ttl_store)

    restarted =
      start_supervised!({MediaStore, name: nil, root: dir, clock: later}, id: :ttl_store)

    assert {:error, :unknown_attachment} = MediaStore.attachment(restarted, "ttl-1")
    refute File.read!(Path.join(dir, "attachments.json")) =~ "ttl-1"
  end

  test "a blob sent again and again keeps only its eight newest attach ids", %{store: store} do
    assert {:ok, digest} = MediaStore.put_bytes(store, "again", %{})

    for index <- 1..10 do
      assert {:ok, :present} =
               MediaStore.begin_upload(store, upload("again-#{index}", "again", digest))
    end

    assert {:error, :unknown_attachment} = MediaStore.attachment(store, "again-1")
    assert {:error, :unknown_attachment} = MediaStore.attachment(store, "again-2")
    assert {:ok, _attachment} = MediaStore.attachment(store, "again-3")
    assert {:ok, _attachment} = MediaStore.attachment(store, "again-10")
  end

  test "the manifest keeps at most its bound of attach ids, newest first", %{root: root} do
    dir = Path.join(root, "bounded")

    store =
      start_supervised!({MediaStore, name: nil, root: dir, max_attachments: 3}, id: :bounded)

    for index <- 1..4 do
      bytes = "blob-#{index}"
      assert {:ok, digest} = MediaStore.put_bytes(store, bytes, %{})
      assert {:ok, :present} = MediaStore.begin_upload(store, upload("b-#{index}", bytes, digest))
    end

    assert {:error, :unknown_attachment} = MediaStore.attachment(store, "b-1")
    assert {:ok, _attachment} = MediaStore.attachment(store, "b-4")
  end

  test "an oversized manifest is dropped and logged, never refused at boot", %{root: root} do
    assert :ok = stop_supervised({MediaStore, root})
    manifest = Path.join(root, "attachments.json")
    File.write!(manifest, String.duplicate(" ", 16 * 1_024 * 1_024 + 1))
    File.chmod!(manifest, 0o600)

    assert :ok = MediaStore.manifest_admissible(root: root)
    {restarted, log} = with_log(fn -> start_store(root) end)

    assert log =~ "attachment manifest"
    assert {:error, :unknown_attachment} = MediaStore.attachment(restarted, "anything")
    assert File.stat!(manifest).size < 1_024
  end

  # Companion protocol 7: the Mac hands over a file by path. It goes through
  # the phone's own upload, chunk by chunk, so the same limits and checks
  # hold, and the reader owns the upload while it runs.
  describe "import_file/3" do
    setup %{root: root} do
      big_root = Path.join(root, "big")
      files = Path.join(root, "files")
      File.mkdir_p!(files)

      store =
        start_supervised!(
          {MediaStore,
           name: nil, root: big_root, max_media_bytes: 1_048_576, max_store_bytes: 4_194_304},
          id: :big_store
        )

      %{big: store, files: files}
    end

    test "a file over several chunks is stored whole, verified, under its attach id", ctx do
      bytes = :crypto.strong_rand_bytes(600 * 1_024)
      path = write_file!(ctx.files, "big", bytes)
      spec = upload("mac-1", bytes, sha256(bytes), name: "big.bin")

      assert {:ok, :present} = MediaStore.import_file(ctx.big, path, spec)
      assert {:ok, %{ref: ref, file_name: "big.bin"}} = MediaStore.attachment(ctx.big, "mac-1")
      assert {:ok, %{path: stored}} = MediaStore.fetch(ctx.big, ref)
      assert File.read!(stored) == bytes
      assert File.read!(path) == bytes

      again = upload("mac-2", bytes, sha256(bytes))
      assert {:ok, :present} = MediaStore.import_file(ctx.big, path, again)
    end

    test "a file that is not what was announced keeps nothing and leaves no upload", ctx do
      bytes = :crypto.strong_rand_bytes(300 * 1_024)
      path = write_file!(ctx.files, "announced", bytes)

      assert {:error, {:size_exceeded, _written, _announced}} =
               MediaStore.import_file(ctx.big, path, %{
                 upload("long", bytes, sha256(bytes))
                 | size_bytes: 1_000
               })

      assert {:error, {:size_mismatch, _announced, _written}} =
               MediaStore.import_file(ctx.big, path, %{
                 upload("short", bytes, sha256(bytes))
                 | size_bytes: byte_size(bytes) + 1
               })

      assert {:error, {:sha256_mismatch, _digests}} =
               MediaStore.import_file(ctx.big, path, upload("other", bytes, sha256("other")))

      for id <- ~w(long short other) do
        assert {:error, :unknown_attachment} = MediaStore.attachment(ctx.big, id)
        assert {:error, :unknown_upload} = MediaStore.cancel_upload(ctx.big, id)
      end
    end

    test "a missing file, a symlink and the store's own limits are refused", ctx do
      bytes = "plain"
      path = write_file!(ctx.files, "plain", bytes)
      link = Path.join(ctx.files, "link")
      :ok = File.ln_s(path, link)

      assert {:error, :file_missing} =
               MediaStore.import_file(
                 ctx.big,
                 Path.join(ctx.files, "none"),
                 upload("a", bytes, sha256(bytes))
               )

      assert {:error, {:not_regular_file, :symlink}} =
               MediaStore.import_file(ctx.big, link, upload("b", bytes, sha256(bytes)))

      assert {:error, {:not_regular_file, :directory}} =
               MediaStore.import_file(ctx.big, ctx.files, upload("c", bytes, sha256(bytes)))

      assert {:error, {:media_too_large, 65, 64}} =
               MediaStore.import_file(ctx.store, path, %{
                 upload("d", bytes, sha256(bytes))
                 | size_bytes: 65
               })

      assert MediaStore.max_media_bytes(ctx.big) == 1_048_576
      assert MediaStore.max_media_bytes(ctx.store) == 64
    end
  end

  test "validates identifiers, hashes, sizes, and root modes", %{root: root, store: store} do
    assert {:error, {:invalid_field, :attach_id}} =
             MediaStore.begin_upload(store, upload("", "x", sha256("x")))

    assert {:error, {:invalid_field, :sha256}} =
             MediaStore.begin_upload(store, upload("a-8", "x", "bad"))

    assert {:error, {:invalid_field, :size_bytes}} =
             MediaStore.begin_upload(store, %{upload("a-9", "x", sha256("x")) | size_bytes: -1})

    assert file_mode(Path.join(root, "media")) == 0o700
    assert file_mode(Path.join(root, "uploads")) == 0o700
  end

  defp upload(id, bytes, digest, opts \\ []) do
    %{
      attach_id: id,
      kind: "image",
      mime: "image/jpeg",
      size_bytes: byte_size(bytes),
      sha256: digest,
      name: Keyword.get(opts, :name)
    }
  end

  # An upload of `size` bytes whose digest names `seed`, distinct per seed.
  defp sized_upload(id, size, seed) do
    %{upload(id, "", sha256(seed)) | size_bytes: size}
  end

  # A process that begins `uploads` and holds them until told to exit.
  defp uploader(store, uploads) do
    test_pid = self()

    pid =
      spawn(fn ->
        results = Enum.map(uploads, &MediaStore.begin_upload(store, &1))
        send(test_pid, {:began, self(), results})

        receive do
          :exit -> :ok
        end
      end)

    on_exit(fn -> send(pid, :exit) end)

    receive do
      {:began, ^pid, results} -> {pid, results}
    after
      2_000 -> flunk("the uploader never began")
    end
  end

  defp assert_eventually(check, attempts \\ 50) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("the condition never held")
      true -> Process.sleep(10) && assert_eventually(check, attempts - 1)
    end
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp write_file!(dir, name, bytes) do
    path = Path.join(dir, name)
    File.write!(path, bytes)
    path
  end

  defp file_mode(path), do: File.stat!(path).mode |> Bitwise.band(0o777)

  defp restart_store(root, opts \\ []) do
    assert :ok = stop_supervised({MediaStore, root})
    start_store(root, opts)
  end

  defp start_store(root, opts \\ []) do
    start_supervised!(
      {MediaStore,
       name: nil,
       root: root,
       max_media_bytes: Keyword.get(opts, :max_media_bytes, 64),
       max_store_bytes: Keyword.get(opts, :max_store_bytes, 128)}
    )
  end

  defp assert_start_failure(root, reason_tag) do
    previous = Process.flag(:trap_exit, true)

    try do
      assert {:error, reason} =
               MediaStore.start_link(
                 name: nil,
                 root: root,
                 max_media_bytes: 64,
                 max_store_bytes: 128
               )

      assert elem(reason, 0) == reason_tag
    after
      Process.flag(:trap_exit, previous)
    end
  end
end
