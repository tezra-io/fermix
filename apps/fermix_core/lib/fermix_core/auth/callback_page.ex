defmodule FermixCore.Auth.CallbackPage do
  @moduledoc """
  The page a browser sign-in lands on when it returns to Fermix's loopback
  listener: one page for every provider and plugin that signs in through
  `Auth.OAuthFlow`.

  It is self-contained (inline style, the pixel mascot inlined as SVG, no
  script, no font or image fetched), because it is served from `127.0.0.1` at
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

  # The site's 15x15 pixel mascot (fermix-site `public/assets/fermix-pixel.svg`),
  # drawn on a light tile in both schemes so its near-black spine and antenna
  # stay visible on a dark card.
  @mascot ~s(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 15 15" ) <>
            ~s(shape-rendering="crispEdges" aria-hidden="true">) <>
            ~s(<path fill="#ffd166" d="M7 0h2v1H7z"/><path fill="#04050b" d="M7 1h2v2H7z"/>) <>
            ~s(<polygon fill="#2b5cff" points="1,4 6,4 8,6 8,14 6,12 1,11"/>) <>
            ~s(<polygon fill="#2b5cff" points="8,6 10,4 15,4 15,11 10,12 8,14"/>) <>
            ~s(<polygon fill="#3b6bff" points="2,5 6,5 7,6 7,12 6,11 2,10"/>) <>
            ~s(<polygon fill="#3b6bff" points="9,6 10,5 14,5 14,10 10,11 9,12"/>) <>
            ~s(<path fill="#9bb8ff" d="M2 5h4v1h1v1H2zM10 5h4v2H9V6h1z"/>) <>
            ~s(<path fill="#04050b" d="M7 5h2v9H7z"/>) <>
            ~s(<path fill="#eef3ff" d="M4 7h3v3H4zM9 7h3v3H9z"/>) <>
            ~s(<path fill="#0b0d17" d="M5 8h1v1H5zM10 8h1v1h-1z"/>) <>
            ~s(<path fill="#51e0ff" d="M2 10h3v1H2zM11 10h3v1h-3z"/></svg>)

  @style """
  :root{color-scheme:light dark;--bg:#f5f6fa;--card:#fff;--text:#0b0d17;--muted:#5a6175;--line:#e3e6ef;--tile:#eef2ff}
  @media (prefers-color-scheme:dark){:root{--bg:#04050b;--card:#0b0d17;--text:#eef3ff;--muted:#9aa3b8;--line:#1c2133;--tile:#e4e9f7}}
  *{box-sizing:border-box}
  body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px 16px;background:var(--bg);color:var(--text);font:16px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}
  main{width:100%;max-width:420px;padding:32px 28px;background:var(--card);border:1px solid var(--line);border-radius:16px;text-align:center}
  .mark{display:inline-grid;place-items:center;width:84px;height:84px;border-radius:20px;background:var(--tile)}
  svg{width:56px;height:56px}
  h1{margin:16px 0 8px;font-size:20px;font-weight:600}
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
    <div class="mark">#{@mascot}</div>
    <h1>#{title}</h1>
    <p>#{message}</p>
    </main></body>
    </html>
    """
  end
end
