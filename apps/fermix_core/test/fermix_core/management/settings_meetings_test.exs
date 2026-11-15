defmodule FermixCore.Management.SettingsMeetingsTest do
  # The meetings section's rows are read from a snapshot handed in, and the
  # Always On server fact is a seam, so nothing here reads this machine or the
  # running engine's settings.
  use ExUnit.Case, async: true

  alias FermixCore.Management.Copy
  alias FermixCore.Management.Settings.Voice
  alias FermixCore.Meetings

  @snapshot %{fermix_core: [meetings: [enabled: true], transcription: []]}

  # M97 D24: after a move every app's Meetings pane shows the server's
  # section, and Google Meet is unavailable there, so the switch's own footer
  # says so, and what does work.
  test "on an Always On server the switch says Google Meet is unavailable there" do
    footer = enabled_footer(always_on_server: true)

    assert footer ==
             "Enable meeting notes for Google Meet and Zoom. " <>
               Meetings.meet_unavailable_sentence()

    assert Copy.violations(footer, :prose) == []
  end

  test "anywhere else the switch says what each lane needs, as before" do
    assert enabled_footer(always_on_server: false) ==
             "Enable meeting notes for Google Meet and Zoom. Google Meet needs the notetaker " <>
               "and browser installed; Zoom uses its RTMS credentials."
  end

  defp enabled_footer(opts) do
    "meetings"
    |> Voice.rows(@snapshot, opts)
    |> Enum.find(&(&1["key"] == "meetings_enabled"))
    |> Map.fetch!("footer")
  end
end
