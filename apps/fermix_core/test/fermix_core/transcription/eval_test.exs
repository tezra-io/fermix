defmodule FermixCore.Transcription.EvalTest do
  # async: false — the available_backends/0 describe mutates global `:fermix_core`
  # Application env to establish a clean baseline (per CLAUDE.md's hermetic-config
  # pitfall), so this module must not run concurrently with config-reading tests.
  use ExUnit.Case, async: false

  import Bitwise, only: [&&&: 2]

  alias FermixCore.Transcription.Eval

  describe "fixtures/0 integrity" do
    test "every fixture resolves to a non-empty MP3 with lowercase keywords" do
      for fixture <- Eval.fixtures() do
        assert File.exists?(fixture.path), "missing fixture: #{fixture.path}"

        {:ok, %File.Stat{size: size}} = File.stat(fixture.path)
        assert size > 0, "empty fixture: #{fixture.path}"

        assert mp3_signature?(File.read!(fixture.path)),
               "not an MP3 (no ID3 tag / MPEG frame sync): #{fixture.path}"

        assert is_list(fixture.keywords) and fixture.keywords != []
        assert Enum.all?(fixture.keywords, &lowercase_binary?/1)
      end
    end
  end

  describe "grade/2" do
    test "full keyword match scores recall 1.0 and passes" do
      keywords = ~w(quick brown fox jumps lazy dog)
      graded = Eval.grade("The quick brown fox jumps over the lazy dog.", keywords)

      assert graded.recall == 1.0
      assert graded.pass?
      assert graded.matched == keywords
      assert graded.missing == []
    end

    test "one miss out of six clears the 0.8 threshold" do
      keywords = ~w(quick brown fox jumps lazy dog)
      graded = Eval.grade("The quick brown fox jumps over the lazy cat.", keywords)

      assert_in_delta graded.recall, 0.833, 0.001
      assert graded.pass?
      assert graded.missing == ["dog"]
    end

    test "two misses out of five falls below threshold and fails" do
      keywords = ~w(assistant runs computer data private)
      graded = Eval.grade("This assistant runs on my computer.", keywords)

      assert_in_delta graded.recall, 0.6, 0.001
      refute graded.pass?
      assert graded.missing == ["data", "private"]
    end

    test "empty transcript scores recall 0.0 and fails" do
      keywords = ~w(remind call dentist tomorrow morning)
      graded = Eval.grade("", keywords)

      assert graded.recall == 0.0
      refute graded.pass?
      assert graded.matched == []
      assert graded.missing == keywords
    end

    test "matching is case-insensitive" do
      graded = Eval.grade("QUICK the Brown FOX ran", ~w(quick brown fox))

      assert graded.recall == 1.0
      assert graded.pass?
    end

    test "punctuation in the transcript still matches" do
      graded = Eval.grade("...over the lazy dog.", ~w(lazy dog))

      assert graded.recall == 1.0
      assert graded.matched == ~w(lazy dog)
    end
  end

  describe "available_backends/0" do
    setup do
      # Establish the production baseline this test asserts on — no configured
      # transcription block, no provider keys — so a leaked env from an earlier
      # module can't make the list non-empty (CLAUDE.md hermetic-config pitfall).
      previous = %{
        transcription: Application.get_env(:fermix_core, :transcription),
        providers: Application.get_env(:fermix_core, :providers)
      }

      Application.put_env(:fermix_core, :transcription, [])
      Application.put_env(:fermix_core, :providers, [])

      on_exit(fn ->
        restore_env(:transcription, previous.transcription)
        restore_env(:providers, previous.providers)
      end)

      :ok
    end

    test "returns [] when no backend key resolves" do
      assert Eval.available_backends() == []
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore_env(key, value), do: Application.put_env(:fermix_core, key, value)

  # An MP3 begins with an "ID3" tag or an MPEG audio frame sync: 0xFF followed by
  # a byte whose top three bits are set (frame-sync 0b111).
  defp mp3_signature?(<<"ID3", _rest::binary>>), do: true
  defp mp3_signature?(<<0xFF, second, _rest::binary>>), do: (second &&& 0xE0) == 0xE0
  defp mp3_signature?(_bytes), do: false

  defp lowercase_binary?(value) do
    is_binary(value) and value == String.downcase(value) and value != ""
  end
end
