defmodule FermixCore.Management.DraftParityTest do
  @moduledoc """
  Replays the macOS application's draft v2 contract against this daemon and
  names every place the two disagree (M34 native setup §7.8, steps 4 and 9).

  The app authored `management-draft-v2` from the design while the engine still
  published protocol 1, and it is built against that draft today. Before it can
  delete the draft and re-vendor `priv/management/`, someone has to read the two
  against each other; this is that reading, executed rather than written down.

  The comparison is deliberately asymmetric about *what* it trusts. The draft is
  the acceptance spec for shapes the app already decodes, so a field it draws
  and the engine omits is a finding. The engine is the source of truth for the
  wire, so a field the engine adds is a finding too, and both are recorded with
  a reason in `divergences.json`. The assertion is equality, not containment: a
  new disagreement fails, and so does a recorded one that no longer happens, so
  the list cannot outlive the fact it describes.

  What is *not* compared, and why: values. A fixture illustrates a shape, and
  the two were written against different homes. Empty collections are not
  compared either, in either direction, because an unilluminated array says
  nothing about the element the other side drew.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Management.Detect
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.Plugins.Row, as: PluginRow
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Router
  alias FermixCore.Management.Settings

  @draft Path.expand("../../fixtures/management_draft_v2", __DIR__)
  @export Application.app_dir(:fermix_core, "priv/management")

  setup_all do
    %{
      draft_schema: read_json(Path.join(@draft, "protocol.schema.json")),
      draft_success: read_lines(Path.join(@draft, "fixtures/success.jsonl")),
      draft_requests: read_lines(Path.join(@draft, "fixtures/requests.jsonl")),
      draft_errors: read_lines(Path.join(@draft, "fixtures/errors.jsonl")),
      export_success: read_lines(Path.join(@export, "fixtures/success.jsonl")),
      export_requests: read_lines(Path.join(@export, "fixtures/requests.jsonl")),
      export_errors: read_lines(Path.join(@export, "fixtures/errors.jsonl"))
    }
  end

  # The vendored copy is only evidence if it is the app's own bytes. SOURCE.json
  # is the app's record of what it authored, so it is the operand rather than a
  # digest regenerated here, which would verify clean over any local edit.
  test "the copied draft is byte-identical to the one the app ships" do
    recorded =
      Path.join(@draft, "SOURCE.json")
      |> read_json()
      |> Map.fetch!("contracts")
      |> Enum.find(&(&1["name"] == "management_draft_v2"))
      |> Map.fetch!("files")

    assert length(recorded) == 5

    for %{"path" => path, "sha256" => digest} <- recorded do
      local = Path.join(@draft, String.replace_prefix(path, "management-draft-v2/", ""))

      assert File.exists?(local), "the draft copy is missing #{path}"
      assert digest_of(local) == digest, "the draft copy of #{path} was edited"
    end
  end

  # Every frame the app will send, through the live envelope validator and the
  # live per-method gate. A refusal here is not a divergence to record: it is a
  # request the released app makes that this daemon answers with an error.
  test "the live protocol accepts every request frame the app sends", %{draft_requests: requests} do
    assert length(requests) == 47

    for record <- requests do
      frame = record["frame"]
      encoded = Jason.encode!(frame)

      assert {:ok, {:v1, request}} = Protocol.decode_request(encoded),
             "the daemon refuses the app's #{record["name"]} frame"

      assert request.method == record["method"]

      assert {:ok, minimum} = Protocol.minimum_version(request.method)
      assert minimum <= request.protocol_version, "#{request.method} needs a newer engine"
    end
  end

  # The two reads that touch no home and start nothing, driven all the way
  # through `Router.route/2` with the app's own frame. Everything else in the
  # catalog either writes, spawns, or waits on a person, and replaying those
  # would make this test the thing it is testing for.
  test "the live router answers the app's own frames", %{draft_requests: requests} do
    for name <- ["settings_sections", "plugins_list"] do
      frame = requests |> Enum.find(&(&1["name"] == name)) |> Map.fetch!("frame")

      request = %{
        request_id: frame["request_id"],
        protocol_version: frame["protocol_version"],
        method: frame["method"],
        params: frame["params"] || %{}
      }

      assert {:ok, result} = Router.route(request, []), "the router refused #{name}"
      assert is_map(result)
    end
  end

  test "every divergence found is one that is recorded, and every recorded one is still found",
       context do
    found =
      MapSet.new(divergences(context), fn {method, field, kind} ->
        %{"method" => method, "field" => field, "kind" => kind}
      end)

    recorded = MapSet.new(recorded_divergences(), &Map.take(&1, ["method", "field", "kind"]))

    unrecorded = sorted(MapSet.difference(found, recorded))
    stale = sorted(MapSet.difference(recorded, found))

    assert unrecorded == [],
           "unrecorded divergences from the app's draft; add each to divergences.json " <>
             "with a why:\n#{render(unrecorded)}"

    assert stale == [],
           "divergences.json records disagreements that no longer happen; delete " <>
             "them:\n#{render(stale)}"
  end

  test "every recorded divergence carries a reason" do
    for entry <- recorded_divergences() do
      assert entry["kind"] in ~w(draft_only engine_only value)
      assert is_binary(entry["why"]) and String.length(entry["why"]) > 20, inspect(entry)
    end
  end

  defp sorted(set), do: set |> MapSet.to_list() |> Enum.sort_by(&{&1["method"], &1["field"]})

  defp render(entries) do
    Enum.map_join(
      entries,
      "\n",
      &~s(  {"method": "#{&1["method"]}", "field": "#{&1["field"]}", "kind": "#{&1["kind"]}", "why": ""},)
    )
  end

  # --- the comparison itself ---

  defp divergences(context) do
    Enum.concat([
      schema_divergences(context.draft_schema),
      error_divergences(context.draft_errors, context.export_errors),
      request_divergences(context.draft_requests, context.export_requests),
      section_param_divergences(context.draft_requests),
      result_divergences(context.draft_success, context.export_success),
      row_divergences(context.draft_success, context.export_success)
    ])
  end

  # Vocabularies, not JSON Schema structure: the draft inlines enums the export
  # names, so comparing definitions would report an authoring style as a wire
  # difference. Each of these is a closed set a client switches on.
  defp schema_divergences(schema) do
    defs = schema["$defs"]

    Enum.concat([
      set_divergence("(schema)", "x-extensions", extensions(schema), export_extensions()),
      set_divergence(
        "(schema)",
        "methods",
        enum(defs["request"]["properties"]["method"]),
        Protocol.methods()
      ),
      set_divergence("(schema)", "error_codes", error_enum(defs), Protocol.error_codes()),
      set_divergence(
        "(schema)",
        "job_kinds",
        enum(defs["jobView"]["properties"]["kind"]),
        strings(Jobs.kinds())
      ),
      vocabulary_divergence(
        "job_failure_codes",
        defs["jobFailure"]["properties"]["code"],
        Jobs.failure_codes()
      ),
      vocabulary_divergence("detect_targets", defs["detectTarget"], Detect.targets()),
      vocabulary_divergence(
        "row_kinds",
        defs["settingsRow"]["properties"]["kind"],
        strings(Settings.vocabulary().kinds)
      ),
      vocabulary_divergence(
        "plugin_runtime_kinds",
        defs["pluginRow"]["properties"]["runtime_kind"],
        PluginRow.runtime_kinds()
      ),
      vocabulary_divergence(
        "plugin_auth_kinds",
        defs["pluginRow"]["properties"]["auth_kind"],
        PluginRow.auth_kinds()
      ),
      set_divergence(
        "(schema)",
        "minimum_versions",
        minimum_pairs(schema),
        minimum_pairs_of(Protocol.method_minimum_versions())
      ),
      set_divergence(
        "(schema)",
        "limits",
        limit_pairs(schema["x-limits"]),
        limit_pairs(stringify(Protocol.limits()))
      )
    ])
  end

  # A set the draft never closes is one finding, not one per value it omits: the
  # app types the field as an open string, so every word this daemon can put in
  # it decodes. Naming each word would read as ten disagreements about a field
  # the two halves do not actually disagree about.
  defp vocabulary_divergence(field, node, engine) do
    case enum(node) do
      [] -> [{"(schema)", "#{field}:open", "engine_only"}]
      draft -> set_divergence("(schema)", field, draft, engine)
    end
  end

  # One error code carries more than one detail shape (`method_not_found` is
  # both "no such method" and "needs a newer engine"), so the operand is the set
  # of shapes per code rather than one shape.
  defp error_divergences(draft, export) do
    Enum.flat_map(Protocol.error_codes(), fn code ->
      set_divergence("(errors)", code, detail_shapes(draft, code), detail_shapes(export, code))
    end)
  end

  defp request_divergences(draft, export) do
    Enum.flat_map(Protocol.methods(), fn method ->
      set_divergence(method, "params", param_keys(draft, method), param_keys(export, method))
    end)
  end

  # A param key set can match while the value names something this daemon does
  # not serve. The section is the one param whose value is a published name, and
  # a request naming a section that does not exist is answered `invalid_params`,
  # which is a pane the app draws and cannot fill.
  defp section_param_divergences(draft) do
    for record <- draft,
        section = get_in(record, ["frame", "params", "section"]),
        is_binary(section),
        not Settings.section?(section),
        do: {record["method"], "params.section:#{section}", "draft_only"}
  end

  defp result_divergences(draft, export) do
    Enum.flat_map(Protocol.methods(), fn method ->
      for selector <- selectors(method, draft, export),
          divergence <- shape_divergence(method, selector, draft, export) do
        divergence
      end
    end)
  end

  # The keys a section publishes are what the app binds a control to, so a key
  # in one and not the other is a pane with a control nothing answers, or a
  # value nothing edits. Compared by name rather than by shape.
  defp row_divergences(draft, export) do
    Enum.flat_map(Settings.sections(), fn section ->
      set_divergence(
        "settings.get:#{section.id}",
        "rows",
        row_keys(draft, section.id),
        row_keys(export, section.id)
      )
    end)
  end

  defp shape_divergence(method, selector, draft, export) do
    a = result_shape(draft, method, selector)
    b = result_shape(export, method, selector)

    if a == %{} or b == %{} do
      []
    else
      Enum.map(illuminated(a, b), &named(method, selector, &1, "draft_only")) ++
        Enum.map(illuminated(b, a), &named(method, selector, &1, "engine_only"))
    end
  end

  defp named(method, nil, path, kind), do: {method, path, kind}
  defp named(method, selector, path, kind), do: {method, "#{selector}:#{path}", kind}

  # A path present in `have` and missing from `other` counts only when `other`
  # illuminated the container it lives in: an empty array says nothing about the
  # element the far side drew.
  defp illuminated(have, other) do
    empty = empty_containers(other)

    have
    |> Map.keys()
    |> Enum.reject(&Map.has_key?(other, &1))
    |> Enum.reject(fn path -> Enum.any?(empty, &String.starts_with?(path, &1 <> "[]")) end)
    |> Enum.sort()
  end

  defp empty_containers(shape) do
    for {path, types} <- shape,
        "array" in types,
        not Enum.any?(Map.keys(shape), &String.starts_with?(&1, path <> "[]")),
        do: path
  end

  # --- shapes ---

  defp result_shape(records, method, selector) do
    records
    |> Enum.filter(&(&1["method"] == method))
    |> Enum.filter(&matching?(&1, selector))
    |> Enum.reduce(%{}, fn record, acc ->
      flatten(record["response"]["result"], "", acc)
    end)
  end

  defp flatten(value, prefix, acc) when is_map(value) do
    Enum.reduce(value, acc, fn {key, item}, inner ->
      path = if prefix == "", do: key, else: "#{prefix}.#{key}"

      flatten(
        item,
        path,
        Map.update(inner, path, type_set(item), &MapSet.union(&1, type_set(item)))
      )
    end)
  end

  defp flatten(value, prefix, acc) when is_list(value) do
    Enum.reduce(value, acc, &flatten(&1, prefix <> "[]", &2))
  end

  defp flatten(_value, _prefix, acc), do: acc

  defp type_set(value) when is_map(value), do: MapSet.new(["object"])
  defp type_set(value) when is_list(value), do: MapSet.new(["array"])
  defp type_set(nil), do: MapSet.new(["null"])
  defp type_set(_value), do: MapSet.new(["scalar"])

  # --- selectors ---

  defp selectors("settings.get", _draft, _export), do: Enum.map(Settings.sections(), & &1.id)
  defp selectors(_method, _draft, _export), do: [nil]

  defp matching?(_record, nil), do: true
  defp matching?(record, selector), do: get_in(record, ["response", "result", "id"]) == selector

  # --- readers ---

  defp row_keys(records, section) do
    records
    |> Enum.find(&(&1["method"] == "settings.get" and matching?(&1, section)))
    |> case do
      nil -> []
      record -> Enum.map(record["response"]["result"]["rows"], & &1["key"])
    end
  end

  defp param_keys(records, method) do
    records
    |> Enum.filter(&(&1["method"] == method))
    |> Enum.flat_map(&Map.keys(&1["frame"]["params"] || %{}))
    |> Enum.uniq()
  end

  defp detail_shapes(records, code) do
    records
    |> Enum.filter(&(&1["code"] == code))
    |> Enum.map(
      &(&1["response"]["error"]["details"]
        |> Map.keys()
        |> Enum.sort()
        |> Enum.join(","))
    )
    |> Enum.uniq()
  end

  defp extensions(schema), do: schema |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "x-"))

  defp export_extensions do
    @export
    |> Path.join("protocol.schema.json")
    |> read_json()
    |> extensions()
  end

  defp enum(nil), do: []
  defp enum(%{"enum" => values}), do: Enum.reject(values, &is_nil/1)
  defp enum(%{"oneOf" => [%{"enum" => values} | _rest]}), do: Enum.reject(values, &is_nil/1)
  defp enum(_node), do: []

  defp error_enum(defs), do: enum(defs["error"]["properties"]["error"]["properties"]["code"])

  defp minimum_pairs(schema), do: minimum_pairs_of(schema["x-method-minimum-versions"] || %{})
  defp minimum_pairs_of(table), do: Enum.map(table, fn {name, min} -> "#{name}=#{min}" end)

  defp limit_pairs(limits),
    do: Enum.map(limits || %{}, fn {name, value} -> "#{name}=#{value}" end)

  defp strings(atoms), do: Enum.map(atoms, &Atom.to_string/1)
  defp stringify(limits), do: Map.new(limits, fn {key, value} -> {Atom.to_string(key), value} end)

  defp set_divergence(method, field, draft, export) do
    only_draft = MapSet.difference(MapSet.new(draft), MapSet.new(export))
    only_export = MapSet.difference(MapSet.new(export), MapSet.new(draft))

    Enum.map(only_draft, &{method, "#{field}:#{&1}", "draft_only"}) ++
      Enum.map(only_export, &{method, "#{field}:#{&1}", "engine_only"})
  end

  defp recorded_divergences do
    @draft |> Path.join("divergences.json") |> read_json() |> Map.fetch!("divergences")
  end

  defp read_json(path), do: path |> File.read!() |> Jason.decode!()

  defp read_lines(path) do
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  defp digest_of(path) do
    :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
  end
end
