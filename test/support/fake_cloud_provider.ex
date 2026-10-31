defmodule FermixTestSupport.FakeCloudProvider do
  @moduledoc """
  An invented second Always On provider, "Nimbus", for the tests that prove
  the shared provisioning code (`Home.Provision`, its ledger,
  `Management.Provision`, the summary, `Management.Copy`) needs nothing of
  Hetzner's: it implements the whole `FermixCore.Home.Provision` contract and
  keeps no world of its own beyond the ledger, writing there what a provider
  writes once its API answered.

  Tokens: `token/0` is accepted and may write; `read_only_token/0` is
  accepted and cannot write (a create answers `:read_only_token`);
  `other_project_token/0` is accepted and reaches nothing Fermix created
  (`:other_project` while something stands); any other is refused
  (`:unauthorized`). `opts[:fail]` makes a create answer that shared kind
  after its check, before anything is written.
  """

  @behaviour FermixCore.Home.Provision

  alias FermixCore.Home.Provision
  alias FermixCore.Home.Provision.FirstBoot
  alias FermixCore.Home.Provision.Ledger

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
  def check_token(token, _opts) when token in [@token, @read_only],
    do: {:ok, %{other_servers: false}}

  def check_token(@other_project, _opts), do: {:ok, %{other_servers: true}}
  def check_token(_token, _opts), do: {:error, :unauthorized}

  @impl true
  def reaches(@other_project, %{server: %{status: status}}, _opts) when status != :gone,
    do: {:error, :other_project}

  def reaches(_token, _ledger, _opts), do: :ok

  @impl true
  def options(_token, _opts) do
    {:ok,
     %{
       "currency" => "EUR",
       "locations" => [
         %{"id" => "osl1", "city" => "Oslo", "country" => "NO"},
         %{"id" => "lis1", "city" => "Lisbon", "country" => "PT"}
       ],
       "offers" => [
         offer("small-4", 4, "osl1", "11.00"),
         offer("small-4", 4, "lis1", "12.00"),
         offer("large-8", 8, "osl1", "21.00")
       ],
       "recommended" => %{"type" => "small-4", "location" => "osl1"},
       "more_room" => %{"type" => "large-8", "location" => "osl1"}
     }}
  end

  defp offer(type, memory, location, monthly) do
    %{
      "type" => type,
      "description" => type_name(type),
      "cores" => div(memory, 2),
      "memory_gb" => memory,
      "disk_gb" => memory * 20,
      "dedicated" => false,
      "location" => location,
      "monthly" => monthly,
      "ipv4_monthly" => "1.00",
      "total_monthly" => "#{String.to_integer(hd(String.split(monthly, "."))) + 1}.00"
    }
  end

  @impl true
  def create(home, %{type: type, location: location, profile: profile}, opts) do
    report(opts, "checking")

    with {:ok, ledger} <- read(home),
         {:ok, token} <- token(ledger),
         :ok <- no_server(ledger),
         :ok <- writes(token),
         :ok <- Keyword.get(opts, :fail, :ok) |> failing(),
         {:ok, code} <- open_code(opts),
         {:ok, _user_data} <- user_data(code) do
      report(opts, "server")
      ref = Provision.fresh_ref(:crypto.strong_rand_bytes(2), Ledger.replaced_ref(ledger))
      name = Provision.server_name(profile, ref)

      server = %{
        name: name,
        id: 21,
        status: :created,
        type: type,
        location: location,
        ipv4: "198.51.100.7",
        power: "running",
        created_at: now(opts),
        seen_at: now(opts)
      }

      with {:ok, written} <- update(home, &created(&1, ref, name, server)),
           do: {:ok, written.server}
    end
  end

  defp created(ledger, ref, name, server) do
    {:ok,
     ledger
     |> Ledger.begin_create(ref, %{name: name})
     |> Ledger.put_firewall(%{id: 11, status: :created})
     |> Ledger.put_server(server)}
  end

  defp no_server(%{server: %{status: status}}) when status != :gone, do: {:error, :server_exists}
  defp no_server(_ledger), do: :ok

  defp writes(@read_only), do: {:error, :read_only_token}
  defp writes(_token), do: :ok

  defp failing(:ok), do: :ok
  defp failing(reason), do: {:error, reason}

  defp open_code(opts) do
    case Keyword.fetch!(opts, :open_code).() do
      {:ok, code} -> {:ok, code}
      {:error, sentence} -> {:error, {:code_unavailable, sentence}}
    end
  end

  defp user_data(code) do
    case FirstBoot.user_data(code, @max_user_data) do
      {:ok, user_data} -> {:ok, user_data}
      {:error, :too_large} -> {:error, :user_data_too_large}
      {:error, :invalid_code} -> {:error, :invalid_code}
    end
  end

  @impl true
  def power(home, action, opts) when action in [:on, :reset] do
    report(opts, "power")

    with {:ok, ledger} <- read(home),
         {:ok, _token} <- token(ledger),
         :ok <- standing(ledger),
         {:ok, _ledger} <- update(home, &{:ok, Ledger.put_server(&1, %{power: "running"})}) do
      :ok
    end
  end

  defp standing(%{server: %{status: :created}}), do: :ok
  defp standing(_ledger), do: {:error, :no_server}

  @impl true
  def reconcile(home, _opts) do
    with {:ok, ledger} <- read(home),
         {:ok, _token} <- token(ledger),
         do: {:ok, ledger}
  end

  @impl true
  def delete(home, opts) do
    report(opts, "deleting")

    with {:ok, ledger} <- read(home),
         {:ok, _token} <- token(ledger),
         :ok <- Keyword.fetch!(opts, :withdraw_code).(),
         {:ok, _ledger} <- update(home, &{:ok, Ledger.clear(&1)}) do
      :ok
    end
  end

  @impl true
  def delete_replaced(home, opts) do
    report(opts, "deleting")

    with {:ok, ledger} <- read(home),
         {:ok, _old} <- Ledger.retired(ledger),
         {:ok, _ledger} <- update(home, &{:ok, Ledger.replaced_deleted(&1, now(opts))}) do
      :ok
    end
  end

  defp read(home) do
    case Ledger.read(home, @id) do
      {:ok, ledger} -> {:ok, ledger}
      {:error, reason} -> {:error, {:ledger, reason}}
    end
  end

  defp update(home, fun) do
    case Ledger.update(home, @id, fun) do
      {:ok, ledger} -> {:ok, ledger}
      {:error, reason} -> {:error, {:ledger, reason}}
    end
  end

  defp token(%{token: token}) when is_binary(token), do: {:ok, token}
  defp token(_ledger), do: {:error, :no_token}

  defp report(opts, phase), do: Keyword.get(opts, :report, fn _phase -> :ok end).(phase)

  defp now(opts), do: DateTime.truncate(Keyword.get(opts, :now, &DateTime.utc_now/0).(), :second)
end
