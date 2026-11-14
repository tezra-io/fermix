defmodule FermixCore.Management.ComputerSettings do
  @moduledoc """
  This computer's own settings after a move, and the server's machine
  settings beside them (M97 §19, D28 and D28a).

  On a linked computer, Settings is the server's, every pane, and what
  belongs to this computer alone is published under the ids
  `Management.Placement`'s rule makes this computer's: `computer` (what
  Fermix on the server may use here) as it is, and each machine section this
  computer has as `computer.<id>`, under the `always_on` pane every app
  already draws, titled for this machine ("Sandbox on this Mac"). Each is
  answered by the plain section's own code here (`plain/2`), and its answer
  carries the prefix again (`own_view/3`, `own_result/2`): its id, and the key
  of each secret row (`computer.env:LEDGER_TOKEN`), so the `secret.set` a row
  sends comes back to this computer. A Linux computer publishes no
  `computer.computer_history` before its recorder exists (§19.2), and none
  publishes `harness_machine`: its own approval is the Coding agents switch
  in `computer` (M98 D4). Nor does any publish `computer.accessories`:
  StackChan is not part of Always On (the owner's decision), so while the
  home is on a server a request for it is refused in the words the StackChan
  screens say (`Management.Accessories.not_here_sentence/1`), and the
  machine file keeps the robot's setting as it is for a move back.

  The server's list (`server_sections/2`) keeps what
  `Placement.listed_from_server?/2` lists: never a `computer` or
  `computer.<id>` it names (a server never publishes one, and one that does
  is not believed), nor its own screen, history or accessories, which are
  that machine's alone; its sandbox and coding approval where the server says
  it applies the rule, and its browser either way, as a server without the
  rule serves it as the home's. Its machine sections are titled with its name
  ("Sandbox on garden server", "garden server" in the coding pane).

  Pure: the callers pass the inventories, the host (`macos?:`) and the
  server as the link knows it.
  """

  alias FermixCore.Management.Accessories
  alias FermixCore.Management.Placement
  alias FermixCore.Management.Settings.ThisComputer

  @pane "always_on"
  # This Mac's order (§19.5): what the server may use here, then this
  # machine's own limits and devices.
  @order ~w(computer sandbox browser computer_use computer_history)
  # Linux has no screen recorder before stage 4 (§19.2), and its app hides
  # the plain id by name, never the new one.
  @mac_only ~w(computer_history)
  # StackChan, which a computer whose home is on a server never runs.
  @accessories "computer.accessories"

  @typedoc "A section as `settings.sections` lists it."
  @type row :: %{String.t() => String.t()}
  @typedoc "The server as this computer's link knows it."
  @type server :: %{name: String.t() | nil, machine_settings: boolean()}

  @doc """
  Whether this engine has a This computer area: a linked computer where
  Always On is offered (`Settings.ThisComputer`; `computer?:` for a test).
  """
  @spec area?(keyword()) :: boolean()
  def area?(opts) when is_list(opts), do: ThisComputer.sections(opts) != []

  @doc """
  This computer's own sections, from this engine's inventory `rows` (as the
  wire lists them), in This Mac's order: `computer`, then each machine
  section it has as `computer.<id>` (its sandbox, browser, screen, history;
  never its StackChan); none where it has no This computer area.
  """
  @spec own_sections([row()], keyword()) :: [row()]
  def own_sections(rows, opts) when is_list(rows) and is_list(opts) do
    if area?(opts) do
      machine = machine(opts)

      rows
      |> Enum.filter(&own?(&1["id"], opts))
      |> Enum.sort_by(&Enum.find_index(@order, fn id -> id == &1["id"] end))
      |> Enum.map(&own_row(&1, machine))
    else
      []
    end
  end

  @doc """
  The plain section a requested `section` names on this engine: itself for a
  plain id or `computer`, the section `computer.<id>` names where this
  computer publishes it, `{:refused, sentence}` for its StackChan where it
  has a This computer area, or `:none`.
  """
  @spec plain(String.t(), keyword()) :: {:ok, String.t()} | {:refused, String.t()} | :none
  def plain("computer" = section, _opts), do: {:ok, section}

  def plain(section, opts) when is_binary(section) and is_list(opts) do
    cond do
      not Placement.computer_id?(section) ->
        {:ok, section}

      area?(opts) and section == @accessories ->
        {:refused, Accessories.not_here_sentence(if(macos?(opts), do: :device, else: :not_mac))}

      area?(opts) and own_machine?(Placement.plain_id(section), opts) ->
        {:ok, Placement.plain_id(section)}

      true ->
        :none
    end
  end

  @doc """
  The sandbox value a requested secret `id` names on this engine: itself for
  a plain id, `env:<NAME>` for this computer's `computer.env:<NAME>` where it
  has a This computer area, or `:none` (this computer stores no other secret
  of its own).
  """
  @spec plain_secret(String.t(), keyword()) :: {:ok, String.t()} | :none
  def plain_secret(id, opts) when is_binary(id) and is_list(opts) do
    cond do
      not Placement.computer_id?(id) -> {:ok, id}
      area?(opts) and String.starts_with?(id, "computer.env:") -> {:ok, Placement.plain_id(id)}
      true -> :none
    end
  end

  @doc """
  A `settings.get` answer for `section` as this computer publishes it: a
  plain section's view as it is, and for `computer.<id>` its id, its title
  for this machine and each secret row's key prefixed.
  """
  @spec own_view(map(), String.t(), keyword()) :: map()
  def own_view(view, "computer", _opts) when is_map(view), do: view

  def own_view(view, section, opts) when is_map(view) and is_binary(section) do
    if Placement.computer_id?(section), do: prefixed_view(view, section, opts), else: view
  end

  defp prefixed_view(%{"id" => plain, "title" => title, "rows" => rows} = view, section, opts) do
    if Placement.computer_id(plain) != section,
      do: raise(ArgumentError, "a view of #{plain} is no answer for #{section}")

    %{
      view
      | "id" => section,
        "title" => own_title(title, machine(opts)),
        "rows" => Enum.map(rows, &own_row_key/1)
    }
  end

  @doc """
  A route result for this computer's `id` answered under its plain id: the
  plain id becomes `id` again wherever the answer or its refusal names it
  (`id`, `section`, `field`), and a refusal's `section` is always this
  computer's (`computer.sandbox` for a sandbox value's outside edit), so a
  surface that sends it back reaches this computer.
  """
  @spec own_result(term(), String.t()) :: term()
  def own_result(result, id) when is_binary(id) do
    case Placement.computer_id?(id) do
      true -> renamed(result, Placement.plain_id(id), id)
      false -> result
    end
  end

  defp renamed({:ok, %{} = answer}, plain, id), do: {:ok, rename(answer, plain, id)}

  defp renamed({:error, code, %{} = details}, plain, id),
    do: {:error, code, details |> rename(plain, id) |> own_section()}

  defp renamed(result, _plain, _id), do: result

  # A refusal of this computer's own write is about this computer's files,
  # whatever section it names, so a reload of that section is this computer's.
  defp own_section(%{"section" => section} = details) when is_binary(section) and section != "",
    do: %{details | "section" => own_id(section)}

  defp own_section(details), do: details

  defp own_id(section) do
    if Placement.computer_id?(section), do: section, else: Placement.computer_id(section)
  end

  defp rename(map, plain, id) do
    Enum.reduce(~w(id section field), map, fn key, acc ->
      if Map.get(acc, key) == plain, do: Map.put(acc, key, id), else: acc
    end)
  end

  @doc """
  The server's sections as this computer lists them (`server`, as its link
  knows it), those `Placement.listed_from_server?/2` lists, its machine
  sections titled with its name.
  """
  @spec server_sections([row()], server()) :: [row()]
  def server_sections(rows, %{machine_settings: takes?} = server)
      when is_list(rows) and is_boolean(takes?) do
    for %{"id" => id} = row <- rows,
        Placement.listed_from_server?(id, takes?),
        do: server_row(row, server)
  end

  @doc """
  The title this computer shows for the server's section `id` titled
  `title` by the server: a machine section's names the server.
  """
  @spec server_title(String.t(), String.t(), String.t() | nil) :: String.t()
  def server_title("harness_machine", _title, name), do: server_name(name)

  def server_title(id, title, name) when is_binary(title) do
    if Placement.machine_section?(id), do: "#{title} on #{server_name(name)}", else: title
  end

  defp server_row(%{"id" => id, "title" => title} = row, %{name: name}),
    do: %{row | "title" => server_title(id, title, name)}

  defp server_name(name) when is_binary(name) and name != "", do: name
  defp server_name(_name), do: "your server"

  # What this computer publishes for itself: `computer` as it is, and each
  # machine section it has as `computer.<id>`.
  defp own?("computer", _opts), do: true
  defp own?(id, opts), do: own_machine?(id, opts)

  # A machine section this computer publishes as `computer.<id>`: never the
  # coding approval nor StackChan, and its history only on a Mac.
  defp own_machine?(id, opts) do
    Placement.machine_section?(id) and id not in ["harness_machine", "accessories"] and
      (macos?(opts) or id not in @mac_only)
  end

  defp own_row(%{"id" => "computer"} = row, _machine), do: row

  defp own_row(%{"id" => id, "title" => title}, machine),
    do: %{
      "id" => Placement.computer_id(id),
      "pane" => @pane,
      "title" => own_title(title, machine)
    }

  defp own_title(title, machine), do: "#{title} on this #{machine}"

  defp own_row_key(%{"kind" => "secret", "key" => key} = row),
    do: %{row | "key" => Placement.computer_id(key)}

  defp own_row_key(row), do: row

  defp machine(opts), do: if(macos?(opts), do: "Mac", else: "computer")

  defp macos?(opts),
    do: Keyword.get_lazy(opts, :macos?, fn -> :os.type() == {:unix, :darwin} end)
end
