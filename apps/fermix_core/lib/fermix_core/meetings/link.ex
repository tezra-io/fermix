defmodule FermixCore.Meetings.Link do
  @moduledoc """
  Parses a meeting URL into its capture lane and identifiers.

  Pure and total. Google Meet and Zoom are separate lanes with no fallback
  between them, so a URL this module cannot place with certainty is refused
  (`:unrecognized_meeting_url`) rather than routed somewhere plausible — a
  guessed platform would send the wrong bot at the wrong meeting.

  A Zoom `pwd` query parameter is carried through opaquely. It is Zoom's own
  tokenized value, not the human passcode, and RTMS never needs it; it is kept
  for meeting metadata only.
  """

  @max_url_bytes 2_000
  @meet_host "meet.google.com"
  @meet_code ~r/^[a-z]{3}-[a-z]{4,5}-[a-z]{3}$/
  @zoom_meeting_id ~r/^\d{9,11}$/
  @scheme ~r{^[a-zA-Z][a-zA-Z0-9+.\-]*://}

  @type parsed :: %{
          platform: :meet | :zoom,
          meeting_id: String.t(),
          passcode: String.t() | nil
        }

  @doc """
  Parses `url` into `%{platform, meeting_id, passcode}`.

  Accepts a scheme-less URL (`meet.google.com/abc-defg-hij`); the host is
  compared case-insensitively, the path is not rewritten.
  """
  @spec parse(String.t()) :: {:ok, parsed()} | {:error, :unrecognized_meeting_url}
  def parse(url) when is_binary(url) and byte_size(url) <= @max_url_bytes do
    url
    |> normalize()
    |> URI.parse()
    |> from_uri()
  end

  def parse(_url), do: {:error, :unrecognized_meeting_url}

  defp normalize(url) do
    trimmed = String.trim(url)

    if Regex.match?(@scheme, trimmed), do: trimmed, else: "https://" <> trimmed
  end

  defp from_uri(%URI{host: host, path: path, query: query}) when is_binary(host) do
    route(String.downcase(host), segments(path), query)
  end

  defp from_uri(_uri), do: {:error, :unrecognized_meeting_url}

  defp route(@meet_host, [code | _rest], _query), do: meet(code)

  defp route(host, segments, query) do
    if zoom_host?(host),
      do: zoom(segments, query),
      else: {:error, :unrecognized_meeting_url}
  end

  defp meet(code) do
    if Regex.match?(@meet_code, code) do
      {:ok, %{platform: :meet, meeting_id: code, passcode: nil}}
    else
      {:error, :unrecognized_meeting_url}
    end
  end

  defp zoom_host?("zoom.us"), do: true
  defp zoom_host?(host), do: String.ends_with?(host, ".zoom.us")

  defp zoom(["j", id], query), do: zoom_meeting(id, query)
  defp zoom(["s", id], query), do: zoom_meeting(id, query)
  defp zoom(["wc", "join", id], query), do: zoom_meeting(id, query)
  defp zoom(["wc", id, "join"], query), do: zoom_meeting(id, query)
  defp zoom(_segments, _query), do: {:error, :unrecognized_meeting_url}

  defp zoom_meeting(id, query) do
    if Regex.match?(@zoom_meeting_id, id) do
      {:ok, %{platform: :zoom, meeting_id: id, passcode: passcode(query)}}
    else
      {:error, :unrecognized_meeting_url}
    end
  end

  defp passcode(nil), do: nil

  defp passcode(query) do
    case query |> URI.decode_query() |> Map.get("pwd") do
      value when is_binary(value) and value != "" -> value
      _absent -> nil
    end
  end

  defp segments(nil), do: []
  defp segments(path), do: path |> String.split("/") |> Enum.reject(&(&1 == ""))
end
