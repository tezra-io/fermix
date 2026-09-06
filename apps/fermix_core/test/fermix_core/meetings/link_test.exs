defmodule FermixCore.Meetings.LinkTest do
  use ExUnit.Case, async: true

  alias FermixCore.Meetings.Link

  describe "Google Meet" do
    test "parses a canonical meeting URL" do
      assert {:ok, %{platform: :meet, meeting_id: "abc-defg-hij", passcode: nil}} =
               Link.parse("https://meet.google.com/abc-defg-hij")
    end

    test "accepts a scheme-less URL, a trailing slash, and a query string" do
      assert {:ok, %{meeting_id: "abc-defg-hij"}} = Link.parse("meet.google.com/abc-defg-hij")
      assert {:ok, %{meeting_id: "abc-defg-hij"}} = Link.parse("  meet.google.com/abc-defg-hij  ")

      assert {:ok, %{meeting_id: "abc-defg-hij"}} =
               Link.parse("https://meet.google.com/abc-defg-hij/")

      assert {:ok, %{meeting_id: "abc-defg-hij"}} =
               Link.parse("https://meet.google.com/abc-defg-hij?hs=122")
    end

    test "accepts both the four- and five-letter middle segment" do
      assert {:ok, %{meeting_id: "xyz-qrst-uvw"}} =
               Link.parse("https://meet.google.com/xyz-qrst-uvw")

      assert {:ok, %{meeting_id: "abc-defgh-hij"}} =
               Link.parse("https://meet.google.com/abc-defgh-hij")
    end

    test "refuses lookup links and anything that is not a meeting code" do
      assert {:error, :unrecognized_meeting_url} =
               Link.parse("https://meet.google.com/lookup/abcdefghij")

      assert {:error, :unrecognized_meeting_url} = Link.parse("https://meet.google.com/")
      assert {:error, :unrecognized_meeting_url} = Link.parse("https://meet.google.com/abc-def")

      assert {:error, :unrecognized_meeting_url} =
               Link.parse("https://meet.google.com/ABC-DEFG-HIJ")

      assert {:error, :unrecognized_meeting_url} =
               Link.parse("https://meet.google.com/abc-defghi-hij")
    end
  end

  describe "Zoom" do
    test "parses every join path shape" do
      assert {:ok, %{platform: :zoom, meeting_id: "123456789", passcode: nil}} =
               Link.parse("https://zoom.us/j/123456789")

      assert {:ok, %{meeting_id: "12345678901"}} = Link.parse("https://zoom.us/s/12345678901")
      assert {:ok, %{meeting_id: "123456789"}} = Link.parse("https://zoom.us/wc/123456789/join")
      assert {:ok, %{meeting_id: "123456789"}} = Link.parse("https://zoom.us/wc/join/123456789")
    end

    test "keeps company vanity subdomains" do
      assert {:ok, %{platform: :zoom, meeting_id: "123456789"}} =
               Link.parse("https://corp.zoom.us/j/123456789")
    end

    test "carries the pwd token through verbatim" do
      assert {:ok, %{passcode: "aBc123XyZ.1"}} =
               Link.parse("https://zoom.us/j/123456789?pwd=aBc123XyZ.1")

      assert {:ok, %{passcode: nil}} = Link.parse("https://zoom.us/j/123456789?pwd=")
      assert {:ok, %{passcode: nil}} = Link.parse("https://zoom.us/j/123456789?uname=ada")
    end

    test "bounds the meeting id to 9-11 digits" do
      assert {:error, :unrecognized_meeting_url} = Link.parse("https://zoom.us/j/12345678")
      assert {:error, :unrecognized_meeting_url} = Link.parse("https://zoom.us/j/123456789012")
      assert {:error, :unrecognized_meeting_url} = Link.parse("https://zoom.us/j/12345678a")
    end

    test "refuses non-join zoom paths" do
      assert {:error, :unrecognized_meeting_url} = Link.parse("https://zoom.us/my/adalovelace")
      assert {:error, :unrecognized_meeting_url} = Link.parse("https://zoom.us/")
    end
  end

  describe "everything else" do
    test "is refused rather than guessed" do
      assert {:error, :unrecognized_meeting_url} = Link.parse("https://teams.microsoft.com/l/x")
      assert {:error, :unrecognized_meeting_url} = Link.parse("https://notzoom.us/j/123456789")
      assert {:error, :unrecognized_meeting_url} = Link.parse("")
      assert {:error, :unrecognized_meeting_url} = Link.parse("not a url at all")
      assert {:error, :unrecognized_meeting_url} = Link.parse(:not_a_string)
    end

    test "refuses an oversize input without parsing it" do
      oversize = "https://meet.google.com/abc-defg-hij?x=" <> String.duplicate("y", 2_000)

      assert {:error, :unrecognized_meeting_url} = Link.parse(oversize)
    end
  end
end
