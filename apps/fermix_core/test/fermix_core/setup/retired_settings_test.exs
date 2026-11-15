defmodule FermixCore.Setup.RetiredSettingsTest do
  # The settings a build retired, found as data in the decoded settings files:
  # a load drops each and names none, and the engine process names what this
  # finds, once (`ConfigStore.say_retired_settings/0`).
  use ExUnit.Case, async: true

  alias FermixCore.Setup.RetiredSettings

  # Each retired setting alone, in the document a load normalizes, with the
  # start of the one sentence that names it.
  @cases [
    {"the Always On test switch", %{"fermix_core" => %{"always_on" => %{"enabled" => true}}},
     "config.toml [fermix_core.always_on] is retired: every build of Fermix serves Always On"},
    {"a provider's retired key",
     %{"fermix_core" => %{"providers" => %{"openai_codex" => %{"fast" => true}}}},
     "config.toml [fermix_core.providers.openai_codex] key(s) fast are retired"},
    {"the retired image backend",
     %{"fermix_core" => %{"tools" => %{"generate_image" => %{"backend" => " OpenAI_Codex "}}}},
     ~s(config.toml [fermix_core.tools.generate_image] backend "openai_codex" is retired)},
    {"the home's history sites",
     %{"fermix_core" => %{"computer_history" => %{"sites" => ["example.org"]}}},
     "computer_history.sites is retired: every site in an allowlisted browser is recorded; " <>
       "remove the key from the file that holds it"},
    {"a retired plugin enabled", %{"fermix_core" => %{"plugins" => %{"enabled" => [" eden "]}}},
     ~s{retired plugin(s) ["eden"] dropped from [fermix_core.plugins]}},
    {"a retired plugin's section",
     %{"fermix_core" => %{"plugins" => %{"eden" => %{"auth_profile" => "eden:primary"}}}},
     ~s{retired plugin(s) ["eden"] dropped from [fermix_core.plugins]}},
    {"a retired plugin's entry",
     %{"fermix_core" => %{"plugins" => %{"entries" => %{"eden" => %{}}}}},
     ~s{retired plugin(s) ["eden"] dropped from [fermix_core.plugins]}},
    {"a retired plugin's stored key",
     %{"fermix_core" => %{"plugin_secrets" => %{"eden" => "@keyring"}}},
     ~s{retired plugin(s) ["eden"] dropped from [fermix_core.plugin_secrets]}},
    {"the FCM table", %{"fermix_channels" => %{"mobile" => %{"fcm" => %{"enabled" => true}}}},
     "config.toml [fermix_channels.mobile.fcm] is retired"}
  ]

  for {name, document, sentence} <- @cases do
    @document document
    @sentence sentence

    test "#{name} is named in one sentence" do
      assert [notice] = RetiredSettings.notices(@document, %{}, "")
      assert String.starts_with?(notice, @sentence), notice
    end
  end

  test "the inbound MCP section is named from config.toml as written" do
    contents = "[mcp.inbound]\nenabled = false\n\n[mcp.inbound.tools.shell]\nexposed = false\n"

    assert [notice] = RetiredSettings.notices(%{}, %{}, contents)
    assert notice =~ "config.toml [mcp.inbound] is retired"
  end

  test "this computer's history sites are named, and once where both files carry them" do
    sites = %{"fermix_core" => %{"computer_history" => %{"sites" => ["example.org"]}}}

    assert [machine_only] = RetiredSettings.notices(%{}, sites, "")
    assert machine_only =~ "computer_history.sites is retired"
    assert RetiredSettings.notices(sites, sites, "") == [machine_only]
  end

  test "every retired setting at once is named once each, in a fixed order" do
    document =
      @cases
      |> Enum.map(&elem(&1, 1))
      |> Enum.reduce(%{}, &deep_merge(&2, &1))

    notices = RetiredSettings.notices(document, %{}, "[mcp.inbound]\nenabled = false\n")

    assert length(notices) == 8
    assert notices == Enum.uniq(notices)
    assert notices == RetiredSettings.notices(document, %{}, "[mcp.inbound]\nenabled = false\n")
  end

  test "settings that carry nothing retired name nothing" do
    live = %{
      "fermix_core" => %{
        "agent" => %{"name" => "Orchard"},
        "providers" => %{"openai_codex" => %{"default_model" => "gpt-5.5"}},
        "tools" => %{"generate_image" => %{"backend" => "openai"}},
        "computer_history" => %{"enabled" => true, "apps" => ["com.apple.Safari"]},
        "plugins" => %{"enabled" => ["github"], "dev_local" => "/src/plugin", "github" => %{}},
        "plugin_secrets" => %{"github" => "@keyring"}
      },
      "fermix_channels" => %{"mobile" => %{"enabled" => true, "push" => %{"enabled" => false}}}
    }

    assert RetiredSettings.notices(%{}, %{}, "") == []
    assert RetiredSettings.notices(live, %{}, "[mcp.servers.files]\ncommand = \"x\"\n") == []
  end

  # The load refuses these; finding them here raises nothing and names nothing.
  test "a value of a shape the load would refuse names nothing" do
    for document <- [
          %{"fermix_core" => "not a table"},
          %{"fermix_core" => %{"providers" => %{"openai_codex" => "fast"}}},
          %{"fermix_core" => %{"tools" => %{"generate_image" => %{"backend" => 7}}}},
          %{"fermix_core" => %{"plugins" => "eden"}},
          %{"fermix_core" => %{"plugins" => %{"enabled" => "eden", "entries" => "eden"}}},
          %{"fermix_core" => %{"plugin_secrets" => ["eden"]}},
          %{"fermix_channels" => %{"mobile" => "fcm"}}
        ] do
      assert RetiredSettings.notices(document, %{}, "") == [], inspect(document)
    end
  end

  test "image_backend?/1 knows the retired backend alone" do
    assert RetiredSettings.image_backend?("openai_codex")
    refute RetiredSettings.image_backend?("openai")
  end

  defp deep_merge(left, right),
    do: Map.merge(left, right, fn _key, a, b -> if is_map(a), do: deep_merge(a, b), else: b end)
end
