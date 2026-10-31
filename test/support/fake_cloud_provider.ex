defmodule FermixTestSupport.FakeCloudProvider do
  @moduledoc """
  An invented second Always On provider, "Nimbus", for the tests that prove
  the shared provisioning code (`Home.Provision`, its driver and ledger,
  `Management.Provision`, the summary, `Management.Copy`) needs nothing of
  Hetzner's. It is what a new provider is: only API primitives of the
  `FermixCore.Home.Provision` contract, over a world of its own (an `Agent`
  the test owns, passed as `opts[:world]`), and it never touches a ledger:
  `Provision.Driver` does every write.

  Tokens: `token/0` is accepted and may write; `read_only_token/0` is
  accepted and cannot write (a write answers `:read_only_token`);
  `other_project_token/0` is accepted and sees none of what the world holds;
  any other is refused (`:unauthorized`).

  The world: the firewalls, servers and addresses it holds (ids are strings,
  as every provider's are to Fermix), the labels of each, how many reads an
  action answers `running` (`:action_polls`), queued `faults` (the next call
  of a primitive answers that error instead), how many deletes a firewall
  answers `:in_use`, and every primitive called, in order, with the arguments
  that matter (`calls/1`). `opts[:spy]`, when given, is called with each
  primitive's name before it runs, so a test can read the ledger as the
  driver left it at that moment.
  """

  @behaviour FermixCore.Home.Provision

  @id "nimbus"
  @token "invented-nimbus-token-5f2c8e1a"
  @read_only "invented-nimbus-read-only-9b3d4c"
  @other_project "invented-nimbus-other-project-71ae"
  @max_user_data 16_384

  @doc "The token Nimbus accepts and lets write."
  def token, do: @token

  @doc "A token Nimbus accepts that can only read."
  def read_only_token, do: @read_only

  @doc "A token of another Nimbus workspace."
  def other_project_token, do: @other_project

  @doc "Starts a world owned by the calling test."
  def start!(overrides \\ []) do
    world =
      Map.merge(
        %{
          servers: %{},
          firewalls: %{},
          primary_ips: %{},
          actions: %{},
          action_polls: 0,
          in_use: 0,
          faults: [],
          calls: [],
          next_id: 100
        },
        Map.new(overrides)
      )

    ExUnit.Callbacks.start_supervised!(
      {Agent, fn -> world end},
      id: {__MODULE__, System.unique_integer([:positive])}
    )
  end

  @doc "Every primitive called, oldest first: `{name, detail}`."
  def calls(world), do: world |> Agent.get(& &1.calls) |> Enum.reverse()

  @doc "The world as it stands."
  def world(world), do: Agent.get(world, & &1)

  @doc "Sets one fact of the world."
  def set(world, key, value), do: Agent.update(world, &Map.put(&1, key, value))

  @doc "The next call of `primitive` answers `{:error, reason}` and does nothing."
  def fault(world, primitive, reason),
    do: Agent.update(world, &%{&1 | faults: &1.faults ++ [{primitive, reason}]})

  @doc "Removes a held resource, as the provider's console would."
  def delete_outside(world, kind, id) when kind in [:servers, :firewalls, :primary_ips],
    do: Agent.update(world, &update_in(&1, [kind], fn held -> Map.delete(held, id) end))

  # -- identity -----------------------------------------------------------------

  @impl true
  def id, do: @id

  @impl true
  def display do
    %{
      name: "Nimbus",
      token_label: "Nimbus access key",
      write_token: "a key that may create servers",
      account: "workspace",
      steps: [
        "Sign in to Nimbus and turn on two-factor sign-in for your account.",
        "Make a workspace for Fermix alone, so the key reaches nothing else.",
        "In that workspace, create an access key that may create servers.",
        "Paste the key here: Fermix checks it at once."
      ],
      console_url: "https://console.nimbus.invalid/",
      docs_anchor: "nimbus",
      locations: [%{id: "osl1", city: "Oslo"}, %{id: "lis1", city: "Lisbon"}],
      proper_nouns: ["Nimbus", "Oslo", "Lisbon"]
    }
  end

  @impl true
  def type_name(type) when is_binary(type),
    do: type |> String.replace("-", " ") |> String.capitalize()

  @impl true
  def max_user_data, do: @max_user_data

  # -- reads --------------------------------------------------------------------

  @impl true
  def check_token(token, opts) do
    call(opts, :check_token, nil, fn world ->
      case token do
        t when t in [@token, @read_only] -> {{:ok, %{other_servers: false}}, world}
        @other_project -> {{:ok, %{other_servers: true}}, world}
        _other -> {{:error, :unauthorized}, world}
      end
    end)
  end

  @impl true
  def catalog(token, opts) do
    call(opts, :catalog, nil, fn world ->
      {readable(token, fn ->
         %{
           currency: "EUR",
           locations: [
             %{id: "osl1", city: "Oslo", country: "NO"},
             %{id: "lis1", city: "Lisbon", country: "PT"},
             %{id: "rey1", city: "Reykjavik", country: "IS"}
           ],
           types: types(),
           ipv4_monthly: %{"osl1" => 10_000, "lis1" => 10_000}
         }
       end), world}
    end)
  end

  @impl true
  def server_type(token, type, opts) do
    call(opts, :server_type, type, fn world ->
      {readable(token, fn ->
         %{
           type: Enum.find(types(), &(&1.name == type)),
           cities: %{"osl1" => "Oslo", "lis1" => "Lisbon"}
         }
       end), world}
    end)
  end

  defp types do
    [
      type("small-4", 4, %{"osl1" => 110_000, "lis1" => 120_000}, ["osl1", "lis1"]),
      type("large-8", 8, %{"osl1" => 210_000}, ["osl1"]),
      type("tiny-2", 2, %{"osl1" => 50_000}, ["osl1"])
    ]
  end

  defp type(name, memory, monthly, stock) do
    %{
      name: name,
      description: type_name(name),
      cores: div(memory, 2),
      memory_gb: memory,
      disk_gb: memory * 20,
      x86: true,
      sold: true,
      dedicated: false,
      stock: stock,
      monthly: monthly
    }
  end

  @impl true
  def system_image(token, opts),
    do: call(opts, :system_image, nil, &{readable(token, fn -> "debian-13-x64" end), &1})

  @impl true
  def action(token, id, opts) do
    call(opts, :action, id, fn world ->
      case {token in [@token, @read_only], world.actions[id]} do
        {false, _action} -> {{:error, :unauthorized}, world}
        {true, nil} -> {{:error, :not_found}, world}
        {true, action} -> polled(action, world)
      end
    end)
  end

  defp polled(%{polls: 0} = action, world),
    do: {{:ok, %{action.view | status: :success}}, world}

  defp polled(action, world),
    do: {{:ok, action.view}, put_in(world.actions[action.view.id].polls, action.polls - 1)}

  @impl true
  def get(token, kind, id, opts) do
    call(opts, :get, {kind, id}, fn world ->
      case {token, Map.get(held(world, kind), id)} do
        {@other_project, _found} -> {{:error, :not_found}, world}
        {_token, nil} -> {{:error, :not_found}, world}
        {_token, found} -> {{:ok, found}, world}
      end
    end)
  end

  @impl true
  def find(token, kind, labels, opts) when kind in [:server, :firewall] do
    call(opts, :find, {kind, labels}, fn world ->
      found =
        world
        |> held(kind)
        |> Map.values()
        |> Enum.find(&(token != @other_project and &1.labels == labels))

      {{:ok, found}, world}
    end)
  end

  # -- writes -------------------------------------------------------------------

  @impl true
  def create_firewall(token, %{name: name, labels: labels}, opts) do
    call(opts, :create_firewall, %{name: name, labels: labels}, fn world ->
      writable(token, world, fn world ->
        {id, world} = next_id(world)
        firewall = %{id: id, name: name, labels: labels}
        {{:ok, id}, put_in(world.firewalls[id], firewall)}
      end)
    end)
  end

  @impl true
  def create_server(token, spec, opts) do
    call(opts, :create_server, Map.delete(spec, :user_data), fn world ->
      writable(token, world, &created(&1, spec))
    end)
  end

  # The answer carries a password the driver must keep nowhere, as a
  # provider's create can.
  defp created(world, spec) do
    {id, world} = next_id(world)
    {ip_id, world} = next_id(world)
    ips = [%{id: ip_id, type: "ipv4", ip: "198.51.100.7"}]

    server = %{
      id: id,
      name: spec.name,
      labels: spec.labels,
      power: "running",
      ipv4: "198.51.100.7",
      created_at: ~U[2031-05-04 10:00:00Z],
      primary_ips: ips
    }

    {action, world} = new_action(world, :create)
    world = %{world | servers: Map.put(world.servers, id, server)}
    world = %{world | primary_ips: Map.put(world.primary_ips, ip_id, hd(ips))}

    answer =
      server
      |> Map.take([:id, :ipv4, :created_at, :primary_ips])
      |> Map.merge(%{actions: [action], password: "invented-nimbus-password-Zk3"})

    {{:ok, answer}, world}
  end

  @impl true
  def power(token, id, verb, opts) when verb in [:on, :reset] do
    call(opts, :power, {id, verb}, fn world ->
      writable(token, world, &powered(&1, id, verb))
    end)
  end

  defp powered(world, id, verb) when is_map_key(world.servers, id) do
    {action, world} = new_action(world, if(verb == :on, do: :power_on, else: :reset))
    {{:ok, action}, put_in(world.servers[id].power, "running")}
  end

  defp powered(world, _id, _verb), do: {{:error, :not_found}, world}

  @impl true
  def delete(token, kind, id, opts) do
    call(opts, :delete, {kind, id}, fn world ->
      writable(token, world, &deleted(&1, kind, id))
    end)
  end

  defp deleted(%{in_use: tries} = world, :firewall, _id) when tries > 0,
    do: {{:error, :in_use}, %{world | in_use: tries - 1}}

  defp deleted(world, kind, id) do
    key = plural(kind)

    case Map.fetch(Map.fetch!(world, key), id) do
      :error ->
        {{:error, :not_found}, world}

      {:ok, _found} ->
        world = Map.update!(world, key, &Map.delete(&1, id))
        if kind == :server, do: deleted_server(world, id), else: {{:ok, nil}, world}
    end
  end

  # A server's addresses go with it.
  defp deleted_server(world, _id) do
    {action, world} = new_action(world, :delete)
    {{:ok, action}, %{world | primary_ips: %{}}}
  end

  # -- the world ----------------------------------------------------------------

  defp call(opts, primitive, detail, fun) do
    if spy = Keyword.get(opts, :spy), do: spy.(primitive)

    Agent.get_and_update(Keyword.fetch!(opts, :world), fn world ->
      world = %{world | calls: [{primitive, detail} | world.calls]}

      case Enum.split_with(world.faults, &(elem(&1, 0) == primitive)) do
        {[{_primitive, reason} | rest], others} ->
          {{:error, reason}, %{world | faults: rest ++ others}}

        {[], _faults} ->
          fun.(world)
      end
    end)
  end

  defp readable(token, answer) when token in [@token, @read_only, @other_project],
    do: {:ok, answer.()}

  defp readable(_token, _answer), do: {:error, :unauthorized}

  defp writable(@token, world, write), do: write.(world)
  defp writable(@read_only, world, _write), do: {{:error, :read_only_token}, world}
  defp writable(@other_project, world, _write), do: {{:error, :not_found}, world}
  defp writable(_token, world, _write), do: {{:error, :unauthorized}, world}

  defp new_action(world, step) do
    {id, world} = next_id(world)
    status = if world.action_polls == 0, do: :success, else: :running
    view = %{id: id, status: status, step: step, message: nil}
    {view, put_in(world.actions[id], %{view: view, polls: world.action_polls})}
  end

  defp next_id(world), do: {"nb-#{world.next_id}", %{world | next_id: world.next_id + 1}}

  defp held(world, kind), do: Map.fetch!(world, plural(kind))

  defp plural(:server), do: :servers
  defp plural(:firewall), do: :firewalls
  defp plural(:primary_ip), do: :primary_ips
end
