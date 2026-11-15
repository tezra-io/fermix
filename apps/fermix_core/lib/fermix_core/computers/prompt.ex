defmodule FermixCore.Computers.Prompt do
  @moduledoc """
  The `## Computers` section of the owner's prompt (M97 §6.5), after
  `## This Fermix`: this server first, then each computer by name, its
  system, whether it is connected or when the home last heard it, and what
  it offers, and the folders its files and commands reach there with where
  any other is allowed (`Offers.Files.reach/2`, M97 §6.4, finding F5), so
  the model asks for a folder it may use or says plainly that the owner
  must allow it at that computer. Names, state, offers and those folders
  only: never an address or an id. A computer that is away is still listed
  with what it last offered, so the model says it is away rather than
  guess. Times are stated in the owner's zone (`FermixCore.Clock`). Pure.

      ## Computers
      - This server: Debian 13. Files, shell and a headless browser run here by default.
      - studio Mac (macOS, connected): files, shell (standard), browser, screen, Messages, history, Apple Maps. Files and shell on studio Mac reach only ~/.fermix/workspace and ~/Projects (~ is studio Mac's home); another folder is allowed only by someone at studio Mac.
      - loft Linux (Linux, last seen Sunday, November 8, 2026 at 10:14 PM EST): files, shell (strict), browser.
  """

  alias FermixCore.Clock
  alias FermixCore.Computers.Computer
  alias FermixCore.Computers.Offers.Files

  @systems %{macos: "macOS", linux: "Linux"}
  # The word each offer goes by in the section; an id this engine has no word
  # for is said as it came.
  @words %{
    "files" => "files",
    "shell" => "shell",
    "browser" => "browser",
    "computer_use" => "screen",
    "imessage" => "Messages",
    "history" => "history",
    "places" => "Apple Maps"
  }

  @doc """
  The section for this server's facts (`HostFacts`' map) and its
  `computers`; `opts` carries `:personalization`, the owner's zone, as
  `FermixCore.Clock` reads it.
  """
  @spec render(map(), [Computer.t()], keyword()) :: String.t()
  def render(host, computers, opts \\ []) when is_map(host) and is_list(computers) do
    lines = [server_line(host) | Enum.map(computers, &computer_line(&1, opts))]
    Enum.join(["## Computers" | lines], "\n")
  end

  defp server_line(%{os_version: version}) when is_binary(version),
    do: "- This server: #{version}. Files, shell and a headless browser run here by default."

  defp server_line(_host),
    do: "- This server. Files, shell and a headless browser run here by default."

  defp computer_line(%Computer{} = computer, opts),
    do:
      "- #{computer.name} (#{state(computer, opts)}): #{offered(computer.offers)}." <>
        reach(Files.reach(computer.offers, computer.name), computer.name)

  defp reach(nil, _name), do: ""
  defp reach(reach, name), do: " #{reach}; another folder is allowed only by someone at #{name}."

  defp state(computer, opts),
    do: Enum.join(Enum.reject([system(computer.platform), seen(computer, opts)], &is_nil/1), ", ")

  defp system(platform), do: Map.get(@systems, platform)

  defp seen(%Computer{connected: true}, _opts), do: "connected"
  defp seen(%Computer{last_seen: nil}, _opts), do: "not connected yet"

  defp seen(%Computer{last_seen: %DateTime{} = at}, opts),
    do: "away, last seen #{Clock.stated_instant(at, opts)}"

  defp offered(offers) do
    case for(%{state: :on} = offer <- offers, do: word(offer)) do
      [] -> "offers nothing"
      words -> Enum.join(words, ", ")
    end
  end

  defp word(%{id: "shell", detail: mode}) when is_binary(mode), do: "shell (#{mode})"

  # The screen's access level follows the computer's sandbox mode; strict is
  # look only (M97 §6.4).
  defp word(%{id: "computer_use", detail: "strict"}), do: "screen (look only)"
  defp word(%{id: id}), do: Map.get(@words, id, String.replace(id, "_", " "))
end
