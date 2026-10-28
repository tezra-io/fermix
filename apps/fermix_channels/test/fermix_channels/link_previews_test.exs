defmodule FermixChannels.LinkPreviewsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixChannels.Channels.Companion
  alias FermixChannels.LinkPreviews
  alias FermixChannels.Mobile.Protocol, as: MobileProtocol

  # The timeline a preview is stored on: it reports each attach to the test.
  defmodule StoreStub do
    def attach_link_preview(profile, server_seq, preview, _opts) do
      send(self(), {:preview_attached, profile, server_seq, preview})
      {:ok, %{server_seq: server_seq, media_refs: [], link_previews: [preview]}}
    end
  end

  setup do
    test_pid = self()
    previous_sink = Application.fetch_env(:fermix_channels, :mobile_event_sink)

    Application.put_env(:fermix_channels, :mobile_event_sink, fn profile_id, event ->
      send(test_pid, {:mobile_event, profile_id, event})
      :ok
    end)

    on_exit(fn ->
      case previous_sink do
        {:ok, value} -> Application.put_env(:fermix_channels, :mobile_event_sink, value)
        :error -> Application.delete_env(:fermix_channels, :mobile_event_sink)
      end
    end)
  end

  test "a link preview is stored on its row before it goes out, with its link, its image and icon no attachment" do
    digest = String.duplicate("b", 64)
    icon_digest = String.duplicate("c", 64)
    test_pid = self()

    resolver = fn links, store_thumbnail, on_preview ->
      send(test_pid, {:thumbnail_resolve, links})
      assert {:ok, ^digest} = store_thumbnail.("png-bytes", "image/png")

      on_preview.(%{
        link: "https://example.com",
        url: "https://www.example.com/",
        site: "Example",
        title: "Example title",
        description: nil,
        image: %{ref: digest, mime: "image/png", size_bytes: 9},
        icon: %{ref: icon_digest, mime: "image/x-icon", size_bytes: 4}
      })

      {:ok, []}
    end

    assert :ok = schedule(resolver, fn _bytes, _mime -> {:ok, digest} end)

    assert_received {:thumbnail_resolve, ["https://example.com"]}
    assert_received {:preview_attached, "main", 73, stored}

    assert stored == %{
             "link" => "https://example.com",
             "url" => "https://www.example.com/",
             "site" => "Example",
             "title" => "Example title",
             "image" => %{
               "ref" => digest,
               "sha256" => digest,
               "kind" => "image",
               "mime" => "image/png",
               "size_bytes" => 9
             },
             "icon" => %{
               "ref" => icon_digest,
               "sha256" => icon_digest,
               "kind" => "image",
               "mime" => "image/x-icon",
               "size_bytes" => 4
             }
           }

    assert_received {:preview_event, {:profile, "main"}, event}

    assert event == %{
             "t" => "link_preview",
             "in_reply_to" => 73,
             "link" => "https://example.com",
             "url" => "https://www.example.com/",
             "site" => "Example",
             "title" => "Example title",
             "image_ref" => digest,
             "icon_ref" => icon_digest
           }

    assert {:ok, _frames} =
             MobileProtocol.encode_server_event(
               "link_preview",
               Map.delete(event, "t"),
               1,
               <<>>,
               []
             )

    # Then that its row changed, which only the Mac's wire carries.
    assert_received {:preview_event, {:profile, "main"},
                     %{"t" => "row_updated", "profile_id" => "main", "server_seq" => 73}}
  end

  # M66: with no sink of a caller's own, each wire hears its own event: the
  # phones the card, and the Mac's connections that the row changed.
  test "a stored link preview reaches the phones as its card and the Mac as row_updated" do
    {:ok, _owner} = Registry.register(Companion.registry(), "main", 3)

    assert :ok =
             LinkPreviews.schedule("main", 73, ["https://example.com"],
               resolver: fn links, _thumbnail, on_preview ->
                 Enum.each(links, &on_preview.(page(&1)))
                 {:ok, []}
               end,
               launcher: fn task -> task.() && :ok end,
               store: StoreStub
             )

    assert_receive {:preview_attached, "main", 73, %{"link" => "https://example.com"}}
    assert_receive {:mobile_event, "main", %{"t" => "link_preview", "in_reply_to" => 73}}

    assert_receive {:companion_event,
                    %{"t" => "row_updated", "profile_id" => "main", "server_seq" => 73}}

    refute_received {:mobile_event, "main", %{"t" => "row_updated"}}
    refute_received {:companion_event, %{"t" => "link_preview"}}
  end

  test "a row that names no link asks for nothing" do
    assert :ok =
             LinkPreviews.schedule("main", 73, [],
               resolver: fn _links, _thumbnail, _on_preview -> flunk("nothing to resolve") end,
               launcher: fn _task -> flunk("nothing to launch") end
             )
  end

  # D7: the preview card's text is cut to its bounds on a UTF-8 boundary; an
  # address past its bound cannot be cut into a working link, so it is not sent.
  test "a link preview's text is cut to its bounds and an over-long address is not sent" do
    long = fn bytes -> String.duplicate("é", div(bytes, 2)) <> "é" end
    too_long_url = "https://example.com/" <> String.duplicate("a", 2_048)

    resolver = fn _links, _store_thumbnail, on_preview ->
      on_preview.(%{
        link: "https://example.com/ok",
        url: "https://example.com/ok",
        site: long.(120),
        title: long.(300),
        description: long.(600),
        image: nil
      })

      on_preview.(%{
        link: "https://example.com/redirects",
        url: too_long_url,
        site: "Example",
        title: "Too long",
        description: nil,
        image: nil
      })

      on_preview.(%{
        link: too_long_url,
        url: "https://example.com/short",
        site: "Example",
        title: "Written too long",
        description: nil,
        image: nil
      })

      {:ok, []}
    end

    links = ["https://example.com/ok", "https://example.com/redirects", too_long_url]

    log =
      capture_log(fn ->
        assert :ok =
                 schedule(resolver, fn _bytes, _mime -> flunk("no thumbnail") end, links: links)
      end)

    assert_received {:preview_attached, "main", 73, stored}
    assert byte_size(stored["site"]) <= 120 and String.valid?(stored["site"])
    assert byte_size(stored["title"]) <= 300 and String.valid?(stored["title"])
    assert byte_size(stored["description"]) <= 600 and String.valid?(stored["description"])
    assert_received {:preview_event, {:profile, "main"}, %{"title" => title}}
    assert title == stored["title"]

    refute_received {:preview_attached, "main", 73, %{"title" => "Too long"}}
    refute_received {:preview_attached, "main", 73, %{"title" => "Written too long"}}
    refute_received {:preview_event, {:profile, "main"}, %{"title" => "Too long"}}
    assert log =~ "link_preview_url_too_long"
  end

  test "a preview its resolver read for no link is not stored" do
    resolver = fn _links, _store_thumbnail, on_preview ->
      on_preview.(%{url: "https://example.com", site: "Example", title: "No link", image: nil})
      {:ok, []}
    end

    log = capture_log(fn -> assert :ok = schedule(resolver, fn _, _ -> {:ok, "x"} end) end)

    refute_received {:preview_attached, "main", 73, _preview}
    assert log =~ "invalid_link_preview_url"
  end

  # SEC-11: a slow-drip server can hold a fetch chunk by chunk forever; the
  # whole resolution has one hard deadline, and what it holds is killed.
  test "a resolution past its hard deadline is stopped and sends nothing" do
    test_pid = self()

    resolver = fn _links, _store_thumbnail, _on_preview ->
      send(test_pid, {:resolver, self()})
      Process.sleep(:infinity)
    end

    log =
      capture_log(fn ->
        assert :ok = schedule(resolver, fn _, _ -> {:ok, "x"} end, deadline_ms: 50)
      end)

    assert_received {:resolver, resolver_pid}
    refute Process.alive?(resolver_pid)
    refute_received {:preview_event, _target, _event}
    assert log =~ "resolution_deadline"
  end

  # A preview is stored and announced as it resolves, outside the process the
  # deadline kills, so a slow site costs the row nothing that already finished.
  # The first hand-over is immediate; a second's deadline leaves a busy runner
  # room to schedule it, and the overflow test below proves the same keeping
  # without a clock.
  test "a preview that resolved is kept although a later one hangs past the deadline" do
    test_pid = self()

    resolver = fn _links, _store_thumbnail, on_preview ->
      on_preview.(page("https://fast.test/"))
      send(test_pid, {:resolver, self()})
      Process.sleep(:infinity)
    end

    log =
      capture_log(fn ->
        assert :ok =
                 schedule(resolver, fn _, _ -> {:ok, "x"} end,
                   deadline_ms: 1_000,
                   links: ["https://fast.test/", "https://slow.test/"]
                 )
      end)

    assert_received {:resolver, resolver_pid}
    refute Process.alive?(resolver_pid)
    assert_received {:preview_attached, "main", 73, %{"link" => "https://fast.test/"}}

    assert_received {:preview_event, {:profile, "main"},
                     %{"t" => "link_preview", "link" => "https://fast.test/"}}

    assert_received {:preview_event, {:profile, "main"}, %{"t" => "row_updated"}}
    assert log =~ "resolution_deadline"
  end

  # The publish loop is bounded by the row's links: a resolver handing over
  # more previews than that is stopped where it stands.
  test "a resolver handing over more previews than the row has links is stopped" do
    test_pid = self()

    resolver = fn _links, _store_thumbnail, on_preview ->
      send(test_pid, {:resolver, self()})
      on_preview.(page("https://a.test/"))
      on_preview.(page("https://b.test/"))
      Process.sleep(:infinity)
    end

    log =
      capture_log(fn ->
        assert :ok = schedule(resolver, fn _, _ -> {:ok, "x"} end, links: ["https://a.test/"])
      end)

    assert_received {:resolver, resolver_pid}
    refute Process.alive?(resolver_pid)
    assert_received {:preview_attached, "main", 73, %{"link" => "https://a.test/"}}
    refute_received {:preview_attached, "main", 73, %{"link" => "https://b.test/"}}
    assert log =~ "resolution_overflow"
  end

  test "resolutions past the concurrency bound are refused, never queued without limit" do
    supervisor = :"link_preview_bound_#{System.unique_integer([:positive])}"
    start_supervised!(LinkPreviews.supervisor_spec(supervisor, 1))
    test_pid = self()

    blocking = fn _links, _store_thumbnail, _on_preview ->
      send(test_pid, :resolution_running)
      Process.sleep(:infinity)
    end

    opts = [resolver: blocking, supervisor: supervisor]

    assert :ok = LinkPreviews.schedule("main", 73, ["https://example.com"], opts)
    assert_receive :resolution_running

    log =
      capture_log(fn ->
        assert :ok = LinkPreviews.schedule("main", 74, ["https://example.com"], opts)
      end)

    assert log =~ "max_children"
    refute_receive :resolution_running, 100
    assert LinkPreviews.max_concurrent() == 4
  end

  test "a mis-shaped injected seam raises instead of selecting the real implementation" do
    assert_raise ArgumentError, ~r/link_preview_resolver override/, fn ->
      LinkPreviews.schedule("main", 73, ["https://example.com"],
        resolver: fn _links, _thumbnail -> {:ok, [], []} end,
        launcher: fn task -> task.() end
      )
    end

    assert_raise ArgumentError, ~r/thumbnail_store override/, fn ->
      LinkPreviews.schedule("main", 73, ["https://example.com"],
        resolver: fn _links, _thumbnail, _on_preview -> {:ok, []} end,
        thumbnail_store: fn _bytes -> :ok end,
        launcher: fn task -> task.() end
      )
    end
  end

  defp page(link), do: %{link: link, url: link, site: "Example", title: "Example title"}

  defp schedule(resolver, thumbnail_store, extra \\ []) do
    test_pid = self()
    {links, extra} = Keyword.pop(extra, :links, ["https://example.com"])

    LinkPreviews.schedule(
      "main",
      73,
      links,
      [
        resolver: resolver,
        launcher: fn task ->
          task.()
          :ok
        end,
        thumbnail_store: thumbnail_store,
        store: StoreStub,
        event_sink: fn target, event ->
          send(test_pid, {:preview_event, target, event})
          :ok
        end
      ] ++ extra
    )
  end
end
