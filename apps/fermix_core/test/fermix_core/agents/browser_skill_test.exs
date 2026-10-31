defmodule FermixCore.Agents.BrowserGuidanceSkillTest do
  use ExUnit.Case, async: true

  alias FermixCore.Agents.SkillRegistry

  test "bundled browser guidance skill loads as a core skill for the browser tool" do
    local =
      Path.join(
        System.tmp_dir!(),
        "fermix-browser-guidance-skill-local-#{System.unique_integer([:positive])}"
      )

    core = Path.expand("../../../priv/skills", __DIR__)
    File.mkdir_p!(local)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(local) end)

    registry =
      start_supervised!(
        {SkillRegistry,
         name: :"browser_guidance_skill_#{System.unique_integer([:positive])}",
         skills_dir: local,
         core_dir: core,
         seed_defaults: false},
        id: :"browser_guidance_skill_child_#{System.unique_integer([:positive])}"
      )

    assert {:ok, definition} = SkillRegistry.load(registry, "browser-guidance")
    assert definition.trust == :operator
    assert definition.allowed_tools == ["browser", "web_fetch", "web_search"]
    assert definition.system_prompt =~ "Use `browser`"
    assert definition.system_prompt =~ "Use the default profile"
    assert definition.system_prompt =~ "not proof that async navigation"

    # The pane has no WebMCP and saves no downloads: the skill names the field
    # that says so and the profile that is always Chrome.
    assert definition.system_prompt =~ "`backend` is `fermix_app`"
    assert definition.system_prompt =~ "runs no WebMCP tools and saves no downloads"
    assert definition.system_prompt =~ ~s(profile: "fermix_chrome")

    # `download` starts nothing: a click starts the file, `download` collects it.
    assert definition.system_prompt =~ "`download` starts nothing"
    assert definition.system_prompt =~ "click the file's link with `act` and then call `download`"

    # A sign-in types the owner's saved login after their yes: the two-step
    # move and the refusals' next moves are named, and a password never is asked for.
    assert definition.system_prompt =~ ~s(`kind: "sign_in"`)
    assert definition.system_prompt =~ "`username_ref` alone"
    assert definition.system_prompt =~ "Never ask the owner for a password"
    assert definition.system_prompt =~ "Settings > Browser > Website logins"

    # A form and a sign-in submit in the same call, and a fill's receipt is
    # its own check: nothing left says a fill never submits or must be verified.
    assert definition.system_prompt =~ "`submit: true`"
    assert definition.system_prompt =~ "receipt is its own check"
    # Backend-neutral: Chrome's receipt carries what each field holds after
    # typing, the pane's carries no `value` and a fill that cannot type fails,
    # so nothing sends the model to `get` a field the receipt left bare.
    assert definition.system_prompt =~ "holds after typing"
    assert definition.system_prompt =~ "fails the fill with an error"
    refute definition.system_prompt =~ "check that one with `get`"
    refute definition.system_prompt =~ "the `value` each field now holds"
    refute definition.system_prompt =~ "After anything else, verify"
    refute definition.system_prompt =~ "fills and does not submit"
    refute definition.system_prompt =~ "no click, no submit"

    for code <- ~w(sign_in_pane_only sign_in_no_login sign_in_denied sign_in_unanswered
                   sign_in_not_delivered sign_in_wrong_site secret_on_screen) do
      assert definition.system_prompt =~ "`#{code}`", "browser-guidance never names #{code}"
    end

    # A CAPTCHA is the model's own call, not a Fermix stop; the human gates stay.
    refute definition.system_prompt =~ ~r/captcha/i
    assert definition.system_prompt =~ "Stop and report for 2FA, payment confirmation"
  end
end
