defmodule FermixCore.ComputerUse.Controls do
  @moduledoc """
  What the model reads about controls (M86 P2, protocol 12): an `elements`
  listing, a control read back after an action, the dialogs and menus an action
  left open, and a wait on the accessibility tree. Section numbers (§) are
  compux `PROTOCOL.md`'s.

  **Pure.** A reply in, text out: no process, no I/O. The session decides which
  of these a reply needs; this module only renders.

  **Application text is untrusted.** Labels, values, paths, roles and surface
  names are whatever the application chose to call things, and a listing's SHAPE
  is what the model reads targets off: one line per control, each opening with
  its reference. A newline inside a label would forge a second line, carrying a
  reference the helper never minted, so every such string goes through
  `safe_text/1` before it is rendered. The helper does the same at the source;
  this side does not depend on that, because the half that renders is the half
  that has to be safe.

  **Nothing is synthesised.** A control the helper gave no point has none here
  (protocol 12 makes bounds optional), a state the helper did not read is not
  described as either, and a secure field's value is never shown even if a reply
  carried one.
  """

  # The helper's own element cap, applied again here: a misbehaving or mismatched
  # helper that answered with thousands would otherwise flood the turn's context
  # with a list nothing bounded on the way in.
  @max_elements 250

  # Two kinds of open surface a model can act on are plenty to name; more is a
  # helper that misread the tree, and it gets the same bound as everything else.
  @max_surfaces 8

  # The verbs a control may list (PROTOCOL.md §6.3). A word outside this set is
  # not one any action can carry, so it is never shown as one.
  @verbs ~w(press set_value type focus select toggle expand collapse scroll_to)

  # The words a state-reading verb reports its control in (§4), closed.
  @states ~w(on off expanded collapsed selected unselected focused unfocused)

  # Each surface kind (§6.2) and the `elements` scope that lists it (§2.1): a
  # popover is a child of its window, which neither the menu nor the dialog
  # scope reads.
  @surface_scopes %{
    "dialog" => "dialog",
    "alert" => "dialog",
    "menu" => "menu",
    "popup" => "window"
  }

  @untrusted_text_max 120
  @helper_sentence_max 600

  @doc "The verbs a control may list, in the contract's order."
  @spec verbs() :: [String.t()]
  def verbs, do: @verbs

  @doc """
  An `elements` reply as the model reads it: a lead naming the list, then one
  line per control. `request` is the request that asked for it, which says
  whether an empty answer is an empty scope or a query that matched nothing.
  """
  @spec listing(map(), map()) :: String.t()
  def listing(%{"elements" => elements} = reply, request)
      when is_list(elements) and is_map(request) do
    case usable(elements) do
      [] ->
        empty_lead(reply) <> empty_listing(request) <> truncated_note(reply)

      usable ->
        listing_lead(reply, length(usable)) <>
          "\n" <>
          Enum.map_join(usable, "\n", &line/1) <> skeleton_note(reply) <> truncated_note(reply)
    end
  end

  @doc """
  The control an action named, as the helper read it back afterwards: its
  state, never a picture of it, and never proof the action had its effect.
  """
  @spec element_after(map() | nil) :: String.t()
  def element_after(%{"present" => true} = element) do
    named = Enum.reject([role(element), quoted(element["label"])], &(&1 == ""))

    rest =
      Enum.reject([enabled_word(element), value_word(element) | states(element)], &(&1 == ""))

    " The control now reads: " <> Enum.join([Enum.join(named, " ") | rest], ", ") <> "."
  end

  # A control that no longer answers, which is the most informative thing this
  # check has to say: a dialog that closed, a row that went away, a window rebuilt
  # under the reference. Evidence, not proof — the tree says it is gone, not that
  # this action removed it — so the next move is to look, not to press again.
  def element_after(%{"present" => false}) do
    " The control this action named no longer answers, so it is gone from the accessibility " <>
      "tree — often because the action worked and dismissed it, and sometimes because the " <>
      "window was rebuilt underneath it. Take `elements` or a `screenshot` to see what is " <>
      "there now; do not press it again."
  end

  def element_after(_absent_or_malformed), do: ""

  @doc """
  The dialogs, alerts, menus and popups open once the action ran (§3.2), by
  kind and label. A surface carries no reference, so the text names the scope
  an `elements` listing reads it with. Absent means the helper did not look,
  and `[]` means nothing is open: both say nothing here, because neither is a
  thing the model has to act on.
  """
  @spec surfaces([map()] | nil) :: String.t()
  def surfaces(surfaces) when is_list(surfaces) do
    named = surfaces |> Enum.map(&surface/1) |> Enum.reject(&is_nil/1) |> Enum.take(@max_surfaces)

    if named == [] do
      ""
    else
      " Open after this action: " <>
        Enum.map_join(named, ", ", &elem(&1, 0)) <> "." <> surfaces_hint(named)
    end
  end

  def surfaces(_absent), do: ""

  @doc """
  What a state-reading verb found (§4): the state before and after it, or that
  the control already held what was asked, so nothing was sent.
  """
  @spec state_change(map()) :: String.t()
  def state_change(%{already: true, state_after: state}) when state in @states,
    do: " It already read #{state}, so nothing was sent."

  def state_change(%{already: true}), do: " It already held that state, so nothing was sent."

  def state_change(%{state_before: before, state_after: after_})
      when before in @states and after_ in @states and before != after_,
      do: " It went from #{before} to #{after_}."

  # Readable, and unchanged: the verb went out and the control did not move. The
  # model needs this before it builds on the state, and it must not read as a
  # reason to send the same verb again.
  def state_change(%{effect: :not_observed, state_after: state}) when state in @states do
    " It still reads #{state}: this did not change it. Do not send it again; take `elements` " <>
      "to see why, or reach the control another way."
  end

  def state_change(%{effect: :unknown}) do
    " Its state could not be read back afterwards, so whether it changed is unknown — take " <>
      "`elements` before acting on it again."
  end

  def state_change(_receipt), do: ""

  @doc """
  The condition an action waited on (`check` with `until`, §5.2). Evidence, not
  a verdict: `effect` still comes from the action's own read-back, and whether
  the input went out from the receipt's dispatch.
  """
  @spec until(map() | nil, map()) :: String.t()
  def until(%{until: "met"} = check, receipt) when is_map(receipt),
    do: " What you waited for held" <> met_tail(check[:waited_ms], receipt) <> cut_note(check)

  def until(%{until: "not_met"} = check, receipt) when is_map(receipt) do
    " What you waited for did not hold within its timeout" <>
      not_met_tail(receipt) <> cut_note(check)
  end

  def until(%{until: "held_before"}, receipt) when is_map(receipt) do
    " What you waited for already held before the input, so it shows nothing about what this " <>
      "action did."
  end

  def until(_absent, receipt) when is_map(receipt), do: ""

  # A condition that held is this action's effect only as far as its input went
  # out: a verb that found its control already in the asked state sent nothing,
  # so what held shows nothing about it.
  defp met_tail(ms, %{already: true}), do: met_without_input(ms)
  defp met_tail(ms, %{dispatch: :sent}), do: waited(ms) <> " after the input."

  defp met_tail(ms, %{dispatch: :partial}),
    do: waited(ms) <> " after the input, of which only part went out."

  defp met_tail(ms, %{dispatch: :unknown}),
    do: waited_after(ms) <> "; whether the input went out is not known."

  defp met_tail(ms, _not_sent), do: met_without_input(ms)

  defp met_without_input(ms) do
    waited_after(ms) <>
      ", but nothing was sent, so it shows nothing about what this action did."
  end

  defp waited(ms) when is_integer(ms), do: " #{ms} ms"
  defp waited(_unknown), do: ""

  defp waited_after(ms) when is_integer(ms), do: " after #{ms} ms"
  defp waited_after(_unknown), do: ""

  # A verb that found its control already in the asked state sent nothing, and
  # its own note says so; every other receipt says how much of the input left.
  defp not_met_tail(%{already: true}), do: "."

  defp not_met_tail(%{dispatch: :sent}),
    do: " after the input. The input was still sent, so do not repeat it for that: look first."

  defp not_met_tail(%{dispatch: :partial}),
    do: " after the input. Only part of the input went out: look before sending anything again."

  defp not_met_tail(%{dispatch: :unknown}),
    do: " after the input. Whether the input went out is not known: look before repeating it."

  defp not_met_tail(_not_sent), do: "."

  @doc """
  A `wait_for` reply (§5.3). Not met by the deadline is an answer, not a
  failure; met may carry what matched, listed like an `elements` reply.
  """
  @spec wait(map()) :: String.t()
  def wait(%{"met" => true} = reply) do
    "The condition held#{after_ms(reply)}." <> cut_note(reply) <> matched(reply)
  end

  def wait(%{"met" => false} = reply) do
    "The condition did not hold#{within_ms(reply)}. Nothing was sent. Look (`elements` or " <>
      "`screenshot`) before deciding what to do next." <> cut_note(reply)
  end

  @doc """
  Why a walk stopped before it ran out of tree, from the helper's closed set.
  """
  @spec truncation_cause(String.t()) :: String.t()
  def truncation_cause("nodes"), do: "it reached the element cap"
  def truncation_cause("depth"), do: "it reached the depth limit"
  def truncation_cause("time"), do: "it ran out of its time budget"

  @doc """
  Application text made safe to render inside a line the model reads targets
  off: one line, no delimiter quotes, bounded. Anything that is not a string is
  nothing.
  """
  @spec safe_text(term()) :: String.t()
  def safe_text(text), do: neutralised(text, @untrusted_text_max)

  @doc """
  A sentence the helper wrote (a refusal's detail, a note on what it did), made
  safe the same way: it can carry a window's title or an application's name
  inside it, and it is longer than a label, so only its bound differs.
  """
  @spec safe_sentence(term()) :: String.t()
  def safe_sentence(text), do: neutralised(text, @helper_sentence_max)

  defp neutralised(text, max) when is_binary(text) do
    text
    |> String.replace(~r/[[:space:][:cntrl:]]+/u, " ")
    |> String.replace("\"", "'")
    |> String.trim()
    |> bound_text(max)
  end

  defp neutralised(_not_a_string, _max), do: ""

  @doc "A label in quotes, or nothing when there is none."
  @spec quoted(term()) :: String.t()
  def quoted(label) do
    case safe_text(label) do
      "" -> ""
      text -> ~s("#{text}")
    end
  end

  @doc "A control's role, or `element` when the helper named none."
  @spec role(map()) :: String.t()
  def role(element) do
    case safe_text(element["role"]) do
      "" -> "element"
      role -> role
    end
  end

  # A control is listed when the model can reach it: by reference, or by point.
  defp usable(elements),
    do: elements |> Enum.filter(&usable?/1) |> Enum.take(@max_elements)

  defp usable?(%{"x" => x, "y" => y}) when is_integer(x) and is_integer(y), do: true
  defp usable?(%{} = element), do: ref(element) != ""
  defp usable?(_not_a_map), do: false

  # An empty listing still names the list it is, as a full one does.
  defp empty_lead(%{"observation_id" => id}) when is_binary(id), do: "List #{id}. "
  defp empty_lead(_reply), do: ""

  defp empty_listing(%{"query" => _query}) do
    "Nothing in that scope matched the query. " <>
      plain_first() <> " Otherwise try a broader query, another `scope`, or a `screenshot`."
  end

  defp empty_listing(request) do
    if Map.has_key?(request, "scope") or request["skeleton"] == true do
      "Nothing was listed there. " <>
        plain_first() <> " Otherwise try another `scope`, or a `screenshot`."
    else
      no_controls()
    end
  end

  defp no_controls do
    "No accessibility-backed controls were exposed. Visible content may still accept pixel " <>
      "interaction: on a page the managed `browser` drives, its `get field=rect` + " <>
      "`click_coords` hit the same target exactly; anywhere else take a `screenshot` and use " <>
      "pixel coordinates read in the image it names."
  end

  # Only a plain listing asks an app that builds its tree late (Chromium,
  # Electron) to expose it (PROTOCOL.md §2.2). The engine never makes that call
  # for the model; it names it as the next step.
  defp plain_first do
    "If this app has not been listed plainly yet, a plain `elements` (no `scope`, `query` or " <>
      "`skeleton`) is the next step: only that asks an app that builds its tree late " <>
      "(Chromium, Electron) to expose it."
  end

  defp listing_lead(%{"observation_id" => id} = reply, count) when is_binary(id) do
    "List #{id}#{where(reply)}: #{count} control(s) — reference, role, label, state, the verbs " <>
      ~s(it takes, its point. Send one of a control's verbs with its `element_ref` and ) <>
      ~s(observation_id "#{id}": no pointer, no aim. A control with no verb you need is ) <>
      "clicked by `element_ref`, or at its point in this list's pixels; one with no point " <>
      "cannot be clicked." <> drill_note(reply, id)
  end

  defp listing_lead(reply, count),
    do: "#{count} control(s)#{where(reply)}, not addressable — take `elements` again to act."

  defp where(%{"root" => root}), do: " (inside #{safe_text(root)})"
  defp where(%{"scope" => scope}) when is_binary(scope), do: " (scope #{safe_text(scope)})"
  defp where(_reply), do: ""

  # A drill replaces the root's descendants and nothing else (§2.3), so every
  # reference the model already holds outside it is still good.
  defp drill_note(%{"root" => root}, id) when is_binary(root) do
    " References outside #{safe_text(root)} are unchanged and work with observation_id " <>
      ~s("#{id}" too.)
  end

  defp drill_note(_reply, _id), do: ""

  # One line per control: what to call it, what it holds, what can be done with
  # it, where to click it, and where it sits. A disabled control is LISTED as
  # disabled rather than dropped — a model that cannot see the greyed-out button
  # invents a reason it is missing, and then a way around it.
  defp line(element) do
    [
      ref(element),
      role(element),
      quoted(element["label"]),
      value_word(element),
      enabled_word(element)
      | states(element)
    ]
    |> Kernel.++([verbs_word(element), hidden_word(element), point_word(element)])
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> Kernel.<>(path_word(element["path"]))
  end

  # A reference is the helper's own token (`e1`, `e2`), but it is rendered where a
  # forged one would be believed, so it is bounded like any other text.
  defp ref(element), do: safe_text(element["element_ref"])

  # A secure field's contents are never read (§2.2): it says so, and shows no
  # value even if a reply carried one.
  defp value_word(%{"secure" => true}), do: "secure"

  defp value_word(element) do
    case safe_text(element["value"]) do
      "" -> ""
      text -> ~s(value="#{text}")
    end
  end

  # Absent is unknown, as everywhere else: a control the helper could not say was
  # enabled is not described as either.
  defp enabled_word(%{"enabled" => true}), do: "enabled"
  defp enabled_word(%{"enabled" => false}), do: "disabled"
  defp enabled_word(_element), do: ""

  defp states(element) do
    Enum.reject(
      [
        boolean_state(element["checked"], "on", "off"),
        boolean_state(element["expanded"], "expanded", "collapsed"),
        boolean_state(element["selected"], "selected", ""),
        boolean_state(element["focused"], "focused", "")
      ],
      &(&1 == "")
    )
  end

  defp boolean_state(true, yes, _no), do: yes
  defp boolean_state(false, _yes, no), do: no
  defp boolean_state(_absent, _yes, _no), do: ""

  # A verb needs a reference to be sent with, so a control the helper named no
  # reference for lists none, whatever it says it supports.
  defp verbs_word(%{"verbs" => verbs} = element) when is_list(verbs) do
    case {ref(element), Enum.filter(verbs, &(&1 in @verbs))} do
      {"", _verbs} -> ""
      {_ref, []} -> ""
      {_ref, listed} -> "[" <> Enum.join(listed, ", ") <> "]"
    end
  end

  defp verbs_word(_element), do: ""

  # A cut node in a skeleton: the children it hides, which `root` lists.
  defp hidden_word(%{"hidden" => n}) when is_integer(n) and n >= 0, do: "+#{n} inside"
  defp hidden_word(_element), do: ""

  defp point_word(%{"x" => x, "y" => y}) when is_integer(x) and is_integer(y),
    do: "at (#{x},#{y})"

  defp point_word(_element), do: ""

  # Ancestor labels, nearest last, so two "Save" buttons in one window are
  # tellable apart.
  defp path_word(path) when is_list(path) do
    case path |> Enum.map(&safe_text/1) |> Enum.reject(&(&1 == "")) do
      [] -> ""
      labels -> " — " <> Enum.join(labels, " › ")
    end
  end

  defp path_word(_absent), do: ""

  defp skeleton_note(%{"skeleton" => %{"depth" => depth} = skeleton}) when is_integer(depth) do
    "\nCut at depth #{depth}: a line with `+N inside` hides N more; list them with `elements` " <>
      "and `root` set to that reference, with this observation_id." <> hidden_note(skeleton)
  end

  defp skeleton_note(_reply), do: ""

  defp hidden_note(%{"hidden" => n}) when is_integer(n) and n > 0,
    do: " #{n} more behind the cuts could not be listed (no position, or outside this view)."

  defp hidden_note(_skeleton), do: ""

  # The walk stopped before it ran out of tree, so this list is not every control.
  # It rides the empty branch too: a walk cut short with nothing usable left reads,
  # without it, as "this application exposes nothing".
  defp truncated_note(%{"truncated" => reason}) when reason in ~w(nodes depth time) do
    "\n(this is not every control — the walk stopped because #{truncation_cause(reason)}. " <>
      "Narrow it with a `query`, a `scope`, `skeleton: true`, or a `region` around the part " <>
      "you need.)"
  end

  defp truncated_note(_reply), do: ""

  defp surface(%{"kind" => kind} = surface) when is_map_key(@surface_scopes, kind) do
    text = [kind, quoted(surface["label"])] |> Enum.reject(&(&1 == "")) |> Enum.join(" ")
    {text, Map.fetch!(@surface_scopes, kind)}
  end

  defp surface(_unknown_kind), do: nil

  defp surfaces_hint([_one] = named), do: " Read it with " <> scopes(named) <> "."
  defp surfaces_hint(named), do: " Read them with " <> scopes(named) <> "."

  defp scopes(named) do
    words = named |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.map_join(" or ", &~s("#{&1}"))
    "`elements` with `scope` " <> words
  end

  # The helper ran out of the request's own deadline before the condition's
  # timeout did, so "not yet" is all a miss can mean here.
  defp cut_note(%{"deadline_cut" => true}), do: cut_sentence()
  defp cut_note(%{deadline_cut: true}), do: cut_sentence()
  defp cut_note(_check), do: ""

  defp cut_sentence,
    do: " The wait was cut short by this request's deadline, before its own timeout."

  defp after_ms(%{"waited_ms" => ms}) when is_integer(ms) and ms >= 0, do: " after #{ms} ms"
  defp after_ms(_reply), do: ""

  defp within_ms(%{"waited_ms" => ms}) when is_integer(ms) and ms >= 0, do: " within #{ms} ms"
  defp within_ms(_reply), do: ""

  defp matched(%{"elements" => [_ | _]} = reply), do: " Matched:\n" <> listing(reply, %{})
  defp matched(_reply), do: ""

  defp bound_text(text, max) do
    if String.length(text) > max,
      do: String.slice(text, 0, max) <> "…",
      else: text
  end
end
