defmodule FermixCore.Tools.Media.OutputTest do
  use ExUnit.Case, async: true

  alias FermixCore.Tools.Media.Output

  @artifact %{bytes: "PNGBYTES", mime: "image/png", ext: "png"}

  describe "emit/3" do
    test "writes the artifact under the sandbox floor and delivers it through reply_fn" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("media-output-deliver")
      test_pid = self()

      try do
        context = sandbox_context(tmp_dir, reply_fn: capturing_reply(test_pid))

        assert {:ok, %{path: path, delivered?: true}} =
                 Output.emit(@artifact, %{modality: :image, delivery: :default}, context)

        assert File.read!(path) == "PNGBYTES"
        # Landed under the workspace `media/` floor (compare via basename — macOS
        # resolves /var/folders to /private/var through the sandbox canonicalize).
        assert Path.basename(Path.dirname(path)) == "media"

        assert_receive {:reply,
                        {:media,
                         %{kind: :image, mime_type: "image/png", path: ^path, filename: filename}}}

        assert filename == Path.basename(path)
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "carries a caption onto the media part when one is supplied" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("media-output-caption")
      test_pid = self()

      try do
        context = sandbox_context(tmp_dir, reply_fn: capturing_reply(test_pid))

        assert {:ok, %{delivered?: true}} =
                 Output.emit(
                   @artifact,
                   %{modality: :image, delivery: :default, caption: "a fox"},
                   context
                 )

        assert_receive {:reply, {:media, %{caption: "a fox"}}}
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "writes the file and reports not-delivered when no channel is present (subagent/job)" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("media-output-no-channel")

      try do
        context = sandbox_context(tmp_dir)

        assert {:ok, %{path: path, delivered?: false}} =
                 Output.emit(@artifact, %{modality: :image, delivery: :default}, context)

        assert File.read!(path) == "PNGBYTES"
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "G01: delivery :save writes the file and never calls the reply function" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("media-output-save")
      test_pid = self()

      try do
        context = sandbox_context(tmp_dir, reply_fn: capturing_reply(test_pid))

        assert {:ok, %{path: path, delivered?: false}} =
                 Output.emit(@artifact, %{modality: :image, delivery: :save}, context)

        assert File.read!(path) == "PNGBYTES"
        refute_receive {:reply, _outbound}, 100
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "delivery :send with a reply function delivers and reports it" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("media-output-send")
      test_pid = self()

      try do
        context = sandbox_context(tmp_dir, reply_fn: capturing_reply(test_pid))

        assert {:ok, %{delivered?: true}} =
                 Output.emit(@artifact, %{modality: :image, delivery: :send}, context)

        assert_receive {:reply, {:media, %{kind: :image}}}
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "delivery :send without a reply function fails loud and keeps the saved path" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("media-output-send-unrouted")

      try do
        context = sandbox_context(tmp_dir)

        assert {:error, %{path: path, reason: reason}} =
                 Output.emit(@artifact, %{modality: :image, delivery: :send}, context)

        assert reason =~ "no channel reply context"
        assert File.read!(path) == "PNGBYTES"
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "humanizes a structured channel delivery error" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("media-output-delivery-error")

      try do
        context =
          sandbox_context(tmp_dir,
            reply_fn: fn {:media, _part} ->
              {:error, {:byte_cap_exceeded, 11_534_337, 10_485_760}}
            end
          )

        assert {:error, %{path: path, reason: reason}} =
                 Output.emit(@artifact, %{modality: :image, delivery: :default}, context)

        assert reason =~ "11.0 MiB"
        assert reason =~ "10.0 MiB"
        # The artifact the caller already paid for is still reported.
        assert File.read!(path) == "PNGBYTES"
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "fails loud when the channel returns an invalid reply result" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("media-output-invalid-reply")

      try do
        context = sandbox_context(tmp_dir, reply_fn: fn {:media, _part} -> :weird end)

        assert {:error, %{path: _path, reason: reason}} =
                 Output.emit(@artifact, %{modality: :image, delivery: :default}, context)

        assert reason =~ "invalid reply result"
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end
  end

  defp capturing_reply(test_pid) do
    fn part ->
      send(test_pid, {:reply, part})
      :ok
    end
  end

  defp sandbox_context(root, extra \\ []) do
    %{
      agent_name: "main",
      conversation_key: :test,
      cwd: root,
      sandbox_config: %{mode: :strict, workspace_root: root, allowed_roots: [root]}
    }
    |> Map.merge(Map.new(extra))
  end
end
