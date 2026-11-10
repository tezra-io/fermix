defmodule FermixChannels.Desktop.Join do
  @moduledoc """
  The computer's side of joining a home (M97 §3.1, §7.5): run in the dial
  subtree (`Desktop.DeviceSupervisor`) while `device/join.json` is here
  (`FermixCore.Home.Join`) and no link is.

  It dials the server the code named (`Mobile.Rail`, `:ikpsk2_enroll`: this
  computer's key from the secret store, the code's gateway key and secret)
  and sends `join_request` with this computer's host and system. Both ends
  derive six digits from the handshake under the computer label
  (`Rail.sas/2`); it records them (`awaiting_approval`), which tells the
  Always On watch, and waits for the owner. `join_approved` is taken
  (`Home.Join.finish/3`: the link, every offer off) and the engine restarts
  as the server's computer. `join_denied`, and a refusal of the code
  (`enrollment_used`, `enrollment_expired`, `enrollment_purpose`), are
  recorded as `denied` with the sentence that says why, and the worker ends;
  the owner cancels the join, or opens a new code.

  A server that cannot be reached, or a session that ends with no answer, is
  dialled again, 1 s doubling to 60 s, until the code's half hour is over;
  then the join is `denied` in its own words. The window re-admits this
  computer's key, so an answer lost to a dropped session reaches it again.
  A helper that restarts takes this worker with it (the dial subtree is
  `:rest_for_one`), and it starts again from the file.

  Test seams: `:home`, `:helper`, `:connect` (a route to a `Mobile.Rail`
  `:connect` function), `:clock`, `:sleep`, `:restart`, `:host` (the
  `join_request`'s `host` and `platform`), `:key_opts` (handed to
  `ComputerKey`) and `:status_changed` (0-arity, in place of telling the
  Always On watch).
  """

  use Task, restart: :transient

  require Logger

  alias FermixChannels.Mobile.Rail
  alias FermixCore.BuildInfo
  alias FermixCore.Home.ComputerKey
  alias FermixCore.Home.ComputerName
  alias FermixCore.Home.Join
  alias FermixCore.Home.StatusWatch
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.SecretWriter

  @first_retry_ms 1_000
  @max_retry_ms 60_000
  # The window lasts thirty minutes; a wait for the owner ends with it, and
  # this much later the worker stops waiting on its own.
  @answer_grace_ms 60_000

  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts) when is_list(opts), do: Task.start_link(__MODULE__, :run, [opts])

  @doc "Carries the join under `opts[:home]` on from its recorded phase."
  @spec run(keyword()) :: :ok
  def run(opts) do
    ctx = context(opts)

    case Join.read(ctx.home) do
      {:ok, %{"phase" => "denied"}} -> :ok
      {:ok, state} -> dial(ctx, state, @first_retry_ms)
      :absent -> :ok
      {:error, reason} -> Logger.error("join: the join could not be read: #{inspect(reason)}")
    end
  end

  defp context(opts) do
    %{
      home: Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0),
      helper: Keyword.get(opts, :helper),
      connect: Keyword.get(opts, :connect),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      sleep: Keyword.get(opts, :sleep, &Process.sleep/1),
      restart: Keyword.get(opts, :restart),
      host: Keyword.get_lazy(opts, :host, &host_facts/0),
      key_opts: Keyword.get(opts, :key_opts, []),
      status_changed: Keyword.get(opts, :status_changed, fn -> StatusWatch.changed(:link) end)
    }
  end

  # -- dialling --------------------------------------------------------------------

  defp dial(ctx, state, pause_ms) do
    case session(ctx, state) do
      {:answered, answer} -> answered(ctx, state, answer)
      {:again, reason} -> again(ctx, state, reason, pause_ms)
    end
  end

  # Until the code's half hour is over: then the join ends in its own words.
  defp again(ctx, state, reason, pause_ms) do
    if expired?(ctx, state) do
      Logger.warning("join: the code expired before the server answered (#{inspect(reason)})")
      deny(ctx, expired_sentence(state))
    else
      Logger.info("join: #{server(state)} not reached yet (#{inspect(reason)}); trying again")
      :ok = record(ctx, "dialing", %{"sas" => nil})
      ctx.sleep.(pause_ms)
      dial(ctx, state, min(pause_ms * 2, @max_retry_ms))
    end
  end

  defp session(ctx, state) do
    with {:ok, keys} <- keys(ctx, state),
         {:ok, rail} <- open(ctx, state, keys) do
      ask(ctx, state, rail)
    else
      {:error, reason} -> {:again, reason}
    end
  end

  defp keys(ctx, state) do
    with {:ok, store} <- SecretWriter.store_of_sentinel(state["key"]),
         {:ok, keypair} <- ComputerKey.read(ctx.home, [store: store] ++ ctx.key_opts),
         {:ok, gateway_pk} <- Base.decode64(state["server"]["gateway_pk"]),
         {:ok, secret} <- Base.decode64(state["secret"] || "") do
      {:ok, [static_keypair: keypair, remote_static: gateway_pk, psk: secret]}
    else
      {:error, reason} -> {:error, {:keys, reason}}
      :error -> {:error, {:keys, :invalid}}
    end
  end

  defp open(ctx, state, keys) do
    server = state["server"]

    route = %{
      node_id: server["node_id"],
      relays: server["relays"],
      relays_rev: server["relays_rev"]
    }

    carrier =
      case ctx.connect do
        nil -> [helper: ctx.helper]
        connect -> [connect: connect.(route)]
      end

    Rail.open(route, :ikpsk2_enroll, keys ++ carrier)
  end

  defp ask(ctx, state, rail) do
    sas = Rail.sas(rail, :computer)

    case Rail.send_event(rail, "join_request", ctx.host) do
      :ok ->
        :ok = record(ctx, "awaiting_approval", %{"sas" => sas})
        await(rail, wait_ms(ctx, state))

      {:error, reason} ->
        {:again, {:send, reason}}
    end
  end

  defp await(rail, wait_ms) do
    receive do
      {:rail, ^rail, {:event, %{"t" => "join_approved"} = approved, _bytes}} ->
        {:answered, {:approved, approved}}

      {:rail, ^rail, {:event, %{"t" => "join_denied", "reason" => reason}, _bytes}} ->
        {:answered, {:denied, reason}}

      {:rail, ^rail, {:event, %{"t" => "error", "code" => code}, _bytes}} ->
        {:answered, {:refused, code}}

      {:rail, ^rail, {:event, _other, _bytes}} ->
        await(rail, wait_ms)

      {:rail, ^rail, {:closed, reason}} ->
        {:again, {:closed, reason}}
    after
      wait_ms ->
        close(rail)
        {:again, :no_answer}
    end
  end

  # -- the answer --------------------------------------------------------------------

  defp answered(ctx, _state, {:approved, approved}) do
    Logger.info("join: added to the home as #{approved["name"]}; restarting as its computer")
    opts = [key_opts: ctx.key_opts] ++ restart_opt(ctx)

    case Join.finish(ctx.home, Map.delete(approved, "t"), opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("join: the server's approval could not be kept: #{inspect(reason)}")
        deny(ctx, Join.error_sentence(reason))
    end
  end

  defp answered(ctx, state, {:denied, reason}), do: deny(ctx, denied_sentence(reason, state))
  defp answered(ctx, state, {:refused, code}), do: deny(ctx, refused_sentence(code, state))

  defp deny(ctx, sentence) do
    :ok = record(ctx, "denied", %{"sentence" => sentence})
    :ok
  end

  defp denied_sentence("denied", state),
    do: "#{server(state)} did not add this computer. Open a new code there to try again."

  defp denied_sentence("timeout", state),
    do: "Nobody added this computer on #{server(state)} in time. Open a new code there."

  defp denied_sentence("cancelled", state),
    do: "The code was cancelled on #{server(state)}. Open a new one there to try again."

  defp denied_sentence(_disconnected, state),
    do:
      "This computer's connection to #{server(state)} dropped before it was added. Open a " <>
        "new code there to try again."

  defp refused_sentence("enrollment_used", state),
    do: "That code was already used on #{server(state)}. Open a new one there."

  defp refused_sentence("enrollment_expired", state), do: expired_sentence(state)

  defp refused_sentence(_code, state),
    do: "#{server(state)} did not take that code. Open a new one with Add a computer."

  defp expired_sentence(state),
    do: "The code expired before this computer was added on #{server(state)}. Open a new one."

  # -- facts ---------------------------------------------------------------------------

  defp record(ctx, phase, fields) do
    with :ok <- Join.record(ctx.home, phase, fields) do
      ctx.status_changed.()
    end
  end

  defp expired?(ctx, state), do: DateTime.compare(ctx.clock.(), expires_at(state)) != :lt

  # Until the window's half hour is over, and a little more.
  defp wait_ms(ctx, state),
    do: max(DateTime.diff(expires_at(state), ctx.clock.(), :millisecond), 0) + @answer_grace_ms

  defp expires_at(state) do
    {:ok, at, _offset} = DateTime.from_iso8601(state["expires_at"])
    at
  end

  defp server(state), do: state["server"]["name"]

  defp restart_opt(%{restart: nil}), do: []
  defp restart_opt(%{restart: restart}), do: [restart: restart]

  defp close(rail) do
    Rail.close(rail)
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal] -> :ok
  end

  defp host_facts do
    {:ok, name} = ComputerName.read()
    arch = :erlang.system_info(:system_architecture) |> to_string() |> String.split("-") |> hd()

    %{
      "host" => %{
        "name" => name,
        "os" => os(),
        "arch" => arch,
        "version" => BuildInfo.product_version()
      },
      "platform" => platform()
    }
  end

  defp os do
    {_family, os} = :os.type()
    Atom.to_string(os)
  end

  # A computer's `platform`: the two systems a computer runs Fermix on.
  defp platform do
    case :os.type() do
      {:unix, :darwin} -> "macos"
      {:unix, :linux} -> "linux"
    end
  end
end
