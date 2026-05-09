defmodule FermixCore.Tools.HtmlTextTest do
  use ExUnit.Case, async: true

  alias FermixCore.Tools.HtmlText

  test "extracts markdown-light text from HTML structure" do
    html = """
    <html><head><style>.x{}</style><script>alert(1)</script></head>
    <body>
      <h1>Title</h1>
      <p>Hello <strong>bold</strong> <a href="https://example.com">link</a>.</p>
      <ul><li>One</li><li>Two</li></ul>
      <pre><code>mix test</code></pre>
    </body></html>
    """

    {:ok, doc} = Floki.parse_document(html)
    text = HtmlText.extract(doc)

    assert text =~ "# Title"
    assert text =~ "Hello bold [link](https://example.com)."
    assert text =~ "- One"
    assert text =~ "- Two"
    assert text =~ "```"
    assert text =~ "mix test"
    refute text =~ "alert"
    refute text =~ ".x"
  end
end
