defmodule FermixCore.Management.Provision do
  @moduledoc """
  The `home.provision.*` family (M75 lean v1 §4.3): Fermix creates the
  owner's Always On server on Hetzner (`FermixCore.Home.Provision.Hetzner`)
  from a project token pasted once.

  Every method is device-class (`Management.Placement`): a linked desktop
  answers it itself and never sends it to the server, since the token and
  the ledger (`Home.Provision.Ledger`, `device/provision/hetzner.json`) stay
  on the computer that created the server.

    * `home.provision.connect {token}` (an owner decision) checks the token
      against Hetzner (`GET /servers`, `GET /pricing`) and keeps it; one
      Hetzner refuses is `invalid_params` on `token` with its sentence. While
      the ledger holds a server or firewall that is not gone, a new token
      replaces the old only when it reaches it (`reaches/3`, the same
      project), so a token that stopped working is replaced and one for
      another project is refused, also on `token`. Answers the view below and
      `other_servers` (the project holds servers Fermix did not create).
    * `home.provision.options` reads the orderable types per location live,
      with their monthly prices as the account is billed, the L2
      recommendation, "more room", and the recommendation in one `sentence`.
    * `home.provision.create {type, location}` (an owner decision; the
      primary only) starts a job, kind `home_provision`, that creates the
      firewall and the server, the 24-hour enrollment code inside.
    * `home.provision.power {action}` (an owner decision), `on` or `reset`, a
      job of the same kind.
    * `home.provision.resources` reads the ledger back from Hetzner (a
      resource deleted outside Fermix is marked gone) and answers the view.
    * `home.provision.delete` (an owner decision) deletes the server, its
      addresses unless they went with it, and the firewall, as a job; it is
      refused while a move to the server runs and once the home lives on it
      (this engine is a linked desktop, or its home carries the moved
      marker): replacing the server is the way to retire it.

  One job of the kind runs at a time (`busy` otherwise). A create's refusal
  is kept in the ledger, so the summary and `home.provision.resources` say
  it after the job is gone; a refusal for the token marks it refused.

  The view: `state` (`none`, `connected`, `creating`, `created`, `deleting`,
  `gone`, `failed`, `unreadable`, as `Ledger.state/1`), `token` (`none`,
  `accepted`, `refused`), `server` (or null), `failure` (`{reason, sentence,
  next_location, at}` or null), `resources` (every resource the ledger
  holds: `{kind, name, id, status}`), and from `home.provision.resources`
  `checked` (whether Hetzner was read just now) and `sentence` (why not, or
  null). The token never leaves the ledger.

  Test seams in `opts`: `:home`, `:engine_role`, `:profile`, `:host` (the
  host module), `:host_opts` (the host's own seams), `:jobs`, `:open_code`
  and `:withdraw_code` (in place of the rail's provisioned window).
  """

  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Link
  alias FermixCore.Home.Move
  alias FermixCore.Home.Moved
  alias FermixCore.Home.Provision
  alias FermixCore.Home.Provision.Hetzner
  alias FermixCore.Home.Provision.Ledger
  alias FermixCore.Home.Role
  alias FermixCore.Management.Jobs
  alias FermixCore.Setup.ConfigStore

  require Logger

  @capability "home"
  @kind :home_provision
  @token_pattern ~r/\A[!-~]{16,512}\z/
  @type_pattern ~r/\A[a-z0-9][a-z0-9-]{0,31}\z/
  @owner_sentence "Only the owner can give Fermix a Hetzner token or create, restart or " <>
                    "delete its server: use the Fermix app."
  @token_shape_sentence "Paste the API token exactly as Hetzner shows it."
  @no_offer_sentence "Hetzner has no server type with 4 GB in stock in Falkenstein, " <>
                       "Nuremberg or Helsinki right now."

  @doc """
  The sentence `daemon.sock` answers when a process Fermix started (or one it
  cannot place) asks to create, power or delete the server: the owner's
  decisions.
  """
  @spec owner_only_sentence() :: String.t()
  def owner_only_sentence, do: @owner_sentence

  @doc "The capability a refusal of this family names."
  @spec capability() :: String.t()
  def capability, do: @capability

  @doc "The job kind a create, a power action and a delete run as."
  @spec job_kind() :: atom()
  def job_kind, do: @kind

  @doc "`home.provision.connect`."
  @spec connect(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def connect(token, opts \\ []) when is_list(opts) do
    with {:ok, token} <- token_param(token) do
      case host(opts).check_token(token, host_opts(opts)) do
        {:ok, %{other_servers: others?}} ->
          with :ok <- same_project(token, opts), do: keep_token(token, others?, opts)

        {:error, :unauthorized} ->
          {:error, {:invalid_params, "token", Provision.error_sentence(:token_invalid)}}

        {:error, reason} ->
          refused(reason, opts)
      end
    end
  end

  # A token that replaces another must reach what the ledger holds.
  defp same_project(token, opts) do
    with {:ok, ledger} <- ledger(opts) do
      case host(opts).reaches(token, ledger, host_opts(opts)) do
        :ok ->
          :ok

        {:error, :other_project} ->
          {:error, {:invalid_params, "token", Provision.error_sentence(:other_project)}}

        {:error, reason} ->
          refused(reason, opts)
      end
    end
  end

  defp ledger(opts) do
    case Ledger.read(home(opts), host(opts).host()) do
      {:ok, ledger} -> {:ok, ledger}
      {:error, reason} -> refused({:ledger, reason}, opts)
    end
  end

  defp keep_token(token, others?, opts) do
    case Ledger.update(
           home(opts),
           host(opts).host(),
           &{:ok, Ledger.connect(&1, token, now(opts))}
         ) do
      {:ok, _ledger} -> {:ok, Map.put(view(home(opts), opts), "other_servers", others?)}
      {:error, reason} -> refused({:ledger, reason}, opts)
    end
  end

  defp token_param(token) when is_binary(token) do
    if Regex.match?(@token_pattern, token),
      do: {:ok, token},
      else: {:error, {:invalid_params, "token", @token_shape_sentence}}
  end

  defp token_param(_token), do: {:error, {:invalid_params, "token", @token_shape_sentence}}

  @doc "`home.provision.options`."
  @spec options(keyword()) :: {:ok, map()} | {:error, term()}
  def options(opts \\ []) when is_list(opts) do
    with {:ok, token} <- stored_token(opts) do
      case host(opts).options(token, host_opts(opts)) do
        {:ok, options} -> {:ok, Map.put(options, "sentence", recommendation(options))}
        {:error, reason} -> refused(reason, opts)
      end
    end
  end

  defp recommendation(%{"recommended" => nil}), do: @no_offer_sentence

  defp recommendation(%{"recommended" => %{"type" => type, "location" => location}} = options) do
    offer = Enum.find(options["offers"], &(&1["type"] == type and &1["location"] == location))
    city = Enum.find_value(options["locations"], location, &(&1["id"] == location && &1["city"]))

    "Recommended: #{offer["description"]} in #{city}, " <>
      "#{price(options["currency"], offer["total_monthly"])} a month."
  end

  # Whole units, as a person reads a monthly price; Details has the cents.
  defp price(currency, total) do
    [units, cents] = String.split(total, ".")
    rounded = String.to_integer(units) + if(String.to_integer(cents) >= 50, do: 1, else: 0)

    case currency do
      "EUR" -> "€#{rounded}"
      "USD" -> "$#{rounded}"
      other -> "#{other} #{rounded}"
    end
  end

  @doc "`home.provision.create`: starts the job that creates the server."
  @spec create(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(params, opts \\ []) when is_map(params) and is_list(opts) do
    with {:ok, request} <- create_params(params, opts),
         :ok <- primary(role(opts)),
         {:ok, _token} <- stored_token(opts),
         :ok <- no_server(opts) do
      start(opts, fn report -> run_create(request, report, opts) end)
    end
  end

  defp create_params(params, opts) do
    with :ok <- known_params(params, ~w(type location)),
         {:ok, type} <- matching(params, "type", @type_pattern),
         {:ok, location} <- location(params) do
      {:ok, %{type: type, location: location, profile: profile(opts)}}
    end
  end

  defp location(%{"location" => location}) when is_binary(location) do
    if location in Hetzner.locations(),
      do: {:ok, location},
      else: invalid("location", "Fermix creates a server in Falkenstein, Nuremberg or Helsinki.")
  end

  defp location(_params),
    do: invalid("location", "Fermix creates a server in Falkenstein, Nuremberg or Helsinki.")

  defp no_server(opts) do
    case Ledger.read(home(opts), host(opts).host()) do
      {:ok, %{server: %{status: status}}} when status != :gone -> refusal(:server_exists)
      {:ok, _ledger} -> :ok
      {:error, reason} -> refused({:ledger, reason}, opts)
    end
  end

  defp run_create(request, report, opts) do
    case host(opts).create(home(opts), request, run_opts(report, opts)) do
      {:ok, server} ->
        {:ok, %{"server" => server.name, "type" => server.type, "location" => server.location}}

      {:error, reason} ->
        job_failure(remembered(reason, opts), opts)
    end
  end

  # A create's refusal stays in the ledger, for the summary; one for the
  # token marks it refused.
  defp remembered(reason, _opts) when reason in [:server_exists, :no_token], do: reason

  defp remembered(reason, opts) do
    reason = token_reason(reason, opts)

    failure = %{
      reason: Provision.failure_word(reason),
      sentence: Provision.error_sentence(reason),
      next_location: next_location(reason),
      at: now(opts)
    }

    case Ledger.update(home(opts), host(opts).host(), &{:ok, Ledger.put_failure(&1, failure)}) do
      {:ok, _ledger} -> reason
      {:error, why} -> log_unkept(why, reason)
    end
  end

  defp next_location({:unavailable, %{next: next}}), do: next
  defp next_location(_reason), do: nil

  defp log_unkept(why, reason) do
    Logger.error("provision: the create's refusal could not be kept: #{inspect(why)}")
    reason
  end

  @doc "`home.provision.power`: starts the job that turns the server on or restarts it."
  @spec power(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def power(params, opts \\ []) when is_map(params) and is_list(opts) do
    with :ok <- known_params(params, ~w(action)),
         {:ok, action} <- power_action(params),
         {:ok, _token} <- stored_token(opts),
         :ok <- has_server(opts) do
      start(opts, fn report -> run_power(action, report, opts) end)
    end
  end

  defp power_action(%{"action" => "on"}), do: {:ok, :on}
  defp power_action(%{"action" => "reset"}), do: {:ok, :reset}
  defp power_action(_params), do: invalid("action", "Turn the server on, or reset it.")

  defp has_server(opts) do
    case Ledger.read(home(opts), host(opts).host()) do
      {:ok, %{server: %{status: :created, id: id}}} when is_integer(id) -> :ok
      {:ok, _ledger} -> refusal(:no_server)
      {:error, reason} -> refused({:ledger, reason}, opts)
    end
  end

  defp run_power(action, report, opts) do
    case host(opts).power(home(opts), action, run_opts(report, opts)) do
      :ok -> {:ok, %{"action" => Atom.to_string(action)}}
      {:error, reason} -> job_failure(token_reason(reason, opts), opts)
    end
  end

  @doc "`home.provision.resources`: the ledger, read back from Hetzner."
  @spec resources(keyword()) :: {:ok, map()}
  def resources(opts \\ []) when is_list(opts) do
    home = home(opts)

    case Ledger.read(home, host(opts).host()) do
      {:ok, %{token: nil}} -> {:ok, checked(view(home, opts), false, nil)}
      {:ok, _ledger} -> {:ok, reconciled(home, opts)}
      {:error, _reason} -> {:ok, checked(view(home, opts), false, nil)}
    end
  end

  defp reconciled(home, opts) do
    case host(opts).reconcile(
           home,
           Keyword.put(host_opts(opts), :running?, running?(opts)) ++ code_opts(opts)
         ) do
      {:ok, _ledger} ->
        checked(view(home, opts), true, nil)

      {:error, reason} ->
        reason = token_reason(reason, opts)
        checked(view(home, opts), false, Provision.error_sentence(reason))
    end
  end

  defp checked(view, checked?, sentence),
    do: Map.merge(view, %{"checked" => checked?, "sentence" => sentence || view["sentence"]})

  @doc "`home.provision.delete`: starts the job that deletes what Fermix created."
  @spec delete(keyword()) :: {:ok, map()} | {:error, term()}
  def delete(opts \\ []) when is_list(opts) do
    with :ok <- not_the_live_home(home(opts), role(opts)),
         {:ok, _token} <- stored_token(opts),
         :ok <- something(opts) do
      start(opts, fn report -> run_delete(report, opts) end)
    end
  end

  # The server the home moved to holds it (this engine is its linked
  # desktop, or this home is retired); a move to it under way is refused too.
  defp not_the_live_home(home, record) do
    cond do
      Move.moving_to(home) != :none -> refusal(:move_under_way)
      DesktopLink.linked?(record, home) -> refusal(:live_home)
      Moved.read(home) != :absent -> refusal(:live_home)
      true -> :ok
    end
  end

  defp something(opts) do
    case Ledger.read(home(opts), host(opts).host()) do
      {:ok, %{server: nil, firewall: nil, primary_ips: [], ref: nil}} ->
        refusal(:nothing_to_delete)

      {:ok, _ledger} ->
        :ok

      {:error, reason} ->
        refused({:ledger, reason}, opts)
    end
  end

  defp run_delete(report, opts) do
    case host(opts).delete(home(opts), run_opts(report, opts)) do
      :ok -> {:ok, %{"deleted" => true}}
      {:error, reason} -> job_failure(token_reason(reason, opts), opts)
    end
  end

  # -- the view -----------------------------------------------------------------

  @doc """
  The family's view of the ledger under `home`: the state, the token's
  standing, the server, the failure and every resource. Never the token.
  """
  @spec view(Path.t(), keyword()) :: map()
  def view(home, opts \\ []) when is_binary(home) and is_list(opts) do
    state = Ledger.state(home, host(opts).host())

    resources =
      case Ledger.read(home, host(opts).host()) do
        {:ok, ledger} -> resource_views(ledger)
        {:error, _reason} -> []
      end

    %{
      "state" => Atom.to_string(state.state),
      "token" => Atom.to_string(state.token),
      "server" => state.server && server_view(state.server),
      "failure" => state.failure && failure_view(state.failure),
      "resources" => resources,
      "sentence" => state.sentence
    }
  end

  defp server_view(server) do
    %{
      "name" => server.name,
      "type" => server.type,
      "location" => server.location,
      "status" => Atom.to_string(server.status),
      "power" => server.power,
      "ipv4" => server.ipv4,
      "created_at" => iso(server.created_at),
      "seen_at" => iso(server.seen_at)
    }
  end

  defp failure_view(failure) do
    %{
      "reason" => failure.reason,
      "sentence" => failure.sentence,
      "next_location" => failure.next_location,
      "at" => iso(failure.at)
    }
  end

  defp resource_views(ledger) do
    server = ledger.server && [resource("server", ledger.server.name, ledger.server)]
    firewall = ledger.firewall && [resource("firewall", ledger.firewall.name, ledger.firewall)]

    ips =
      for ip <- ledger.primary_ips,
          do: %{"kind" => "primary_ip", "name" => ip.ip, "id" => ip.id, "status" => "created"}

    (server || []) ++ (firewall || []) ++ ips
  end

  defp resource(kind, name, %{id: id, status: status}),
    do: %{"kind" => kind, "name" => name, "id" => id, "status" => Atom.to_string(status)}

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)

  # -- jobs -----------------------------------------------------------------------

  defp start(opts, run) do
    started =
      Jobs.start(
        @kind,
        Keyword.merge(Keyword.get(opts, :jobs, []),
          name: host(opts).host(),
          run: fn _job_id, report -> run.(&report.({:phase, &1})) end
        )
      )

    case started do
      {:ok, view} -> {:ok, view}
      {:error, :busy} -> {:error, {:busy, Atom.to_string(@kind)}}
    end
  end

  defp running?(opts) do
    {:ok, views} = Jobs.list(Keyword.get(opts, :jobs, []))
    kind = Atom.to_string(@kind)
    Enum.any?(views, &(&1["kind"] == kind and &1["status"] == "running"))
  end

  defp run_opts(report, opts), do: host_opts(opts) ++ [report: report] ++ code_opts(opts)

  defp code_opts(opts) do
    [
      open_code: Keyword.get(opts, :open_code, &open_code/0),
      withdraw_code:
        Keyword.get(opts, :withdraw_code, fn -> Link.impl().withdraw_enrollment() end)
    ]
  end

  defp open_code do
    case Link.impl().open_enrollment(:provisioned) do
      {:ok, %{code: code}} -> {:ok, code}
      {:error, {:unavailable, sentence}} -> {:error, sentence}
    end
  end

  # A host that answered, or could not be reached, refused; anything the
  # engine itself could not do is unavailable.
  defp job_failure(reason, _opts) do
    code = if unavailable_reason?(reason), do: :unavailable, else: :refused
    {:error, {code, Provision.error_sentence(reason)}}
  end

  defp unavailable_reason?({kind, _detail})
       when kind in [:unreachable, :rate_limited, :action_timeout, :code_unavailable, :ledger],
       do: true

  defp unavailable_reason?(_reason), do: false

  # Hetzner refusing the token after it accepted it: the token stopped working.
  defp token_reason(:unauthorized, opts) do
    case Ledger.update(home(opts), host(opts).host(), &token_refused/1) do
      {:ok, _ledger} -> :token_refused
      {:error, why} -> log_unkept(why, :token_refused)
    end
  end

  defp token_reason(reason, _opts), do: reason

  defp token_refused(%{token: nil}), do: {:error, :no_token}
  defp token_refused(ledger), do: {:ok, Ledger.token_refused(ledger)}

  # -- refusals and seams -------------------------------------------------------

  defp refused(reason, opts) do
    reason = token_reason(reason, opts)
    Logger.warning("provision: refused (#{Provision.failure_word(reason)})")
    refusal(reason)
  end

  defp refusal(reason),
    do: {:error, {:unavailable, @capability, Provision.error_sentence(reason)}}

  defp stored_token(opts) do
    case Ledger.read(home(opts), host(opts).host()) do
      {:ok, %{token: token}} when is_binary(token) -> {:ok, token}
      {:ok, _ledger} -> refusal(:no_token)
      {:error, reason} -> refused({:ledger, reason}, opts)
    end
  end

  defp primary(%{role: :primary}), do: :ok
  defp primary(_record), do: refusal(:not_primary)

  defp known_params(params, allowed) do
    case Enum.find(Map.keys(params), &(&1 not in allowed)) do
      nil -> :ok
      field -> invalid(field, "Fermix does not take #{field} here.")
    end
  end

  defp matching(params, field, pattern) do
    value = Map.get(params, field)

    if is_binary(value) and Regex.match?(pattern, value),
      do: {:ok, value},
      else: invalid(field, "Choose one of the server types Fermix offers.")
  end

  defp invalid(field, sentence), do: {:error, {:invalid_params, field, sentence}}

  defp host(opts), do: Keyword.get(opts, :host, Hetzner)
  defp host_opts(opts), do: Keyword.get(opts, :host_opts, [])
  defp home(opts), do: Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)
  defp role(opts), do: Keyword.get_lazy(opts, :engine_role, &Role.recorded/0)

  defp now(opts),
    do: DateTime.truncate(Keyword.get(host_opts(opts), :now, &DateTime.utc_now/0).(), :second)

  defp profile(opts) do
    Keyword.get_lazy(opts, :profile, fn ->
      case Application.get_env(:fermix_core, :profile) do
        profile when is_binary(profile) and profile != "" -> profile
        _unset -> "general"
      end
    end)
  end
end
