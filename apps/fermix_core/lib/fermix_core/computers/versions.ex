defmodule FermixCore.Computers.Versions do
  @moduledoc """
  Where a computer stands against the server it reaches (M97 §3.4, D14: the
  server leads). The server updates on its own; a computer is a client with a
  window, counted in minor versions so a burst of patch releases never closes
  it (§17):

    * `:current`: the computer runs the server's major.minor;
    * `:behind`: the same major, up to #{2} minor versions behind: served as
      `:current` is, for chat, tool requests and history;
    * `:ahead`: newer than the server: it speaks the server's versions;
    * `:settings_only`: further behind, or on an older major: the computer
      keeps its link for settings alone and offers nothing until it updates,
      and its chat is refused. It never holds the server back.

  The patch is never compared. A computer's version that is not one (no
  engine ever says so) stands `:settings_only`: the window fails closed. The
  server's own version is this engine's, so one that is not a version raises.
  """

  @window_minors 2
  @standings [:current, :behind, :ahead, :settings_only]

  @type standing :: :current | :behind | :ahead | :settings_only

  @doc "How many minor versions behind the server a computer is still served."
  @spec window_minors() :: pos_integer()
  def window_minors, do: @window_minors

  @doc "Every standing, in the order the protocols list them."
  @spec standings() :: [standing()]
  def standings, do: @standings

  @doc """
  Where a computer running `computer` stands against a server running
  `server`, both engine versions (the moduledoc).
  """
  @spec standing(String.t(), String.t()) :: standing()
  def standing(computer, server) when is_binary(computer) and is_binary(server) do
    ours = key!(server)

    case key(computer) do
      {:ok, theirs} -> compare(theirs, ours)
      :error -> :settings_only
    end
  end

  @doc "Whether a computer that `standing` describes is served chat, requests and history."
  @spec served?(standing()) :: boolean()
  def served?(standing) when standing in @standings, do: standing != :settings_only

  defp compare(same, same), do: :current

  defp compare({major, minor}, {major, server_minor})
       when minor < server_minor and server_minor - minor <= @window_minors,
       do: :behind

  defp compare(theirs, ours) when theirs > ours, do: :ahead
  defp compare(_theirs, _ours), do: :settings_only

  defp key(text) do
    case Version.parse(text) do
      {:ok, %Version{major: major, minor: minor}} -> {:ok, {major, minor}}
      :error -> :error
    end
  end

  defp key!(server) do
    case key(server) do
      {:ok, key} -> key
      :error -> raise ArgumentError, "the server's version is not a version: #{inspect(server)}"
    end
  end
end
