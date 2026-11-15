defmodule FermixChannels.Desktop.InvokePlacesTest do
  # M89 D13: a Mac refuses its server's place search while its owner has
  # Apple Maps switched off here, in the offer's own sentence, and takes it
  # again once it is on; the master switch and a review in wait refuse it as
  # they refuse everything. The link is stood in for: each answer comes to
  # the test as `{:sent, event, payload}`. The capability is a stand-in that
  # names the `places` offer, so no Apple Maps search runs.
  use ExUnit.Case, async: true

  alias FermixChannels.Desktop.Invoke
  alias FermixCore.Computers.Offers
  alias FermixCore.Computers.Switches
  alias FermixCore.Sandbox.Config
  alias FermixTestSupport.SafeRm

  defmodule Look do
    @moduledoc false
    @behaviour FermixCore.Computers.Capability

    @impl true
    def id, do: :places
    @impl true
    def offer, do: :places
    @impl true
    def ops, do: ["search"]
    @impl true
    def effect?(_op), do: false
    @impl true
    def long_lived?(_op), do: false
    @impl true
    def validate(_op, _args), do: :ok
    @impl true
    def bounds(_op), do: %{result_bytes: 1_024, part_bytes: 0}
    @impl true
    def admit(_op, _args, _context), do: :ok
    @impl true
    def run("search", _args, nil, _context), do: {:ok, %{"places" => []}, nil}
    @impl true
    def target(_op, _args), do: "Apple Maps"
  end

  setup do
    home = SafeRm.make_tmp_dir!("desktop_invoke_places")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    test = self()
    switches = start_supervised!({Agent, fn -> Switches.only([:places]) end})
    name = :"desktop_invoke_places_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Invoke,
       name: name,
       home: home,
       switches: fn -> Agent.get(switches, & &1) end,
       sandbox: fn -> Config.normalize(mode: :strict, home: home, os_home: home) end,
       capabilities: %{"places" => Look},
       clock: &DateTime.utc_now/0,
       relay: :no_relay,
       send: fn _relay, event, payload ->
         send(test, {:sent, event, payload})
         :ok
       end,
       timer: fn _message, _delay -> make_ref() end,
       link_epoch: fn -> {:ok, 3} end}
    )

    %{admission: Invoke.admission(name), switches: switches}
  end

  defp search(ctx, id) do
    header = %{
      "id" => id,
      "capability" => "places",
      "op" => "search",
      "deadline_ms" => 15_000,
      "epoch" => 3,
      "origin" => "chat",
      "turn" => %{"session_id" => "main-7", "tool_call_id" => "call-#{id}"}
    }

    Invoke.handle(ctx.admission, "invoke_open", header, ~s({"query":"Prado"}))
    assert_receive {:sent, %{"t" => "invoke_result", "id" => ^id} = event, payload}
    {event, payload}
  end

  defp switch(ctx, switches), do: Agent.update(ctx.switches, fn _ -> switches end)

  # This machine's word in the offer's sentences: "Mac" on a Mac.
  defp machine, do: if(:os.type() == {:unix, :darwin}, do: "Mac", else: "computer")

  test "Apple Maps switched off here refuses the search in the offer's words, on again runs it",
       ctx do
    assert {%{"status" => "ok"}, payload} = search(ctx, "inv-on")
    assert Jason.decode!(payload) == %{"places" => []}

    switch(ctx, Switches.only([:files_and_shell, :browser]))

    assert {%{"status" => "refused", "refusal" => "off"} = event, _payload} =
             search(ctx, "inv-off")

    assert event["message"] == Offers.switched_off_sentence(machine())

    switch(ctx, Switches.only([:files_and_shell, :browser, :places]))
    assert {%{"status" => "ok"}, _payload} = search(ctx, "inv-again")
  end

  test "with nothing stored for it, Apple Maps is on; the master off or a review in wait refuses it",
       ctx do
    switch(ctx, enabled: true, reviewed: true)
    assert {%{"status" => "ok"}, _payload} = search(ctx, "inv-default")

    switch(ctx, Switches.only([:places], enabled: false))
    assert {%{"refusal" => "off", "message" => master}, _payload} = search(ctx, "inv-master")
    assert master == Offers.master_off_sentence(machine())

    switch(ctx, Switches.only([:places], reviewed: false))
    assert {%{"refusal" => "off", "message" => waiting}, _payload} = search(ctx, "inv-review")
    assert waiting == Offers.waiting_sentence(machine())
  end
end
