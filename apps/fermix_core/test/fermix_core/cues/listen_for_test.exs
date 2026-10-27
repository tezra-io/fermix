defmodule FermixCore.Cues.ListenForTest do
  use ExUnit.Case, async: true

  alias FermixCore.Cues.ListenFor

  defp matches?(words, item) do
    {:ok, words} = ListenFor.validate(words)
    ListenFor.match?(ListenFor.compile(words), ListenFor.prepare(item))
  end

  defp post(text, extra \\ %{}),
    do: %{type: "create", subject: nil, title: nil, data: Map.merge(%{"text" => text}, extra)}

  describe "validate/1" do
    test "trims, keeps the first spelling of words that normalize alike, and counts 1 to 200" do
      assert ListenFor.validate([" TSMC ", "tsmc", "Café", "cafe"]) == {:ok, ["TSMC", "Café"]}
      assert {:error, "A watcher listens for at least one word."} = ListenFor.validate([])

      assert {:error, "A watcher listens for at most 200 words or short phrases."} =
               ListenFor.validate(Enum.map(1..201, &"word#{&1}"))
    end

    test "refuses what cannot be a word" do
      assert {:error, "A word to listen for cannot be empty."} = ListenFor.validate(["  "])

      assert {:error, "Each word to listen for takes a single line."} =
               ListenFor.validate(["a\nb"])

      assert {:error, "A word to listen for needs a letter or a digit: --"} =
               ListenFor.validate(["--"])

      assert {:error, "Each word to listen for is at most 64" <> _} =
               ListenFor.validate([String.duplicate("x", 65)])

      assert {:error, "Give the words to listen for as a list."} = ListenFor.validate("chips")
      assert {:error, "Each word to listen for is text."} = ListenFor.validate([42])
    end
  end

  describe "matching" do
    test "whole tokens, ignoring case and accents, never inside a word" do
      assert matches?(["ai"], post("New AI model tops the charts"))
      refute matches?(["ai"], post("She said the rain would stop"))
      assert matches?(["semicondutor"], post("Novo SEMICONDUTOR nacional"))
      assert matches?(["eleição"], post("A eleicao de hoje"))
    end

    test "a phrase matches its tokens in order" do
      assert matches?(["large language model"], post("A large-language model, released today"))
      refute matches?(["large language model"], post("a model of large language"))
    end

    test "scripts written without spaces match as substrings, and split from Latin" do
      assert matches?(["芯片"], post("台积电扩产芯片工厂"))
      assert matches?(["ai"], post("AI芯片が新しい"))
      assert matches?(["ロケット"], post("新型ロケットを打ち上げ"))
    end

    test "Japanese dakuten stay, so が does not match か" do
      assert matches?(["が"], post("これが答え"))
      refute matches?(["が"], post("これか答え"))
    end

    test "a word with digits matches; a piece with neither a letter nor a digit is not read" do
      assert matches?(["RTX 5090"], post("The RTX 5090 is out of stock again"))
      assert matches?(["iPhone 17"], post("iPhone 17 review: the battery lasts"))
      bare = %{type: nil, subject: nil, title: nil, data: %{"text" => "Launch — today !!"}}
      assert ListenFor.prepare(bare).text == "launch today"
    end

    test "a link's piece is skipped, the rest of its value is read" do
      assert matches?(["半導体"], post("新しい半導体工場を発表 https://example.com/news/1"))
    end

    test "keys, addresses, DIDs and dotted names are never searched" do
      item = %{
        type: "create",
        subject: "did:plc:feedpostapp",
        title: nil,
        data: %{
          "$type" => "app.bsky.feed.post",
          "app" => "x",
          "uri" => "at://did:plc:abc/app.bsky.feed.post/1",
          "text" => "lunch was nice"
        }
      }

      refute matches?(["app"], item)
      refute matches?(["feed"], item)
      refute matches?(["post"], item)
      refute matches?(["plc"], item)
    end

    test "a link card's title counts with the post's text" do
      card = %{"embed" => %{"external" => %{"title" => "Chipmaker opens a new fab"}}}
      assert matches?(["fab"], post("worth a read", card))
    end

    test "the words are a broad gate, not the judge: ordinary collisions still match" do
      # §1.1: these reach the filter model, which drops them.
      assert matches?(["ai"], post("j'ai fini"))
      assert matches?(["chip"], post("one more chocolate chip cookie"))
    end

    test "no word matches an item with no text" do
      refute matches?(["chip"], %{type: nil, subject: nil, title: nil, data: nil})
    end
  end

  test "text past 64 KiB is not read" do
    filler = String.duplicate("a ", 40_000)
    assert matches?(["chip"], post("chip " <> filler))
    refute matches?(["chip"], post(filler <> " chip"))
  end
end
