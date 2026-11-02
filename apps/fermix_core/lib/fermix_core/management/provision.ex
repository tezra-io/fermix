defmodule FermixCore.Management.Provision do
  @moduledoc """
  Fermix creates the owner's Always On server on a cloud provider (M75 lean
  v1 §4.3; `FermixCore.Home.Provision`, the contract; `Provision.Registry`,
  the providers, one today) from an API token pasted once. Nothing here names
  a provider: each one's words come from its display data, and its refusals
  arrive as the contract's shared kinds.

  Everything here is answered on the computer that created the server
  (`Management.Placement`: a linked desktop answers it itself and never
  sends it to the server), since the tokens and the ledgers
  (`Home.Provision.Ledger`, `device/provision/<id>.json`, one per provider)
  stay there. One method is on the wire, `home.provision.options`; the rest
  are Always On's steps, which `Management.AlwaysOn.act/2` (`home.act`)
  runs:

    * `connect/2` (`paste_token`) checks the token with that provider and
      keeps it in that provider's ledger; one the provider refuses is
      `invalid_params` on `token` with its sentence. While that ledger holds
      a server or firewall that is not gone, a new token replaces the old
      only when it reaches it (`reaches/3`, the same account), so a token that
      stopped working is replaced and one for another account is refused,
      also on `token`. Answers that provider's view (below) and
      `other_servers` (the account holds servers Fermix did not create).
    * `options/1` (`home.provision.options`, no params) reads what the
      provider in use (`Provision.current/2`) sells, live: the orderable
      types per location, with their monthly prices as the account is
      billed, the L2 recommendation, "more room", the recommendation in one
      `sentence`, each offer's `label` and `price` in `Management.Copy`'s
      words, and that `provider` (`{id, name}`) for display; refused
      until the provider in use holds a token.
    * `start_create/2` (`create_server`, `create_in`, `replace_server`)
      starts a job, kind `home_provision`, that creates the firewall and the
      server of the size and place the owner was shown, the 24-hour
      enrollment code inside. Refused while any provider
      holds a server Fermix created. On the primary only, unless `replace`:
      then on the linked desktop whose ledger of that provider holds the
      server the home lives on, which asks that server over the link for the
      code (`home.enroll.open {kind: provisioned}`, rail-only) and keeps both
      servers in the ledger (`Ledger.begin_replace/3`), the old one holding
      the home until the move to the new one is done.
    * `start_again/2` (`start_again`): one job that deletes what stands and
      creates the server again.
    * `power/2` (`turn_on`, `restart_server`), `on` or `reset`, a job of the
      same kind.
    * `delete/1` (`delete_server`, `cancel`) deletes the server, its
      addresses unless they went with it, and the firewall, as a job; it is
      refused while a move to the server runs and once the home lives on it
      (this engine is a linked desktop, or its home carries the moved
      marker): replacing the server is the way to retire it. During a replace
      it deletes what does not hold the home: the new server before the move
      (Cancel, which closes its code on the old server and gives the ledger
      back the old one), or the old server after it (when deleting it
      failed); while the move runs, nothing. `stop_step/1` cancels a step's
      job first, answering once its run has stopped.

  These act on the provider Always On speaks of (`Provision.current/2`): the
  one Fermix created something on, else the one whose token was given last,
  else the first the registry offers.

  After a replace's move: the desktop's `home.act` records that it started
  the move to the new server (`move_forwarded/3`, once the server answered
  its `home.move.start`), and the desktop relay reports every primary epoch it
  reaches (`primary_reached/2`). Once that is above the epoch the old server
  held, the move to the new one is done: this desktop's link names the new
  server from then on (`Home.Link`'s `rename_primary/1`), and the old server
  is deleted, once, as a job of the same kind (`Provision.Driver.delete_replaced/3`); a failed delete
  stays in the ledger with its sentence, and Delete your old server tries it
  again. The old server answering again at its own epoch after the move
  started means it undid the move: the replace waits for its move again.

  One job of the kind runs at a time (`busy` otherwise). A create's refusal
  is kept in the ledger, so the summary says it after the job is gone; a
  refusal for the token marks it refused.

  **A step and its ending** (Always On setup §5). The step a job runs is
  named in the ledger before the job starts (`put_action/2`, which
  `Management.AlwaysOn.act/2` writes ahead of `Jobs.start`), and the end of
  every create, power and delete job clears it (`clear_action/1` for a step
  that never started its job). Every ending lands in the ledger: a create's,
  a power action's and a delete's failure, with the step, the server's size
  and place, except a refusal of the token, which marks the token. A
  create's size and place are the owner's, kept on the step's action before
  its job starts; the job reads the live offer first, whose price the server
  is written with. At boot
  a step left with no job, since jobs live in memory, becomes the failure
  `interrupted` (`interrupt_left_actions/1`). `start_reconcile/1` reads the
  ledger back from the provider as a job of the same kind, named by the
  provider, so it never runs beside a step; `home.status` starts it when the
  ledger was last checked over a minute ago.

  The view: `provider` (the provider's id), `state` (`none`, `connected`,
  `creating`, `created`, `deleting`, `gone`, `failed`, `unreadable`, as
  `Ledger.state/3`), `token` (`none`, `accepted`, `refused`), `server` (or
  null), `failure` (`{reason, sentence, next_location, at}` or null),
  `replace` (null, or `{state, current, old, failure}` as `Ledger.state/3`'s),
  `resources` (every resource the ledger holds: `{kind, name, id, status,
  replaced}`, `id` the provider's own as a string, `replaced` true for the
  old server's) and `sentence`. The token never leaves the ledger.

  Test seams in `opts`: `:home`, `:engine_role`, `:profile`, `:providers` (in
  place of `Provision.Registry.all/0`), `:provider_opts` (the providers' own
  seams), `:jobs`, `:open_code` and `:withdraw_code` (in place of the rail's
  provisioned window), and `:primary_forward`, the daemon's way to the server
  on a linked desktop, and `:rename_primary` (in place of the rail's, given
  the new server's name).
  """

  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Link
  alias FermixCore.Home.Move
  alias FermixCore.Home.Moved
  alias FermixCore.Home.Provision
  alias FermixCore.Home.Provision.Driver
  alias FermixCore.Home.Provision.Ledger
  alias FermixCore.Home.Provision.Registry
  alias FermixCore.Home.Role
  alias FermixCore.Management.Copy
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.Protocol
  alias FermixCore.Setup.ConfigStore

  require Logger

  @capability "home"
  @kind :home_provision
  @token_pattern ~r/\A[!-~]{16,512}\z/
  @type_pattern ~r/\A[a-z0-9][a-z0-9-]{0,31}\z/
  @provider_sentence "Choose one of the providers Fermix creates a server on."
  # What `Ledger.begin_replace/3` refuses, each a reason with its sentence.
  @replace_refusals [:replacement_exists, :replace_moving, :old_server_remains, :not_primary]

  @doc "The job kind a create, a power action and a delete run as."
  @spec job_kind() :: atom()
  def job_kind, do: @kind

  @doc """
  Writes, under the ledger's lock, that a step's job is about to start on
  the provider Always On speaks of: `kind` (one of
  `Home.Provision.Ledger.action_kinds/0`), from now. Refused `busy` while
  another step's action stands; the job's end clears it.
  """
  @spec put_action(String.t(), keyword()) :: :ok | {:error, term()}
  def put_action(kind, opts \\ []) when is_binary(kind) and is_list(opts) do
    provider = current(opts)

    case Ledger.update(home(opts), provider.id(), &Ledger.put_action(&1, kind, now(opts))) do
      {:ok, _ledger} -> :ok
      {:error, :busy} -> {:error, {:busy, Atom.to_string(@kind)}}
      {:error, reason} -> refused({:ledger, reason}, provider, opts)
    end
  end

  @doc """
  Clears the step's action on the provider Always On speaks of, for a step
  whose job never started (its start was refused); `:ok` when none stands.
  """
  @spec clear_action(keyword()) :: :ok | {:error, term()}
  def clear_action(opts \\ []) when is_list(opts) do
    provider = current(opts)

    case Ledger.update(home(opts), provider.id(), &Ledger.clear_action/1) do
      {:ok, _ledger} -> :ok
      {:error, :no_action} -> :ok
      {:error, reason} -> refused({:ledger, reason}, provider, opts)
    end
  end

  @doc """
  Whether the ledger of the provider Always On speaks of holds anything
  Fermix created or was creating, or a replace (`Ledger.holding?/1`): what a
  cancelled create leaves for the delete.
  """
  @spec holding(keyword()) :: {:ok, boolean()} | {:error, term()}
  def holding(opts \\ []) when is_list(opts) do
    provider = current(opts)
    with {:ok, ledger} <- ledger(provider, opts), do: {:ok, Ledger.holding?(ledger)}
  end

  @doc """
  Cancels the family's running job (a step's, or a read of the provider) and
  answers once its run has stopped (`Jobs.cancel/2`), so a step started
  after it never runs beside it. One that ended between the listing and the
  cancel has stopped already.
  """
  @spec stop_step(keyword()) :: :ok
  def stop_step(opts \\ []) when is_list(opts) do
    jobs = Keyword.get(opts, :jobs, [])
    {:ok, views} = Jobs.list(jobs)
    kind = Atom.to_string(@kind)

    for %{"kind" => ^kind, "status" => "running", "job_id" => id} <- views do
      case Jobs.cancel(id, jobs) do
        {:ok, _view} -> :ok
        {:error, :unknown_job} -> :ok
      end
    end

    :ok
  end

  @doc """
  At boot: on every provider, a step left standing with no job (jobs live
  in memory, so a restart ends every one) becomes the failure `interrupted`,
  keeping the step and its size and place, so the summary offers what
  starts it again. Each is logged; a ledger that cannot be read or written
  is logged and left as it is.
  """
  @spec interrupt_left_actions(keyword()) :: :ok
  def interrupt_left_actions(opts \\ []) when is_list(opts),
    do: Enum.each(providers_of(opts), &interrupt_left(&1, opts))

  @doc """
  The supervision child that runs `interrupt_left_actions/1` once, before
  the job family and the socket start, so no step written after the boot is
  taken for one the restart left; it starts no process.
  """
  @spec interrupt_at_boot() :: :ignore
  def interrupt_at_boot do
    :ok = interrupt_left_actions()
    :ignore
  end

  defp interrupt_left(provider, opts) do
    case Ledger.update(home(opts), provider.id(), &Ledger.interrupt(&1, provider, now(opts))) do
      {:ok, ledger} ->
        Logger.warning(
          "provision: the #{ledger.failure.action} step on #{provider.id()} stopped with " <>
            "the engine; it is kept as interrupted"
        )

      {:error, :no_action} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "provision: a step the last run left on #{provider.id()} could not be kept as " <>
            "interrupted: #{inspect(reason)}"
        )
    end
  end

  @doc "`paste_token`'s step: checks the token and keeps it (the moduledoc)."
  @spec connect(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def connect(params, opts \\ []) when is_map(params) and is_list(opts) do
    with {:ok, provider} <- provider_param(params, opts),
         {:ok, token} <- token_param(params, provider),
         {:ok, others?} <- accepted(provider, token, opts),
         :ok <- same_project(provider, token, opts) do
      keep_token(provider, token, others?, opts)
    end
  end

  defp accepted(provider, token, opts) do
    case provider.check_token(token, provider_opts(opts)) do
      {:ok, %{other_servers: others?}} ->
        {:ok, others?}

      {:error, :unauthorized} ->
        {:error, {:invalid_params, "token", Provision.error_sentence(:token_invalid, provider)}}

      {:error, reason} ->
        refused(reason, provider, opts)
    end
  end

  # A token that replaces another must reach what the ledger holds.
  defp same_project(provider, token, opts) do
    with {:ok, ledger} <- ledger(provider, opts) do
      case Driver.reaches(provider, token, ledger, provider_opts(opts)) do
        :ok ->
          :ok

        {:error, :other_project} ->
          {:error, {:invalid_params, "token", Provision.error_sentence(:other_project, provider)}}

        {:error, reason} ->
          refused(reason, provider, opts)
      end
    end
  end

  defp ledger(provider, opts) do
    case Ledger.read(home(opts), provider.id()) do
      {:ok, ledger} -> {:ok, ledger}
      {:error, reason} -> refused({:ledger, reason}, provider, opts)
    end
  end

  defp keep_token(provider, token, others?, opts) do
    change = &{:ok, &1 |> Ledger.connect(token, now(opts)) |> Ledger.token_replaced(provider)}

    case Ledger.update(home(opts), provider.id(), change) do
      {:ok, _ledger} ->
        {:ok, Map.put(provider_ledger_view(home(opts), provider), "other_servers", others?)}

      {:error, reason} ->
        refused({:ledger, reason}, provider, opts)
    end
  end

  defp token_param(%{"token" => token}, provider) when is_binary(token) do
    if Regex.match?(@token_pattern, token),
      do: {:ok, token},
      else: token_shape(provider)
  end

  defp token_param(_params, provider), do: token_shape(provider)

  defp token_shape(provider),
    do: invalid("token", "Paste the API token exactly as #{provider.display().name} shows it.")

  # The provider a call names: one the registry offers.
  defp provider_param(%{"provider" => id}, opts) do
    case Provision.provider(providers_of(opts), id) do
      {:ok, provider} -> {:ok, provider}
      :error -> invalid("provider", @provider_sentence)
    end
  end

  defp provider_param(_params, _opts), do: invalid("provider", @provider_sentence)

  @doc """
  `home.provision.options`: what the provider in use sells now (the
  moduledoc), with that provider's id and name.
  """
  @spec options(keyword()) :: {:ok, map()} | {:error, term()}
  def options(opts \\ []) when is_list(opts) do
    provider = current(opts)

    with {:ok, token} <- stored_token(provider, opts) do
      case Driver.options(provider, token, provider_opts(opts)) do
        {:ok, options} -> {:ok, offers(options, provider)}
        {:error, reason} -> refused(reason, provider, opts)
      end
    end
  end

  defp offers(options, provider) do
    Map.merge(options, %{
      "offers" => Enum.map(options["offers"], &worded(&1, options["currency"])),
      "sentence" => recommendation(options, provider),
      "provider" => %{"id" => provider.id(), "name" => provider.display().name}
    })
  end

  # Each offer's size and price in the engine's words, drawn as sent.
  defp worded(offer, currency) do
    Map.merge(offer, %{
      "label" => Copy.offer_label(offer),
      "price" => Copy.offer_price(offer["total_monthly"], currency)
    })
  end

  defp recommendation(%{"recommended" => nil}, provider),
    do:
      "#{provider.display().name} has no server type with 4 GB in stock in " <>
        "#{Provision.cities(provider)} right now."

  defp recommendation(
         %{"recommended" => %{"type" => type, "location" => location}} = options,
         _provider
       ) do
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

  @doc """
  Starts the create job on the provider Always On speaks of, which creates
  the firewall and the server, the 24-hour enrollment code inside: `type`
  and `location`, the offer the owner was shown (the recommendation is one
  like any other, and the job never makes one), kept on the step's action
  before the job starts; `replace` true to replace the server the home
  lives on. Refused by field when either is missing or not one Fermix
  offers; refused while any provider holds a server Fermix created, and on
  a linked desktop unless `replace`.
  """
  @spec start_create(
          %{type: String.t() | nil, location: String.t() | nil, replace: boolean()},
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def start_create(%{type: type, location: location, replace: replace?}, opts \\ [])
      when is_boolean(replace?) and is_list(opts) do
    provider = current(opts)

    with {:ok, choice} <- choice(type, location, provider),
         do: begin_create(provider, choice, replace?, opts)
  end

  @doc """
  Starts Start again's one job on the provider Always On speaks of: what the
  ledger holds is deleted first (the step's action, `create`, stays named
  while it runs, so the summary says the delete), then a server is created
  with the size and place of the one that stood, else of the failure the
  step answers, else of `type` and `location` (refused by field without
  them, as a create is); with `replace`, on the linked desktop whose ledger
  holds the server the home lives on. A delete that stops ends the job with
  its failure kept, as a delete's is.
  """
  @spec start_again(
          %{replace: boolean(), type: String.t() | nil, location: String.t() | nil},
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def start_again(%{replace: replace?, type: type, location: location}, opts \\ [])
      when is_boolean(replace?) and is_list(opts) do
    provider = current(opts)

    with {:ok, ledger} <- ledger(provider, opts),
         {:ok, _token} <- stored_token(provider, opts),
         {:ok, choice} <- again(ledger, type, location, provider),
         :ok <- keep_choice(provider, choice, opts) do
      request = Map.put(choice, :profile, profile(opts))

      start(
        provider,
        opts,
        fn report -> run_again(provider, replace?, request, report, opts) end,
        :clears_action
      )
    end
  end

  # The server's size and place, else the failure's, else the owner's.
  defp again(%{server: %{type: type, location: location}}, _type, _location, _provider)
       when is_binary(type) and is_binary(location),
       do: {:ok, %{type: type, location: location}}

  defp again(%{failure: %{type: type, location: location}}, _type, _location, _provider)
       when is_binary(type) and is_binary(location),
       do: {:ok, %{type: type, location: location}}

  defp again(_ledger, type, location, provider), do: choice(type, location, provider)

  defp run_again(provider, replace?, request, report, opts) do
    with {:ok, _deleted} <- cleared(provider, report, opts),
         {:ok, plan} <- again_plan(provider, replace?, opts),
         do: run_create(provider, plan, request, report, opts)
  end

  defp cleared(provider, report, opts) do
    case Ledger.read(home(opts), provider.id()) do
      {:ok, ledger} ->
        if Ledger.holding?(ledger),
          do: run_delete(provider, :current, report, opts),
          else: {:ok, %{"deleted" => false}}

      {:error, reason} ->
        job_failure({:ledger, reason}, provider)
    end
  end

  # What the create checks before it starts, once what stood is gone.
  defp again_plan(provider, replace?, opts) do
    case create_plan(provider, replace?, opts) do
      {:ok, plan} -> {:ok, plan}
      {:error, {:unavailable, _capability, sentence}} -> {:error, {:refused, sentence}}
    end
  end

  defp begin_create(provider, choice, replace?, opts) do
    request = Map.put(choice, :profile, profile(opts))

    with {:ok, plan} <- create_plan(provider, replace?, opts),
         :ok <- keep_choice(provider, choice, opts) do
      start(
        provider,
        opts,
        fn report -> run_create(provider, plan, request, report, opts) end,
        :clears_action
      )
    end
  end

  # The size and place the owner was shown: both.
  defp choice(type, location, provider) do
    with {:ok, type} <- matching(%{"type" => type}, "type", @type_pattern),
         {:ok, location} <- location(%{"location" => location}, provider),
         do: {:ok, %{type: type, location: location}}
  end

  # A server is created on the primary, and replaced from the linked desktop
  # whose ledger holds the server the home lives on.
  defp create_plan(provider, false, opts) do
    with :ok <- creating_here(provider, opts),
         {:ok, _token} <- stored_token(provider, opts),
         :ok <- no_server(provider, opts),
         do: {:ok, :create}
  end

  defp create_plan(provider, true, opts) do
    with :ok <- replacing_here(provider, opts),
         {:ok, _token} <- stored_token(provider, opts),
         {:ok, from_epoch} <- replaceable(provider, opts),
         do: {:ok, {:replace, from_epoch}}
  end

  defp creating_here(provider, opts) do
    cond do
      primary?(role(opts)) -> :ok
      not DesktopLink.linked?(role(opts), home(opts)) -> refusal(:not_primary, provider)
      holds_nothing?(provider, opts) -> refusal(:not_primary, provider)
      true -> refusal(:replace_only, provider)
    end
  end

  defp holds_nothing?(provider, opts) do
    case Ledger.read(home(opts), provider.id()) do
      {:ok, ledger} -> Ledger.replacing(ledger) == {:error, :not_primary}
      {:error, _reason} -> true
    end
  end

  defp replacing_here(provider, opts) do
    cond do
      primary?(role(opts)) -> refusal(:nothing_to_replace, provider)
      DesktopLink.linked?(role(opts), home(opts)) -> :ok
      true -> refusal(:not_primary, provider)
    end
  end

  # The primary epoch the old server holds: this desktop's highest seen, since
  # it reaches that server now.
  defp replaceable(provider, opts) do
    with {:ok, ledger} <- ledger(provider, opts) do
      case Ledger.replacing(ledger) do
        :begin -> held_epoch(provider, opts)
        :continue -> {:ok, ledger.replace.from_epoch}
        {:error, reason} -> refusal(reason, provider)
      end
    end
  end

  defp held_epoch(provider, opts) do
    case DesktopLink.read(home(opts)) do
      {:ok, %{epoch: epoch}} ->
        {:ok, epoch}

      {:error, reason} ->
        Logger.error("provision: the desktop link could not be read: #{inspect(reason)}")
        refusal(:no_link, provider)
    end
  end

  defp location(%{"location" => location}, provider) when is_binary(location) do
    if location in Provision.location_ids(provider),
      do: {:ok, location},
      else: location_refused(provider)
  end

  defp location(_params, provider), do: location_refused(provider)

  defp location_refused(provider),
    do: invalid("location", "Fermix creates a server in #{Provision.cities(provider)}.")

  # Fermix creates on one provider at a time: a server any provider's ledger
  # holds, or one it cannot read, comes first.
  defp no_server(provider, opts) do
    Enum.reduce_while(providers_of(opts), :ok, fn each, :ok ->
      case Ledger.read(home(opts), each.id()) do
        {:ok, %{server: %{status: status}}} when status != :gone ->
          {:halt, refusal(:server_exists, provider)}

        {:ok, _ledger} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, refused({:ledger, reason}, each, opts)}
      end
    end)
  end

  # The live offer prices the choice before the create writes anything of
  # its own.
  defp run_create(provider, plan, request, report, opts) do
    case priced(provider, request, opts) do
      {:ok, priced} -> run_plan(provider, plan, priced, report, opts)
      {:error, reason} -> create_failed(reason, provider, request, opts)
    end
  end

  defp priced(provider, request, opts) do
    with {:ok, token} <- job_token(provider, opts),
         {:ok, options} <- Driver.options(provider, token, provider_opts(opts)),
         do: offered(options, request)
  end

  # An offer the catalog does not hold now is priced at nothing: the create's
  # own check of the stock refuses it before anything is written.
  defp offered(options, %{type: type, location: location} = request) do
    offer = Enum.find(options["offers"], &(&1["type"] == type and &1["location"] == location))

    {:ok,
     Map.merge(request, %{
       total_monthly: offer && offer["total_monthly"],
       currency: offer && options["currency"]
     })}
  end

  defp job_token(provider, opts) do
    case Ledger.read(home(opts), provider.id()) do
      {:ok, %{token: token}} when is_binary(token) -> {:ok, token}
      {:ok, _ledger} -> {:error, :no_token}
      {:error, reason} -> {:error, {:ledger, reason}}
    end
  end

  # The step's action keeps the size and place before its job starts, so a
  # step that never ends keeps them for Start again; a create started with
  # no step named keeps them nowhere.
  defp keep_choice(provider, choice, opts) do
    case Ledger.update(home(opts), provider.id(), &chosen(&1, choice)) do
      {:ok, _ledger} -> :ok
      {:error, :no_action} -> :ok
      {:error, reason} -> refused({:ledger, reason}, provider, opts)
    end
  end

  defp chosen(%{action: nil}, _choice), do: {:error, :no_action}
  defp chosen(ledger, choice), do: {:ok, Ledger.choose(ledger, choice)}

  # The server a replace leaves is set aside first, so a refusal from here on
  # is the new server's.
  defp run_plan(provider, {:replace, from_epoch}, request, report, opts) do
    case Ledger.update(
           home(opts),
           provider.id(),
           &Ledger.begin_replace(&1, from_epoch, now(opts))
         ) do
      {:ok, _ledger} -> run_plan(provider, :create, request, report, opts)
      {:error, reason} when reason in @replace_refusals -> job_failure(reason, provider)
      {:error, reason} -> job_failure({:ledger, reason}, provider)
    end
  end

  defp run_plan(provider, :create, request, report, opts) do
    case Driver.create(provider, home(opts), request, run_opts(provider, report, opts)) do
      {:ok, server} ->
        {:ok, %{"server" => server.name, "type" => server.type, "location" => server.location}}

      {:error, reason} ->
        create_failed(reason, provider, request, opts)
    end
  end

  # A create's refusal is the failure its ending keeps (`ended/3`), with the
  # size and place it was for; one for the token marks it refused too. One
  # that found a server, or no token, kept nothing to say.
  defp create_failed(reason, provider, _request, _opts)
       when reason in [:server_exists, :no_token],
       do: job_failure(reason, provider)

  defp create_failed(reason, provider, request, opts) do
    reason = token_reason(reason, provider, opts)

    failure = %{
      reason: Provision.failure_word(reason),
      sentence: Provision.error_sentence(reason, provider),
      next_location: next_location(reason),
      at: now(opts),
      action: "create",
      type: request.type,
      location: request.location
    }

    step_failure(reason, provider, failure)
  end

  defp next_location({:unavailable, %{next: next}}), do: next
  defp next_location(_reason), do: nil

  defp log_unkept(why, reason) do
    Logger.error("provision: the create's refusal could not be kept: #{inspect(why)}")
    reason
  end

  @doc "Starts the job that turns the server on or restarts it (`turn_on`, `restart_server`)."
  @spec power(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def power(params, opts \\ []) when is_map(params) and is_list(opts) do
    provider = current(opts)

    with :ok <- known_params(params, ~w(action)),
         {:ok, action} <- power_action(params),
         {:ok, _token} <- stored_token(provider, opts),
         :ok <- has_server(provider, opts) do
      start(
        provider,
        opts,
        fn report -> run_power(provider, action, report, opts) end,
        :clears_action
      )
    end
  end

  defp power_action(%{"action" => "on"}), do: {:ok, :on}
  defp power_action(%{"action" => "reset"}), do: {:ok, :reset}
  defp power_action(_params), do: invalid("action", "Turn the server on, or reset it.")

  defp has_server(provider, opts) do
    case Ledger.read(home(opts), provider.id()) do
      {:ok, %{server: %{status: :created, id: id}}} when is_binary(id) -> :ok
      {:ok, _ledger} -> refusal(:no_server, provider)
      {:error, reason} -> refused({:ledger, reason}, provider, opts)
    end
  end

  defp run_power(provider, action, report, opts) do
    case Driver.power(provider, home(opts), action, run_opts(provider, report, opts)) do
      :ok ->
        {:ok, %{"action" => Atom.to_string(action)}}

      {:error, reason} ->
        step_failed(reason, power_step(action), provider, opts)
    end
  end

  defp power_step(:on), do: "power_on"
  defp power_step(:reset), do: "power_reset"

  @doc """
  Starts the job that deletes what Fermix created and does not hold the home
  (`delete_server`, `cancel`).
  """
  @spec delete(keyword()) :: {:ok, map()} | {:error, term()}
  def delete(opts \\ []) when is_list(opts) do
    provider = current(opts)

    with {:ok, ledger} <- ledger(provider, opts),
         {:ok, target} <- delete_target(ledger, provider, home(opts), role(opts)),
         {:ok, _token} <- stored_token(provider, opts),
         :ok <- something(ledger, provider) do
      start(
        provider,
        opts,
        fn report -> run_delete(provider, target, report, opts) end,
        :clears_action
      )
    end
  end

  # The server the home moved to holds it (this engine is its linked
  # desktop, or this home is retired); a move to it under way is refused too.
  defp delete_target(ledger, provider, home, record) do
    cond do
      Move.moving_to(home) != :none -> refusal(:move_under_way, provider)
      DesktopLink.linked?(record, home) -> not_holding(ledger, provider)
      Moved.read(home) != :absent -> not_holding(ledger, provider)
      true -> {:ok, :current}
    end
  end

  # On the computer the home left, only what does not hold it: the new server
  # before a replace's move (Cancel), the old one after it.
  defp not_holding(%{replace: %{deleted_at: %DateTime{}}}, provider),
    do: refusal(:live_home, provider)

  defp not_holding(%{replace: %{moved_at: %DateTime{}}}, _provider), do: {:ok, :replaced}

  defp not_holding(%{replace: %{move_started_at: %DateTime{}}}, provider),
    do: refusal(:move_under_way, provider)

  defp not_holding(%{replace: %{}}, _provider), do: {:ok, :current}
  defp not_holding(_ledger, provider), do: refusal(:live_home, provider)

  defp something(ledger, provider) do
    if Ledger.holding?(ledger), do: :ok, else: refusal(:nothing_to_delete, provider)
  end

  defp run_delete(provider, :current, report, opts) do
    case Driver.delete(provider, home(opts), run_opts(provider, report, opts)) do
      :ok -> {:ok, %{"deleted" => true}}
      {:error, reason} -> step_failed(reason, "delete", provider, opts)
    end
  end

  # A failed delete of the old server is kept with its sentence, for the
  # summary and for the owner's Delete, which tries it again.
  defp run_delete(provider, :replaced, report, opts) do
    case keep_replace_failure(provider, nil, opts) do
      {:ok, _ledger} -> delete_replaced(provider, report, opts)
      {:error, reason} -> job_failure({:ledger, reason}, provider)
    end
  end

  defp delete_replaced(provider, report, opts) do
    case Driver.delete_replaced(provider, home(opts), run_opts(provider, report, opts)) do
      :ok ->
        {:ok, %{"deleted" => true}}

      {:error, reason} ->
        reason = token_reason(reason, provider, opts)
        job_failure(old_server_kept(reason, provider, opts), provider)
    end
  end

  defp old_server_kept(reason, provider, opts) do
    failure = %{
      reason: Provision.failure_word(reason),
      sentence: Provision.error_sentence({:old_server, reason}, provider),
      next_location: nil,
      at: now(opts)
    }

    case keep_replace_failure(provider, failure, opts) do
      {:ok, _ledger} -> {:old_server, reason}
      {:error, why} -> log_unkept(why, {:old_server, reason})
    end
  end

  defp keep_replace_failure(provider, failure, opts),
    do:
      Ledger.update(
        home(opts),
        provider.id(),
        &{:ok, Ledger.put_replace_failure(&1, failure)}
      )

  # A power action or a delete that stopped is the failure its ending keeps,
  # with the step (and the server's size and place, `Ledger.end_step/2`),
  # unless the token's refusal, which marks the token, says it.
  defp step_failed(reason, step, provider, opts) do
    case token_reason(reason, provider, opts) do
      :token_refused ->
        job_failure(:token_refused, provider)

      reason ->
        failure = %{
          reason: Provision.failure_word(reason),
          sentence: Provision.error_sentence(reason, provider),
          next_location: nil,
          at: now(opts),
          action: step
        }

        step_failure(reason, provider, failure)
    end
  end

  # -- after a replace's move ---------------------------------------------------

  @doc """
  Records, after `home.act`'s Move now sent `home.move.start` with `params`
  (`Management.AlwaysOn`), that this desktop started the move to the new
  server of a replace, when
  the server answered `answer` with it started (or with it `unconfirmed`):
  `:recorded`, `:nothing` when no replace waits for its move or the move did
  not start, or why the ledger could not keep it (logged).
  """
  @spec move_forwarded(map(), Protocol.route_result(), keyword()) ::
          :recorded | :nothing | {:error, term()}
  def move_forwarded(params, answer, opts \\ []) when is_map(params) and is_list(opts) do
    case {started?(answer), params["candidate_id"]} do
      {true, candidate_id} when is_binary(candidate_id) -> record_move(candidate_id, opts)
      _not_started -> :nothing
    end
  end

  defp started?({:ok, _result}), do: true
  defp started?({:error, :unconfirmed, _details}), do: true
  defp started?(_answer), do: false

  defp record_move(candidate_id, opts) do
    case Ledger.update(
           home(opts),
           current(opts).id(),
           &Ledger.move_started(&1, candidate_id, now(opts))
         ) do
      {:ok, _ledger} -> :recorded
      {:error, :not_replacing} -> :nothing
      {:error, reason} -> unrecorded("the move to your new server", reason)
    end
  end

  @doc """
  The desktop relay reached its server at primary epoch `epoch`. When that
  is above the epoch the old server of a replace held, the move to the new
  one is done and the old server is deleted, as a `home_provision` job
  (`{:deleting, job}`; `{:error, {:busy, kind}}` while another runs, and the
  next time the relay reaches the server tries again); once its delete
  failed, never by itself. The old server answering again at its own epoch
  after the move started undid the move (`:undone`). Otherwise `:nothing`.
  """
  @spec primary_reached(pos_integer(), keyword()) ::
          :nothing | :undone | {:deleting, map()} | {:error, term()}
  def primary_reached(epoch, opts \\ [])
      when is_integer(epoch) and epoch > 0 and is_list(opts) do
    provider = current(opts)

    case Ledger.read(home(opts), provider.id()) do
      {:ok, ledger} -> reached(Ledger.replace_due(ledger, epoch), provider, epoch, opts)
      {:error, reason} -> unrecorded("what the server's epoch means for a replace", reason)
    end
  end

  defp reached(:none, _provider, _epoch, _opts), do: :nothing

  defp reached(:undone, provider, _epoch, opts) do
    case Ledger.update(home(opts), provider.id(), &Ledger.move_undone/1) do
      {:ok, _ledger} ->
        Logger.info("provision: your server answered again without the move; it waits again")
        :undone

      {:error, :not_replacing} ->
        :nothing

      {:error, reason} ->
        unrecorded("that the move was undone", reason)
    end
  end

  defp reached(:clean_up, provider, epoch, opts) do
    case start(
           provider,
           opts,
           fn report -> run_clean_up(provider, epoch, report, opts) end,
           :keeps_action
         ) do
      {:ok, view} ->
        Logger.info("provision: the move to your new server is done; deleting the old one")
        {:deleting, view}

      {:error, {:busy, _kind}} = busy ->
        Logger.info("provision: the old server waits for the running job before it is deleted")
        busy
    end
  end

  defp run_clean_up(provider, epoch, report, opts) do
    case Ledger.update(home(opts), provider.id(), &Ledger.moved(&1, epoch, now(opts))) do
      {:ok, ledger} ->
        :ok = rename_primary(ledger, opts)
        run_delete(provider, :replaced, report, opts)

      {:error, :not_moved} ->
        {:ok, %{"deleted" => false}}

      {:error, reason} ->
        job_failure({:ledger, reason}, provider)
    end
  end

  # The home lives on the new server now, reached at the same node id: the
  # desktop's link names it, so no sentence names the old one. A name the
  # link could not keep costs the words only, and is logged.
  defp rename_primary(%{server: %{name: name}}, opts) do
    rename = Keyword.get(opts, :rename_primary, fn name -> Link.impl().rename_primary(name) end)

    case rename.(name) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("provision: the link could not name your new server: #{inspect(reason)}")
    end
  end

  defp unrecorded(what, reason) do
    Logger.error("provision: #{what} could not be kept: #{inspect(reason)}")
    {:error, {:ledger, reason}}
  end

  # -- the view -----------------------------------------------------------------

  @doc """
  The family's view of the ledger under `home` of the provider Always On
  speaks of (`Provision.current/2`): the provider, the state, the token's
  standing, the server, the failure and every resource. Never the token.
  """
  @spec view(Path.t(), keyword()) :: map()
  def view(home, opts \\ []) when is_binary(home) and is_list(opts),
    do: provider_ledger_view(home, Provision.current(home, providers_of(opts)))

  defp provider_ledger_view(home, provider) do
    state = Ledger.state(home, provider)

    resources =
      case Ledger.read(home, provider.id()) do
        {:ok, ledger} -> resource_views(ledger)
        {:error, _reason} -> []
      end

    %{
      "provider" => provider.id(),
      "state" => Atom.to_string(state.state),
      "token" => Atom.to_string(state.token),
      "server" => state.server && server_view(state.server),
      "failure" => state.failure && failure_view(state.failure),
      "replace" => state.replace && replace_view(state.replace),
      "resources" => resources,
      "sentence" => state.sentence
    }
  end

  defp replace_view(replace) do
    %{
      "state" => Atom.to_string(replace.state),
      "current" => Atom.to_string(replace.current),
      "old" => replace.old && server_view(replace.old),
      "failure" => replace.failure && failure_view(replace.failure)
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

  # The ledger's own, then the old server's while a replace keeps it.
  defp resource_views(ledger),
    do: set_views(ledger, false) ++ set_views(Ledger.replaced_set(ledger), true)

  defp set_views(nil, _replaced?), do: []

  defp set_views(set, replaced?) do
    server = set.server && [resource("server", set.server.name, set.server, replaced?)]
    firewall = set.firewall && [resource("firewall", set.firewall.name, set.firewall, replaced?)]

    ips =
      for ip <- set.primary_ips,
          do: %{
            "kind" => "primary_ip",
            "name" => ip.ip,
            "id" => ip.id,
            "status" => "created",
            "replaced" => replaced?
          }

    (server || []) ++ (firewall || []) ++ ips
  end

  defp resource(kind, name, %{id: id, status: status}, replaced?),
    do: %{
      "kind" => kind,
      "name" => name,
      "id" => id,
      "status" => Atom.to_string(status),
      "replaced" => replaced?
    }

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)

  # -- jobs -----------------------------------------------------------------------

  @doc """
  Starts one reconcile of the provider Always On speaks of: its ledger read
  back from the provider (`Provision.Driver.reconcile/3`), which writes when
  it was checked and anything that changed. A job of the family, named by
  the provider, so it is refused `busy` beside any other step and never
  runs twice at once; it names no step and clears none.
  """
  @spec start_reconcile(keyword()) :: {:ok, map()} | {:error, {:busy, String.t()}}
  def start_reconcile(opts \\ []) when is_list(opts) do
    provider = current(opts)
    start(provider, opts, fn _report -> run_reconcile(provider, opts) end, :keeps_action)
  end

  defp run_reconcile(provider, opts) do
    case Driver.reconcile(provider, home(opts), provider_opts(opts) ++ code_opts(provider, opts)) do
      {:ok, _ledger} -> {:ok, %{"checked" => true}}
      {:error, reason} -> job_failure(token_reason(reason, provider, opts), provider)
    end
  end

  # A step's job (`:clears_action`) is ended by its owner, the job family,
  # however its run ended (`ended/3`); a reconcile and the clean-up after a
  # replace's move name no step (`:keeps_action`).
  defp start(provider, opts, run, ending) when ending in [:clears_action, :keeps_action] do
    job = [
      name: provider.id(),
      run: fn _job_id, report -> run.(&report.({:phase, &1})) end
    ]

    job = if ending == :clears_action, do: job ++ [ending: &ended(provider, opts, &1)], else: job

    case Jobs.start(@kind, Keyword.merge(Keyword.get(opts, :jobs, []), job)) do
      {:ok, view} -> {:ok, view}
      {:error, :busy} -> {:error, {:busy, Atom.to_string(@kind)}}
    end
  end

  # The one ending of a step (Always On setup §5): in one write, what its run
  # left, then its action goes. A failure the run answered is kept as it
  # said it; a run that answered nothing (it raised, exited, was killed or ran
  # past its budget) is kept as interrupted, whose reason is in the job
  # family's log; a cancelled one leaves nothing, since whoever cancelled it
  # takes the next step.
  defp ended(provider, opts, ended) do
    change = &ending(&1, ended, provider, now(opts))

    case Ledger.update(home(opts), provider.id(), change) do
      {:ok, ledger} ->
        log_ending(ended, ledger, provider)

      {:error, :no_action} ->
        :ok

      {:error, reason} ->
        Logger.error("provision: the end of a step could not be kept: #{inspect(reason)}")
    end
  end

  defp ending(ledger, {:answered, {:error, _refusal, %{} = failure}}, _provider, _at),
    do: {:ok, Ledger.end_step(ledger, failure)}

  defp ending(ledger, {:answered, _answer}, _provider, _at), do: Ledger.clear_action(ledger)
  defp ending(ledger, :cancelled, _provider, _at), do: Ledger.clear_action(ledger)

  defp ending(ledger, unanswered, provider, at) when unanswered in [:crashed, :timed_out],
    do: Ledger.interrupt(ledger, provider, at)

  defp log_ending(unanswered, ledger, provider) when unanswered in [:crashed, :timed_out] do
    Logger.warning(
      "provision: the #{ledger.failure.action} step on #{provider.id()} ended without an " <>
        "answer (#{unanswered}); it is kept as interrupted"
    )
  end

  defp log_ending(_ended, _ledger, _provider), do: :ok

  defp run_opts(provider, report, opts),
    do: provider_opts(opts) ++ [report: report] ++ code_opts(provider, opts)

  defp code_opts(provider, opts) do
    {open, withdraw} = code_window(provider, opts)

    [
      open_code: Keyword.get(opts, :open_code, open),
      withdraw_code: Keyword.get(opts, :withdraw_code, withdraw)
    ]
  end

  # On a linked desktop the window is its server's, reached over the link; on
  # the primary, its own.
  defp code_window(provider, opts) do
    case Keyword.fetch(opts, :primary_forward) do
      {:ok, forward} ->
        {fn -> forwarded_code(forward, provider) end,
         fn -> forwarded_withdraw(forward, provider) end}

      :error ->
        {&open_code/0, fn -> Link.impl().withdraw_enrollment(:provisioned) end}
    end
  end

  defp forwarded_code(forward, provider) do
    case forward.(server_request("home.enroll.open", %{"kind" => "provisioned"}), []) do
      {:ok, %{"code" => code}} when is_binary(code) ->
        {:ok, code}

      {:error, :primary_unreachable, _details} ->
        {:error, Provision.error_sentence(:code_unreachable, provider)}

      {:error, _code, %{"sentence" => sentence}} when is_binary(sentence) ->
        {:error, sentence}

      {:error, code, _details} ->
        Logger.warning("provision: your server refused home.enroll.open (#{code})")
        {:error, Provision.error_sentence({:code_refused, Atom.to_string(code)}, provider)}
    end
  end

  defp forwarded_withdraw(forward, provider) do
    case forward.(server_request("home.enroll.withdraw", %{}), []) do
      {:ok, _result} ->
        :ok

      {:error, :primary_unreachable, _details} ->
        {:error, {:unavailable, Provision.error_sentence(:withdraw_unreachable, provider)}}

      {:error, _code, %{"sentence" => sentence}} when is_binary(sentence) ->
        {:error, {:unavailable, sentence}}

      {:error, code, _details} ->
        Logger.warning("provision: your server refused home.enroll.withdraw (#{code})")

        {:error,
         {:unavailable,
          Provision.error_sentence({:withdraw_refused, Atom.to_string(code)}, provider)}}
    end
  end

  defp server_request(method, params) do
    %{
      request_id: "provision-" <> method,
      protocol_version: Protocol.protocol_version(),
      method: method,
      params: params
    }
  end

  defp open_code do
    case Link.impl().open_enrollment(:provisioned) do
      {:ok, %{code: code}} -> {:ok, code}
      {:error, {:unavailable, sentence}} -> {:error, sentence}
    end
  end

  # A provider that answered refused; one out of reach or limiting the rate,
  # and anything the engine itself could not do, is unavailable.
  defp job_failure(reason, provider) do
    code = if unavailable_reason?(reason), do: :unavailable, else: :refused
    {:error, {code, Provision.error_sentence(reason, provider)}}
  end

  # A refusal whose failure the step's ending keeps (`ended/3`).
  defp step_failure(reason, provider, failure) do
    {:error, refusal} = job_failure(reason, provider)
    {:error, refusal, failure}
  end

  defp unavailable_reason?({kind, _detail})
       when kind in [:unreachable, :rate_limited, :action_timeout, :code_unavailable, :ledger],
       do: true

  defp unavailable_reason?({:old_server, reason}), do: unavailable_reason?(reason)
  defp unavailable_reason?(_reason), do: false

  # The provider refusing the token after it accepted it: the token stopped
  # working.
  defp token_reason(:unauthorized, provider, opts) do
    case Ledger.update(home(opts), provider.id(), &token_refused/1) do
      {:ok, _ledger} -> :token_refused
      {:error, why} -> log_unkept(why, :token_refused)
    end
  end

  defp token_reason(reason, _provider, _opts), do: reason

  defp token_refused(%{token: nil}), do: {:error, :no_token}
  defp token_refused(ledger), do: {:ok, Ledger.token_refused(ledger)}

  # -- refusals and seams -------------------------------------------------------

  defp refused(reason, provider, opts) do
    reason = token_reason(reason, provider, opts)
    Logger.warning("provision: #{provider.id()} refused (#{Provision.failure_word(reason)})")
    refusal(reason, provider)
  end

  defp refusal(reason, provider),
    do: {:error, {:unavailable, @capability, Provision.error_sentence(reason, provider)}}

  defp stored_token(provider, opts) do
    case Ledger.read(home(opts), provider.id()) do
      {:ok, %{token: token}} when is_binary(token) -> {:ok, token}
      {:ok, _ledger} -> refusal(:no_token, provider)
      {:error, reason} -> refused({:ledger, reason}, provider, opts)
    end
  end

  defp primary?(%{role: role}), do: role == :primary

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

  defp providers_of(opts), do: Keyword.get_lazy(opts, :providers, &Registry.all/0)
  defp current(opts), do: Provision.current(home(opts), providers_of(opts))
  defp provider_opts(opts), do: Keyword.get(opts, :provider_opts, [])
  defp home(opts), do: Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)
  defp role(opts), do: Keyword.get_lazy(opts, :engine_role, &Role.recorded/0)

  defp now(opts),
    do: DateTime.truncate(Keyword.get(provider_opts(opts), :now, &DateTime.utc_now/0).(), :second)

  defp profile(opts) do
    Keyword.get_lazy(opts, :profile, fn ->
      case Application.get_env(:fermix_core, :profile) do
        profile when is_binary(profile) and profile != "" -> profile
        _unset -> "general"
      end
    end)
  end
end
