defmodule FermixCore.Tools.SendAttachmentTest do
  use ExUnit.Case, async: true

  alias FermixCore.Sandbox.PathPolicy
  alias FermixCore.Tools.SendAttachment

  describe "metadata" do
    test "is exposed as a channel-specific builtin" do
      assert SendAttachment.name() == "send_attachment"
      assert SendAttachment.category() == :channel
    end
  end

  describe "execute/2" do
    test "sends an in-sandbox local attachment through reply_fn" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("send-attachment")

      try do
        File.mkdir_p!(tmp_dir)
        path = Path.join(tmp_dir, "report.txt")
        File.write!(path, "hello")
        resolved_path = PathPolicy.canonical_path(path)

        test_pid = self()

        context = %{
          cwd: tmp_dir,
          sandbox_config: %{mode: :strict, workspace_root: tmp_dir, allowed_roots: [tmp_dir]},
          reply_fn: fn part ->
            send(test_pid, {:reply, part})
            :ok
          end
        }

        args = %{"path" => path, "caption" => "Report", "kind" => "document"}

        assert {:ok, %{success: true, output: output, error: nil}} =
                 SendAttachment.execute(args, context)

        assert output =~ "report.txt"

        assert_receive {:reply,
                        {:media,
                         %{
                           path: ^resolved_path,
                           caption: "Report",
                           kind: :document,
                           filename: "report.txt"
                         }}}
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "does not fetch or attach URLs" do
      context = %{cwd: System.tmp_dir!(), sandbox_config: %{}, reply_fn: fn _part -> :ok end}

      assert {:ok, %{success: false, error: error}} =
               SendAttachment.execute(%{"path" => "https://example.com/file.png"}, context)

      assert error =~ "URLs are not supported"
    end

    test "fails loudly when no channel reply function is available" do
      context = %{cwd: System.tmp_dir!(), sandbox_config: %{}}

      assert {:ok, %{success: false, error: "send_attachment requires a channel reply context"}} =
               SendAttachment.execute(%{"path" => "report.txt"}, context)
    end

    test "normalizes sandbox denial reasons into tool errors" do
      dir = FermixTestSupport.SafeRm.make_tmp_dir!("send-attachment-denied")
      root = Path.join(dir, "root")
      outside = Path.join(dir, "outside.txt")

      try do
        File.mkdir_p!(root)
        File.write!(outside, "nope")

        context = %{
          cwd: root,
          sandbox_config: %{mode: :strict, workspace_root: root},
          reply_fn: fn _part -> :ok end
        }

        assert {:ok, %{success: false, error: error}} =
                 SendAttachment.execute(%{"path" => outside}, context)

        assert error =~ "outside the sandbox roots"
      after
        FermixTestSupport.SafeRm.rm_rf!(dir)
      end
    end

    test "emits tool execution telemetry" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("send-attachment-telemetry")
      handler_id = "send-attachment-telemetry-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:fermix, :tool, :exec],
          fn event, measurements, metadata, pid ->
            if self() == pid do
              send(pid, {:telemetry, event, measurements, metadata})
            end
          end,
          self()
        )

      try do
        path = Path.join(tmp_dir, "report.txt")
        File.write!(path, "hello")

        context = %{
          agent_name: "main",
          cwd: tmp_dir,
          sandbox_config: %{mode: :strict, workspace_root: tmp_dir, allowed_roots: [tmp_dir]},
          reply_fn: fn _part -> :ok end
        }

        assert {:ok, %{success: true}} =
                 SendAttachment.execute(%{"path" => path, "kind" => "document"}, context)

        assert_receive {:telemetry, [:fermix, :tool, :exec], %{duration_ms: duration_ms},
                        %{tool: "send_attachment", agent: "main", success: true}}

        assert is_integer(duration_ms)
        assert duration_ms >= 0
      after
        :telemetry.detach(handler_id)
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "surfaces channel media unsupported errors" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("send-attachment-media-unsupported")

      try do
        path = Path.join(tmp_dir, "report.txt")
        File.write!(path, "hello")

        context = %{
          cwd: tmp_dir,
          sandbox_config: %{mode: :strict, workspace_root: tmp_dir, allowed_roots: [tmp_dir]},
          reply_fn: fn {:media, _part} -> {:error, :media_unsupported} end
        }

        assert {:ok, %{success: false, error: error}} =
                 SendAttachment.execute(%{"path" => path, "kind" => "document"}, context)

        assert error == "Failed to send attachment: :media_unsupported"
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "humanizes structured channel delivery errors" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("send-attachment-delivery-errors")

      try do
        path = Path.join(tmp_dir, "report.txt")
        File.write!(path, "hello")

        context = %{
          cwd: tmp_dir,
          sandbox_config: %{mode: :strict, workspace_root: tmp_dir, allowed_roots: [tmp_dir]},
          reply_fn: fn {:media, _part} ->
            {:error, {:byte_cap_exceeded, 11_534_337, 10_485_760}}
          end
        }

        assert {:ok, %{success: false, error: error}} =
                 SendAttachment.execute(%{"path" => path, "kind" => "document"}, context)

        assert error == "Failed to send attachment: attachment is 11.0 MiB; limit is 10.0 MiB"
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "humanizes rate-limit delivery errors" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("send-attachment-rate-limit")

      try do
        path = Path.join(tmp_dir, "report.txt")
        File.write!(path, "hello")

        context = %{
          cwd: tmp_dir,
          sandbox_config: %{mode: :strict, workspace_root: tmp_dir, allowed_roots: [tmp_dir]},
          reply_fn: fn {:media, _part} -> {:error, {:rate_limited, 3_000}} end
        }

        assert {:ok, %{success: false, error: error}} =
                 SendAttachment.execute(%{"path" => path, "kind" => "document"}, context)

        assert error == "Failed to send attachment: channel is rate limited; retry after 3s"
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end
  end
end
