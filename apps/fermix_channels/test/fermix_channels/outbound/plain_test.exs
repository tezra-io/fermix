defmodule FermixChannels.Outbound.PlainTest do
  @moduledoc """
  The shared plain-text dialect (MILESTONE_54 §8.1): one dialect, two channels.
  Signal's own goldens stay in `channels/signal/plain_test.exs` and now run
  through Signal's delegation; this file pins the shared module itself and that
  the two names are one renderer.
  """
  use ExUnit.Case, async: true

  alias FermixChannels.Channels.Signal
  alias FermixChannels.Outbound.Plain

  @samples [
    "a **bold** claim with *emphasis* and ~~strike~~",
    "see [the schedule](https://example.com/s?a=1&b_c=2)",
    "### Heading\n\n- one\n- two\n\n> quoted",
    "```elixir\ndef go, do: :ok\n```",
    "| a | b |\n|---|---|\n| 1 | 22 |",
    "snake_case and 2 * 3 * 4 stay"
  ]

  test "renders model Markdown as plain text" do
    assert Plain.render("a **bold** [link](https://x.test)") == "a bold link: https://x.test"
    assert Plain.render("- item") == "• item"
    assert Plain.render("```\ncode\n```") == "    code"
  end

  test "measures the rendered form, not the Markdown" do
    assert Plain.rendered_length("**ab**") == 2
  end

  test "Signal's dialect is this module, byte for byte" do
    for sample <- @samples do
      assert Signal.Plain.render(sample) == Plain.render(sample)
      assert Signal.Plain.rendered_length(sample) == Plain.rendered_length(sample)
    end
  end
end
