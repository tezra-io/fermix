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

  defp x_row(row) do
    source =
      %{
        "sources" => %{"space-posts" => %{"preset" => "x_accounts", "handles" => ["NASA", "esa"]}}
      }
      |> CuesConfig.normalize()
      |> CuesConfig.sources()
      |> hd()

    facts = %{row: row, summary: nil, running?: true, cues_on?: true, memory?: true, window_s: 1}
    SourceRow.build(source, facts)
  end

  # M60_X_ACCOUNTS_SOURCE.md §4.
  describe "an X accounts source" do
    test "reads its handles where a feed reads its host, and has no URL" do
      row = x_row(%{status: "polling", stop_reason: nil})

      assert row["location"] == "@nasa, @esa"
      assert row["url"] == nil
      assert row["label"] == "X accounts"
      assert row["secrets"] == []
    end

    test "waiting for the X sign-in says where to connect X" do
      row = x_row(%{status: "auth_failed", stop_reason: "x_sign_in"})

      assert row["state"] == "auth_failed"
      assert row["status_sentence"] == "Needs your X sign-in: connect X under Plugins."
    end
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
