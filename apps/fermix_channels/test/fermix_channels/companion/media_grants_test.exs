defmodule FermixChannels.Companion.MediaGrantsTest do
  # The log assertions count only lines that name this test's own root, so no
  # other test's output can reach them.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias FermixChannels.Companion.MediaGrants
  alias FermixTestSupport.SafeRm

  # A holder's :DOWN reaches the server on a signal path of its own; a test
  # waits for its effect for at most this long instead of racing it.
  @down_bound_ms 10_000

  setup do
    tmp = SafeRm.make_tmp_dir!("companion-media-grants")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)

    store = Path.join(tmp, "store")
    File.mkdir_p!(store)

    %{
      tmp: tmp,
      root: Path.join(tmp, "media"),
      store: store,
      clock: :atomics.new(1, signed: true)
    }
  end

  describe "a grant" do
    test "copies the stored bytes into <ref>.ogg, read-only, in a private root", ctx do
      server = start_grants(ctx)
      media = put_blob(ctx, "a voice note")

      assert {:ok, path} = MediaGrants.grant(server, media, self())

      assert path == Path.join(ctx.root, media.ref <> ".ogg")
      assert File.read!(path) == "a voice note"
      assert mode(path) == 0o400
      assert mode(ctx.root) == 0o700
      assert entries(ctx.root) == [media.ref <> ".ogg"]
      assert_received {:blob_asked, ref}
      assert ref == media.ref
    end

    test "asked again returns the same path without asking the store, whoever asks", ctx do
      server = start_grants(ctx)
      media = put_blob(ctx, "a picture")
      other = holder(:other)

      assert {:ok, path} = MediaGrants.grant(server, media, self())
      assert_received {:blob_asked, _ref}

      assert {:ok, ^path} = MediaGrants.grant(server, media, self())
      assert {:ok, ^path} = MediaGrants.grant(server, media, other)
      refute_received {:blob_asked, _ref}
      assert entries(ctx.root) == [media.ref <> ".ogg"]
    end

    test "makes a file removed from outside again at the same path", ctx do
      server = start_grants(ctx)
      media = put_blob(ctx, "a sound file")

      assert {:ok, path} = MediaGrants.grant(server, media, self())
      SafeRm.rm!(path)

      assert {:ok, ^path} = MediaGrants.grant(server, media, self())
      assert_received {:blob_asked, _first}
      assert_received {:blob_asked, _again}
      assert File.read!(path) == "a sound file"
      assert mode(path) == 0o400
    end

    test "of zero-byte media is an empty file", ctx do
      server = start_grants(ctx)
      media = put_blob(ctx, "")

      assert {:ok, path} = MediaGrants.grant(server, media, self())
      assert path == Path.join(ctx.root, media.ref <> ".ogg")
      assert File.read!(path) == ""
      assert mode(path) == 0o400
    end

    test "refuses a ref that is not a sha256 without asking the store", ctx do
      server = start_grants(ctx)
      media = %{ref: "../../etc/passwd", kind: "file", mime: "text/plain", size_bytes: 1}

      assert {:error, {:invalid_field, :ref}} = MediaGrants.grant(server, media, self())
      refute_received {:blob_asked, _ref}
    end
  end

  describe "nothing to grant" do
    test "a store that no longer holds the bytes, or is not running, is media_missing", ctx do
      media = put_blob(ctx, "gone")

      for reason <- [:media_gone, :store_not_running] do
        server = start_grants(ctx, id: reason, blob: fn _ref -> {:error, reason} end)
        assert {:error, :media_missing} = MediaGrants.grant(server, media, self())
      end

      assert entries(ctx.root) == []
    end

    test "a stored blob of another size than the row names is media_missing", ctx do
      server = start_grants(ctx)
      media = put_blob(ctx, "four")

      assert {:error, :media_missing} =
               MediaGrants.grant(server, %{media | size_bytes: 5}, self())

      assert entries(ctx.root) == []
    end

    test "bytes that no longer hash to the ref are media_missing and leave no temp file", ctx do
      server = start_grants(ctx)
      media = put_blob(ctx, "original")
      File.write!(Path.join(ctx.store, media.ref), "tampered")

      assert {:error, :media_missing} = MediaGrants.grant(server, media, self())
      assert entries(ctx.root) == []
    end

    test "a blob longer than its row is cut off as media_missing", ctx do
      longer = Path.join(ctx.store, "longer")
      File.write!(longer, String.duplicate("x", 200_000))
      media = media_for("xxxx")
      blob = fn _ref -> {:ok, %{path: longer, size_bytes: media.size_bytes}} end
      server = start_grants(ctx, blob: blob)

      assert {:error, :media_missing} = MediaGrants.grant(server, media, self())
      assert entries(ctx.root) == []
    end

    test "a blob the store evicted after answering is media_missing", ctx do
      media = media_for("evicted")
      evicted = Path.join(ctx.store, media.ref)
      blob = fn _ref -> {:ok, %{path: evicted, size_bytes: media.size_bytes}} end
      server = start_grants(ctx, blob: blob)

      assert {:error, :media_missing} = MediaGrants.grant(server, media, self())
      assert entries(ctx.root) == []
    end

    test "any other store error passes through", ctx do
      server = start_grants(ctx, blob: fn _ref -> {:error, :disk_on_fire} end)

      assert {:error, :disk_on_fire} = MediaGrants.grant(server, media_for("x"), self())
      assert entries(ctx.root) == []
    end
  end

  describe "holds" do
    test "a holder that exits releases what it held", ctx do
      server = start_grants(ctx, budget_bytes: 10, grace_ms: 0)
      gone = put_blob(ctx, "12345678")
      kept = put_blob(ctx, "abcdefgh")
      leaving = holder(:leaving)

      assert {:ok, gone_path} = MediaGrants.grant(server, gone, leaving)
      assert {:ok, kept_path} = MediaGrants.grant(server, kept, self())
      assert File.exists?(gone_path)

      :ok = stop_supervised!({:holder, :leaving})

      await_removed(gone_path)
      assert File.exists?(kept_path)
      refute {:process, leaving} in monitors(server)
    end

    test "a holder is monitored once and forgotten once it holds nothing", ctx do
      server = start_grants(ctx)
      first = put_blob(ctx, "first")
      second = put_blob(ctx, "second")

      assert {:ok, _path} = MediaGrants.grant(server, first, self())
      assert {:ok, _path} = MediaGrants.grant(server, first, self())
      assert {:ok, _path} = MediaGrants.grant(server, second, self())
      assert Enum.count(monitors(server), &(&1 == {:process, self()})) == 1

      assert :ok = MediaGrants.release(server, first.ref, self())
      assert {:process, self()} in monitors(server)

      assert :ok = MediaGrants.release(server, second.ref, self())
      refute {:process, self()} in monitors(server)
    end

    test "releasing a ref the holder does not hold changes nothing", ctx do
      server = start_grants(ctx, budget_bytes: 10)
      held = put_blob(ctx, "12345678")
      other = holder(:other)

      assert {:ok, held_path} = MediaGrants.grant(server, held, self())
      assert :ok = MediaGrants.release(server, held.ref, other)
      assert :ok = MediaGrants.release(server, String.duplicate("0", 64), self())

      advance(ctx, 10_000)
      assert {:ok, _path} = MediaGrants.grant(server, put_blob(ctx, "abcdefgh"), self())

      assert File.exists?(held_path)
    end
  end

  describe "the budget" do
    test "never removes a held file", ctx do
      server = start_grants(ctx, budget_bytes: 10)

      paths =
        for bytes <- ["aaaaaaaa", "bbbbbbbb", "cccccccc"] do
          assert {:ok, path} = MediaGrants.grant(server, put_blob(ctx, bytes), self())
          path
        end

      advance(ctx, 10_000)
      reclaim_now(server)

      assert Enum.all?(paths, &File.exists?/1)
    end

    test "keeps a released file through its grace, then removes the least recently released first, only as far as needed",
         ctx do
      server = start_grants(ctx, budget_bytes: 20, grace_ms: 1_000)
      # Released in descending ref order, so an order by ref would pick the other.
      [earlier, later] =
        Enum.sort_by([put_blob(ctx, "aaaaaaaa"), put_blob(ctx, "bbbbbbbb")], & &1.ref, :desc)

      assert {:ok, earlier_path} = MediaGrants.grant(server, earlier, self())
      assert {:ok, later_path} = MediaGrants.grant(server, later, self())
      assert :ok = MediaGrants.release(server, earlier.ref, self())
      advance(ctx, 100)
      assert :ok = MediaGrants.release(server, later.ref, self())

      advance(ctx, 400)
      assert {:ok, held_path} = MediaGrants.grant(server, put_blob(ctx, "cccccccc"), self())
      assert Enum.all?([earlier_path, later_path, held_path], &File.exists?/1)

      advance(ctx, 700)
      reclaim_now(server)

      refute File.exists?(earlier_path)
      assert File.exists?(later_path)
      assert File.exists?(held_path)
    end

    test "one grace timer brings the files back under the budget without another call", ctx do
      server = start_grants(ctx, budget_bytes: 10, grace_ms: 600_000)
      first = put_blob(ctx, "aaaaaaaa")
      second = put_blob(ctx, "bbbbbbbb")

      assert {:ok, first_path} = MediaGrants.grant(server, first, self())
      assert {:ok, second_path} = MediaGrants.grant(server, second, self())
      assert timer(server) == nil

      assert :ok = MediaGrants.release(server, first.ref, self())
      armed = timer(server)
      assert is_integer(Process.read_timer(armed))

      advance(ctx, 10)
      assert :ok = MediaGrants.release(server, second.ref, self())
      rearmed = timer(server)
      assert is_integer(Process.read_timer(rearmed))
      assert Process.read_timer(armed) == false

      advance(ctx, 599_990)
      reclaim_now(server)

      refute File.exists?(first_path)
      assert File.exists?(second_path)
      assert timer(server) == nil
    end

    test "passed by held files alone still grants, and logs the overage once an episode", ctx do
      server = start_grants(ctx, budget_bytes: 10, grace_ms: 0)
      [a, b, c] = Enum.map(["aaaaaaaa", "bbbbbbbb", "cccccccc"], &put_blob(ctx, &1))

      {_paths, log} =
        with_log(fn ->
          for media <- [a, b, c] do
            assert {:ok, path} = MediaGrants.grant(server, media, self())
            path
          end
        end)

      assert [line] = overage_lines(log, ctx.root)
      assert line =~ "16 bytes held"
      assert line =~ "against 10"

      for media <- [a, b, c], do: assert(:ok = MediaGrants.release(server, media.ref, self()))
      assert entries(ctx.root) == [c.ref <> ".ogg"]

      {_grants, again} =
        with_log(fn ->
          assert {:ok, _path} = MediaGrants.grant(server, a, self())
          assert {:ok, _path} = MediaGrants.grant(server, b, self())
        end)

      assert [_line] = overage_lines(again, ctx.root)
    end
  end

  describe "start" do
    test "removes what a previous run left and leaves a directory and a symlink alone", ctx do
      outside = Path.join(ctx.tmp, "outside.txt")
      File.write!(outside, "not ours")
      File.mkdir_p!(Path.join(ctx.root, "a-directory"))
      File.write!(Path.join(ctx.root, "leftover.ogg"), "old")
      File.write!(Path.join(ctx.root, "crashed.part"), "half")
      File.ln_s!(outside, Path.join(ctx.root, "a-link"))

      {_server, log} = with_log(fn -> start_grants(ctx) end)

      assert entries(ctx.root) == ["a-directory", "a-link"]
      assert File.read!(outside) == "not ours"
      assert log =~ Path.join(ctx.root, "a-directory")
      assert log =~ Path.join(ctx.root, "a-link")
    end

    test "a root that cannot be made stops the server", ctx do
      blocker = Path.join(ctx.tmp, "a-file")
      File.write!(blocker, "")
      root = Path.join(blocker, "media")

      assert {:error, {{:directory_failed, ^root, :enotdir}, _child}} =
               start_supervised({MediaGrants, options(%{ctx | root: root}, [])})
    end
  end

  # -- helpers ------------------------------------------------------------------

  defp start_grants(ctx, overrides \\ []) do
    {id, overrides} = Keyword.pop(overrides, :id, MediaGrants)
    start_supervised!(Supervisor.child_spec({MediaGrants, options(ctx, overrides)}, id: id))
  end

  defp options(ctx, overrides) do
    clock = ctx.clock
    test = self()
    store = ctx.store

    Keyword.merge(
      [
        name: nil,
        root: ctx.root,
        budget_bytes: 1_000_000,
        grace_ms: 1_000,
        clock: fn -> :atomics.get(clock, 1) end,
        blob: fn ref -> stored_blob(store, ref, test) end
      ],
      overrides
    )
  end

  # The phone store's answer for the blobs this test wrote, telling the test
  # each time it is asked.
  defp stored_blob(store, ref, test) do
    send(test, {:blob_asked, ref})
    path = Path.join(store, ref)

    case File.stat(path) do
      {:ok, %{size: size}} -> {:ok, %{path: path, size_bytes: size}}
      {:error, :enoent} -> {:error, :media_gone}
    end
  end

  defp put_blob(ctx, bytes, mime \\ "audio/ogg") do
    media = media_for(bytes, mime)
    File.write!(Path.join(ctx.store, media.ref), bytes)
    media
  end

  defp media_for(bytes, mime \\ "audio/ogg") do
    ref = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
    %{ref: ref, kind: "audio", mime: mime, size_bytes: byte_size(bytes)}
  end

  defp holder(name) do
    start_supervised!(Supervisor.child_spec({Agent, fn -> name end}, id: {:holder, name}))
  end

  defp advance(ctx, ms), do: :atomics.add(ctx.clock, 1, ms)

  # The message the grace timer sends, delivered by hand; the state read after
  # it means it was handled.
  defp reclaim_now(server) do
    send(server, :reclaim)
    _state = :sys.get_state(server)
    :ok
  end

  defp timer(server), do: :sys.get_state(server).timer

  defp monitors(server) do
    {:monitors, monitors} = Process.info(server, :monitors)
    monitors
  end

  defp overage_lines(log, root) do
    log
    |> String.split("\n")
    |> Enum.filter(&(&1 =~ "passes its budget" and &1 =~ root))
  end

  defp entries(root), do: root |> File.ls!() |> Enum.sort()

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  defp await_removed(path) do
    deadline = System.monotonic_time(:millisecond) + @down_bound_ms
    await_removed(path, deadline)
  end

  defp await_removed(path, deadline) do
    cond do
      not File.exists?(path) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("#{path} was still there #{@down_bound_ms} ms after its holder exited")

      true ->
        Process.sleep(10)
        await_removed(path, deadline)
    end
  end
end
