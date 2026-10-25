defmodule FermixCore.Management.Cues.SourceRowTest do
  use ExUnit.Case, async: true

  alias FermixCore.Cues.Config, as: CuesConfig
  alias FermixCore.Management.Cues.SourceRow

  defp source do
    %{
      "sources" => %{
        "harbour-hours" => %{"preset" => "rss", "url" => "https://example.org/feed.xml"}
      }
    }
    |> CuesConfig.normalize()
    |> CuesConfig.sources()
    |> hd()
  end

  defp sentence(row) do
    facts = %{
      row: row,
      summary: nil,
      running?: true,
      cues_on?: true,
      memory?: true,
      window_s: 86_400
    }

    SourceRow.build(source(), facts)["status_sentence"]
  end

  describe "an unavailable source" do
    test "says its feed is too large when it stopped for that" do
      row = %{status: "unavailable", stop_reason: "too_large", notices: %{}}
      assert sentence(row) == "Its feed is larger than Fermix reads."
    end

    test "says Fermix could not reach it when it stopped with no reason, whatever it was told" do
      row = %{status: "unavailable", stop_reason: nil, notices: %{"too_large" => "2026-10-20"}}
      assert sentence(row) == "Fermix could not reach it."
    end
  end
end
