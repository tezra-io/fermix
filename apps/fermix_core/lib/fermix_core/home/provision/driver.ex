defmodule FermixCore.Home.Provision.Driver do
  @moduledoc """
  What every provider's server is created, powered, read back and deleted
  through (M75 lean v1 §4.3): the orchestration around a provider's API
  primitives (`FermixCore.Home.Provision`'s callbacks), the same for every
  provider. Only the driver writes the ledger (`Provision.Ledger`), each
  write before the call that creates or deletes and after it, so a provider
  module is an API adapter and nothing more.

  **Create.** The type is checked against the live stock first
  (`server_type/3`), so a type sold out where asked is refused before
  anything is written, naming the next place in stock, and a type that is not
  x86 with 4 GB still sold is refused by name. Then, each written to the
  ledger before its call and after it: the firewall with no inbound rule
  (the first write, where a read-only token is refused before anything costs
  money), the system image, a fresh provisioned enrollment code (24 hours,
  L15) inside the first boot (`Provision.FirstBoot`, refused past the
  provider's limit), and the server, named and labelled by the ledger's ref
  (`Provision.server_name/2`, `Provision.labels/2`). Its actions are polled
  (every 2 s, at most 150 reads each; a rate-limited read waits 10 s, and one
  that got no answer is tried again, both counted), then the server is read
  once more to record it running. A create that stopped after its firewall
  stood reuses that firewall and the ref. A write the provider refused
  leaves nothing behind (a refused server's code withdrawn); one whose
  outcome is unknown (`{:unknown, _}`) stays `requested` and keeps its code,
  for `reconcile/3` to find by its labels. Of a created server's answer only
  its facts are kept: its id, its address, when it was created, its primary
  addresses and its actions.

  **Reconcile.** Reads what the ledger names by its id (or, for a resource
  asked for and never answered, by its labels): absent with an id is `gone`
  (or removed when a delete was under way); absent with no id is removed,
  the create failed `interrupted` unless it recorded why, and its code
  withdrawn; found is recorded, and a lost create recovers its addresses.
  Changes apply only where the ledger still names what was read, and
  nothing is asked while a job runs (`:running?`).

  **Delete.** Withdraws the code, then the server (polled; already gone is
  as good as deleted), each primary address unless it went with the server,
  then the firewall (one its server still holds is tried again every 2 s,
  ten times), each written as `deleting` before its call and dropped after
  it; the token stays. It is refused once the move to a replacing server is
  done (`:live_home`) and with nothing created. `delete_replaced/3` does the
  same for the server a replace retired, never one that holds the home.

  Every function answers a provider's refusal as a `Provision.reason/0`,
  `{:unknown, _}` unwrapped once the driver has acted on it.
  """

  alias FermixCore.Home.Provision
  alias FermixCore.Home.Provision.FirstBoot
  alias FermixCore.Home.Provision.Ledger
  alias FermixCore.Home.Provision.Offering

  require Logger

  @poll_ms 2_000
  @max_polls 150
  @rate_wait_ms 10_000
  @in_use_tries 10
  # What the driver keeps of a created server's answer.
  @created_facts [:id, :ipv4, :created_at, :primary_ips, :actions]

  # -- the token and the offer --------------------------------------------------

  @doc """
  Whether `token` reaches what `ledger` holds: one read, by id, of its server
  (or else its firewall) that is not gone, or of the server a replace set
  aside; `{:error, :other_project}` when the provider has no such thing for
  this token. Nothing standing is reached by any token.
  """
  @spec reaches(module(), String.t(), Ledger.t(), Provision.opts()) ::
          :ok | {:error, Provision.reason()}
  def reaches(provider, token, ledger, opts) when is_binary(token) and is_map(ledger) do
    case standing(ledger) || standing(Ledger.replaced_set(ledger)) do
      nil -> :ok
      {kind, id} -> reached(provider.get(token, kind, id, opts))
    end
  end

  defp standing(%{server: %{id: id, status: status}}) when is_binary(id) and status != :gone,
    do: {:server, id}

  defp standing(%{firewall: %{id: id, status: status}}) when is_binary(id) and status != :gone,
    do: {:firewall, id}

  defp standing(_ledger), do: nil

  defp reached({:ok, _found}), do: :ok
  defp reached({:error, :not_found}), do: {:error, :other_project}
  defp reached(answer), do: plain(answer)

  @doc "What the provider sells now, and the L2 recommendation (`Provision.Offering`)."
  @spec options(module(), String.t(), Provision.opts()) :: {:ok, map()} | {:error, term()}
  def options(provider, token, opts) when is_binary(token) and is_list(opts) do
    case provider.catalog(token, opts) do
      {:ok, catalog} -> {:ok, Offering.offering(provider, catalog)}
      answer -> plain(answer)
    end
  end

  # -- create -------------------------------------------------------------------

  @doc "Creates the server `request` asks for, as the moduledoc says."
  @spec create(module(), Path.t(), Provision.request(), Provision.opts()) ::
          {:ok, Ledger.server()} | {:error, Provision.reason()}
  def create(provider, home, %{type: type, location: location, profile: profile} = request, opts)
      when is_binary(home) and is_binary(type) and is_binary(location) and is_binary(profile) do
    true = location in Provision.location_ids(provider)
    report(opts, "checking")

    with {:ok, ledger} <- read(provider, home),
         {:ok, token} <- token(ledger),
         :ok <- no_server(ledger),
         {:ok, facts} <- checked(provider, token, request, opts),
         {:ok, plan} <- begin(provider, home, ledger, facts, profile),
         {:ok, firewall} <- firewall(provider, home, token, plan, opts),
         {:ok, image} <- plain(provider.system_image(token, opts)),
         {:ok, user_data} <- user_data(provider, opts),
         parts = %{firewall: firewall, image: image, user_data: user_data},
         {:ok, created} <- server(provider, home, token, plan, parts, opts) do
      started(provider, home, token, created, opts)
    end
  end

  defp no_server(%{server: %{status: status}}) when status != :gone, do: {:error, :server_exists}
  defp no_server(_ledger), do: :ok

  # The type as the provider sells it now, and the places' names, before
  # anything is written.
  defp checked(provider, token, %{type: type, location: location}, opts) do
    with {:ok, %{type: found, cities: cities}} <- plain(provider.server_type(token, type, opts)),
         :ok <- eligible(found, type) do
      places = Provision.location_ids(provider)

      facts = %{
        type: type,
        description: found.description,
        location: location,
        city: Map.get(cities, location, location),
        stock: Enum.filter(places, &(&1 in found.stock)),
        cities: Map.new(places, &{&1, Map.get(cities, &1, &1)})
      }

      if location in facts.stock, do: {:ok, facts}, else: {:error, unavailable(facts)}
    end
  end

  defp eligible(%{} = found, type),
    do: if(Offering.eligible?(found), do: :ok, else: {:error, {:ineligible_type, type}})

  defp eligible(nil, type), do: {:error, {:ineligible_type, type}}

  defp unavailable(facts) do
    next = Enum.find(facts.stock, &(&1 != facts.location))

    {:unavailable,
     %{
       type: facts.type,
       description: facts.description,
       location: facts.location,
       city: facts.city,
       next: next,
       next_city: next && facts.cities[next]
     }}
  end

  # A create that stopped after its firewall stood keeps that firewall and the
  # ledger's ref; any other starts afresh with a new ref.
  defp begin(provider, home, ledger, facts, profile) do
    {ref, reuse} =
      case ledger do
        %{ref: ref, firewall: %{status: :created, id: id}} when is_binary(ref) -> {ref, id}
        _fresh -> {fresh_ref(ledger), nil}
      end

    name = Provision.server_name(profile, ref)
    plan = Map.merge(facts, %{ref: ref, profile: profile, name: name, reuse_firewall: reuse})

    transform =
      if reuse,
        do: &%{&1 | failure: nil, server: nil},
        else: &Ledger.begin_create(&1, ref, %{name: name})

    with {:ok, _ledger} <- update(provider, home, &{:ok, transform.(&1)}), do: {:ok, plan}
  end

  defp fresh_ref(ledger),
    do: Provision.fresh_ref(:crypto.strong_rand_bytes(2), Ledger.replaced_ref(ledger))

  defp firewall(_provider, _home, _token, %{reuse_firewall: id}, _opts) when is_binary(id),
    do: {:ok, id}

  defp firewall(provider, home, token, plan, opts) do
    report(opts, "firewall")
    asked = %{name: plan.name, labels: Provision.labels(plan.profile, plan.ref)}

    case provider.create_firewall(token, asked, opts) do
      {:ok, id} when is_binary(id) ->
        with {:ok, _ledger} <-
               update(
                 provider,
                 home,
                 &{:ok, Ledger.put_firewall(&1, %{id: id, status: :created})}
               ),
             do: {:ok, id}

      {:error, {:unknown, reason}} ->
        {:error, reason}

      {:error, reason} ->
        with {:ok, _ledger} <- update(provider, home, &{:ok, Ledger.remove(&1, :firewall)}),
             do: {:error, reason}
    end
  end

  defp user_data(provider, opts) do
    with {:ok, code} <- open_code(opts) do
      case FirstBoot.user_data(code, provider.max_user_data()) do
        {:ok, user_data} -> {:ok, user_data}
        {:error, :too_large} -> withdrawn(opts, :user_data_too_large)
        {:error, :invalid_code} -> withdrawn(opts, :invalid_code)
      end
    end
  end

  defp server(provider, home, token, plan, parts, opts) do
    report(opts, "server")
    asked = %{name: plan.name, type: plan.type, location: plan.location, status: :requested}

    spec =
      Map.merge(parts, %{
        name: plan.name,
        type: plan.type,
        location: plan.location,
        labels: Provision.labels(plan.profile, plan.ref)
      })

    with {:ok, _ledger} <- update(provider, home, &{:ok, Ledger.put_server(&1, asked)}) do
      case provider.create_server(token, spec, opts) do
        {:ok, answer} -> created(provider, home, Map.take(answer, @created_facts))
        {:error, {:unknown, reason}} -> {:error, reason}
        {:error, reason} -> server_refused(provider, home, plan, reason, opts)
      end
    end
  end

  defp created(provider, home, %{id: id, actions: actions} = answer) when is_binary(id) do
    facts = %{
      id: id,
      status: :creating,
      ipv4: answer.ipv4,
      created_at: answer.created_at
    }

    change = &{:ok, &1 |> Ledger.put_server(facts) |> Ledger.put_primary_ips(answer.primary_ips)}
    with {:ok, _ledger} <- update(provider, home, change), do: {:ok, %{id: id, actions: actions}}
  end

  # A server the provider refused will not exist: it leaves the ledger and its
  # code is withdrawn.
  defp server_refused(provider, home, plan, reason, opts) do
    with {:ok, _ledger} <- update(provider, home, &{:ok, Ledger.remove(&1, :server)}),
         do: withdrawn(opts, named(reason, plan))
  end

  defp named(:no_capacity, plan), do: unavailable(plan)
  defp named(reason, _plan), do: reason

  defp started(provider, home, token, %{id: id, actions: actions}, opts) do
    report(opts, "starting")

    with :ok <- await_all(provider, token, actions, opts),
         {:ok, server} <- plain(provider.get(token, :server, id, opts)),
         {:ok, ledger} <-
           update(provider, home, &{:ok, Ledger.put_server(&1, seen(server, :created, opts))}) do
      {:ok, ledger.server}
    end
  end

  defp seen(server, status, opts), do: %{status: status, power: server.power, seen_at: now(opts)}

  # -- power ----------------------------------------------------------------------

  @doc "Turns the server on (`:on`) or restarts it (`:reset`), and records its power."
  @spec power(module(), Path.t(), :on | :reset, Provision.opts()) ::
          :ok | {:error, Provision.reason()}
  def power(provider, home, action, opts) when is_binary(home) and action in [:on, :reset] do
    report(opts, "power")

    with {:ok, ledger} <- read(provider, home),
         {:ok, token} <- token(ledger),
         {:ok, id} <- server_id(ledger),
         {:ok, started} <- plain(provider.power(token, id, action, opts)),
         :ok <- await_all(provider, token, [started], opts),
         {:ok, server} <- plain(provider.get(token, :server, id, opts)) do
      change = &{:ok, Ledger.put_server(&1, %{power: server.power, seen_at: now(opts)})}
      with {:ok, _ledger} <- update(provider, home, change), do: :ok
    end
  end

  defp server_id(%{server: %{status: :created, id: id}}) when is_binary(id), do: {:ok, id}
  defp server_id(_ledger), do: {:error, :no_server}

  # -- reconcile ------------------------------------------------------------------

  @doc "Reads what the ledger names back from the provider, as the moduledoc says."
  @spec reconcile(module(), Path.t(), Provision.opts()) ::
          {:ok, Ledger.t()} | {:error, Provision.reason()}
  def reconcile(provider, home, opts) when is_binary(home) and is_list(opts) do
    with {:ok, ledger} <- read(provider, home),
         {:ok, token} <- token(ledger) do
      if Keyword.get(opts, :running?, false),
        do: {:ok, ledger},
        else: reconciled(provider, home, token, ledger, opts)
    end
  end

  defp reconciled(provider, home, token, ledger, opts) do
    with {:ok, server} <- observe(provider, token, :server, ledger, opts),
         {:ok, firewall} <- observe(provider, token, :firewall, ledger, opts),
         {:ok, changed} <-
           update(
             provider,
             home,
             &{:ok, observed(&1, ledger, {server, firewall}, provider, opts)}
           ),
         :ok <- withdraw_unborn(ledger, server, opts) do
      reconciled_replaced(provider, home, token, Ledger.replaced_set(ledger), changed, opts)
    end
  end

  # The server a replace set aside was created, so it is read by its ids.
  defp reconciled_replaced(_provider, _home, _token, nil, changed, _opts), do: {:ok, changed}

  defp reconciled_replaced(provider, home, token, old, _changed, opts) do
    with {:ok, server} <- observe(provider, token, :server, old, opts),
         {:ok, firewall} <- observe(provider, token, :firewall, old, opts) do
      update(
        provider,
        home,
        :replaced,
        &{:ok, observed(&1, old, {server, firewall}, provider, opts)}
      )
    end
  end

  # A server asked for whose create never reached the provider will not enroll.
  defp withdraw_unborn(%{server: %{id: nil}}, :absent, opts), do: withdraw_code(opts)
  defp withdraw_unborn(_ledger, _observed, _opts), do: :ok

  defp observe(provider, token, kind, set, opts) do
    case Map.fetch!(set, kind) do
      nil -> {:ok, :unchanged}
      %{status: :gone} -> {:ok, :unchanged}
      %{id: nil} -> by_labels(provider, token, kind, set, opts)
      %{id: id} -> by_id(provider, token, kind, id, opts)
    end
  end

  defp by_id(provider, token, kind, id, opts) do
    case provider.get(token, kind, id, opts) do
      {:ok, found} -> {:ok, {:found, found}}
      {:error, :not_found} -> {:ok, :absent}
      answer -> plain(answer)
    end
  end

  defp by_labels(provider, token, kind, set, opts) do
    case provider.find(token, kind, set_labels(set), opts) do
      {:ok, %{} = found} -> {:ok, {:found, found}}
      {:ok, nil} -> {:ok, :absent}
      answer -> plain(answer)
    end
  end

  # The labels a create of the set's ref put on everything it made; the
  # profile's part is the middle of the name it gave them.
  defp set_labels(%{ref: ref} = set) do
    name = (set.server || set.firewall).name
    part = name |> String.replace_prefix("fermix-", "") |> String.replace_suffix("-" <> ref, "")
    Provision.labels(part, ref)
  end

  # Applied to the ledger as it is now, and only where it still names what
  # was read, so a change written meanwhile is never undone.
  defp observed(current, read, {server, firewall}, provider, opts) do
    current
    |> apply_server(read.server, server, {provider, opts})
    |> apply_firewall(read.firewall, firewall)
  end

  defp apply_server(current, _read, :unchanged, _seams), do: current

  # Absent at the provider: never created (no id), deleted by a delete that
  # stopped before it recorded so (no job runs while this is read), or
  # deleted outside Fermix.
  defp apply_server(%{server: %{id: nil}} = current, %{id: nil}, :absent, seams),
    do: interrupted(current, seams)

  defp apply_server(%{server: %{id: id, status: :deleting}} = current, %{id: id}, :absent, _s),
    do: Ledger.remove(current, :server)

  defp apply_server(%{server: %{id: id}} = current, %{id: id}, :absent, _seams),
    do: Ledger.put_server(current, %{status: :gone})

  defp apply_server(%{server: %{id: id}} = current, %{id: id}, {:found, found}, {_p, opts}) do
    status = if found.power in ["running", "off"], do: :created, else: :creating

    facts =
      Map.merge(seen(found, status, opts), %{
        id: found.id,
        ipv4: found.ipv4,
        created_at: found.created_at
      })

    current |> Ledger.put_server(facts) |> recovered(id, found)
  end

  defp apply_server(current, _read, _observed, _seams), do: current

  # A lost create found again stands: its addresses are recorded, and the
  # failure its lost answer left goes.
  defp recovered(ledger, nil, found),
    do: ledger |> Ledger.put_primary_ips(found.primary_ips) |> Ledger.put_failure(nil)

  defp recovered(ledger, _id, _found), do: ledger

  # Nothing was created: the server leaves the ledger, and a create that
  # recorded no reason of its own stopped before it was done.
  defp interrupted(current, {provider, opts}) do
    failure =
      current.failure ||
        %{
          reason: "interrupted",
          sentence: Provision.error_sentence(:interrupted, provider),
          next_location: nil,
          at: now(opts)
        }

    current |> Ledger.remove(:server) |> Ledger.put_failure(failure)
  end

  defp apply_firewall(current, _read, :unchanged), do: current

  defp apply_firewall(%{firewall: %{id: id, status: status}} = current, %{id: id}, :absent)
       when id == nil or status == :deleting,
       do: Ledger.remove(current, :firewall)

  defp apply_firewall(%{firewall: %{id: id}} = current, %{id: id}, :absent),
    do: Ledger.put_firewall(current, %{status: :gone})

  defp apply_firewall(%{firewall: %{id: id}} = current, %{id: id}, {:found, found}),
    do: Ledger.put_firewall(current, %{id: found.id, status: :created})

  defp apply_firewall(current, _read, _observed), do: current

  # -- delete ---------------------------------------------------------------------

  @doc """
  Deletes what Fermix created and the ledger holds as its own: never the
  server a replace moved the home to (`:live_home`).
  """
  @spec delete(module(), Path.t(), Provision.opts()) :: :ok | {:error, Provision.reason()}
  def delete(provider, home, opts) when is_binary(home) and is_list(opts) do
    with {:ok, ledger} <- read(provider, home),
         {:ok, token} <- token(ledger),
         :ok <- something(ledger),
         :ok <- not_moved_to(ledger) do
      report(opts, "deleting")

      with :ok <- withdraw_code(opts),
           :ok <- delete_set(provider, home, :current, token, ledger, opts),
           {:ok, _ledger} <- update(provider, home, &{:ok, Ledger.clear(&1)}) do
        :ok
      end
    end
  end

  # A replace begun with nothing created yet is something to undo.
  defp something(ledger),
    do: if(Ledger.holding?(ledger), do: :ok, else: {:error, :nothing_to_delete})

  # The new server a replace moved the home to holds it.
  defp not_moved_to(%{replace: %{moved_at: %DateTime{}}}), do: {:error, :live_home}
  defp not_moved_to(_ledger), do: :ok

  @doc """
  Deletes the server a replace retired, once the move to the new one is done
  (`Ledger.retired/1`), and records the replace done.
  """
  @spec delete_replaced(module(), Path.t(), Provision.opts()) ::
          :ok | {:error, Provision.reason()}
  def delete_replaced(provider, home, opts) when is_binary(home) and is_list(opts) do
    with {:ok, ledger} <- read(provider, home),
         {:ok, token} <- token(ledger),
         {:ok, old} <- Ledger.retired(ledger) do
      report(opts, "deleting")
      change = &{:ok, Ledger.replaced_deleted(&1, now(opts))}

      with :ok <- delete_set(provider, home, :replaced, token, old, opts),
           {:ok, _ledger} <- update(provider, home, change) do
        :ok
      end
    end
  end

  # One server and what came with it, in the ledger's own places (`:current`)
  # or the ones a replace set aside (`:replaced`): the server, then its
  # addresses unless they went with it, then the firewall.
  defp delete_set(provider, home, slot, token, set, opts) do
    with :ok <- delete_server(provider, home, slot, token, set, opts),
         :ok <- delete_ips(provider, token, set.primary_ips, opts) do
      delete_firewall(provider, home, slot, token, set, opts)
    end
  end

  defp delete_server(_provider, _home, _slot, _token, %{server: nil}, _opts), do: :ok

  defp delete_server(provider, home, slot, _token, %{server: %{status: :gone}}, _opts),
    do: forgotten(provider, home, slot, :server)

  defp delete_server(provider, home, slot, token, %{server: %{id: nil}} = set, opts) do
    case by_labels(provider, token, :server, set, opts) do
      {:ok, {:found, %{id: id}}} ->
        delete_server(provider, home, slot, token, put_in(set.server.id, id), opts)

      {:ok, :absent} ->
        forgotten(provider, home, slot, :server)

      {:error, _reason} = error ->
        error
    end
  end

  defp delete_server(provider, home, slot, token, %{server: %{id: id}}, opts) do
    change = &{:ok, Ledger.put_server(&1, %{id: id, status: :deleting})}

    with {:ok, _ledger} <- update(provider, home, slot, change),
         :ok <- server_deleted(provider, token, id, opts) do
      forgotten(provider, home, slot, :server)
    end
  end

  # A server already gone from the provider is as good as deleted.
  defp server_deleted(provider, token, id, opts) do
    case provider.delete(token, :server, id, opts) do
      {:ok, %{} = action} -> await_all(provider, token, [action], opts)
      {:ok, nil} -> :ok
      {:error, :not_found} -> :ok
      answer -> plain(answer)
    end
  end

  defp forgotten(provider, home, slot, kind) do
    with {:ok, _ledger} <- update(provider, home, slot, &{:ok, Ledger.remove(&1, kind)}),
         do: :ok
  end

  # An address that went with its server is not found; one that stayed is
  # deleted.
  defp delete_ips(provider, token, ips, opts) do
    Enum.reduce_while(ips, :ok, fn %{id: id}, :ok ->
      case delete_ip(provider, token, id, opts) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp delete_ip(provider, token, id, opts) do
    case provider.get(token, :primary_ip, id, opts) do
      {:ok, _ip} -> gone_ok(provider.delete(token, :primary_ip, id, opts))
      {:error, :not_found} -> :ok
      answer -> plain(answer)
    end
  end

  defp gone_ok({:ok, _action}), do: :ok
  defp gone_ok({:error, :not_found}), do: :ok
  defp gone_ok(answer), do: plain(answer)

  defp delete_firewall(_provider, _home, _slot, _token, %{firewall: nil}, _opts), do: :ok

  defp delete_firewall(provider, home, slot, _token, %{firewall: %{status: :gone}}, _opts),
    do: forgotten(provider, home, slot, :firewall)

  defp delete_firewall(provider, home, slot, token, %{firewall: %{id: nil}} = set, opts) do
    case by_labels(provider, token, :firewall, set, opts) do
      {:ok, {:found, %{id: id}}} ->
        delete_firewall(provider, home, slot, token, put_in(set.firewall.id, id), opts)

      {:ok, :absent} ->
        forgotten(provider, home, slot, :firewall)

      {:error, _reason} = error ->
        error
    end
  end

  defp delete_firewall(provider, home, slot, token, %{firewall: %{id: id}}, opts) do
    with {:ok, _ledger} <-
           update(provider, home, slot, &{:ok, Ledger.put_firewall(&1, %{status: :deleting})}),
         :ok <- firewall_deleted(provider, token, id, opts, @in_use_tries) do
      forgotten(provider, home, slot, :firewall)
    end
  end

  # A deleted server's firewall is let go a moment after the server's action
  # ends; until then the provider answers that it is in use.
  defp firewall_deleted(_provider, _token, _id, _opts, 0), do: {:error, :resource_in_use}

  defp firewall_deleted(provider, token, id, opts, tries) do
    case provider.delete(token, :firewall, id, opts) do
      {:ok, _action} ->
        :ok

      {:error, :not_found} ->
        :ok

      {:error, :in_use} ->
        paused(opts, @poll_ms, fn -> firewall_deleted(provider, token, id, opts, tries - 1) end)

      answer ->
        plain(answer)
    end
  end

  # -- actions ------------------------------------------------------------------

  defp await_all(provider, token, actions, opts) do
    Enum.reduce_while(actions, :ok, fn action, :ok ->
      case await(provider, token, action, opts, Keyword.get(opts, :max_polls, @max_polls)) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp await(_provider, _token, %{status: :success}, _opts, _polls), do: :ok

  defp await(_provider, _token, %{status: :error, step: step, message: message}, _opts, _polls),
    do: {:error, {:action_failed, step, message}}

  defp await(_provider, _token, %{step: step}, _opts, 0), do: {:error, {:action_timeout, step}}

  defp await(provider, token, action, opts, polls),
    do: paused(opts, @poll_ms, fn -> poll(provider, token, action, opts, polls) end)

  # A rate-limited read waits longer, and a read that got no answer is tried
  # again; both count against the bound.
  defp poll(provider, token, action, opts, polls) do
    case provider.action(token, action.id, opts) do
      {:ok, read} ->
        await(provider, token, read, opts, polls - 1)

      {:error, {:rate_limited, _reset}} ->
        paused(opts, @rate_wait_ms, fn -> await(provider, token, action, opts, polls - 1) end)

      {:error, {:unknown, _reason}} ->
        await(provider, token, action, opts, polls - 1)

      {:error, _reason} = error ->
        error
    end
  end

  defp paused(opts, ms, next) do
    Keyword.get(opts, :sleep, &Process.sleep/1).(ms)
    next.()
  end

  # -- the code window ----------------------------------------------------------

  defp open_code(opts) do
    case Keyword.fetch!(opts, :open_code).() do
      {:ok, code} -> {:ok, code}
      {:error, sentence} when is_binary(sentence) -> {:error, {:code_unavailable, sentence}}
    end
  end

  defp withdraw_code(opts) do
    case Keyword.fetch!(opts, :withdraw_code).() do
      :ok -> :ok
      {:error, {:unavailable, sentence}} -> {:error, {:code_unavailable, sentence}}
    end
  end

  # The code of a server that will not exist is withdrawn; the create's own
  # reason is the answer, and a code that could not be withdrawn is logged
  # beside it (it expires by itself).
  defp withdrawn(opts, reason) do
    case withdraw_code(opts) do
      :ok ->
        {:error, reason}

      {:error, {:code_unavailable, sentence}} ->
        Logger.error("provision: the server's enrollment code stays open: #{sentence}")
        {:error, reason}
    end
  end

  # -- the ledger -----------------------------------------------------------------

  defp read(provider, home) do
    case Ledger.read(home, provider.id()) do
      {:ok, ledger} -> {:ok, ledger}
      {:error, reason} -> {:error, {:ledger, reason}}
    end
  end

  defp update(provider, home, fun) do
    case Ledger.update(home, provider.id(), fun) do
      {:ok, ledger} -> {:ok, ledger}
      {:error, reason} -> {:error, {:ledger, reason}}
    end
  end

  # `fun` changes one server and what came with it: the ledger's own places,
  # or the ones a replace set aside (left as it is once none is).
  defp update(provider, home, :current, fun), do: update(provider, home, fun)

  defp update(provider, home, :replaced, fun),
    do: update(provider, home, &replaced_changed(&1, fun))

  defp replaced_changed(ledger, fun) do
    case Ledger.replaced_set(ledger) do
      nil -> {:ok, ledger}
      set -> with {:ok, changed} <- fun.(set), do: {:ok, Ledger.put_replaced_set(ledger, changed)}
    end
  end

  defp token(%{token: token}) when is_binary(token), do: {:ok, token}
  defp token(_ledger), do: {:error, :no_token}

  # A refusal whose outcome the driver no longer acts on is said as it is.
  defp plain({:error, {:unknown, reason}}), do: {:error, reason}
  defp plain(answer), do: answer

  defp report(opts, phase), do: Keyword.get(opts, :report, fn _phase -> :ok end).(phase)

  defp now(opts), do: DateTime.truncate(Keyword.get(opts, :now, &DateTime.utc_now/0).(), :second)
end
