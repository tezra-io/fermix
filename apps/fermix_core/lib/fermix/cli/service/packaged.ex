defmodule Fermix.CLI.Service.Packaged do
  @moduledoc """
  The service transaction for a Fermix installed from a Linux distribution
  package (M38 §4.1, §4.4, §4.7).

  The package owns `/usr/lib/systemd/user/fermix.service`, so **nothing here
  ever writes a unit file**. What this CLI owns is the per-user binding, the
  linger grant, the enablement and one named drop-in, and it verifies the
  outcome rather than trusting the exit status of `systemctl enable`.

  `install/1` is one ordered sequence with no alternative route through it:

    1. inspect the user unit path; a foreign unit or a foreign drop-in refuses
       and names the file it will not touch,
    2. resolve the home from `--home`, else the binding, else a recognised
       legacy generated unit, else the default,
    3. refuse to move an active service's home,
    4. persist the listener port through the shared config write,
    5. migrate a recognised legacy unit: carry its observability values into
       the CLI-owned drop-in, remove the shadowing unit, reload,
    6. require linger, which is fatal before enablement,
    7. reload, reset the start-limit budget, enable now,
    8. verify: the bound home's own socket answers `hello` as a packaged
       engine, and that daemon's own web address answers, inside 90 seconds.

  Every command runs through `opts[:cmd]`, every socket call through
  `opts[:hello]` and every web probe through `opts[:health_probe]`, so the
  whole transaction is reachable from fixtures.
  """

  alias Fermix.CLI.Daemon.Client
  alias Fermix.CLI.Service
  alias Fermix.CLI.Service.Binding
  alias Fermix.CLI.Service.Status
  alias Fermix.CLI.Service.Systemd
  alias Fermix.CLI.Service.Templates
  alias FermixCore.BuildInfo
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.WebListener

  @unit "fermix.service"
  @drop_in_name "fermix-observability.conf"
  @engine_manifest "/usr/share/fermix/engine.json"
  @socket_name "daemon.sock"
  @hello_timeout_ms 3_000

  # 500 ms × 180 = 90 s, the activation ceiling §4.1 sets for one transaction.
  @poll_interval_ms 500
  @poll_attempts 180

  @type reason ::
          :user_manager_unreachable
          | :service_unbound
          | :loginctl_absent
          | :no_identity
          | :activation_timeout
          | :health_unavailable
          | {:invalid_home, String.t()}
          | {:invalid_port, String.t()}
          | {:lifecycle_refused, String.t()}
          | {:config_write_failed, term()}
          | {:home_change_refused, Path.t()}
          | {:foreign_unit, Path.t()}
          | {:linger_denied, String.t()}
          | {:systemctl_failed, non_neg_integer(), String.t()}
          | {:binding_write_failed, term()}

  @doc "Binds, enables and verifies this account's packaged background service."
  @spec install(keyword()) :: {:ok, map()} | {:error, reason()}
  def install(opts \\ []) when is_list(opts) do
    with {:ok, unit_state} <- inspect_user_unit(opts),
         {:ok, properties} <- Systemd.show(@unit, opts),
         {:ok, home} <- resolve_home(unit_state, properties, opts),
         :ok <- Service.persist_port(home, Keyword.get(opts, :port)),
         :ok <- write_binding(home, opts),
         :ok <- migrate(unit_state, opts),
         :ok <- require_linger(opts),
         :ok <- enable(opts),
         {:ok, hello} <- verify(home, opts) do
      build_status(home, hello, opts)
    end
  end

  # `resolve_home/3` has already validated this home, so a refusal here is a
  # binding file that changed underneath the transaction. It is republished as
  # the home refusal it is rather than reaching the renderer's untyped branch.
  defp write_binding(home, opts) do
    case Binding.write(home, binding_opts(opts)) do
      :ok -> :ok
      {:error, {:invalid, sentence}} -> {:error, {:invalid_home, sentence}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Restarts this account's packaged background service (M38 §4.1).

  One ordered transaction, and the ordering is the point:

    1. `hello` on the bound home's socket, for the generation being replaced,
    2. `lifecycle.prepare` on that same generation — interrupt mode, because
       published protocol 1 and 2 have no idle lease to take,
    3. `reset-failed`, so this explicit attempt gets the whole start budget,
    4. one `systemctl --user restart`,
    5. wait for a **different** pid to answer, inside the same 90-second ceiling
       `install` uses,
    6. the typed alignment of the new generation against the installed engine.

  **The lease is never committed.** `lifecycle.commit` means "shut this process
  down", and on Linux systemd owns the termination signal; committing would ask
  the daemon to stop itself out from under the restart job. The lease is
  cancelled on a failure that happens **before** the restart is issued — the
  generation that granted it is still alive then — and left to expire with its
  process afterwards. No lease is ever carried into the new generation.

  A daemon that is not answering is a recovery, not a refusal: there is no
  previous pid and no lease to take, so the reset and restart run and the wait
  accepts the first generation that answers.
  """
  @spec restart(keyword()) :: {:ok, map()} | {:error, reason()}
  def restart(opts \\ []) when is_list(opts) do
    with {:ok, home} <- bound_home(opts),
         {:ok, previous} <- previous_generation(home, opts),
         :ok <- issue_restart(previous, opts),
         {:ok, hello} <- await_new_generation(home, previous.pid, opts) do
      {:ok, restart_result(previous.pid, hello, opts)}
    end
  end

  @doc """
  Disables and stops this account's packaged background service.

  The binding, the home, the vendor unit and the extracted runtime all stay:
  this is "stop running it", not "forget it was ever set up".
  """
  @spec uninstall(keyword()) :: :ok | {:error, reason()}
  def uninstall(opts \\ []) when is_list(opts) do
    Systemd.disable_now(@unit, opts)
  end

  @doc """
  Whether this account's packaged background service is set up.

  Two facts, both required: a home is bound, and the package's own unit is the
  effective one. Either alone is a half-install — a binding with a foreign unit
  shadowing the vendor one is not a service this CLI drives, and a vendor unit
  with no binding has no home to start in.

  A predicate has one answer, so an unreachable user manager is "not set up"
  rather than a raised error: the callers are `fermix setup`'s activation and
  the published service state, and both must treat a session that cannot see a
  service manager as a session with no service. The reasoned refusal for the
  same condition is `status/1`'s `user_manager_unreachable`.
  """
  @spec installed?(keyword()) :: boolean()
  def installed?(opts \\ []) when is_list(opts) do
    bound?(opts) and vendor_unit_effective?(opts)
  end

  defp bound?(opts), do: match?({:ok, _binding}, Binding.read(binding_opts(opts)))

  defp vendor_unit_effective?(opts) do
    case Systemd.show(@unit, opts) do
      {:ok, properties} -> properties["FragmentPath"] == Status.vendor_unit_path()
      {:error, _unreachable_or_unreadable} -> false
    end
  end

  @doc """
  The published service status (§4.4.1), available with no daemon running.

  An unreachable user manager is a structured error rather than an inactive
  unit, because the two call for different remedies.
  """
  @spec status(keyword()) :: {:ok, map()} | {:error, reason()}
  def status(opts \\ []) when is_list(opts) do
    with {:ok, properties} <- Systemd.show(@unit, opts) do
      binding = Binding.read(binding_opts(opts))

      {:ok,
       Status.build(%{
         binding: binding,
         properties: properties,
         user_unit: published_unit_state(opts),
         linger: Systemd.linger_state(opts),
         installed: installed(opts),
         hello: bound_hello(binding, opts),
         configured_listener: configured_listener(binding)
       })}
    end
  end

  # ── the sequence ───────────────────────────────────────────────────────────

  # A unit this binary did not write is never rewritten, and neither is a
  # drop-in it does not own. Both refuse by naming the exact file.
  defp inspect_user_unit(opts) do
    path = user_unit_path(opts)

    case foreign_drop_in(path) do
      nil -> {:ok, {Status.classify_unit(read_unit(path)), path}}
      drop_in -> {:error, {:foreign_unit, drop_in}}
    end
    |> refuse_foreign_unit()
  end

  defp refuse_foreign_unit({:ok, {:foreign, path}}), do: {:error, {:foreign_unit, path}}
  defp refuse_foreign_unit(result), do: result

  defp resolve_home({kind, path}, properties, opts) do
    selected =
      case Keyword.get(opts, :home) do
        home when is_binary(home) -> {:selected, home}
        nil -> inherited_home(kind, path, opts)
      end

    with {:ok, home} <- validated_home(selected) do
      refuse_move(home, properties, opts)
    end
  end

  # The binding wins over the legacy unit, because an operator who has already
  # bound a home chose it; the legacy unit only answers on a first migration.
  defp inherited_home(kind, path, opts) do
    case Binding.read(binding_opts(opts)) do
      {:ok, %{home: home}} -> {:selected, home}
      {:error, {:invalid, sentence}} -> {:invalid, sentence}
      {:error, :missing} -> legacy_or_default(kind, path, opts)
    end
  end

  defp legacy_or_default(:legacy_generated, path, opts) do
    case Status.legacy_home(read_unit(path)) do
      {:ok, home} -> {:selected, home}
      :error -> {:selected, default_home(opts)}
    end
  end

  defp legacy_or_default(_kind, _path, opts), do: {:selected, default_home(opts)}

  defp validated_home({:invalid, sentence}), do: {:error, {:invalid_home, sentence}}

  defp validated_home({:selected, home}) do
    case Binding.validate(home) do
      :ok -> {:ok, home}
      {:error, {:invalid, sentence}} -> {:error, {:invalid_home, sentence}}
    end
  end

  # Changing an active service's home is refused until it has been stopped
  # explicitly: the running daemon owns the sockets and the memory database of
  # the home it was started with (§4.7).
  defp refuse_move(home, properties, opts) do
    bound = Binding.read(binding_opts(opts))
    active? = properties["ActiveState"] == "active"

    case bound do
      {:ok, %{home: current}} when active? and current != home ->
        {:error, {:home_change_refused, current}}

      _otherwise ->
        {:ok, home}
    end
  end

  defp migrate({:legacy_generated, path}, opts) do
    contents = read_unit(path)

    with :ok <- write_drop_in(path, Status.legacy_observability(contents)),
         :ok <- remove_unit(path) do
      Systemd.daemon_reload(opts)
    end
  end

  defp migrate({_kind, _path}, _opts), do: :ok

  defp require_linger(opts) do
    case Systemd.ensure_linger(opts) do
      :ok -> :ok
      :already_enabled -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp enable(opts) do
    with :ok <- Systemd.daemon_reload(opts),
         :ok <- Systemd.reset_failed(@unit, opts) do
      Systemd.enable_now(@unit, opts)
    end
  end

  # The completion proof (§4.1): this home's own socket answers as a packaged
  # engine, and that same daemon's published web address answers. A `systemctl`
  # exit status is not evidence that any of that happened.
  defp verify(home, opts) do
    attempts = Keyword.get(opts, :poll_attempts, @poll_attempts)

    with {:ok, hello} <- await_packaged_hello(home, attempts, opts),
         :ok <- probe_health(hello, opts) do
      {:ok, hello}
    end
  end

  defp await_packaged_hello(_home, attempts, _opts) when attempts <= 0 do
    {:error, :activation_timeout}
  end

  defp await_packaged_hello(home, attempts, opts) do
    case hello(home, opts) do
      {:ok, %{"engine" => %{"distribution_identity" => "linux_package"}} = hello} ->
        {:ok, hello}

      _not_yet ->
        sleep(opts).(@poll_interval_ms)
        await_packaged_hello(home, attempts - 1, opts)
    end
  end

  defp probe_health(hello, opts) do
    origin = get_in(hello, ["setup", "origin"])

    case health_probe(opts).(origin) do
      :ok -> :ok
      {:error, _reason} -> {:error, :health_unavailable}
    end
  end

  # Re-read after enablement, because the properties gathered at step 2 describe
  # the unit before it was started. A manager that stops answering between the
  # two reads is the same refusal every other step would give, not a crash in
  # the renderer that was about to print the success.
  defp build_status(home, hello, opts) do
    with {:ok, properties} <- Systemd.show(@unit, opts) do
      binding = {:ok, %{home: home}}

      {:ok,
       Status.build(%{
         binding: binding,
         properties: properties,
         user_unit: published_unit_state(opts),
         linger: Systemd.linger_state(opts),
         installed: installed(opts),
         hello: hello,
         configured_listener: configured_listener(binding)
       })}
    end
  end

  # What the listener WOULD be from this home's settings, for the status a
  # stopped service still has to answer. A running daemon's own published origin
  # wins over it, because that is the port something is actually listening on.
  defp configured_listener({:ok, %{home: home}}) do
    case WebListener.configured_port(home) do
      {:ok, port} -> WebListener.port("linux_package", %{}, configured: port)
      {:error, reason} -> {:error, reason}
    end
  end

  defp configured_listener(_unbound_or_invalid), do: {:error, :unbound}

  # ── restart ────────────────────────────────────────────────────────────────

  defp bound_home(opts) do
    case Binding.read(binding_opts(opts)) do
      {:ok, %{home: home}} -> {:ok, home}
      {:error, :missing} -> {:error, :service_unbound}
      {:error, {:invalid, sentence}} -> {:error, {:invalid_home, sentence}}
    end
  end

  # The generation being replaced, and the admission lease taken from it. A
  # daemon that does not answer has neither, and that is the recovery case
  # rather than a refusal.
  defp previous_generation(home, opts) do
    case hello(home, opts) do
      {:ok, hello} -> prepared_generation(engine_pid(hello), opts)
      {:error, _not_running} -> {:ok, %{pid: nil, lease: nil}}
    end
  end

  defp prepared_generation(pid, opts) do
    case request(home_socket(opts), "lifecycle.prepare", %{}, opts) do
      {:ok, %{"lease_id" => lease}} when is_binary(lease) -> {:ok, %{pid: pid, lease: lease}}
      {:ok, _other} -> {:error, {:lifecycle_refused, "the daemon returned no lease"}}
      {:error, reason} -> {:error, {:lifecycle_refused, Client.describe_error(reason)}}
    end
  end

  defp issue_restart(previous, opts) do
    with :ok <- Systemd.reset_failed(@unit, opts),
         :ok <- Systemd.restart(@unit, opts) do
      :ok
    else
      {:error, reason} ->
        # Still the live generation, so its lease is cancellable and leaving it
        # held would refuse the operator's next attempt for the whole ttl.
        _ = cancel_lease(previous, opts)
        {:error, reason}
    end
  end

  defp cancel_lease(%{lease: nil}, _opts), do: :ok

  defp cancel_lease(%{lease: lease}, opts) do
    request(home_socket(opts), "lifecycle.cancel", %{"lease_id" => lease}, opts)
  end

  defp await_new_generation(home, previous_pid, opts) do
    attempts = Keyword.get(opts, :poll_attempts, @poll_attempts)

    poll_new_generation(home, previous_pid, attempts, opts)
  end

  defp poll_new_generation(_home, _previous_pid, attempts, _opts) when attempts <= 0 do
    {:error, :activation_timeout}
  end

  defp poll_new_generation(home, previous_pid, attempts, opts) do
    case hello(home, opts) do
      {:ok, hello} -> new_generation(hello, home, previous_pid, attempts, opts)
      {:error, _not_yet} -> retry_generation(home, previous_pid, attempts, opts)
    end
  end

  # The same pid is the old process still serving: the restart job replies
  # before the VM stops, so an answer is not by itself a new generation.
  defp new_generation(hello, home, previous_pid, attempts, opts) do
    case engine_pid(hello) do
      pid when is_binary(pid) and pid != previous_pid -> {:ok, hello}
      _same_or_absent -> retry_generation(home, previous_pid, attempts, opts)
    end
  end

  defp retry_generation(home, previous_pid, attempts, opts) do
    sleep(opts).(@poll_interval_ms)
    poll_new_generation(home, previous_pid, attempts - 1, opts)
  end

  defp restart_result(previous_pid, hello, opts) do
    running = Map.get(hello, "engine")

    %{
      "previous_pid" => previous_pid,
      "pid" => engine_pid(hello),
      "alignment" => Status.alignment(installed(opts), running)
    }
  end

  defp engine_pid(hello), do: get_in(hello, ["engine", "pid"])

  defp home_socket(opts) do
    case Binding.read(binding_opts(opts)) do
      {:ok, %{home: home}} -> Path.join(home, @socket_name)
      {:error, _absent} -> nil
    end
  end

  defp request(socket_path, method, params, opts) do
    Keyword.get(opts, :request, &default_request/3).(socket_path, method, params)
  end

  defp default_request(socket_path, method, params) do
    Client.request_v1(method, params, socket_path: socket_path, timeout: @hello_timeout_ms)
  end

  # ── evidence ───────────────────────────────────────────────────────────────

  defp published_unit_state(opts) do
    path = user_unit_path(opts)

    case foreign_drop_in(path) do
      nil -> Status.classify_unit(read_unit(path))
      _drop_in -> :foreign
    end
  end

  defp installed(opts) do
    build_info = Keyword.get(opts, :build_info, BuildInfo)
    Status.installed(build_info.public_identity(), read_manifest(opts))
  end

  defp read_manifest(opts) do
    path = Keyword.get(opts, :engine_manifest_path, @engine_manifest)

    with {:ok, contents} <- File.read(path), do: Jason.decode(contents)
  end

  defp bound_hello({:ok, %{home: home}}, opts) do
    case hello(home, opts) do
      {:ok, hello} -> hello
      {:error, _not_running} -> nil
    end
  end

  defp bound_hello(_unbound_or_invalid, _opts), do: nil

  defp hello(home, opts) do
    Keyword.get(opts, :hello, &default_hello/1).(Path.join(home, @socket_name))
  end

  defp default_hello(socket_path) do
    Client.request_v1("hello", %{}, socket_path: socket_path, timeout: @hello_timeout_ms)
  end

  # ── files this CLI owns ────────────────────────────────────────────────────

  defp write_drop_in(_unit_path, environment) when map_size(environment) == 0, do: :ok

  defp write_drop_in(unit_path, environment) do
    dir = unit_path <> ".d"
    path = Path.join(dir, @drop_in_name)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, drop_in_body(environment)) do
      :ok
    else
      {:error, reason} -> {:error, {:binding_write_failed, reason}}
    end
  end

  defp drop_in_body(environment) do
    assignments =
      environment
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join("\n", fn {key, value} ->
        Templates.systemd_environment(key, value)
      end)

    "[Service]\n" <> assignments <> "\n"
  end

  defp remove_unit(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:binding_write_failed, reason}}
    end
  end

  defp foreign_drop_in(unit_path) do
    dir = unit_path <> ".d"

    case File.ls(dir) do
      {:ok, entries} -> entries |> Enum.sort() |> foreign_entry(dir)
      {:error, _absent} -> nil
    end
  end

  defp foreign_entry(entries, dir) do
    case Enum.reject(entries, &(&1 == @drop_in_name)) do
      [] -> nil
      [name | _rest] -> Path.join(dir, name)
    end
  end

  defp read_unit(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, _absent} -> nil
    end
  end

  # ── injection ──────────────────────────────────────────────────────────────

  defp binding_opts(opts) do
    case Keyword.fetch(opts, :binding_root) do
      {:ok, root} -> [root: root]
      :error -> []
    end
  end

  defp user_unit_path(opts) do
    Keyword.get_lazy(opts, :user_unit_path, fn ->
      Path.join(System.user_home!(), ".config/systemd/user/#{@unit}")
    end)
  end

  defp default_home(opts) do
    Keyword.get_lazy(opts, :default_home, &ConfigStore.fermix_home/0)
  end

  defp sleep(opts), do: Keyword.get(opts, :sleep, &Process.sleep/1)

  defp health_probe(opts), do: Keyword.get(opts, :health_probe, &Service.health_probe/1)
end
