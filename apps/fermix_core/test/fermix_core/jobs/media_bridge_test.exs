defmodule FermixCore.Jobs.MediaBridgeTest do
  use ExUnit.Case, async: true

  alias FermixCore.Jobs.MediaBridge

  defmodule MediaAdapter do
    @moduledoc false
    def send_message(_destination, _text, _opts), do: :ok

    def send_media(destination, part, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:media_sent, destination, part, opts})
      :ok
    end
  end

  defmodule TextOnlyAdapter do
    @moduledoc false
    def send_message(_destination, _text, _opts), do: :ok
  end

  defmodule FailingAdapter do
    @moduledoc false
    def send_message(_destination, _text, _opts), do: :ok
    def send_media(_destination, _part, _opts), do: {:error, {:http_status, 500}}
  end

  @part %{kind: :image, path: "/tmp/preview.png", filename: "preview.png"}

  describe "build/3 — resolution" do
    test "binds a media reply function and hands back the target it resolved" do
      assert {:ok, reply_fn, target} = build(job(), opts())
      assert is_function(reply_fn, 1)
      assert target.platform == "telegram"
      assert target.destination == "123"
      assert Keyword.fetch!(target.opts, :message_thread_id) == "77"
    end

    test "derives the destination from an origin session id when no target is stored" do
      job =
        job()
        |> Map.delete(:delivery_target)
        |> Map.put(:created_by_session_id, "telegram:999:root")

      assert {:ok, reply_fn, _target} = build(job, opts())
      assert :ok = reply_fn.({:media, @part})
      assert_received {:media_sent, "999", _part, _opts}
    end

    test "refuses local and none delivery modes by name" do
      assert {:unavailable, {:delivery_mode, "local"}} =
               build(Map.put(job(), :delivery_mode, "local"), opts())

      assert {:unavailable, {:delivery_mode, "none"}} =
               build(Map.put(job(), :delivery_mode, "none"), opts())
    end

    test "refuses a target it cannot resolve" do
      job = Map.put(job(), :delivery_target, %{"platform" => "telegram"})

      assert {:unavailable, {:invalid_delivery_target, _reason}} = build(job, opts())
    end

    test "refuses an adapter that cannot send media" do
      assert {:unavailable, {:media_adapter_unsupported, _reason}} =
               build(job(), opts(adapter: TextOnlyAdapter))
    end

    test "every unavailable reason renders a short prompt fragment" do
      assert MediaBridge.unavailable_reason({:delivery_mode, "local"}) == "delivery mode is local"

      assert MediaBridge.unavailable_reason({:invalid_delivery_target, :missing}) =~
               "no valid delivery target"

      assert MediaBridge.unavailable_reason({:media_adapter_unsupported, :nope}) =~
               "cannot send files"
    end
  end

  describe "the reply function" do
    test "sends a media part to the captured destination with the run's proactive key" do
      assert {:ok, reply_fn, _target} = build(job(), opts(delivery_opts: [test_pid: self()]))
      assert :ok = reply_fn.({:media, @part})

      assert_received {:media_sent, "123", part, send_opts}
      assert part == @part
      assert Keyword.fetch!(send_opts, :proactive_key) == "job:run_1"
      assert Keyword.fetch!(send_opts, :message_thread_id) == "77"
      assert Keyword.fetch!(send_opts, :proactive_part_id) == "media-1"
    end

    # The mobile adapter refuses a proactive media send whose key carries no part
    # id, and a shared key would collapse a run's attachments into one timeline
    # entry — so each send names its own position in the run.
    test "each send carries its own proactive part id" do
      assert {:ok, reply_fn, _target} = build(job(), opts())

      assert :ok = reply_fn.({:media, @part})
      assert :ok = reply_fn.({:media, @part})

      assert_received {:media_sent, _d1, _p1, first_opts}
      assert_received {:media_sent, _d2, _p2, second_opts}
      assert Keyword.fetch!(first_opts, :proactive_part_id) == "media-1"
      assert Keyword.fetch!(second_opts, :proactive_part_id) == "media-2"
      assert Keyword.fetch!(first_opts, :proactive_key) == "job:run_1"
      assert Keyword.fetch!(second_opts, :proactive_key) == "job:run_1"
    end

    test "accepts only {:media, part} — the final text stays scheduler-owned" do
      assert {:ok, reply_fn, _target} = build(job(), opts())

      assert {:error, {:unsupported_job_reply, :text}} = reply_fn.({:text, "hello"})
      assert {:error, {:unsupported_job_reply, :react}} = reply_fn.({:react, "👍"})

      assert {:error, {:unsupported_job_reply, :approval_prompt}} =
               reply_fn.({:approval_prompt, "approve?", "TOK"})

      assert {:error, {:unsupported_job_reply, :unknown}} = reply_fn.(:something_else)

      refute_received {:media_sent, _destination, _part, _opts}
    end

    test "job_not_active: a leaked closure cannot send once the run is over" do
      active = active_ref()
      assert {:ok, reply_fn, _target} = build(job(), opts(active: active))

      assert :ok = reply_fn.({:media, @part})
      assert_received {:media_sent, _destination, _part, _opts}

      :atomics.put(active, 1, 0)

      assert {:error, :job_not_active} = reply_fn.({:media, @part})
      refute_received {:media_sent, _destination, _part, _opts}
    end

    test "the seventeenth request is refused without reaching the adapter" do
      assert {:ok, reply_fn, _target} = build(job(), opts())

      for _index <- 1..MediaBridge.max_sends() do
        assert :ok = reply_fn.({:media, @part})
      end

      assert {:error, :media_limit_reached} = reply_fn.({:media, @part})

      # Exactly sixteen adapter calls, and the refusal made none.
      assert drain_media_sends(0) == MediaBridge.max_sends()
    end

    test "failed attempts count against the bound" do
      assert {:ok, reply_fn, _target} = build(job(), opts(adapter: FailingAdapter))

      for _index <- 1..MediaBridge.max_sends() do
        assert {:error, {:http_status, 500}} = reply_fn.({:media, @part})
      end

      assert {:error, :media_limit_reached} = reply_fn.({:media, @part})
    end

    test "a spent run deadline refuses before the adapter is touched" do
      past = System.monotonic_time(:millisecond) - 1_000
      assert {:ok, reply_fn, _target} = build(job(), opts(deadline_ms: past))

      assert {:error, :job_deadline_exceeded} = reply_fn.({:media, @part})
      refute_received {:media_sent, _destination, _part, _opts}
    end

    test "a nil deadline leaves the configured delivery timeout as the only bound" do
      assert {:ok, reply_fn, _target} =
               build(job(), opts(deadline_ms: nil, delivery_timeout_ms: 1_000))

      assert :ok = reply_fn.({:media, @part})
      assert_received {:media_sent, _destination, _part, _opts}
    end
  end

  defp build(job, opts), do: MediaBridge.build(job, %{id: "run_1"}, opts)

  defp job do
    %{
      id: "job_1",
      delivery_mode: "origin",
      delivery_target: %{
        "platform" => "telegram",
        "chat_id" => "123",
        "message_thread_id" => "77"
      }
    }
  end

  defp opts(overrides \\ []) do
    Keyword.merge(
      [
        adapter: MediaAdapter,
        channels: %{},
        delivery_opts: [test_pid: self()],
        delivery_timeout_ms: 5_000,
        deadline_ms: System.monotonic_time(:millisecond) + 60_000,
        active: active_ref(),
        sends: :atomics.new(1, signed: false),
        delivery_max_attempts: 1,
        delivery_backoff_ms: 0
      ],
      overrides
    )
  end

  defp active_ref do
    ref = :atomics.new(1, signed: false)
    :atomics.put(ref, 1, 1)
    ref
  end

  defp drain_media_sends(count) do
    receive do
      {:media_sent, _destination, _part, _opts} -> drain_media_sends(count + 1)
    after
      0 -> count
    end
  end
end
