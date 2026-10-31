defmodule FermixCore.Management.Provision do
  @moduledoc """
  The `home.provision.*` family (M75 lean v1 §4.3): Fermix creates the
  owner's Always On server on a cloud provider (`FermixCore.Home.Provision`,
  the contract; `Provision.Registry`, the providers, one today) from an API
  token pasted once. Nothing here names a provider: each one's words come
  from its display data, and its refusals arrive as the contract's shared
  kinds.

  Every method is device-class (`Management.Placement`): a linked desktop
  answers it itself and never sends it to the server, since the tokens and
  the ledgers (`Home.Provision.Ledger`, `device/provision/<id>.json`, one per
  provider) stay on the computer that created the server.

    * `home.provision.providers` answers each provider's display data, in
      the order the apps offer them: `{id, name, token_label, steps,
      console_url, docs_anchor}`, so the apps draw the token and choose
      screens from it and need no change for a new provider.
    * `home.provision.connect {provider, token}` (an owner decision) checks
      the token with that provider and keeps it in that provider's ledger;
      one the provider refuses is `invalid_params` on `token` with its
      sentence. While that ledger holds a server or firewall that is not
      gone, a new token replaces the old only when it reaches it
      (`reaches/3`, the same account), so a token that stopped working is
      replaced and one for another account is refused, also on `token`.
      Answers that provider's view (below) and `other_servers` (the account
      holds servers Fermix did not create).
    * `home.provision.options {provider}` reads the orderable types per
      location live, with their monthly prices as the account is billed, the
      L2 recommendation, "more room", and the recommendation in one
      `sentence`.
    * `home.provision.create {provider, type, location, replace?}` (an owner
      decision) starts a job, kind `home_provision`, that creates the
      firewall and the server, the 24-hour enrollment code inside. Refused
      while any provider holds a server Fermix created. On the primary only,
      unless `replace` is true: then on the linked desktop whose ledger of
      that provider holds the server the home lives on, which asks that
      server over the link for the code (`home.enroll.open {kind:
      provisioned}`, forwarded) and keeps both servers in the ledger
      (`Ledger.begin_replace/3`), the old one holding the home until the move
      to the new one is done.
    * `home.provision.power {action}` (an owner decision), `on` or `reset`, a
      job of the same kind.
    * `home.provision.resources` reads the ledger back from the provider (a
      resource deleted outside Fermix is marked gone) and answers the view.
    * `home.provision.delete` (an owner decision) deletes the server, its
      addresses unless they went with it, and the firewall, as a job; it is
      refused while a move to the server runs and once the home lives on it
      (this engine is a linked desktop, or its home carries the moved
      marker): replacing the server is the way to retire it. During a replace
      it deletes what does not hold the home: the new server before the move
      (Cancel, which closes its code on the old server and gives the ledger
      back the old one), or the old server after it (when deleting it
      failed); while the move runs, nothing.

  Power, resources, delete and what follows a replace's move act on the
  provider Always On speaks of (`Provision.current/2`): the one Fermix
  created something on, else the one whose token was given last, else the
  first the registry offers.

  After a replace's move: the daemon records that this desktop started the
  move to the new server (`move_forwarded/3`, beside the forwarded
  `home.move.start`), and the desktop relay reports every primary epoch it
  reaches (`primary_reached/2`). Once that is above the epoch the old server
  held, the move to the new one is done: this desktop's link names the new
  server from then on (`Home.Link`'s `rename_primary/1`), and the old server
  is deleted, once, as a job of the same kind (`Provision.delete_replaced/2`); a failed delete
  stays in the ledger with its sentence, and `home.provision.delete` tries it
  again. The old server answering again at its own epoch after the move
  started means it undid the move: the replace waits for its move again.

  One job of the kind runs at a time (`busy` otherwise). A create's refusal
  is kept in the ledger, so the summary and `home.provision.resources` say
  it after the job is gone; a refusal for the token marks it refused.

  The view: `provider` (the provider's id), `state` (`none`, `connected`,
  `creating`, `created`, `deleting`, `gone`, `failed`, `unreadable`, as
  `Ledger.state/3`), `token` (`none`, `accepted`, `refused`), `server` (or
  null), `failure` (`{reason, sentence, next_location, at}` or null),
  `replace` (null, or `{state, current, old, failure}` as `Ledger.state/3`'s),
  `resources` (every resource the ledger holds: `{kind, name, id, status,
  replaced}`, `replaced` true for the old server's), and from
  `home.provision.resources` `checked` (whether the provider was read just
  now) and `sentence` (why not, or null). The token never leaves the ledger.

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
  alias FermixCore.Home.Provision.Ledger
  alias FermixCore.Home.Provision.Registry
  alias FermixCore.Home.Role
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.Protocol
  alias FermixCore.Setup.ConfigStore

  require Logger

  @capability "home"
  @kind :home_provision
  @token_pattern ~r/\A[!-~]{16,512}\z/
  @type_pattern ~r/\A[a-z0-9][a-z0-9-]{0,31}\z/
  @owner_sentence "Only the owner can give Fermix an API token or create, restart or delete " <>
                    "its server: use the Fermix app."
  @provider_sentence "Choose one of the providers Fermix creates a server on."
  # What `Ledger.begin_replace/3` refuses, each a reason with its sentence.
  @replace_refusals [:replacement_exists, :replace_moving, :old_server_remains, :not_primary]

  @doc """
  The sentence `daemon.sock` answers when a process Fermix started (or one it
  cannot place) asks to give Fermix a token, or to create, power or delete
  the server: the owner's decisions.
  """
  @spec owner_only_sentence() :: String.t()
  def owner_only_sentence, do: @owner_sentence

  @doc "The capability a refusal of this family names."
  @spec capability() :: String.t()
  def capability, do: @capability

  @doc "The job kind a create, a power action and a delete run as."
  @spec job_kind() :: atom()
  def job_kind, do: @kind

  @doc "`home.provision.providers`: each provider's display data, in the order offered."
  @spec providers(keyword()) :: {:ok, map()}
  def providers(opts \\ []) when is_list(opts),
    do: {:ok, %{"providers" => Enum.map(providers_of(opts), &provider_view/1)}}

  defp provider_view(provider) do
    display = provider.display()

    %{
      "id" => provider.id(),
      "name" => display.name,
      "token_label" => display.token_label,
      "steps" => display.steps,
      "console_url" => display.console_url,
      "docs_anchor" => display.docs_anchor
    }
  end

  @doc "`home.provision.connect`."
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
      case provider.reaches(token, ledger, provider_opts(opts)) do
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
    case Ledger.update(home(opts), provider.id(), &{:ok, Ledger.connect(&1, token, now(opts))}) do
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

  @doc "`home.provision.options`."
  @spec options(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def options(params, opts \\ []) when is_map(params) and is_list(opts) do
    with {:ok, provider} <- provider_param(params, opts),
         {:ok, token} <- stored_token(provider, opts) do
      case provider.options(token, provider_opts(opts)) do
        {:ok, options} -> {:ok, Map.put(options, "sentence", recommendation(options, provider))}
        {:error, reason} -> refused(reason, provider, opts)
      end
    end
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
  `home.provision.create`: starts the job that creates the server, or with
  `replace` the one that replaces the server the home lives on.
  """
  @spec create(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(params, opts \\ []) when is_map(params) and is_list(opts) do
    with {:ok, provider, request, replace?} <- create_params(params, opts),
         {:ok, plan} <- create_plan(provider, replace?, opts) do
      start(provider, opts, fn report -> run_create(provider, plan, request, report, opts) end)
    end
  end

  defp create_params(params, opts) do
    with :ok <- known_params(params, ~w(provider type location replace)),
         {:ok, provider} <- provider_param(params, opts),
         {:ok, type} <- matching(params, "type", @type_pattern),
         {:ok, location} <- location(params, provider),
         {:ok, replace?} <- replace_param(params) do
      {:ok, provider, %{type: type, location: location, profile: profile(opts)}, replace?}
    end
  end

  defp replace_param(params) do
    case Map.get(params, "replace", false) do
      replace? when is_boolean(replace?) -> {:ok, replace?}
      _other -> invalid("replace", "Say true to replace the server the home lives on.")
    end
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

  # The server a replace leaves is set aside first, so a refusal from here on
  # is the new server's.
  defp run_create(provider, {:replace, from_epoch}, request, report, opts) do
    case Ledger.update(
           home(opts),
           provider.id(),
           &Ledger.begin_replace(&1, from_epoch, now(opts))
         ) do
      {:ok, _ledger} -> run_create(provider, :create, request, report, opts)
      {:error, reason} when reason in @replace_refusals -> job_failure(reason, provider)
      {:error, reason} -> job_failure({:ledger, reason}, provider)
    end
  end

  defp run_create(provider, :create, request, report, opts) do
    case provider.create(home(opts), request, run_opts(provider, report, opts)) do
      {:ok, server} ->
        {:ok, %{"server" => server.name, "type" => server.type, "location" => server.location}}

      {:error, reason} ->
        job_failure(remembered(reason, provider, opts), provider)
    end
  end

  # A create's refusal stays in the ledger, for the summary; one for the
  # token marks it refused.
  defp remembered(reason, _provider, _opts) when reason in [:server_exists, :no_token],
    do: reason

  defp remembered(reason, provider, opts) do
    reason = token_reason(reason, provider, opts)

    failure = %{
      reason: Provision.failure_word(reason),
      sentence: Provision.error_sentence(reason, provider),
      next_location: next_location(reason),
      at: now(opts)
    }

    case Ledger.update(home(opts), provider.id(), &{:ok, Ledger.put_failure(&1, failure)}) do
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
    provider = current(opts)

    with :ok <- known_params(params, ~w(action)),
         {:ok, action} <- power_action(params),
         {:ok, _token} <- stored_token(provider, opts),
         :ok <- has_server(provider, opts) do
      start(provider, opts, fn report -> run_power(provider, action, report, opts) end)
    end
  end

  defp power_action(%{"action" => "on"}), do: {:ok, :on}
  defp power_action(%{"action" => "reset"}), do: {:ok, :reset}
  defp power_action(_params), do: invalid("action", "Turn the server on, or reset it.")

  defp has_server(provider, opts) do
    case Ledger.read(home(opts), provider.id()) do
      {:ok, %{server: %{status: :created, id: id}}} when is_integer(id) -> :ok
      {:ok, _ledger} -> refusal(:no_server, provider)
      {:error, reason} -> refused({:ledger, reason}, provider, opts)
    end
  end

  defp run_power(provider, action, report, opts) do
    case provider.power(home(opts), action, run_opts(provider, report, opts)) do
      :ok -> {:ok, %{"action" => Atom.to_string(action)}}
      {:error, reason} -> job_failure(token_reason(reason, provider, opts), provider)
    end
  end

  @doc "`home.provision.resources`: the ledger, read back from its provider."
  @spec resources(keyword()) :: {:ok, map()}
  def resources(opts \\ []) when is_list(opts) do
    home = home(opts)
    provider = current(opts)

    case Ledger.read(home, provider.id()) do
      {:ok, %{token: nil}} -> {:ok, checked(provider_ledger_view(home, provider), false, nil)}
      {:ok, _ledger} -> {:ok, reconciled(home, provider, opts)}
      {:error, _reason} -> {:ok, checked(provider_ledger_view(home, provider), false, nil)}
    end
  end

  defp reconciled(home, provider, opts) do
    case provider.reconcile(
           home,
           Keyword.put(provider_opts(opts), :running?, running?(opts)) ++
             code_opts(provider, opts)
         ) do
      {:ok, _ledger} ->
        checked(provider_ledger_view(home, provider), true, nil)

      {:error, reason} ->
        reason = token_reason(reason, provider, opts)

        checked(
          provider_ledger_view(home, provider),
          false,
          Provision.error_sentence(reason, provider)
        )
    end
  end

  defp checked(view, checked?, sentence),
    do: Map.merge(view, %{"checked" => checked?, "sentence" => sentence || view["sentence"]})

  @doc """
  `home.provision.delete`: starts the job that deletes what Fermix created
  and does not hold the home.
  """
  @spec delete(keyword()) :: {:ok, map()} | {:error, term()}
  def delete(opts \\ []) when is_list(opts) do
    provider = current(opts)

    with {:ok, ledger} <- ledger(provider, opts),
         {:ok, target} <- delete_target(ledger, provider, home(opts), role(opts)),
         {:ok, _token} <- stored_token(provider, opts),
         :ok <- something(ledger, provider) do
      start(provider, opts, fn report -> run_delete(provider, target, report, opts) end)
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
    case provider.delete(home(opts), run_opts(provider, report, opts)) do
      :ok -> {:ok, %{"deleted" => true}}
      {:error, reason} -> job_failure(token_reason(reason, provider, opts), provider)
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
    case provider.delete_replaced(home(opts), run_opts(provider, report, opts)) do
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

  # -- after a replace's move ---------------------------------------------------

  @doc """
  Records, beside the daemon's forward of `home.move.start` with `params`,
  that this desktop started the move to the new server of a replace, when
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
    case start(provider, opts, fn report -> run_clean_up(provider, epoch, report, opts) end) do
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

  defp start(provider, opts, run) do
    started =
      Jobs.start(
        @kind,
        Keyword.merge(Keyword.get(opts, :jobs, []),
          name: provider.id(),
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
        {&open_code/0, fn -> Link.impl().withdraw_enrollment() end}
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

  defp unavailable_reason?({kind, _detail})
       when kind in [:unreachable, :rate_limited, :code_unavailable, :ledger],
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
