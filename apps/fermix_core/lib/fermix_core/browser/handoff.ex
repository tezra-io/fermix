defmodule FermixCore.Browser.Handoff do
  @moduledoc """
  The browser session hand-off (M75 D18, B10): the owner's signed-in sites
  moved from a desktop's engine-owned Chrome profile to the primary's, for a
  bounded time, by the owner alone.

  **On the desktop** (device role, attended). The owner signs in with
  `fermix browser signin URL` (`DevTools.open_headed/2`), then runs
  `fermix browser handoff SITE…`: `collect/2` reads that profile's cookies for
  exactly the named sites (`Handoff.Sites`, `Handoff.Cookies`) and the
  channels side sends them over the rail (`Handoff.Link`). Identity providers
  move only when named with `--allow-identity-provider`. A hand-off lasts 7
  days unless the owner says otherwise, at most 30.

  **On the primary.** `store/2` puts the cookies into the owner profile
  through DevTools (starting Chrome headless for it when none runs), each
  capped at the hand-off's expiry, and records each cookie's key, never its
  value, in the ledger (`Handoff.Ledger`). `sweep/1` (every 60 s,
  `Handoff.Sweeper`) deletes the cookies of every expired hand-off from the
  running Chrome; with no Chrome running, `purge_on_launch/2` deletes them as
  the next one starts. `wipe/2` deletes a site's, or every, hand-off now.
  What was deleted from a Chrome that was already running is deleted once
  more as the next one starts (the ledger's `purge`): Chrome writes a change
  to its profile within about 30 s, and one stopped sooner keeps the cookie.

  **Never the agent.** No tool starts, lists or wipes a hand-off, and nothing
  the model reaches calls this module. The owner starts one at a terminal on
  the desktop (`browser.handoff.send` on `daemon.sock`); the agent can only
  ask the owner to.

  Every operation emits one point event (`Handoff.Telemetry`).
  """

  alias FermixCore.Browser.Handoff.Cookies
  alias FermixCore.Browser.Handoff.DevTools
  alias FermixCore.Browser.Handoff.Ledger
  alias FermixCore.Browser.Handoff.Sites
  alias FermixCore.Browser.Handoff.Telemetry
  alias FermixCore.Setup.ConfigStore

  require Logger

  @default_days 7
  @max_days 30
  @day_s 86_400
  # A primary accepts an expiry a little past the desktop's thirty days, for
  # the two machines' clocks.
  @clock_slack_s 3_600

  @typedoc "A hand-off as the primary stores it."
  @type stored_handoff :: %{
          handoff_id: String.t(),
          from: String.t(),
          sites: [String.t()],
          expires_at: DateTime.t(),
          cookies: [Cookies.t()]
        }

  @doc "How long a hand-off lasts unless the owner says: 7 days, in seconds."
  @spec default_expiry_s() :: pos_integer()
  def default_expiry_s, do: @default_days * @day_s

  @doc "The longest a hand-off may last: 30 days, in seconds."
  @spec max_expiry_s() :: pos_integer()
  def max_expiry_s, do: @max_days * @day_s

  @doc """
  Desktop: the owner profile's cookies for `sites`. `opts`: `:devtools` (in
  place of `DevTools.run/3`) and what it takes.
  """
  @spec collect([String.t()], keyword()) :: {:ok, [Cookies.t()]} | {:error, term()}
  def collect(sites, opts \\ []) when is_list(sites) and is_list(opts) do
    devtools = Keyword.get(opts, :devtools, &DevTools.run/3)

    case devtools.(:launch_headless, &all_cookies/1, opts) do
      {:ok, cookies} -> selected(Cookies.select(cookies, sites))
      {:error, _reason} = error -> error
    end
  end

  defp all_cookies(command) do
    case command.("Storage.getCookies", %{}) do
      {:ok, %{"cookies" => cookies}} when is_list(cookies) -> {:ok, cookies}
      {:ok, _other} -> {:error, :invalid_cookie_list}
      {:error, reason} -> {:error, {:devtools_failed, reason}}
    end
  end

  defp selected([]), do: {:error, :no_cookies}
  defp selected(cookies), do: {:ok, cookies}

  @doc """
  Primary: stores `handoff`'s cookies in the owner profile and records them.
  `opts`: `:home`, `:now` (a 0-arity clock), `:devtools`.
  """
  @spec store(stored_handoff(), keyword()) ::
          {:ok, %{cookies: non_neg_integer(), expires_at: DateTime.t()}} | {:error, term()}
  def store(%{handoff_id: id, cookies: [_ | _] = cookies} = handoff, opts \\ [])
      when is_binary(id) and is_list(opts) do
    started = System.monotonic_time(:millisecond)
    facts = %{sites: length(handoff.sites), cookies: length(cookies)}

    result =
      with :ok <- expiry_within(handoff.expires_at, now(opts)),
           {:ok, ledger} <- Ledger.read(home(opts)),
           recorded = Ledger.record(ledger, entry(handoff, now(opts))),
           :ok <- Ledger.write(home(opts), recorded),
           :ok <- set_cookies(cookies, handoff.expires_at, opts) do
        {:ok, %{cookies: length(cookies), expires_at: handoff.expires_at}}
      else
        {:error, {:set_cookies, reason}} -> unrecord(id, reason, opts)
        {:error, _reason} = error -> error
      end

    emit(:stored, result, facts, started)
    result
  end

  defp entry(handoff, now) do
    %{
      handoff_id: handoff.handoff_id,
      from: handoff.from,
      sites: handoff.sites,
      stored_at: DateTime.truncate(now, :second),
      expires_at: DateTime.truncate(handoff.expires_at, :second),
      cookies: Enum.map(handoff.cookies, &Cookies.key/1)
    }
  end

  defp expiry_within(expires_at, now) do
    seconds = DateTime.diff(expires_at, now, :second)

    if seconds > 0 and seconds <= @max_days * @day_s + @clock_slack_s,
      do: :ok,
      else: {:error, {:invalid_expiry, expires_at}}
  end

  defp set_cookies(cookies, expires_at, opts) do
    cap = DateTime.to_unix(expires_at)
    params = Enum.map(cookies, &Cookies.set_params(&1, cap))
    devtools = Keyword.get(opts, :devtools, &DevTools.run/3)

    case devtools.(:launch_headless, &set(&1, params), opts) do
      :ok -> :ok
      {:error, reason} -> {:error, {:set_cookies, reason}}
    end
  end

  defp set(command, params) do
    case command.("Storage.setCookies", %{"cookies" => params}) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:devtools_failed, reason}}
    end
  end

  # The cookies were not stored, so the entry that described them goes.
  defp unrecord(id, reason, opts) do
    with {:ok, ledger} <- Ledger.read(home(opts)),
         :ok <- Ledger.write(home(opts), Ledger.drop(ledger, [id])) do
      {:error, reason}
    else
      {:error, ledger_reason} ->
        Logger.error(
          "browser hand-off: #{id} was not stored and its record stays: #{inspect(ledger_reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Primary: deletes the cookies of `sites`' hand-offs (or of every hand-off,
  `:all`) from the owner profile now, and forgets them. `opts` as `store/2`.
  """
  @spec wipe([String.t()] | :all, keyword()) ::
          {:ok, %{cookies: non_neg_integer(), sites: [String.t()] | :all}} | {:error, term()}
  def wipe(sites, opts \\ []) when (sites == :all or is_list(sites)) and is_list(opts) do
    started = System.monotonic_time(:millisecond)

    result =
      with {:ok, ledger} <- Ledger.read(home(opts)),
           {keys, kept} = Ledger.take(ledger, sites),
           :ok <- delete(keys, :launch_headless, opts),
           :ok <- Ledger.write(home(opts), Ledger.retire(kept, keys)) do
        {:ok, %{cookies: length(keys), sites: sites}}
      end

    facts = %{sites: if(sites == :all, do: 0, else: length(sites)), cookies: deleted(result)}
    emit(:wiped, result, facts, started)
    result
  end

  @doc """
  Primary: deletes the cookies of every hand-off expired by now from the
  owner profile's running Chrome, and forgets them. With no Chrome running it
  leaves them for `purge_on_launch/2` and answers `{:ok, 0}`.
  """
  @spec sweep(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sweep(opts \\ []) when is_list(opts) do
    with {:ok, ledger} <- Ledger.read(home(opts)) do
      case Ledger.expired(ledger, now(opts)) do
        [] -> {:ok, 0}
        expired -> expire(ledger, expired, &delete(&1, :running_only, opts), opts)
      end
    end
  end

  @doc """
  Primary: through `command`, the DevTools connection of an owner-profile
  Chrome that just started, deletes the expired hand-offs' cookies and, once
  more, the ones deleted while an earlier Chrome ran (which it may not have
  written before it stopped), and forgets them all. `opts` as `store/2`.
  """
  @spec purge_on_launch(DevTools.command(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def purge_on_launch(command, opts \\ []) when is_function(command, 2) and is_list(opts) do
    with {:ok, ledger} <- Ledger.read(home(opts)) do
      case {Ledger.expired(ledger, now(opts)), ledger.purge} do
        {[], []} -> {:ok, 0}
        {expired, _again} -> purge(ledger, expired, command, opts)
      end
    end
  end

  # The deleted-again keys are not this launch's expiries: only the expired
  # hand-offs are counted and reported.
  defp purge(ledger, expired, command, opts) do
    with :ok <- delete_with(command, ledger.purge) do
      expire(Ledger.purged(ledger), expired, &delete_with(command, &1), opts)
    end
  end

  defp expire(ledger, [], _delete, opts) do
    with :ok <- Ledger.write(home(opts), ledger), do: {:ok, 0}
  end

  defp expire(ledger, expired, delete, opts) do
    started = System.monotonic_time(:millisecond)
    keys = Enum.flat_map(expired, & &1.cookies)
    sites = expired |> Enum.flat_map(& &1.sites) |> Enum.uniq()

    case delete.(keys) do
      {:error, :not_running} ->
        {:ok, 0}

      deleted ->
        result = with :ok <- deleted, do: forget(ledger, expired, keys, opts)
        emit(:expired, result, %{sites: length(sites), cookies: length(keys)}, started)
        with :ok <- result, do: {:ok, length(keys)}
    end
  end

  # The expired hand-offs go; their keys are deleted once more at the next
  # Chrome start, since the Chrome deleting them now may stop before it
  # writes that to its profile. A start clears what it deletes again, so a
  # key is deleted at most twice more.
  defp forget(ledger, expired, keys, opts) do
    ledger = Ledger.drop(ledger, Enum.map(expired, & &1.handoff_id))
    Ledger.write(home(opts), Ledger.retire(ledger, keys))
  end

  @doc "The hand-offs stored on this primary, oldest first. `opts`: `:home`."
  @spec list(keyword()) :: {:ok, [Ledger.entry()]} | {:error, term()}
  def list(opts \\ []) when is_list(opts) do
    with {:ok, %{handoffs: handoffs}} <- Ledger.read(home(opts)), do: {:ok, handoffs}
  end

  @doc """
  The expiry of a hand-off asked for `expires_s` seconds from `now` (the
  default when `nil`), or the refusal of a duration past 30 days.
  """
  @spec expires_at(pos_integer() | nil, DateTime.t()) ::
          {:ok, DateTime.t()} | {:error, {:expiry_too_long, pos_integer()}}
  def expires_at(nil, %DateTime{} = now), do: expires_at(@default_days * @day_s, now)

  def expires_at(seconds, %DateTime{} = now) when is_integer(seconds) and seconds > 0 do
    if seconds <= @max_days * @day_s,
      do: {:ok, now |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)},
      else: {:error, {:expiry_too_long, seconds}}
  end

  @doc "Parses the sites the owner named; see `Handoff.Sites.parse/2`."
  @spec sites([String.t()], boolean()) :: {:ok, [String.t()]} | {:error, Sites.refusal()}
  defdelegate sites(names, allow_identity_provider?), to: Sites, as: :parse

  defp delete([], _mode, _opts), do: :ok

  defp delete(keys, mode, opts) do
    devtools = Keyword.get(opts, :devtools, &DevTools.run/3)
    devtools.(mode, &delete_with(&1, keys), opts)
  end

  defp delete_with(_command, []), do: :ok

  defp delete_with(command, keys) do
    params = Enum.map(keys, &Cookies.delete_params/1)

    case command.("Storage.setCookies", %{"cookies" => params}) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:devtools_failed, reason}}
    end
  end

  defp deleted({:ok, %{cookies: count}}), do: count
  defp deleted(_failed), do: 0

  defp emit(op, {:ok, _value}, facts, started), do: Telemetry.emit(op, :ok, facts, started)
  defp emit(op, :ok, facts, started), do: Telemetry.emit(op, :ok, facts, started)

  defp emit(op, {:error, reason}, facts, started),
    do: Telemetry.emit(op, {:failed, reason}, facts, started)

  defp home(opts), do: Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)
  defp now(opts), do: Keyword.get(opts, :now, &DateTime.utc_now/0).()
end
