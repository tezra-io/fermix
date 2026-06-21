defmodule FermixCore.Providers.ScreenshotRetention do
  @moduledoc """
  Bounds how many tool-result screenshot images ride in the replayed provider
  history.

  Every provider surface re-sends the full message/item list each turn (no
  `previous_response_id` shortcut on any of them), so without a cap every
  accumulated screenshot's bytes are re-uploaded on every continuation — a
  cost/latency blow-up on long browser / computer-use sessions. This keeps image
  payloads only in the most recent `keep` screenshot carriers and elides older
  ones to a text marker, so the model still sees that a screenshot was there (and
  keeps its textual context) but not the stale bytes.

  It operates over the *assembled* history (where old screenshots already live),
  which is the only place "keep the most recent N" can be expressed — a per-turn
  counter cannot, because each continuation only sees the current turn's fresh
  results. Inbound user-content images are NOT screenshot carriers: each adapter's
  `screenshot?` predicate matches only its own tool-result carrier shape (the
  `tool_result`-embedded image blocks on Anthropic, the labelled follow-up turn on
  the OpenAI surfaces), so genuine user images are never touched.
  """

  @doc """
  Keep screenshot image payloads only in the last `keep` carriers of `units`.

  `screenshot?` identifies a carrier that still holds image bytes; `elide`
  returns the same unit with its images replaced by a text marker. A `keep` of
  `nil` disables retention (returns `units` unchanged). The earliest
  `count - keep` carriers are elided; the rest pass through untouched.
  """
  @spec keep_last([unit], non_neg_integer() | nil, (unit -> boolean()), (unit -> unit)) :: [unit]
        when unit: term()
  def keep_last(units, nil, _screenshot?, _elide) when is_list(units), do: units

  def keep_last(units, keep, screenshot?, elide)
      when is_list(units) and is_integer(keep) and keep >= 0 and
             is_function(screenshot?, 1) and is_function(elide, 1) do
    drop = max(Enum.count(units, screenshot?) - keep, 0)

    {result, _elided} =
      Enum.map_reduce(units, 0, fn unit, elided ->
        if screenshot?.(unit) and elided < drop,
          do: {elide.(unit), elided + 1},
          else: {unit, elided}
      end)

    result
  end
end
