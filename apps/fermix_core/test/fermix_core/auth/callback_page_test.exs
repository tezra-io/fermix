defmodule FermixCore.Auth.CallbackPageTest do
  use ExUnit.Case, async: true

  alias FermixCore.Auth.CallbackPage

  @kinds [:received, :not_this_sign_in, :failed]

  test "each outcome has its own title" do
    assert CallbackPage.render(:received) =~ "<h1>Return to Fermix</h1>"
    assert CallbackPage.render(:not_this_sign_in) =~ "<h1>Not part of this sign-in</h1>"
    assert CallbackPage.render(:failed) =~ "<h1>Sign-in didn't finish</h1>"
  end

  # Answered before the code is exchanged, so it must never claim success.
  test "the received page never claims the sign-in succeeded" do
    page = CallbackPage.render(:received)

    refute page =~ ~r/complete|success|signed in/i
    assert page =~ "The result shows where you started the sign-in."
  end

  # Served from 127.0.0.1 at sign-in time: it must render offline and fetch
  # nothing, so the Fermix pet mark is an inline data image and nothing points
  # off the page.
  test "every page is self-contained: the inline pet mark, no script, nothing fetched" do
    for kind <- @kinds do
      page = CallbackPage.render(kind)

      assert page =~ ~s(<div class="mark" aria-hidden="true"></div>)
      assert page =~ "--mark:url(data:image/png;base64,"
      refute page =~ "<script"
      refute page =~ ~r/(src|href)=/
      refute page =~ "@import"
      assert Regex.scan(~r/url\((?!data:image\/png;base64,)/, page) == []
    end
  end

  # The mark is the pet in one ink, so it takes the text colour and follows the
  # scheme rather than carrying colours of its own.
  test "the pet mark is drawn in the text colour" do
    assert CallbackPage.render(:received) =~
             "width:72px;height:72px;margin:0 auto;background:var(--text);"
  end

  # One copy of the image: both mask rules read it from a custom property.
  test "the mark's image is inlined once" do
    assert length(String.split(CallbackPage.render(:received), "data:image/png;base64,")) == 2
  end

  test "every page follows the browser's light or dark scheme" do
    for kind <- @kinds do
      assert CallbackPage.render(kind) =~ "@media (prefers-color-scheme:dark)"
    end
  end

  test "an unknown outcome is refused" do
    assert_raise FunctionClauseError, fn -> CallbackPage.render(:other) end
  end
end
