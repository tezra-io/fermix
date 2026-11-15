defmodule FermixCore.Computers.Offers.Files do
  @moduledoc """
  `files` (M97 §3.2): reading, writing, editing and searching files inside
  this computer's sandbox roots, on a Mac or a Linux computer. The one switch
  for files and commands decides it (`files_and_shell`,
  `Computers.Offers.switched/4`, M97 D27).

  On, it carries the folders files and commands reach on this computer
  (`roots`, `Computers.Facts`' roots as the wire can carry them,
  `Offers.wire_roots/1`; M97 §6.4, finding F5) and the folder a path's `~`
  stands for there (`home`, `Sandbox.PathPolicy.tilde_home/0`), so the
  server tells the model which folders it may use there (`Computers.Prompt`)
  and names them when a path outside them is refused (`Computers.Remote`),
  in the one sentence `reach/2` makes. Commands and files share them: the
  shell capability holds a command's folder to the same sandbox.

  The wire keeps each folder whole; the sentence says a folder in that
  computer's home from `~` (`~/Projects`), which every file and command tool
  resolves against that computer's own home when it runs there, so the
  account's name stays out of the prompt and the traces, and names the
  computer beside it so the `~` is never the server's. A folder outside the
  home, and every folder of a computer that sent no home, is said whole.
  """

  @behaviour FermixCore.Computers.Offer

  alias FermixCore.Computers.Offers

  @impl true
  def id, do: :files

  @impl true
  def label, do: "files"

  @impl true
  def systems, do: [:macos, :linux]

  @impl true
  def state(switches, %{os: os} = facts) when is_list(switches) do
    if os in systems(),
      do: with_roots(Offers.switched(switches, id(), facts, nil), facts),
      else: {:unavailable, Offers.no_system_sentence()}
  end

  defp with_roots({:on, detail}, %{roots: roots} = facts) do
    case Offers.wire_roots(roots) do
      [] -> {:on, detail}
      carried -> {:on, detail, with_home(%{roots: carried}, facts)}
    end
  end

  defp with_roots(state, _facts), do: state

  defp with_home(more, %{home: home}) do
    if Offers.wire_root?(home), do: Map.put(more, :home, home), else: more
  end

  @doc """
  The folders the files offer among `offers` names, while it is on: none
  where it is not on, or names none (a computer older than this rule).
  """
  @spec roots([Offers.offer()]) :: [String.t()]
  def roots(offers) when is_list(offers) do
    case Enum.find(offers, &(&1.id == "files" and &1.state == :on)) do
      %{roots: [_ | _] = roots} -> roots
      _none -> []
    end
  end

  @doc """
  What files and commands reach on the computer `name` whose offers are
  `offers`, in one sentence without its end (the moduledoc): "Files and shell
  on studio Mac reach only ~/Projects and /Volumes/Garden (~ is studio Mac's
  home)"; nil when its files offer names no folder.
  """
  @spec reach([Offers.offer()], String.t()) :: String.t() | nil
  def reach(offers, name) when is_list(offers) and is_binary(name) do
    case roots(offers) do
      [] -> nil
      roots -> said(Enum.map(roots, &from_home(&1, home(offers))), name)
    end
  end

  defp home(offers) do
    case Enum.find(offers, &(&1.id == "files")) do
      %{home: home} when is_binary(home) -> home
      _none -> nil
    end
  end

  defp from_home(root, nil), do: root
  defp from_home(home, home), do: "~"

  defp from_home(root, home) do
    prefix = home <> "/"

    if String.starts_with?(root, prefix),
      do: "~/" <> String.replace_prefix(root, prefix, ""),
      else: root
  end

  defp said(folders, name) do
    "Files and shell on #{name} reach only " <> listed(folders) <> tilde_note(folders, name)
  end

  defp tilde_note(folders, name) do
    if Enum.any?(folders, &String.starts_with?(&1, "~")), do: " (~ is #{name}'s home)", else: ""
  end

  defp listed([only]), do: only
  defp listed(roots), do: Enum.join(Enum.drop(roots, -1), ", ") <> " and " <> List.last(roots)
end
