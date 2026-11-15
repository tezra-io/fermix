defmodule FermixChannels.Mobile.WebPush.PayloadTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.WebPush.Encryption
  alias FermixChannels.Mobile.WebPush.Payload

  @max 2_047

  defp message(preview, overrides \\ %{}) do
    Map.merge(
      %{kind: :message, profile_id: "main", server_seq: 42, preview_text: preview},
      overrides
    )
  end

  defp preview_of(json), do: Jason.decode!(json)["preview_text"]

  # The kept text is a whole-grapheme prefix of the original, then "…".
  defp assert_cut(json, original) do
    assert byte_size(json) <= @max
    assert String.valid?(json)

    preview = preview_of(json)
    assert String.ends_with?(preview, "…")
    kept = String.replace_suffix(preview, "…", "")

    assert String.starts_with?(original, kept)
    kept_graphemes = String.graphemes(kept)
    assert Enum.take(String.graphemes(original), length(kept_graphemes)) == kept_graphemes
    kept
  end

  describe "encode/1" do
    test "a message is compact JSON with its keys in a fixed order" do
      assert {:ok, json} = Payload.encode(message("Dinner at Orvane is booked for 19:30."))

      assert json ==
               ~s({"v":1,"kind":"message","profile_id":"main","server_seq":42,) <>
                 ~s("preview_text":"Dinner at Orvane is booked for 19:30."})
    end

    test "a message without a preview or a row number writes JSON null for each" do
      assert {:ok, json} = Payload.encode(message(nil, %{server_seq: nil}))

      assert json ==
               ~s({"v":1,"kind":"message","profile_id":"main","server_seq":null,"preview_text":null})
    end

    test "an approval carries no preview and no row number" do
      approval = %{kind: :approval, profile_id: "work", server_seq: nil, preview_text: nil}

      assert {:ok, json} = Payload.encode(approval)

      assert json ==
               ~s({"v":1,"kind":"approval","profile_id":"work","server_seq":null,"preview_text":null})

      assert {:error, :approval_with_content} =
               Payload.encode(%{approval | preview_text: "rm -rf build"})

      assert {:error, :approval_with_content} = Payload.encode(%{approval | server_seq: 7})
    end

    test "a preview that fits is kept whole, up to exactly 2,047 bytes" do
      {:ok, base} = Payload.encode(message(""))
      fitting = :binary.copy("a", @max - byte_size(base))

      assert {:ok, json} = Payload.encode(message(fitting))
      assert byte_size(json) == @max
      assert preview_of(json) == fitting
    end

    test "one byte over, the preview is cut and ends with an ellipsis" do
      {:ok, base} = Payload.encode(message(""))
      over = :binary.copy("a", @max - byte_size(base) + 1)

      assert {:ok, json} = Payload.encode(message(over))
      kept = assert_cut(json, over)
      assert byte_size(json) == @max
      assert byte_size(kept) == byte_size(over) - 1 - 3
    end

    test "a long ASCII preview is cut to fill the record exactly" do
      long = String.duplicate("The quarterly review moved to Thursday. ", 200)

      assert {:ok, json} = Payload.encode(message(long))
      assert_cut(json, long)
      assert byte_size(json) == @max
    end

    test "multi-byte text is cut at a character boundary, never inside one" do
      for unit <- ["é", "日本語", "🙂", "👩‍👩‍👧", "é"] do
        long = String.duplicate("ab" <> unit, 1_200)

        assert {:ok, json} = Payload.encode(message(long))
        assert_cut(json, long)
      end
    end

    test "text the JSON has to escape is measured escaped" do
      long = String.duplicate(~s(say "hi"\n\t\\ \u0001 ), 400)

      assert {:ok, json} = Payload.encode(message(long))
      assert_cut(json, long)
    end

    test "the longest profile, the largest row number and a huge preview still fit one record" do
      fields = %{
        kind: :message,
        profile_id: :binary.copy(<<1>>, 128),
        server_seq: 18_446_744_073_709_551_615,
        preview_text: String.duplicate("🙂", 100_000)
      }

      assert {:ok, json} = Payload.encode(fields)
      assert_cut(json, fields.preview_text)

      {public, _private} = :crypto.generate_key(:ecdh, :secp256r1)
      assert {:ok, body} = Encryption.encrypt(json, public, :crypto.strong_rand_bytes(16))
      assert byte_size(body) == Encryption.body_size()
    end
  end

  describe "refusals" do
    test "a profile id that is empty, longer than 128 bytes or not UTF-8 is refused" do
      for profile_id <- ["", :binary.copy("p", 129), <<0xFF, 0xFE>>, :main] do
        assert {:error, {:invalid_field, :profile_id}} =
                 Payload.encode(message("x", %{profile_id: profile_id}))
      end

      assert {:ok, _json} = Payload.encode(message("x", %{profile_id: :binary.copy("p", 128)}))
    end

    test "a row number that is not a positive 64-bit integer is refused" do
      for seq <- [0, -1, 18_446_744_073_709_551_616, 1.5, "42"] do
        assert {:error, {:invalid_field, :server_seq}} =
                 Payload.encode(message("x", %{server_seq: seq}))
      end
    end

    test "a preview that is not UTF-8 text is refused" do
      for preview <- [<<0xC3>>, :text, 42] do
        assert {:error, {:invalid_field, :preview_text}} = Payload.encode(message(preview))
      end
    end

    test "an unknown kind or an unknown field is refused" do
      assert {:error, {:invalid_field, :kind}} = Payload.encode(message("x", %{kind: :reminder}))

      assert {:error, {:unknown_fields, [:title]}} =
               Payload.encode(message("x", %{title: "Fermix"}))
    end
  end
end
