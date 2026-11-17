defmodule Fermix.CLI.SettingsCommandPhoneCallsTest do
  @moduledoc """
  `fermix settings secret set` and `secret clear` of a credential a phone
  call reads (M94 §12), end to end through the management router and the
  writer that holds it: refused with the hold's sentence while a call is in
  progress, stored value untouched, and through once the call has ended. And
  `phone-calls recovery` and `phone-calls confirm-ended`, the owner's way out
  of a call whose end is unconfirmed.

  The daemon here is the router itself, in this process, against a temporary
  FERMIX_HOME, the stub keychain and a ledger of the case's own
  (`PhoneCallGoldens.world/1`). Every name, number and credential is invented.
  """

  # async: false: the writes go through the one restart state and the settings
  # file of the FERMIX_HOME this case sets.
  use ExUnit.Case, async: false

  alias Fermix.CLI.SettingsCommand
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Router
  alias FermixCore.Management.Secrets
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.Setup.RestartState
  alias FermixTestSupport.PhoneCallGoldens
  alias FermixTestSupport.PipedTerminal
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub

  @apps [:fermix_core, :fermix_channels]
  @key "sk-invented-openai-key"
  @new_key "sk-another-invented-key"
  @held "fermix settings secret set: A phone call is in progress and uses this key. Ask " <>
          "Fermix to stop the call, or let it end, then change the key.\n"

  setup do
    envs = for app <- @apps, do: {app, Application.get_all_env(app)}
    fermix_home = System.get_env("FERMIX_HOME")
    home = SafeRm.make_tmp_dir!("settings_command_phone_calls")

    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    SecretWriterStub.reset()
    System.put_env("FERMIX_HOME", home)

    for key <- [:providers, :realtime, :phone_calls],
        do: Application.put_env(:fermix_core, key, [])

    :ok = RestartState.record_persisted_baseline()

    on_exit(fn ->
      Enum.each(envs, fn {app, env} -> restore_all(app, env) end)
      SecretWriterStub.reset()

      case fermix_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      SafeRm.rm_rf!(home)
      :ok = RestartState.record_persisted_baseline()
    end)

    assert {:ok, %{"present" => true}} = Secrets.set("openai_api_key", @key)
    %{world: PhoneCallGoldens.world(:in_progress)}
  end

  test "secret set is refused with the hold's sentence during a call, and stores after it",
       %{world: world} do
    assert run(["secret", "set", "openai_api_key", "--stdin"], world, @new_key) ==
             {1, "", @held}

    assert SecretWriterStub.get(:openai_api_key) == {:ok, @key}

    end_call!(world)

    assert {0, "Stored openai_api_key.\n" <> _restart, ""} =
             run(["secret", "set", "openai_api_key", "--stdin"], world, @new_key)

    assert SecretWriterStub.get(:openai_api_key) == {:ok, @new_key}
  end

  test "secret clear is refused during a call, and the key stays stored", %{world: world} do
    held = String.replace(@held, "secret set", "secret clear")
    assert run(["secret", "clear", "openai_api_key"], world) == {1, "", held}
    assert SecretWriterStub.get(:openai_api_key) == {:ok, @key}

    end_call!(world)

    assert {0, "Cleared openai_api_key.\n" <> _restart, ""} =
             run(["secret", "clear", "openai_api_key"], world)
  end

  test "the SpaceXAI key is stored during a call: no phone call reads it", %{world: world} do
    assert {0, "Stored xai_api_key.\n" <> _restart, ""} =
             run(["secret", "set", "xai_api_key", "--stdin"], world, "xai-invented-voice-key")

    assert SecretWriterStub.get(:xai_api_key) == {:ok, "xai-invented-voice-key"}
  end

  describe "an unresolved call" do
    test "recovery shows what is known, the steps at Telnyx and how to confirm it ended" do
      world = PhoneCallGoldens.world(:lost)
      lost = PhoneCallGoldens.ids().lost

      assert {0, out, ""} = run(["phone-calls", "recovery"], world)

      assert out =~
               "Whether the call was placed is unknown, because OpenAI never said."

      assert out =~ "Call: #{lost}\nCalled: Calloway Bistro +12125550101\n"
      assert out =~ "- In the Telnyx portal, end any call still active on your connection"

      assert out =~
               "Once your Telnyx portal shows it ended: fermix settings phone-calls " <>
                 "confirm-ended #{lost}\n"
    end

    test "confirm-ended frees its slot, and the recovery view is then empty" do
      world = PhoneCallGoldens.world(:lost)
      lost = PhoneCallGoldens.ids().lost

      assert run(["phone-calls", "confirm-ended", lost], world) ==
               {0,
                "Fermix marked the call ended on your word, so a new call may be placed. What " <>
                  "was agreed stays unknown.\n", ""}

      assert {:ok, %{slot_release_reason: "owner_confirmed"}} =
               Ledger.get(lost, server: world[:repo])

      assert run(["phone-calls", "recovery"], world) ==
               {0, "No phone call's termination is unconfirmed.\n", ""}
    end

    test "confirm-ended refuses a call in progress in the daemon's words", %{world: world} do
      id = PhoneCallGoldens.ids().in_progress

      assert run(["phone-calls", "confirm-ended", id], world) ==
               {1, "",
                "fermix settings phone-calls confirm-ended: That call is still in progress, so " <>
                  "only stopping it ends it.\n"}
    end
  end

  # The command with the management router as its daemon, the secret writers
  # handed the case's ledger, as `secret.set` and `secret.clear` reach them.
  defp run(argv, world, value \\ "") do
    {:ok, stdout} = StringIO.open("")
    {:ok, stderr} = StringIO.open("")
    {:ok, device} = StringIO.open(value <> "\n")

    status =
      SettingsCommand.run(argv,
        client: daemon(world),
        stdout: stdout,
        stderr: stderr,
        app_managed?: fn -> false end,
        restart_route: fn -> {:service, :user} end,
        secret_input: [device: device, terminal: PipedTerminal]
      )

    {status, contents(stdout), contents(stderr)}
  end

  defp daemon(world) do
    fn method, params, _opts ->
      request = %{request_id: "req-1", protocol_version: 2, method: method, params: params}

      opts = [
        secret_writer: &Secrets.set(&1, &2, phone_calls: world),
        secret_clearer: &Secrets.clear(&1, phone_calls: world),
        operation_opts: [phone_calls: world]
      ]

      case Router.route(request, opts) do
        {:ok, result} -> {:ok, result}
        {:error, code, details} -> {:error, management_error(code, details)}
      end
    end
  end

  defp management_error(code, details),
    do:
      {:management_error, Atom.to_string(code), Map.fetch!(Protocol.error_messages(), code),
       details}

  defp end_call!(world) do
    id = PhoneCallGoldens.ids().in_progress
    fields = %{ended_at: PhoneCallGoldens.now()}
    {:ok, _row} = Ledger.terminalize(id, "ended", fields, server: world[:repo])
    :ok
  end

  defp contents(device) do
    {:ok, {_input, output}} = StringIO.close(device)
    output
  end

  defp restore_all(app, env) do
    for {key, _value} <- Application.get_all_env(app),
        not Keyword.has_key?(env, key),
        do: Application.delete_env(app, key)

    for {key, value} <- env, do: Application.put_env(app, key, value)
  end
end
