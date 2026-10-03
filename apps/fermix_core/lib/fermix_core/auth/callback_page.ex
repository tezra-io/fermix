defmodule FermixCore.Auth.CallbackPage do
  @moduledoc """
  The page a browser sign-in lands on when it returns to Fermix's loopback
  listener: one page for every provider and plugin that signs in through
  `Auth.OAuthFlow`.

  It is self-contained (inline style, the Fermix pet mark inlined as a data
  image, no script, nothing fetched), because it is served from `127.0.0.1` at
  the moment a sign-in completes and must render offline and leak nothing. It
  follows the browser's light or dark scheme.

  The browser is answered before the code is exchanged and the account is
  verified, so the received page never claims the sign-in succeeded: the result
  shows where the sign-in was started.
  """

  @type kind :: :received | :not_this_sign_in | :failed

  @copy %{
    received:
      {"Return to Fermix",
       "Fermix received your sign-in and is finishing it. You can close this tab. " <>
         "The result shows where you started the sign-in."},
    not_this_sign_in:
      {"Not part of this sign-in",
       "This address doesn't belong to the sign-in Fermix is waiting for. " <>
         "Return to Fermix and start the sign-in from there."},
    failed:
      {"Sign-in didn't finish",
       "Fermix couldn't finish this sign-in. The reason shows where you started it."}
  }

  # The Fermix pet in one ink: the macOS app's interim mark
  # (fermix-macos `Resources/MenuBarTemplate/FermixMarkMaster.png`, derived from
  # the pet artwork by its `scripts/build_mascot_mark.py`), downscaled to 192px.
  # It is alpha only, so it is drawn as a CSS mask filled with the text colour:
  # dark ink on a light page, light ink on a dark one, the visor showing through.
  @mark_path Path.expand("../../../priv/brand/fermix-mark.png", __DIR__)
  @external_resource @mark_path
  @mark_uri "data:image/png;base64," <> Base.encode64(File.read!(@mark_path))

  @style """
  :root{color-scheme:light dark;--bg:#f5f6fa;--card:#fff;--text:#0b0d17;--muted:#5a6175;--line:#e3e6ef}
  @media (prefers-color-scheme:dark){:root{--bg:#04050b;--card:#0b0d17;--text:#eef3ff;--muted:#9aa3b8;--line:#1c2133}}
  *{box-sizing:border-box}
  body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px 16px;background:var(--bg);color:var(--text);font:16px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}
  main{width:100%;max-width:420px;padding:32px 28px;background:var(--card);border:1px solid var(--line);border-radius:16px;text-align:center}
  .mark{--mark:url(#{@mark_uri});width:72px;height:72px;margin:0 auto;background:var(--text);-webkit-mask:var(--mark) center/contain no-repeat;mask:var(--mark) center/contain no-repeat}
  h1{margin:18px 0 8px;font-size:20px;font-weight:600}
  p{margin:0;color:var(--muted)}
  """

  @doc "The page for one callback outcome."
  @spec render(kind()) :: String.t()
  def render(kind) when is_map_key(@copy, kind) do
    {title, message} = Map.fetch!(@copy, kind)

    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Fermix</title>
    <style>
    #{@style}</style>
    </head>
    <body><main>
    <div class="mark" aria-hidden="true"></div>
    <h1>#{title}</h1>
    <p>#{message}</p>
    </main></body>
    </html>
    """
  end
end
