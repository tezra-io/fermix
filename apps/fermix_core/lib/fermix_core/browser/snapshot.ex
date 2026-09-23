defmodule FermixCore.Browser.Snapshot do
  @moduledoc false

  @interactive_roles MapSet.new(~w(button link textbox checkbox radio combobox listbox option
                                   searchbox slider spinbutton switch tab treeitem menuitem))
  @content_roles MapSet.new(~w(heading cell gridcell columnheader rowheader listitem article
                               region main navigation text StaticText paragraph))
  @structural_roles MapSet.new(~w(generic group list table row rowgroup grid document
                                  RootWebArea WebArea none presentation))

  # Marks a ref in the text (`@link_3 [link] "Search"`); it is not part of the ref.
  @ref_sigil "@"

  @spec render([map()], map()) :: {:ok, map()}
  def render(nodes, opts) when is_list(nodes) and is_map(opts) do
    index = Map.new(nodes, &{to_string(Map.get(&1, "nodeId")), &1})
    roots = root_nodes(nodes)
    state = %{counts: %{}, lines: []}

    rendered =
      Enum.reduce(roots, state, fn node, acc ->
        render_node(node, index, opts, 0, acc)
      end)

    lines = Enum.reverse(rendered.lines)
    {kept, truncated?} = take_lines(lines, Map.fetch!(opts, :max_chars))
    inner = Enum.map_join(kept, "\n", & &1.text)
    refs = kept |> Enum.map(& &1.ref) |> Enum.reject(&is_nil/1)
    {:ok, %{text: boundary(inner), refs: refs, truncated: truncated?}}
  end

  # Depth is counted in EMITTED nodes, not raw tree levels: a transparent
  # wrapper (a compact-skipped structural div, or a node filtered out by
  # interactive mode) does not consume the depth budget. Otherwise the chain of
  # wrapper <div>s around a real form pushes its inputs past the depth cap, so
  # login textboxes never emit a line or get a ref. The cap still bounds how
  # deep MEANINGFUL structure is reported.
  defp render_node(node, index, opts, depth, state) do
    if depth >= Map.fetch!(opts, :depth) do
      state
    else
      {emitted?, state} = maybe_add_line(node, opts, depth, state)
      child_depth = if emitted?, do: depth + 1, else: depth

      node
      |> Map.get("childIds", [])
      |> Enum.take(Map.fetch!(opts, :max_children))
      |> render_children(index, opts, child_depth, state)
    end
  end

  defp render_children(child_ids, index, opts, depth, state) do
    Enum.reduce(child_ids, state, fn id, acc ->
      render_child(Map.fetch(index, to_string(id)), index, opts, depth, acc)
    end)
  end

  defp render_child({:ok, child}, index, opts, depth, state) do
    render_node(child, index, opts, depth, state)
  end

  defp render_child(:error, _index, _opts, _depth, state), do: state

  defp maybe_add_line(node, opts, depth, state) do
    role = role(node)

    cond do
      compact_skip?(node, opts) ->
        {false, state}

      Map.get(opts, :interactive) and not important?(node, role) ->
        {false, state}

      true ->
        {true, add_line(node, role, depth, opts, state)}
    end
  end

  # A line carries its own ref, so truncation keeps or drops both together.
  defp add_line(node, role, depth, opts, state) do
    {prefix, ref, state} = ref_prefix(node, role, state)

    line =
      "#{String.duplicate("  ", depth)}#{prefix}[#{role}]#{name_part(node)}#{url_part(node, opts)}"

    %{state | lines: [%{text: line, ref: ref} | state.lines]}
  end

  defp ref_prefix(node, role, state) do
    if actionable?(node, role) and Map.has_key?(node, "backendDOMNodeId") do
      count = Map.get(state.counts, role, 0) + 1
      name = "#{role}_#{count}"
      ref = %{ref: name, role: role, name: name(node), backend_node_id: node["backendDOMNodeId"]}

      {"#{@ref_sigil}#{name} ", ref, %{state | counts: Map.put(state.counts, role, count)}}
    else
      {"", nil, state}
    end
  end

  @doc """
  The ref-map key for a ref a model sends back. A model copies the ref as the text
  prints it, sigil included, so the sigil comes off here; a bare ref is the key.
  """
  @spec ref_key(String.t()) :: String.t()
  def ref_key(@ref_sigil <> ref), do: ref
  def ref_key(ref) when is_binary(ref), do: ref

  defp compact_skip?(node, opts) do
    Map.get(opts, :compact) and role(node) in @structural_roles and name(node) == ""
  end

  defp important?(node, role), do: actionable?(node, role) or MapSet.member?(@content_roles, role)

  # Actionable = a known interactive role OR an editable/settable form field.
  # The property check catches inputs that surface with a non-textbox role
  # (e.g. password fields, contenteditable) so they still get a usable ref.
  defp actionable?(node, role), do: interactable?(role) or editable?(node)
  defp interactable?(role), do: MapSet.member?(@interactive_roles, role)

  defp editable?(node) do
    not is_nil(property(node, "editable")) or property(node, "settable") == "true"
  end

  defp root_nodes(nodes) do
    child_ids = nodes |> Enum.flat_map(&Map.get(&1, "childIds", [])) |> MapSet.new(&to_string/1)
    roots = Enum.reject(nodes, &MapSet.member?(child_ids, to_string(Map.get(&1, "nodeId"))))
    if roots == [], do: Enum.take(nodes, 1), else: roots
  end

  defp role(node), do: ax_value(Map.get(node, "role")) || "unknown"
  defp name(node), do: ax_value(Map.get(node, "name")) || ""

  defp name_part(node) do
    case name(node) do
      "" -> ""
      value -> " #{inspect(value)}"
    end
  end

  defp url_part(node, %{include_urls: true}) do
    node
    |> property("url")
    |> case do
      nil -> ""
      url -> " url=#{inspect(url)}"
    end
  end

  defp url_part(_node, _opts), do: ""

  defp property(node, name) do
    node
    |> Map.get("properties", [])
    |> Enum.find(&(Map.get(&1, "name") == name))
    |> case do
      nil -> nil
      property -> ax_value(Map.get(property, "value"))
    end
  end

  defp ax_value(%{"value" => value}) when is_binary(value), do: String.trim(value)
  defp ax_value(%{"value" => value}), do: to_string(value)
  defp ax_value(_value), do: nil

  @doc """
  Wrap page-controlled text in the delimiters that mark it as content the model
  reads as data, never as instructions.

  Public because `webmcp` results are page bytes too and must carry the same
  marking — one boundary literal, not two.
  """
  @spec boundary(String.t()) :: String.t()
  def boundary(text) when is_binary(text),
    do: "<browser_page_content>\n#{neutralize_delimiters(text)}\n</browser_page_content>"

  # Defang a delimiter the PAGE itself carries, so page text cannot close the
  # block early and have the rest of itself read outside the marking. Same shape
  # as `Capabilities.UntrustedContent.neutralize_delimiters/1` — a space after
  # the angle bracket keeps the text readable while leaving the appended tag as
  # the only real one. Case-insensitive because the attacker picks the spelling.
  defp neutralize_delimiters(text) do
    text
    |> String.replace(~r{</browser_page_content}i, "</ browser_page_content")
    |> String.replace(~r{<browser_page_content}i, "< browser_page_content")
  end

  # Truncate by WHOLE LINES, which is what makes the text and the ref map one
  # boundary: a ref is returned only when the line that shows it survived, so
  # acting on a control the model never saw yields the stale_ref sentence instead
  # of a click on something invisible. Counted in graphemes (never bytes) so the
  # result is always valid UTF-8 — a byte-offset cut can split a codepoint and
  # make Jason.encode! raise. The boundary markers are wrapped afterwards so the
  # closing tag is always kept.
  defp take_lines(lines, max_chars) when is_integer(max_chars) and max_chars > 0 do
    {kept, _used} =
      Enum.reduce_while(lines, {[], 0}, fn line, {kept, used} ->
        next = used + String.length(line.text) + separator(kept)
        if next <= max_chars, do: {:cont, {[line | kept], next}}, else: {:halt, {kept, used}}
      end)

    kept = Enum.reverse(kept)
    {bounded_lines(kept, lines, max_chars), length(kept) < length(lines)}
  end

  defp separator([]), do: 0
  defp separator(_kept), do: 1

  # An accessible NAME is page-controlled and can be longer than the whole budget
  # on its own, which would leave an empty snapshot that reads as "this page has
  # nothing on it". Keep a head of that one line, and NOT its ref: the line the
  # model sees is incomplete, so nothing on it is actionable.
  defp bounded_lines([], [first | _rest], max_chars),
    do: [%{text: String.slice(first.text, 0, max_chars), ref: nil}]

  defp bounded_lines(kept, _lines, _max_chars), do: kept
end
