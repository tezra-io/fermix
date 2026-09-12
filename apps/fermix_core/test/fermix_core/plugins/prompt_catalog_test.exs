defmodule FermixCore.Plugins.PromptCatalogTest do
  use ExUnit.Case, async: false

  alias FermixCore.Auth.Store
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Plugins.PromptCatalog

  setup do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("prompt-catalog-home")
    old_home = System.get_env("FERMIX_HOME")
    plugins = Application.get_env(:fermix_core, :plugins, [])
    oauth = Application.get_env(:fermix_core, :oauth, %{})

    System.put_env("FERMIX_HOME", home)
    Application.put_env(:fermix_core, :plugins, enabled: [])
    Application.put_env(:fermix_core, :oauth, %{})

    on_exit(fn ->
      case old_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      Application.put_env(:fermix_core, :plugins, plugins)
      Application.put_env(:fermix_core, :oauth, oauth)
      FermixTestSupport.SafeRm.rm_rf!(home)
    end)

    :ok
  end

  defp plugin_cap(name, plugin) do
    Capability.new(%{
      name: name,
      description: "x",
      parameters: %{"type" => "object"},
      kind: :builtin,
      executor: {__MODULE__, :unused, []},
      policy_class: :external_api,
      metadata: %{plugin_owned?: true, plugin: plugin}
    })
  end

  defp builtin_cap(name) do
    Capability.new(%{
      name: name,
      description: "x",
      parameters: %{"type" => "object"},
      kind: :builtin,
      executor: {__MODULE__, :unused, []},
      policy_class: :read_only,
      metadata: %{}
    })
  end

  test "entries/2 derives tools from plugin-owned capabilities only" do
    caps = [
      plugin_cap("google_calendar_search_events", "google_calendar"),
      builtin_cap("file_read")
    ]

    assert [entry] = PromptCatalog.entries(caps, ["google-calendar"])
    assert entry.name == "google_calendar"
    assert entry.status == :ready
    assert entry.tools == ["google_calendar_search_events"]
    assert entry.skills == ["google-calendar"]
  end

  test "entries/2 lists only skills that are actually loaded" do
    caps = [plugin_cap("google_calendar_search_events", "google_calendar")]

    assert [entry] = PromptCatalog.entries(caps, [])
    assert entry.skills == []
  end

  test "entries/2 is empty when no capability is plugin-owned" do
    assert PromptCatalog.entries([builtin_cap("file_read")], ["google-calendar"]) == []
  end

  test "an enabled plugin that is not ready contributes a status entry" do
    # gmail is bundled and oauth2; with no OAuth client configured its
    # status is :needs_client_config — the entry must say so.
    Application.put_env(:fermix_core, :plugins, enabled: ["gmail"])

    assert [entry] = PromptCatalog.entries([], [])
    assert entry.name == "gmail"
    assert entry.status == :needs_client_config
    assert entry.tools == []
    assert entry.skills == []
    assert is_binary(entry.remediation) and entry.remediation != ""
  end

  test "an enabled name absent from every plugin source surfaces as :not_installed" do
    Application.put_env(:fermix_core, :plugins, enabled: ["ghost"])

    assert [entry] = PromptCatalog.entries([], [])
    assert entry.name == "ghost"
    assert entry.status == :not_installed
    assert entry.remediation =~ "fermix plugins install ghost"
  end

  describe "a quarantined grant" do
    setup do
      Application.put_env(:fermix_core, :plugins, enabled: ["gmail"])

      Application.put_env(:fermix_core, :oauth, %{
        "google" => [client_id: "123.apps.googleusercontent.com", client_secret: "stale"]
      })

      :ok
    end

    defp store_gmail_grant(status) do
      :ok =
        Store.write("gmail:primary", %{
          auth_mode: "oauth2",
          provider: "google",
          granted_scopes: [],
          tokens: %{access_token: "AT", refresh_token: "RT"},
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          last_refresh: nil,
          status: status
        })
    end

    # Signing in again under the same refused client cannot work, so the agent
    # is told to have the owner fix the client first.
    test "a refused sign-in client sends the owner to the client, then the sign-in" do
      store_gmail_grant("client_rejected")

      assert [entry] = PromptCatalog.entries([], [])
      assert entry.status == :reauthorization_required
      assert entry.remediation =~ "refused the saved sign-in client"
      assert entry.remediation =~ "ID and secret in setup"
      assert entry.remediation =~ "sign in again"
      refute entry.remediation =~ "fermix plugins auth login"
    end

    test "a grant that merely expired still points at the sign-in" do
      store_gmail_grant("reauthorization_required")

      assert [entry] = PromptCatalog.entries([], [])
      assert entry.status == :reauthorization_required
      assert entry.remediation =~ "fermix plugins auth login gmail"
    end
  end

  test "a plugin with registered capabilities yields no extra status entry" do
    Application.put_env(:fermix_core, :plugins, enabled: ["gmail"])
    caps = [plugin_cap("gmail_send_email", "gmail")]

    assert [entry] = PromptCatalog.entries(caps, [])
    assert entry.name == "gmail"
    assert entry.status == :ready
    assert entry.tools == ["gmail_send_email"]
  end
end
