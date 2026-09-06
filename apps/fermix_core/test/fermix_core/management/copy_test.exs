defmodule FermixCore.Management.CopyTest do
  @moduledoc """
  The daemon-side copy gate (M34 native setup §7.7, §7.8 step 4).

  Every sentence in this file's case set is one a front-end renders verbatim:
  the app cannot correct it and the browser door does not try. The case set is
  walked out of the live producers rather than listed here, so a row, a
  remediation, a restart reason or a readiness action added in Elixir joins the
  gate on the day it lands instead of on the day someone remembers.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Auth.Redaction
  alias FermixCore.Management.Copy
  alias FermixCore.Management.Doctor.Remediation
  alias FermixCore.Management.Plugins
  alias FermixCore.Management.Plugins.Row, as: PluginRow
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Settings
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Readiness
  alias FermixCore.Setup.RestartState

  # What the two renderers really answer for a reason the plugin installer
  # produces: a tuple, a map, and the operator's own home directory.
  @internal_term Redaction.format({:tree_missing, %{root: "/Users/example/.fermix/plugins"}})
  @placeholder "Value"

  # A backticked span is a literal the operator types, which is the one place a
  # path belongs; the rest of the sentence is prose and may carry none.
  @backticked ~r/`[^`]*`/
  @term_shapes [map: ~r/%\{/, tuple: ~r/\{:/, absolute_path: ~r{(?<![\w~])/[A-Za-z0-9._-]+/}]

  describe "the rules themselves" do
    # A rule the module publishes and nothing here provokes is a rule nobody has
    # ever seen fire, so the offenders are asserted against `rules/0` rather
    # than listed loosely beside it.
    test "each rule names its own offender" do
      offenders = [
        {:em_dash, "A sentence — with a dash."},
        {:exclamation, "Welcome!"},
        {:mix_task, "Run mix fermix.setup now."},
        {:version_number, "Needs Fermix 0.9.0."},
        {:wire_token, "Set bot_token here."},
        {:sentence_case, "Set the Token here."}
      ]

      assert Enum.map(offenders, &elem(&1, 0)) == Copy.rules()

      for {rule, text} <- offenders do
        assert rule in Enum.map(Copy.violations(text, :prose), &elem(&1, 0)),
               "#{rule} did not fire on #{inspect(text)}"
      end
    end

    test "a backticked literal is what the operator types, not prose" do
      assert Copy.violations("Set `bot_token` in the settings file.", :prose) == []
      assert Copy.violations("Run `fermix setup`.", :prose) == []
    end

    test "a name is held to the four rules that apply to a name" do
      assert Copy.violations("GPT-5.6 Sol (default, latest)", :name) == []
      assert Copy.violations("New York", :name) == []
      assert {:em_dash, "—"} in Copy.violations("Grok — fast", :name)
    end

    test "an initialism and a proper noun are not capitalisation defects" do
      assert Copy.violations("Your Telegram user ID is needed.", :prose) == []

      assert Copy.violations("Runs as Fermix Computer Use, a separate signed helper.", :prose) ==
               []
    end

    # The four sentences this slice rewrote, kept as the proof the gate is not
    # vacuous: each one shipped, each one is what the rule exists to catch.
    test "the sentences this gate was written for are still caught" do
      assert [{:mix_task, _} | _] =
               Copy.violations(
                 "Run mix fermix.setup to provide your name, timezone, and communication style.",
                 :prose
               )

      assert {:em_dash, "—"} in Copy.violations(
               ~s(Invalid auth_mode "x" — set it to "api_key" or "oauth".),
               :prose
             )

      assert {:wire_token, "bot_token"} in Copy.violations(
               "Set the Telegram bot token: run `fermix setup` or set bot_token in config.toml.",
               :prose
             )

      assert {:wire_token, "base_url"} in Copy.violations(
               "Set [fermix_core.providers.ollama] base_url.",
               :prose
             )
    end

    test "an interpolated name is data the call site declares" do
      sentence = "Your prompt reaches Eden."

      assert {:sentence_case, "Eden"} in Copy.violations(sentence, :prose)
      assert Copy.violations(sentence, :prose, ["Eden"]) == []
    end
  end

  describe "the copy the management wire publishes" do
    test "every published error sentence obeys the rules" do
      for {code, message} <- Protocol.error_messages() do
        assert_clean(message, :prose, [], "error #{code}")
      end
    end

    test "every section title obeys the rules" do
      for section <- Settings.sections() do
        assert_clean(section.title, :prose, [], "section title #{section.id}")
      end
    end

    test "every row label, footer, unit and option obeys the rules" do
      for section <- Settings.sections(), row <- rows(section.id) do
        where = "#{section.id}.#{row["key"]}"

        assert_clean(row["label"], :prose, [], "row label #{where}")
        assert_clean(row["footer"], :prose, [], "row footer #{where}")
        assert_clean(row["unit"], :name, [], "row unit #{where}")

        for option <- row["options"] do
          assert_clean(option["label"], :name, [], "option label #{where}")
          assert_clean(option["hint"], :prose, [], "option hint #{where}")
        end
      end
    end

    test "every remediation title and body obeys the rules" do
      for key <- Remediation.keys() do
        [id, status] = String.split(key, ".")
        entry = Remediation.fetch(id, status)

        assert_clean(entry["title"], :prose, [], "remediation title #{key}")
        assert_clean(entry["body"], :prose, [], "remediation body #{key}")
      end
    end

    test "every restart reason obeys the rules" do
      for {section, sentence} <- RestartState.boot_bound_sections() do
        assert_clean(sentence, :prose, [], "restart reason #{section}")
      end
    end

    test "every readiness action obeys the rules" do
      for {detail_key, action} <- Readiness.published_actions() do
        assert_clean(action, :prose, [], "readiness action #{detail_key}")
      end
    end

    test "every plugin verb obeys the rules" do
      for verb <- PluginRow.verbs(), do: assert_clean(verb, :name, [], "plugin verb")
    end

    test "every plugin row sentence obeys the rules" do
      for row <- plugin_rows() do
        where = row["name"]
        names = [row["title"], row["account_label"]] |> Enum.reject(&is_nil/1)

        assert_clean(row["status_sentence"], :prose, names, "plugin status #{where}")
        assert_clean(row["consent_sentence"], :prose, names, "plugin consent #{where}")
        assert_clean(row["remote_disclosure"], :prose, names, "plugin disclosure #{where}")

        for setting <- row["settings"] do
          assert_clean(setting["label"], :prose, names, "plugin setting #{where}")
        end
      end
    end

    test "every plugin status has a sentence, and it obeys the rules" do
      for status <- PluginRow.statuses() do
        assert_clean(PluginRow.check_sentence(status), :prose, [], "check sentence #{status}")
      end
    end
  end

  # A refusal sentence is only produced by the failure it names, so no live call
  # can enumerate the set. The modules that write them can: every complete
  # sentence literal in the management tree is copy a client renders, and
  # reading them out of the source cannot go stale the way a list beside it
  # would. Docs are skipped; an interpolated fragment is not a whole sentence
  # and does not reach this set.
  describe "the sentences the management modules write" do
    test "every one obeys the rules" do
      for {file, sentence} <- source_sentences() do
        assert_clean(sentence, :prose, [], "sentence in #{Path.basename(file)}")
      end
    end

    test "the sweep reads the whole management tree" do
      files = source_sentences() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      assert length(files) > 10
      assert Enum.count(source_sentences()) > 100
      assert Enum.any?(files, &String.ends_with?(&1, "plugins.ex"))
      assert Enum.any?(files, &String.ends_with?(&1, "readiness.ex"))
    end
  end

  # The one defect the rules above cannot see. `inspect/1` and
  # `Redaction.format/1` answer Elixir term syntax, and the reasons that reach
  # these sentences carry the operator's own paths, so a sentence assembled from
  # one reads as a crash dump in the app, on the browser door, and again in the
  # `management_job` bookend that carries it. The set is the same source sweep,
  # with the templates rendered: a fixed sentence plus a daemon-side log is what
  # passes, and nothing else does.
  describe "the internal terms a published sentence must never carry" do
    test "no published sentence carries a map, a tuple or an absolute path" do
      for {file, sentence} <- published_sentences() do
        assert internal_terms(sentence) == [],
               "sentence in #{Path.basename(file)}: #{inspect(sentence)} " <>
                 "carries #{inspect(internal_terms(sentence))}"
      end
    end

    # A gate nothing provokes is a gate nobody has seen fire, so each shape is
    # asserted against a sentence assembled the way the refused ones were.
    test "each forbidden shape names its own offender" do
      assert :map in internal_terms("The install did not finish: #{@internal_term}.")
      assert :tuple in internal_terms("The install did not finish: #{@internal_term}.")
      assert :absolute_path in internal_terms("The install did not finish: #{@internal_term}.")
      assert internal_terms("The install did not finish. See the daemon log.") == []
    end

    test "the template half of the sweep reads real sentences" do
      templates = source_templates() |> Enum.map(&elem(&1, 1))

      assert length(templates) > 10
      assert Enum.any?(templates, &String.contains?(&1, @placeholder))
    end
  end

  # A producer that answers nothing turns its whole clause above into a loop
  # over an empty list, which passes. The floors are the shapes of the live
  # registries, not round numbers.
  test "every producer the gate walks answers something" do
    assert length(Settings.sections()) >= length(Descriptor.all())
    assert Enum.count(published_copy()) > 200
    assert plugin_rows() != []
    assert Readiness.published_actions() != []
    assert Remediation.keys() != []
    assert Enum.any?(Settings.sections(), &(rows(&1.id) != []))
  end

  # A proper noun nothing publishes any more is a rule that has quietly widened:
  # the list is the only hand-maintained part of the gate, so it is asserted
  # against the copy rather than trusted.
  test "every hand-listed proper noun is still used by published copy" do
    corpus = Enum.join(published_copy(), "\n")
    unused = Enum.reject(hand_listed(), &String.contains?(corpus, &1))

    assert unused == [], "proper nouns no published sentence uses: #{inspect(unused)}"
  end

  # The derived half comes from the provider registry and cannot go stale; only
  # what the module writes by hand has to be asserted against the copy.
  defp hand_listed do
    derived =
      Descriptor.all()
      |> Enum.flat_map(&String.split(&1.label, ~r/[\s()]+/, trim: true))
      |> MapSet.new()

    Enum.reject(Copy.proper_nouns(), &MapSet.member?(derived, &1))
  end

  defp published_copy do
    section_copy() ++
      Enum.map(Settings.sections(), & &1.title) ++
      Enum.flat_map(Remediation.keys(), fn key ->
        [id, status] = String.split(key, ".")
        entry = Remediation.fetch(id, status)
        [entry["title"], entry["body"]]
      end) ++
      Enum.map(RestartState.boot_bound_sections(), fn {_section, sentence} -> sentence end) ++
      Enum.map(Readiness.published_actions(), fn {_key, action} -> action end) ++
      Map.values(Protocol.error_messages()) ++
      PluginRow.verbs() ++
      Enum.map(PluginRow.statuses(), &PluginRow.check_sentence/1) ++
      plugin_copy() ++
      Enum.map(source_sentences(), &elem(&1, 1))
  end

  defp section_copy do
    for section <- Settings.sections(),
        row <- rows(section.id),
        text <- [row["label"], row["footer"], row["unit"]] ++ option_copy(row),
        is_binary(text) do
      text
    end
  end

  defp option_copy(row) do
    Enum.flat_map(row["options"], &[&1["label"], &1["hint"]])
  end

  defp plugin_copy do
    for row <- plugin_rows(),
        text <- [row["status_sentence"], row["consent_sentence"], row["remote_disclosure"]],
        is_binary(text) do
      text
    end
  end

  defp rows(section) do
    {:ok, view} = Settings.get(section)
    view["rows"]
  end

  defp plugin_rows do
    {:ok, %{"plugins" => rows}} = Plugins.list()
    rows
  end

  @lib Path.expand("../../../lib/fermix_core", __DIR__)

  defp published_sentences, do: source_sentences() ++ source_templates()

  defp internal_terms(sentence) do
    prose = Regex.replace(@backticked, sentence, "``")

    for {shape, pattern} <- @term_shapes, Regex.match?(pattern, prose), do: shape
  end

  defp source_files do
    Path.wildcard(Path.join(@lib, "management/**/*.ex")) ++
      [
        Path.join(@lib, "readiness.ex"),
        Path.join(@lib, "setup/restart_state.ex"),
        Path.join(@lib, "setup/coexistence.ex")
      ]
  end

  defp source_sentences, do: collect(&literal/1)

  # The same sweep, reading the sentences that are assembled rather than
  # written: every interpolation is rendered, so a template that inlines a
  # reason is judged on the text a client would actually be shown.
  defp source_templates, do: collect(&template/1)

  defp collect(render) do
    Enum.flat_map(source_files(), fn file ->
      {:ok, ast} = Code.string_to_quoted(File.read!(file))
      {_ast, found} = Macro.prewalk(ast, [], &collect_sentence(&1, &2, render))

      found |> Enum.uniq() |> Enum.map(&{file, &1})
    end)
  end

  defp collect_sentence({:@, meta, [{doc, _, _}]}, acc, _render)
       when doc in [:moduledoc, :doc, :typedoc],
       do: {{:@, meta, []}, acc}

  defp collect_sentence(node, acc, render) do
    case render.(node) do
      {:ok, text} -> {node, [text | acc]}
      :skip -> {node, acc}
    end
  end

  defp literal(node) when is_binary(node), do: keep(node)
  defp literal(_node), do: :skip

  defp template({:<<>>, _meta, parts}), do: parts |> Enum.map_join(&part/1) |> keep()
  defp template(_node), do: :skip

  defp keep(text), do: if(sentence?(text), do: {:ok, text}, else: :skip)

  defp part(text) when is_binary(text), do: text

  defp part({:"::", _meta, [{{:., _dot, [Kernel, :to_string]}, _call, [expr]}, _binary]}),
    do: interpolated(expr)

  defp part(_other), do: @placeholder

  # `inspect/1` and `Redaction.format/1` (and auth's one-line delegate to it)
  # answer an internal term; everything else a sentence interpolates is a
  # bounded scalar the daemon has already chosen. The placeholder is
  # capitalised so a template that opens with an interpolation still reads as a
  # sentence to `sentence?/1`.
  defp interpolated({:inspect, _meta, [_term]}), do: @internal_term
  defp interpolated({:format, _meta, [_term]}), do: @internal_term
  defp interpolated({{:., _meta, [_module, :format]}, _call, [_term]}), do: @internal_term
  defp interpolated(_expr), do: @placeholder

  # A whole sentence: it opens with a capital, closes with a full stop, and has
  # more than one word. A key, a format fragment and a log prefix do not.
  defp sentence?(text) do
    String.contains?(text, " ") and String.ends_with?(text, ".") and
      String.match?(text, ~r/^[A-Z]/)
  end

  defp assert_clean(nil, _kind, _names, _where), do: :ok

  defp assert_clean(text, kind, names, where) when is_binary(text) do
    assert Copy.violations(text, kind, names) == [],
           "#{where}: #{inspect(text)} breaks #{inspect(Copy.violations(text, kind, names))}"
  end
end
