defmodule FermixCore.Clock do
  @moduledoc """
  The owner's clock: the one place Fermix resolves the owner's time zone and
  states a time.

  Instants are stored in UTC everywhere. Everything a model or the owner is
  shown is stated here, in the owner's zone (`[fermix_core.personalization]
  timezone`), so "today", the day a thing was said and the time a run happens
  are always read off one clock and never need converting between two.

  Two questions, two functions:

    * `zone/1` serves code that interprets the owner's wall-clock words ("by
      Friday", "at 9"). Without a usable zone those words mean nothing, so a
      missing or unknown zone is an error the caller returns.
    * `shown_zone/1` serves code that states an instant. It is the owner's zone,
      or UTC when none is configured or the configured name is not one the time
      zone database knows. `display_zone/1` says which, so a surface that falls
      to UTC says so rather than presenting UTC as local time.

  Pure apart from reading application env: callers pass the instant, so a test
  pins the clock by passing a fixed `DateTime`.
  """

  @utc "Etc/UTC"

  @type zone_error :: :timezone_not_configured | {:invalid_timezone, term()}

  @doc """
  The owner's zone for interpreting their wall-clock words.

  `opts` may carry `:personalization` (a keyword list) in place of the
  application env, the seam the registries already accept.
  """
  @spec zone(keyword()) :: {:ok, String.t()} | {:error, zone_error()}
  def zone(opts \\ []) when is_list(opts) do
    case configured(opts) do
      zone when is_binary(zone) and zone != "" -> validate_zone(zone)
      nil -> {:error, :timezone_not_configured}
      "" -> {:error, :timezone_not_configured}
      other -> {:error, {:invalid_timezone, other}}
    end
  end

  @doc """
  The zone instants are stated in, and why: `{:ok, zone}` for the owner's zone,
  `{:utc, reason}` when it is missing or unusable and UTC is shown instead.
  """
  @spec display_zone(keyword()) :: {:ok, String.t()} | {:utc, zone_error()}
  def display_zone(opts \\ []) when is_list(opts) do
    case zone(opts) do
      {:ok, zone} -> {:ok, zone}
      {:error, reason} -> {:utc, reason}
    end
  end

  @doc "The zone name instants are stated in: the owner's, or `\"Etc/UTC\"`."
  @spec shown_zone(keyword()) :: String.t()
  def shown_zone(opts \\ []) when is_list(opts) do
    case display_zone(opts) do
      {:ok, zone} -> zone
      {:utc, _reason} -> @utc
    end
  end

  @doc """
  Whether the time zone database knows `zone`. A name it does not know fails
  here rather than silently becoming UTC.
  """
  @spec validate_zone(term()) :: {:ok, String.t()} | {:error, {:invalid_timezone, term()}}
  def validate_zone(zone) when is_binary(zone) and zone != "" do
    case DateTime.shift_zone(DateTime.utc_now(), zone) do
      {:ok, _shifted} -> {:ok, zone}
      {:error, _reason} -> {:error, {:invalid_timezone, zone}}
    end
  end

  def validate_zone(other), do: {:error, {:invalid_timezone, other}}

  @doc ~S|The local day of `at`: `"Saturday, October 24, 2026"`.|
  @spec stated_day(DateTime.t(), keyword()) :: String.t()
  def stated_day(%DateTime{} = at, opts \\ []) when is_list(opts) do
    at |> local(opts) |> Calendar.strftime("%A, %B %-d, %Y")
  end

  @doc ~S|The local day and time of `at`: `"Saturday, October 24, 2026 at 8:17 PM EDT"`.|
  @spec stated_instant(DateTime.t(), keyword()) :: String.t()
  def stated_instant(%DateTime{} = at, opts \\ []) when is_list(opts) do
    at |> local(opts) |> Calendar.strftime("%A, %B %-d, %Y at %-I:%M %p %Z")
  end

  @doc ~S|The local time of day of `at`, with the zone: `"8:17 PM EDT"`.|
  @spec stated_time(DateTime.t(), keyword()) :: String.t()
  def stated_time(%DateTime{} = at, opts \\ []) when is_list(opts) do
    at |> local(opts) |> Calendar.strftime("%-I:%M %p %Z")
  end

  @doc ~S|`at` as ISO 8601 with the owner's offset: `"2026-10-24T20:17:02-04:00"`.|
  @spec iso(DateTime.t(), keyword()) :: String.t()
  def iso(%DateTime{} = at, opts \\ []) when is_list(opts) do
    at |> local(opts) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  @doc ~S|The owner's offset from UTC at `at`: `"UTC-04:00"`, or `"UTC+00:00"` in UTC.|
  @spec utc_offset(DateTime.t(), keyword()) :: String.t()
  def utc_offset(%DateTime{} = at, opts \\ []) when is_list(opts) do
    local = local(at, opts)
    total = div(local.utc_offset + local.std_offset, 60)
    sign = if total < 0, do: "-", else: "+"
    hours = total |> abs() |> div(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    minutes = total |> abs() |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    "UTC" <> sign <> hours <> ":" <> minutes
  end

  @doc """
  The line that tells a run the current time to the minute, for runs that
  reason about time left. It belongs in a run's own message, never in a note
  ahead of conversation history, where a minute would change every request.
  """
  @spec now_line(DateTime.t(), keyword()) :: String.t()
  def now_line(%DateTime{} = now, opts \\ []) when is_list(opts) do
    "Now: " <> stated_instant(now, opts) <> "."
  end

  defp local(at, opts), do: DateTime.shift_zone!(at, shown_zone(opts))

  defp configured(opts) do
    opts
    |> Keyword.get_lazy(:personalization, fn ->
      Application.get_env(:fermix_core, :personalization, [])
    end)
    |> Keyword.get(:timezone)
  end
end
