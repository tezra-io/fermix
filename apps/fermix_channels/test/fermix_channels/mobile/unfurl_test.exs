defmodule FermixChannels.Mobile.UnfurlTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Unfurl

  @max_body_bytes 1_048_576
  @public_ip {93, 184, 216, 34}

  test "resolves at most four unique links, each keeping the link it was read for, and extracts Open Graph metadata" do
    test_pid = self()

    request = fn pinned, opts ->
      send(test_pid, {:request, pinned, opts})

      cond do
        String.ends_with?(pinned.original_url, "/card.png") ->
          {:ok, image("image/png", "png-bytes")}

        String.ends_with?(pinned.original_url, "/favicon.ico") ->
          {:ok, ico()}

        true ->
          {:ok, page_body(html("Fermix", "A private assistant", "/card.png"))}
      end
    end

    store_thumbnail = fn bytes, mime ->
      send(test_pid, {:stored_thumbnail, bytes, mime})
      {:ok, String.duplicate("a", 64)}
    end

    links =
      ~w(https://example.com/a https://example.com/a https://example.com/b) ++
        ~w(https://example.com/c https://example.com/d https://example.com/e)

    assert {:ok, previews, []} =
             Unfurl.resolve(links,
               resolver: resolver(),
               request: request,
               store_thumbnail: store_thumbnail
             )

    assert Enum.map(previews, & &1.link) == Enum.uniq(links) |> Enum.take(4)
    assert Enum.map(previews, & &1.url) == Enum.map(previews, & &1.link)

    assert Enum.all?(previews, fn preview ->
             preview.site == "Example" and preview.title == "Fermix" and
               preview.description == "A private assistant" and
               preview.image == %{
                 ref: String.duplicate("a", 64),
                 mime: "image/png",
                 size_bytes: byte_size("png-bytes")
               } and
               preview.icon == %{
                 ref: String.duplicate("a", 64),
                 mime: "image/x-icon",
                 size_bytes: 8
               }
           end)

    assert_receive {:request, %{url: "https://93.184.216.34/a", original_host: "example.com"},
                    opts}

    assert {"host", "example.com"} in opts[:headers]
    assert opts[:method] == :get
    assert opts[:receive_timeout] == 15_000
    assert_receive {:stored_thumbnail, "png-bytes", "image/png"}

    # One origin, one icon fetch, shared by the four previews.
    assert_receive {:stored_thumbnail, _ico, "image/x-icon"}
    refute_received {:stored_thumbnail, _ico, "image/x-icon"}
  end

  test "stores only image thumbnails and reports a non-image content type" do
    request = fn pinned, _opts ->
      if String.ends_with?(pinned.original_url, "/card.png") do
        {:ok,
         %{
           status: 200,
           headers: %{"content-type" => ["text/html; charset=utf-8"]},
           private: %{},
           body: "<html><body>not an image</body></html>"
         }}
      else
        {:ok, page_body(html("Title", nil, "/card.png"))}
      end
    end

    assert {:ok, [%{title: "Title", image: nil}], [warning, favicon_warning]} =
             Unfurl.resolve(["https://example.com/a"],
               resolver: resolver(),
               request: request,
               store_thumbnail: fn _bytes, _mime -> flunk("a non-image thumbnail was stored") end
             )

    assert warning ==
             {"https://example.com/card.png", {:unsupported_thumbnail_type, "text/html"}}

    assert favicon_warning ==
             {"https://example.com/favicon.ico", {:unsupported_icon_type, "text/html"}}
  end

  test "revalidates and pins every redirect target" do
    test_pid = self()

    request = fn pinned, _opts ->
      send(test_pid, {:requested, pinned.original_url})

      case pinned.original_url do
        "https://example.com/start" ->
          {:ok,
           %{
             status: 302,
             headers: %{"location" => ["https://other.test/end"]},
             body: "",
             private: %{}
           }}

        "https://other.test/end" ->
          {:ok, %{status: 200, headers: %{}, body: html("End", nil, nil), private: %{}}}

        "https://other.test/favicon.ico" ->
          {:ok, %{status: 404, headers: %{}, body: "", private: %{}}}
      end
    end

    assert {:ok,
            [%{link: "https://example.com/start", url: "https://other.test/end", title: "End"}],
            [{"https://other.test/favicon.ico", {:http_status, 404}}]} =
             Unfurl.resolve(["https://example.com/start"],
               resolver: resolver(),
               request: request
             )

    assert_receive {:requested, "https://example.com/start"}
    assert_receive {:requested, "https://other.test/end"}
    assert_receive {:requested, "https://other.test/favicon.ico"}
  end

  test "reports SSRF and oversized-body failures without hiding successful previews" do
    request = fn pinned, _opts ->
      {:ok,
       %{
         status: if(String.ends_with?(pinned.original_url, "/favicon.ico"), do: 404, else: 200),
         headers: %{},
         private: %{},
         body:
           if(pinned.original_host == "large.test",
             do: String.duplicate("x", 1_048_577),
             else: html("Good", nil, nil)
           )
       }}
    end

    resolver = fn
      "private.test" -> {:ok, [{127, 0, 0, 1}]}
      _host -> {:ok, [@public_ip]}
    end

    links = ~w(https://good.test/a https://private.test/b https://large.test/c)

    assert {:ok, [%{title: "Good"}], [_favicon, {"https://private.test/b", reason}, _large]} =
             Unfurl.resolve(links, resolver: resolver, request: request)

    assert reason == {:resolved_to_private_address, {127, 0, 0, 1}}

    assert {:ok, [], [{"https://large.test/c", :body_too_large}]} =
             Unfurl.resolve(["https://large.test/c"], resolver: resolver, request: request)
  end

  test "bounds redirects and keeps a thumbnail failure observable" do
    redirect = fn _pinned, _opts ->
      {:ok, %{status: 302, headers: %{"location" => ["/again"]}, body: "", private: %{}}}
    end

    assert {:ok, [], [{"https://example.com/start", :redirect_limit}]} =
             Unfurl.resolve(["https://example.com/start"],
               resolver: resolver(),
               request: redirect
             )

    page = fn pinned, _opts ->
      body =
        if pinned.original_url == "https://example.com/a",
          do: html("Title", nil, "/missing.png"),
          else: "image"

      status = if pinned.original_url == "https://example.com/a", do: 200, else: 500
      {:ok, %{status: status, headers: %{}, body: body, private: %{}}}
    end

    assert {:ok, [%{title: "Title", image: nil}], [warning, favicon_warning]} =
             Unfurl.resolve(["https://example.com/a"], resolver: resolver(), request: page)

    assert warning == {"https://example.com/missing.png", {:http_status, 500}}
    assert favicon_warning == {"https://example.com/favicon.ico", {:http_status, 500}}
  end

  test "streams both the page and thumbnail through the one MiB hard cap" do
    test_pid = self()

    request = fn pinned, opts ->
      send(test_pid, {:stream_options, pinned.original_url, opts})

      case pinned.original_url do
        "https://example.com/a" ->
          {:ok,
           %{
             status: 200,
             headers: %{},
             private: %{},
             body: html("Title", nil, "/large.png")
           }}

        "https://example.com/large.png" ->
          collector = Keyword.fetch!(opts, :into)
          response = %Req.Response{status: 200, headers: %{}, body: ""}
          chunk = String.duplicate("x", @max_body_bytes + 1)

          assert {:halt, {_request, capped}} =
                   collector.({:data, chunk}, {Req.new(), response})

          assert capped.body == ""
          {:ok, capped}

        "https://example.com/favicon.ico" ->
          {:ok, %{status: 404, headers: %{}, body: "", private: %{}}}
      end
    end

    assert {:ok, [%{title: "Title", image: nil}], [warning, _favicon]} =
             Unfurl.resolve(["https://example.com/a"],
               resolver: resolver(),
               request: request,
               store_thumbnail: fn _bytes, _mime -> flunk("oversized thumbnail was stored") end
             )

    assert warning == {"https://example.com/large.png", :body_too_large}

    assert_receive {:stream_options, "https://example.com/a", page_options}
    assert_receive {:stream_options, "https://example.com/large.png", thumbnail_options}

    for options <- [page_options, thumbnail_options] do
      assert options[:decode_body] == false
      assert is_function(options[:into], 2)
    end
  end

  # Links in the sentence (note 01): a site's icon comes from the head the
  # page already gave, under its own bounds, and never from a client.
  describe "a site's icon" do
    test "the PNG icon nearest 64 px is fetched before any other candidate" do
      head = """
      <link rel="icon" type="image/png" sizes="16x16" href="/i16.png">
      <link rel="icon" type="image/png" sizes="48x48" href="/i48.png">
      <link rel="icon" type="image/png" sizes="192x192" href="/i192.png">
      <link rel="apple-touch-icon" href="/apple.png">
      <link rel="shortcut icon" href="/fav.ico">
      <link rel="icon" type="image/svg+xml" href="/icon.svg">
      """

      site =
        site(%{"https://example.com/a" => page(head), "https://example.com/i48.png" => png()})

      assert {:ok, [%{title: "Title", icon: icon}], []} = resolve(["https://example.com/a"], site)
      assert icon == %{ref: digest(png_bytes()), mime: "image/png", size_bytes: 12}
      assert_received {:stored, _bytes, "image/png"}
      assert requested() == ["https://example.com/a", "https://example.com/i48.png"]
    end

    test "apple-touch-icon, then another non-SVG icon, when no PNG icon is declared" do
      site =
        site(%{
          "https://a.test/" =>
            page(
              ~s(<link rel="apple-touch-icon" href="/apple.png"><link rel="icon" href="/f.ico">)
            ),
          "https://a.test/apple.png" => png(),
          "https://b.test/" =>
            page(~s(<link rel="icon" href="/v.svg"><link rel="shortcut icon" href="/f.ico">)),
          "https://b.test/f.ico" => ico()
        })

      assert {:ok, [apple, ico], []} = resolve(["https://a.test/", "https://b.test/"], site)
      assert apple.icon.mime == "image/png"
      assert ico.icon == %{ref: digest(ico_bytes()), mime: "image/x-icon", size_bytes: 8}

      assert requested() -- ["https://a.test/", "https://b.test/"] ==
               ["https://a.test/apple.png", "https://b.test/f.ico"]
    end

    test "/favicon.ico at the page's final origin is the second and last try" do
      site =
        site(%{
          "https://example.com/start" => redirect("https://other.test/end"),
          "https://other.test/end" => page(""),
          "https://other.test/favicon.ico" => ico(),
          "https://fails.test/a" => page(~s(<link rel="icon" type="image/png" href="/i.png">))
        })

      assert {:ok, [moved, failed], warnings} =
               resolve(["https://example.com/start", "https://fails.test/a"], site)

      assert moved.icon.mime == "image/x-icon"
      assert failed.icon == nil

      assert warnings == [
               {"https://fails.test/i.png", {:http_status, 404}},
               {"https://fails.test/favicon.ico", {:http_status, 404}}
             ]

      assert requested() == [
               "https://example.com/start",
               "https://other.test/end",
               "https://other.test/favicon.ico",
               "https://fails.test/a",
               "https://fails.test/i.png",
               "https://fails.test/favicon.ico"
             ]
    end

    test "an icon is cut at 64 KiB while it streams, where a page keeps its MiB" do
      over = String.duplicate("x", 65_537)

      stream = fn body, opts ->
        collector = Keyword.fetch!(opts, :into)

        response = %Req.Response{
          status: 200,
          headers: %{"content-type" => ["image/png"]},
          body: ""
        }

        case collector.({:data, body}, {Req.new(), response}) do
          {:halt, {_request, capped}} -> {:ok, capped}
          {:cont, {_request, full}} -> {:ok, full}
        end
      end

      site =
        site(%{
          "https://example.com/a" => fn opts ->
            assert {:cont, _} =
                     Keyword.fetch!(opts, :into).(
                       {:data, over},
                       {Req.new(), %Req.Response{body: ""}}
                     )

            {:ok, page(~s(<link rel="icon" type="image/png" href="/big.png">))}
          end,
          "https://example.com/big.png" => &stream.(over, &1),
          "https://example.com/favicon.ico" =>
            &stream.(png_bytes() <> String.duplicate("x", 65_524), &1)
        })

      assert {:ok, [%{icon: icon}], [{"https://example.com/big.png", :body_too_large}]} =
               resolve(["https://example.com/a"], site)

      assert icon.size_bytes == 65_536
      refute_received {:stored, ^over, _mime}
    end

    test "refuses SVG by type and by href, a non-image type, and bytes of no allowed format" do
      site =
        site(%{
          "https://svg-type.test/" => page(~s(<link rel="icon" href="/icon">)),
          "https://svg-type.test/icon" => image("image/svg+xml", "<svg/>"),
          "https://svg-href.test/" =>
            page(~s(<link rel="icon" type="image/png" href="/icon.svg">)),
          "https://svg-href.test/favicon.ico" => ico(),
          "https://html.test/" => page(""),
          "https://html.test/favicon.ico" => image("text/html", "<html>no</html>"),
          "https://bytes.test/" => page(~s(<link rel="icon" type="image/png" href="/i.png">)),
          "https://bytes.test/i.png" => image("image/png", "<html>not a png</html>")
        })

      links =
        ~w(https://svg-type.test/ https://svg-href.test/ https://html.test/ https://bytes.test/)

      assert {:ok, [by_type, by_href, html, bytes], warnings} = resolve(links, site)

      assert by_type.icon == nil
      assert by_href.icon.mime == "image/x-icon"
      assert html.icon == nil
      assert bytes.icon == nil

      assert warnings == [
               {"https://svg-type.test/icon", {:unsupported_icon_type, "image/svg+xml"}},
               {"https://svg-type.test/favicon.ico", {:http_status, 404}},
               {"https://html.test/favicon.ico", {:unsupported_icon_type, "text/html"}},
               {"https://bytes.test/i.png", {:unrecognised_icon_bytes, "image/png"}},
               {"https://bytes.test/favicon.ico", {:http_status, 404}}
             ]

      refute_received {:stored, "<svg/>", _mime}
      refute_received {:stored, "<html>not a png</html>", _mime}
      refute "https://svg-href.test/icon.svg" in requested()
    end

    test "an icon on a private address is refused by the guard before any request" do
      site =
        site(%{
          "https://good.test/" =>
            page(~s(<link rel="icon" type="image/png" href="https://private.test/i.png">)),
          "https://good.test/favicon.ico" => ico()
        })

      resolver = fn
        "private.test" -> {:ok, [{127, 0, 0, 1}]}
        _host -> {:ok, [@public_ip]}
      end

      assert {:ok, [%{icon: %{mime: "image/x-icon"}}], [warning]} =
               resolve(["https://good.test/"], site, resolver: resolver)

      assert warning ==
               {"https://private.test/i.png", {:resolved_to_private_address, {127, 0, 0, 1}}}

      refute "https://private.test/i.png" in requested()
    end

    test "an icon's redirects are pinned one by one and bounded" do
      site =
        site(%{
          "https://moved.test/" => page(~s(<link rel="icon" type="image/png" href="/i.png">)),
          "https://moved.test/i.png" => redirect("https://cdn.test/i.png"),
          "https://cdn.test/i.png" => png(),
          "https://loop.test/" => page(~s(<link rel="icon" type="image/png" href="/i.png">)),
          "https://loop.test/i.png" => redirect("/i.png"),
          "https://loop.test/favicon.ico" => ico()
        })

      assert {:ok, [moved, looped], [{"https://loop.test/i.png", :redirect_limit}]} =
               resolve(["https://moved.test/", "https://loop.test/"], site)

      assert moved.icon.mime == "image/png"
      assert looped.icon.mime == "image/x-icon"
      assert "https://cdn.test/i.png" in requested()
    end

    test "links on one host share one icon fetch, a refused icon included" do
      declared = ~s(<link rel="icon" type="image/png" href="/i.png">)

      site =
        site(%{
          "https://example.com/a" => page(declared),
          "https://example.com/b" => page(declared),
          "https://example.com/i.png" => png(),
          "https://none.test/a" => page(""),
          "https://none.test/b" => page("")
        })

      links =
        ~w(https://example.com/a https://example.com/b https://none.test/a https://none.test/b)

      assert {:ok, [a, b, none_a, none_b],
              [{"https://none.test/favicon.ico", {:http_status, 404}}]} =
               resolve(links, site)

      assert a.icon == b.icon
      assert a.icon.mime == "image/png"
      assert none_a.icon == nil and none_b.icon == nil

      requested = requested()
      assert Enum.count(requested, &(&1 == "https://example.com/i.png")) == 1
      assert Enum.count(requested, &(&1 == "https://none.test/favicon.ico")) == 1
    end
  end

  # Each preview is handed over as it resolves, so a caller can publish it
  # before a slower link's page answers.
  test "each preview is handed to on_preview as it resolves, before the next page is fetched" do
    test_pid = self()
    site = site(%{"https://a.test/" => page(""), "https://b.test/" => page("")})

    assert {:ok, [a, b], _warnings} =
             resolve(["https://a.test/", "https://b.test/"], site,
               on_preview: &send(test_pid, {:preview, &1})
             )

    order =
      mailbox()
      |> Enum.filter(&(match?({:preview, _}, &1) or match?({:requested, _, _}, &1)))
      |> Enum.map(&elem(&1, 1))

    assert order == [
             "https://a.test/",
             "https://a.test/favicon.ico",
             a,
             "https://b.test/",
             "https://b.test/favicon.ico",
             b
           ]

    assert {:error, :invalid_on_preview} =
             resolve(["https://a.test/"], site, on_preview: fn -> :ok end)
  end

  defp resolver do
    fn _host -> {:ok, [@public_ip]} end
  end

  defp resolve(links, site, extra \\ []) do
    test_pid = self()

    store = fn bytes, mime ->
      send(test_pid, {:stored, bytes, mime})
      {:ok, digest(bytes)}
    end

    Unfurl.resolve(
      links,
      Keyword.merge([resolver: resolver(), request: site, store_thumbnail: store], extra)
    )
  end

  # A site the request seam answers from: a response by URL, a function of the
  # request options, or 404 for anything else. Every request is reported.
  defp site(pages) do
    test_pid = self()

    fn pinned, opts ->
      send(test_pid, {:requested, pinned.original_url, opts})

      case Map.get(pages, pinned.original_url) do
        nil -> {:ok, %{status: 404, headers: %{}, body: "", private: %{}}}
        answer when is_function(answer, 1) -> answer.(opts)
        response -> {:ok, response}
      end
    end
  end

  defp page(head), do: image("text/html; charset=utf-8", html("Title", nil, nil, head))
  defp page_body(body), do: image("text/html; charset=utf-8", body)
  defp png, do: image("image/png", png_bytes())
  defp ico, do: image("image/x-icon", ico_bytes())
  defp png_bytes, do: <<0x89, "PNG\r\n\x1A\n", "rest">>
  defp ico_bytes, do: <<0, 0, 1, 0, "rest">>

  defp image(type, body),
    do: %{status: 200, headers: %{"content-type" => [type]}, private: %{}, body: body}

  defp redirect(to), do: %{status: 302, headers: %{"location" => [to]}, private: %{}, body: ""}
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp requested,
    do: mailbox() |> Enum.filter(&match?({:requested, _, _}, &1)) |> Enum.map(&elem(&1, 1))

  # Every message in the order it arrived: the seams run in this process, so
  # all of it is already here.
  defp mailbox, do: mailbox([])

  defp mailbox(acc) do
    receive do
      message -> mailbox([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp html(title, description, image, head \\ "") do
    """
    <html><head>
      <meta property="og:site_name" content="Example">
      <meta property="og:title" content="#{title}">
      #{meta("og:description", description)}
      #{meta("og:image", image)}
      #{head}
      <title>Fallback</title>
    </head><body></body></html>
    """
  end

  defp meta(_property, nil), do: ""
  defp meta(property, value), do: ~s(<meta property="#{property}" content="#{value}">)
end
