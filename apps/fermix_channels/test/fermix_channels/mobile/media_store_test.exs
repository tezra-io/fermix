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

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
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
