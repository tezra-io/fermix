defmodule FermixCore.Attachments.WorkspaceTest do
  use ExUnit.Case, async: true

  alias FermixCore.Attachments
  alias FermixCore.Attachments.Workspace
  alias FermixCore.Sandbox.Config
  alias FermixTestSupport.SafeRm

  @day 24 * 60 * 60
  @mib 1024 * 1024
  # Noon, 2026-10-12 UTC.
  @now 1_791_806_400

  setup do
    dir = SafeRm.make_tmp_dir!("attachment-workspace")
    on_exit(fn -> SafeRm.rm_rf!(dir) end)
    workspace = Path.join(dir, "workspace")
    File.mkdir_p!(workspace)

    %{
      dir: dir,
      workspace: workspace,
      context: %{sandbox_config: Config.normalize(mode: :strict, workspace_root: workspace)},
      session_id: "main-workspace-#{System.unique_integer([:positive])}"
    }
  end

  defp att(fields), do: struct!(Attachments, Map.merge(%{status: :ready}, Map.new(fields)))

  defp save(attachments, ctx, opts \\ []) do
    Workspace.save(
      attachments,
      ctx.context,
      Keyword.merge([channel: "telegram", session_id: ctx.session_id, now: @now], opts)
    )
  end

  defp today do
    {{year, month, day}, _time} = :calendar.system_time_to_local_time(@now, :second)
    year |> Date.new!(month, day) |> Date.to_iso8601()
  end

  defp inbound(ctx), do: Path.join([ctx.workspace, "media", "inbound"])

  defp swap_target(:day, workspace, outside),
    do: swap_target("media/inbound/2026-09-01", workspace, outside)

  defp swap_target(:inbound, workspace, outside),
    do: swap_target("media/inbound", workspace, outside)

  defp swap_target(:media, workspace, outside), do: swap_target("media", workspace, outside)

  defp swap_target(rel, workspace, outside) when is_binary(rel),
    do: %{inside: Path.join(workspace, rel), outside: Path.join(outside, rel)}

  # A global handler: it keeps only this test's own events, filtered in its
  # body, so another test's event can never raise in it and detach it.
  defp listen_for_save(session_id) do
    test_pid = self()
    handler_id = "workspace-save-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:fermix, :attachment, :save],
      fn _event, measurements, metadata, _config ->
        if metadata.session_id == session_id,
          do: send(test_pid, {:save, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp sparse!(path, size, mtime) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, fd} = :file.open(path, [:write, :raw, :binary])
    :ok = :file.pwrite(fd, size - 1, <<0>>)
    :ok = :file.close(fd)
    File.touch!(path, mtime)
  end

  test "an attachment is kept under media/inbound/<date>, named for the sender's file", ctx do
    [chart] =
      save(
        [att(kind: :still, mime_type: "image/png", name: "Q3 chart (final).png", bytes: "PNG")],
        ctx
      )

    assert {:saved, path, []} = chart.saved
    assert path =~ ~r"/media/inbound/#{today()}/Q3-chart-final-[0-9a-f]{8}\.png\z"
    assert File.read!(path) == "PNG"
  end

  test "a nameless file is named for its kind, an unreadable one keeps its own extension", ctx do
    [photo, docx] =
      save(
        [
          att(kind: :still, mime_type: "image/jpeg", bytes: "JPG"),
          att(
            kind: :unknown,
            mime_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            name: "budget.docx",
            bytes: "PK",
            status: {:unusable, {:unknown_type, "application/vnd.openxmlformats"}}
          )
        ],
        ctx
      )

    assert {:saved, photo_path, []} = photo.saved
    assert Path.basename(photo_path) =~ ~r/\Aimage-[0-9a-f]{8}\.jpg\z/
    assert {:saved, docx_path, []} = docx.saved
    assert Path.basename(docx_path) =~ ~r/\Abudget-[0-9a-f]{8}\.docx\z/
    assert File.read!(docx_path) == "PK"
  end

  test "what the model saw of a GIF or a video is kept beside it", ctx do
    gif =
      att(
        kind: :animation,
        mime_type: "image/gif",
        name: "spinner.gif",
        bytes: "GIF-ALL",
        poster: %{mime_type: "image/gif", bytes: "GIF-FIRST"}
      )

    clip =
      att(
        kind: :video,
        mime_type: "video/mp4",
        name: "clip.mp4",
        bytes: "MP4",
        frames: [%{mime_type: "image/jpeg", bytes: "F1"}, %{mime_type: "image/jpeg", bytes: "F2"}]
      )

    [gif, clip] = save([gif, clip], ctx)

    assert {:saved, gif_path, [still]} = gif.saved
    assert still == String.replace_suffix(gif_path, ".gif", "-still.gif")
    assert File.read!(still) == "GIF-FIRST"

    assert {:saved, clip_path, [frame1, frame2]} = clip.saved
    assert frame1 == String.replace_suffix(clip_path, ".mp4", "-frame1.jpg")
    assert File.read!(frame2) == "F2"
  end

  test "nothing never downloaded, and no voice note, is kept", ctx do
    attachments = [
      att(
        kind: :video,
        mime_type: "video/mp4",
        status: {:unusable, {:too_large, 30 * @mib, 20 * @mib}}
      ),
      att(kind: :audio, mime_type: "audio/ogg", bytes: "OGG", status: :transcribed)
    ]

    assert save(attachments, ctx) == attachments
    refute File.exists?(inbound(ctx))
  end

  describe "the prune" do
    test "removes what is past 14 days, then the oldest until the turn fits in 1 GiB", ctx do
      stale = Path.join([inbound(ctx), "2026-09-20", "old-00000001.txt"])
      older = Path.join([inbound(ctx), "2026-10-09", "big-00000002.mp4"])
      newer = Path.join([inbound(ctx), "2026-10-11", "big-00000003.mp4"])
      File.mkdir_p!(Path.dirname(stale))
      File.write!(stale, "stale")
      File.touch!(stale, @now - 15 * @day)
      sparse!(older, 600 * @mib, @now - 3 * @day)
      sparse!(newer, 600 * @mib, @now - 1 * @day)

      [_saved] = save([att(kind: :text, mime_type: "text/plain", bytes: "fresh")], ctx)

      refute File.exists?(stale)
      refute File.exists?(older)
      assert File.exists?(newer)
    end

    test "deletes only regular files inside the folder: never through a link, never deeper",
         ctx do
      outside = Path.join(ctx.dir, "outside")
      File.mkdir_p!(outside)
      secret = Path.join(outside, "secret.txt")
      File.write!(secret, "keep me")
      File.touch!(secret, @now - 40 * @day)

      day = Path.join(inbound(ctx), "2026-09-01")
      deep = Path.join([day, "nested", "deep.txt"])
      File.mkdir_p!(Path.dirname(deep))
      File.write!(deep, "deep")
      File.touch!(deep, @now - 40 * @day)
      File.ln_s!(secret, Path.join(day, "link.txt"))
      File.ln_s!(outside, Path.join(inbound(ctx), "2026-08-01"))

      [_saved] = save([att(kind: :text, mime_type: "text/plain", bytes: "fresh")], ctx)

      assert File.read!(secret) == "keep me"
      assert File.read!(deep) == "deep"
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(day, "link.txt"))
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(inbound(ctx), "2026-08-01"))
    end
  end

  describe "a prune that cannot trust the folder" do
    # Review fix 2: the walk saw a real day folder; something with write access
    # to the workspace swaps it for a link before the delete. The prune stops.
    for swapped <- [:day, :inbound, :media] do
      test "#{swapped} swapped for a link mid-prune stops it, and nothing outside goes", ctx do
        # The outside tree mirrors the workspace's with hard links to the very
        # same files, so after the swap each file still has the inode the walk
        # saw: only the folders on the way can tell the prune it moved.
        outside = Path.join(ctx.dir, "outside")
        rel = Path.join(["media", "inbound", "2026-09-01"])
        File.mkdir_p!(Path.join(ctx.workspace, rel))
        File.mkdir_p!(Path.join(outside, rel))

        for name <- ~w(a-00000001.txt b-00000002.txt) do
          inside = Path.join([ctx.workspace, rel, name])
          File.write!(inside, "old")
          File.touch!(inside, @now - 40 * @day)
          File.ln!(inside, Path.join([outside, rel, name]))
        end

        target = swap_target(unquote(swapped), ctx.workspace, outside)

        swap = fn _path ->
          if File.lstat!(target.inside).type == :directory do
            File.rename!(target.inside, target.inside <> "-moved")
            File.ln_s!(target.outside, target.inside)
          end
        end

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            [kept] =
              save([att(kind: :text, mime_type: "text/plain", bytes: "fresh")], ctx,
                before_delete: swap
              )

            assert {:not_saved, sentence} = kept.saved
            assert sentence =~ "changed while it was being pruned"
          end)

        assert log =~ "changed while it was being pruned"

        for name <- ~w(a-00000001.txt b-00000002.txt),
            do: assert(File.read!(Path.join([outside, rel, name])) == "old")
      end
    end

    # Review fix 11: a failure names folders, never a sender's file name.
    test "a file it cannot delete is named by its folder, never by the sender's name", ctx do
      day = Path.join(inbound(ctx), "2026-09-01")
      stale = Path.join(day, "holiday-plans-00000001.txt")
      File.mkdir_p!(day)
      File.write!(stale, "old")
      File.touch!(stale, @now - 40 * @day)
      File.chmod!(day, 0o555)
      on_exit(fn -> File.chmod(day, 0o755) end)

      [kept] = save([att(kind: :text, mime_type: "text/plain", bytes: "fresh")], ctx)

      assert {:not_saved, sentence} = kept.saved
      assert sentence =~ "the inbound attachments folder could not be pruned"
      assert sentence =~ "2026-09-01"
      refute sentence =~ "holiday"
    end

    test "a write the sandbox refuses is named without the attachment's name", ctx do
      outside = Path.join(ctx.dir, "elsewhere")
      File.mkdir_p!(outside)
      File.mkdir_p!(inbound(ctx))
      File.ln_s!(outside, Path.join(inbound(ctx), today()))

      [chart] =
        save(
          [att(kind: :still, mime_type: "image/png", name: "secret-chart.png", bytes: "P")],
          ctx
        )

      assert {:not_saved, sentence} = chart.saved
      assert sentence =~ "outside the sandbox roots"
      refute sentence =~ "secret-chart"
      assert File.ls!(outside) == []
    end
  end

  test "a save that fails is named on each attachment and traced, and drops nothing", ctx do
    listen_for_save(ctx.session_id)

    # `media/inbound` is a file, so the folder can be neither listed nor pruned.
    File.mkdir_p!(Path.dirname(inbound(ctx)))
    File.write!(inbound(ctx), "not a folder")

    [chart, lost] =
      save(
        [
          att(kind: :still, mime_type: "image/png", name: "chart.png", bytes: "PNG"),
          att(
            kind: :still,
            mime_type: "image/png",
            status: {:unusable, {:download_failed, :boom}}
          )
        ],
        ctx
      )

    assert {:not_saved, sentence} = chart.saved
    assert sentence =~ "the inbound attachments folder could not be pruned"
    assert sentence =~ "not a directory"
    assert lost.saved == nil

    assert_receive {:save, %{saved: 0, failed: 1, files: 0, bytes: 0},
                    %{channel: "telegram", outcome: :failed, detail: detail}}

    assert String.starts_with?(sentence, detail)
    assert detail =~ "not a directory"
  end

  test "one save event per turn: what was written and what the prune removed", ctx do
    listen_for_save(ctx.session_id)

    stale = Path.join([inbound(ctx), "2026-09-01", "old-00000001.txt"])
    File.mkdir_p!(Path.dirname(stale))
    File.write!(stale, "12345")
    File.touch!(stale, @now - 20 * @day)

    save(
      [
        att(kind: :still, mime_type: "image/png", bytes: "PNG"),
        att(
          kind: :animation,
          mime_type: "image/gif",
          bytes: "GIF",
          poster: %{mime_type: "image/gif", bytes: "G1"}
        )
      ],
      ctx
    )

    assert_receive {:save, measurements, %{outcome: :saved, detail: nil}}

    assert %{saved: 2, failed: 0, files: 3, bytes: 8, pruned_files: 1, pruned_bytes: 5} =
             measurements

    assert is_integer(measurements.duration_us)
  end
end
