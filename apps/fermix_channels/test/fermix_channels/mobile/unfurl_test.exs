defmodule FermixChannels.Mobile.UnfurlTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Unfurl

  @max_body_bytes 1_048_576
  @public_ip {93, 184, 216, 34}

  test "resolves at most two unique links and extracts Open Graph metadata" do
    test_pid = self()

    request = fn pinned, opts ->
      send(test_pid, {:request, pinned, opts})

      if String.ends_with?(pinned.original_url, "/card.png") do
        {:ok,
         %{
           status: 200,
           headers: %{"content-type" => ["image/png"]},
           private: %{},
           body: "png-bytes"
         }}
      else
        {:ok,
         %{
           status: 200,
           headers: %{"content-type" => ["text/html; charset=utf-8"]},
           private: %{},
           body: html("Fermix", "A private assistant", "/card.png")
         }}
      end
    end

    store_thumbnail = fn bytes, mime ->
      send(test_pid, {:stored_thumbnail, bytes, mime})
      {:ok, String.duplicate("a", 64)}
    end

    text =
      "See https://example.com/a, again https://example.com/a and " <>
        "https://example.com/b plus https://example.com/c"

    assert {:ok, previews, []} =
             Unfurl.resolve(text,
               resolver: resolver(),
               request: request,
               store_thumbnail: store_thumbnail
             )

    assert Enum.map(previews, & &1.url) == ["https://example.com/a", "https://example.com/b"]

    assert Enum.all?(previews, fn preview ->
             preview.site == "Example" and preview.title == "Fermix" and
               preview.description == "A private assistant" and
               preview.image_ref == String.duplicate("a", 64)
           end)

    assert_receive {:request, %{url: "https://93.184.216.34/a", original_host: "example.com"},
                    opts}

    assert {"host", "example.com"} in opts[:headers]
    assert opts[:receive_timeout] == 15_000
    assert_receive {:stored_thumbnail, "png-bytes", "image/png"}
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
        {:ok,
         %{
           status: 200,
           headers: %{"content-type" => ["text/html"]},
           private: %{},
           body: html("Title", nil, "/card.png")
         }}
      end
    end

    assert {:ok, [%{title: "Title", image_ref: nil}], [warning]} =
             Unfurl.resolve("https://example.com/a",
               resolver: resolver(),
               request: request,
               store_thumbnail: fn _bytes, _mime -> flunk("a non-image thumbnail was stored") end
             )

    assert warning ==
             {"https://example.com/card.png", {:unsupported_thumbnail_type, "text/html"}}
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
      end
    end

    assert {:ok, [%{url: "https://other.test/end", title: "End"}], []} =
             Unfurl.resolve("https://example.com/start",
               resolver: resolver(),
               request: request
             )

    assert_receive {:requested, "https://example.com/start"}
    assert_receive {:requested, "https://other.test/end"}
  end

  test "reports SSRF and oversized-body failures without hiding successful previews" do
    request = fn pinned, _opts ->
      {:ok,
       %{
         status: 200,
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

    text = "https://good.test/a https://private.test/b https://large.test/c"

    assert {:ok, [%{title: "Good"}], [{"https://private.test/b", reason}]} =
             Unfurl.resolve(text, resolver: resolver, request: request)

    assert reason == {:resolved_to_private_address, {127, 0, 0, 1}}

    assert {:ok, [], [{"https://large.test/c", :body_too_large}]} =
             Unfurl.resolve("https://large.test/c", resolver: resolver, request: request)
  end

  test "bounds redirects and keeps a thumbnail failure observable" do
    redirect = fn _pinned, _opts ->
      {:ok, %{status: 302, headers: %{"location" => ["/again"]}, body: "", private: %{}}}
    end

    assert {:ok, [], [{"https://example.com/start", :redirect_limit}]} =
             Unfurl.resolve("https://example.com/start",
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

    assert {:ok, [%{title: "Title", image_ref: nil}], [warning]} =
             Unfurl.resolve("https://example.com/a", resolver: resolver(), request: page)

    assert warning == {"https://example.com/missing.png", {:http_status, 500}}
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
      end
    end

    assert {:ok, [%{title: "Title", image_ref: nil}], [warning]} =
             Unfurl.resolve("https://example.com/a",
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

  defp resolver do
    fn _host -> {:ok, [@public_ip]} end
  end

  defp html(title, description, image) do
    """
    <html><head>
      <meta property="og:site_name" content="Example">
      <meta property="og:title" content="#{title}">
      #{meta("og:description", description)}
      #{meta("og:image", image)}
      <title>Fallback</title>
    </head><body></body></html>
    """
  end

  defp meta(_property, nil), do: ""
  defp meta(property, value), do: ~s(<meta property="#{property}" content="#{value}">)
end
