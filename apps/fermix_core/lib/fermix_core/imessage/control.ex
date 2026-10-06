defmodule FermixCore.IMessage.Control do
  @moduledoc """
  One-shot control-plane calls to the **Fermix Messages** helper (M54 §6, R8).

  The control plane never opens the Messages database and works from zero
  permissions, so the engine can read and change the helper's state before
  anything is granted: `probe/1` (never prompts), `grant/2` (the one system
  prompt, or the Full Disk Access pane), `policy_get/1` and `policy_set/2` (the
  helper's own on-screen confirmation). Each call spawns the helper binary
  directly, outside the channel's long-lived `serve` session, so setup,
  Doctor and the management wire need nothing from `fermix_channels`.

  ## The one-shot contract

      fermix-messages probe      --home <FERMIX_HOME>
      fermix-messages grant      --home <FERMIX_HOME> --service automation|full_disk_access
      fermix-messages policy-get --home <FERMIX_HOME>
      fermix-messages policy-set --home <FERMIX_HOME> --owner <handle> [--handle <handle>]...

  The helper writes exactly one JSON object to stdout and exits 0, whether the
  object is a result or `{"error": {"kind", "message"}}` with a kind from the
  closed vocabulary in §6. A process-level failure exits with the
  compux/disclaim code instead (64 usage, 70 disclaim unavailable, 71 disclaim
  refused, 72 exec failed, 74 I/O, 75 temporary, 76 protocol) and its stdout is
  not read. `stderr` is the helper's log and is left to the daemon's.

  Every call is bounded: 15 s for a probe or a policy read, 120 s for a grant
  (a person answers the prompt) and 180 s for a policy confirmation (a person
  reads the dialog). At the bound the helper's process group is killed and the
  call answers `{:error, :timeout}`. Parsing is pure (`parse/2`,
  `exit_error/1`); only `run/3` touches a process.

  The account posture is never asked of the owner or sent to the helper: the
  helper derives it when it confirms the recipients (the owner among the
  signed-in account's own aliases is `own_account`, anything else
  `dedicated_account`), refuses an owner that is this Mac's own address with
  `owner_is_this_mac` until the own-account mode is supported, and reports the
  posture it stored in every `policy-get` and `policy-set` result.
  """

  alias FermixCore.IMessage
  alias FermixCore.IMessage.HelperInstaller
  alias FermixCore.ProcessGroup
  alias FermixCore.Setup.ConfigStore

  @probe_timeout_ms 15_000
  @grant_timeout_ms 120_000
  @policy_get_timeout_ms 15_000
  @policy_set_timeout_ms 180_000
  @max_stdout_bytes 1_048_576

  @services [:automation, :full_disk_access]

  @exit_classes %{
    64 => :usage,
    70 => :disclaim_unavailable,
    71 => :disclaim_refused,
    72 => :exec_failed,
    74 => :io,
    75 => :temporary,
    76 => :protocol
  }

  # The closed error vocabulary of protocol v1 (M54 §6), word => atom, built
  # once from the literal list so no helper-supplied string ever becomes an atom.
  @error_kinds ~w(
                 not_initialized protocol_mismatch permission_denied db_missing db_unreadable
                 db_schema_unexpected policy_absent policy_unconfirmed policy_refused
                 policy_violation owner_not_self owner_is_this_mac not_signed_in no_user_session
                 service_not_imessage chat_not_found automation_refused send_timeout
                 path_refused attachment_not_admitted attachment_too_large busy
               )
               |> Map.new(&{&1, String.to_atom(&1)})

  # field => the closed word set it may carry. `signed_in` is the one that is a
  # boolean OR a word: it needs Automation, and without it the helper cannot say.
  @probe_words %{
    full_disk_access: %{"granted" => :granted, "denied" => :denied},
    db: %{
      "readable" => :readable,
      "missing" => :missing,
      "unreadable" => :unreadable,
      "schema_unexpected" => :schema_unexpected
    },
    automation: %{
      "granted" => :granted,
      "denied" => :denied,
      "not_determined" => :not_determined,
      "unknown" => :unknown
    },
    policy: %{"confirmed" => :confirmed, "unconfirmed" => :unconfirmed, "absent" => :absent}
  }
  @probe_booleans [:messages_running, :user_session]

  @type service :: :automation | :full_disk_access
  @type posture :: :dedicated_account | :own_account
  @type probe :: %{
          helper_version: String.t(),
          full_disk_access: :granted | :denied,
          db: :readable | :missing | :unreadable | :schema_unexpected,
          automation: :granted | :denied | :not_determined | :unknown,
          messages_running: boolean(),
          signed_in: boolean() | :unknown,
          user_session: boolean(),
          policy: :confirmed | :unconfirmed | :absent,
          self_aliases: [String.t()] | nil
        }
  @type policy :: %{
          posture: posture(),
          owner_handle: String.t(),
          handles: [String.t()],
          confirmed_at: String.t()
        }
  @type policy_request :: %{owner_handle: String.t(), handles: [String.t()]}
  @type confirmation :: %{confirmed_at: String.t(), posture: posture()}
  @type exit_class ::
          :usage
          | :disclaim_unavailable
          | :disclaim_refused
          | :exec_failed
          | :io
          | :temporary
          | :protocol
          | {:unexpected, integer()}
  @type error ::
          :not_installed
          | :timeout
          | {:spawn_failed, term()}
          | {:helper_exit, exit_class()}
          | {:helper_error, atom(), String.t()}
          | {:helper_protocol, term()}
  @type kind :: :probe | :grant | :policy_get | :policy_set

  @doc "The non-prompting permission and policy state."
  @spec probe(keyword()) :: {:ok, probe()} | {:error, error()}
  def probe(opts \\ []) when is_list(opts) do
    run(:probe, ["probe" | home_args(opts)], timeout(opts, @probe_timeout_ms), opts)
  end

  @doc "Asks for one grant, then answers with the probe afterwards."
  @spec grant(service(), keyword()) :: {:ok, probe()} | {:error, error()}
  def grant(service, opts \\ []) when service in @services and is_list(opts) do
    args = ["grant" | home_args(opts)] ++ ["--service", Atom.to_string(service)]

    run(:grant, args, timeout(opts, @grant_timeout_ms), opts)
  end

  @doc "The recipient policy the helper holds, or `nil` when none is stored."
  @spec policy_get(keyword()) :: {:ok, policy() | nil} | {:error, error()}
  def policy_get(opts \\ []) when is_list(opts) do
    run(
      :policy_get,
      ["policy-get" | home_args(opts)],
      timeout(opts, @policy_get_timeout_ms),
      opts
    )
  end

  @doc """
  Asks the helper to store a recipient policy. A changed policy shows the
  helper's own dialog; `{:error, {:helper_error, :policy_refused, _}}` is the
  owner pressing Cancel, and `{:error, {:helper_error, :owner_is_this_mac, _}}`
  an owner that is the address Messages on this Mac is signed in as. The
  result names the posture the helper derived.
  """
  @spec policy_set(policy_request(), keyword()) :: {:ok, confirmation()} | {:error, error()}
  def policy_set(%{owner_handle: owner, handles: handles}, opts \\ [])
      when is_binary(owner) and is_list(handles) and is_list(opts) do
    args =
      ["policy-set" | home_args(opts)] ++
        ["--owner", owner] ++ Enum.flat_map(handles, &["--handle", &1])

    run(:policy_set, args, timeout(opts, @policy_set_timeout_ms), opts)
  end

  @doc """
  The policy a confirmation stores for a saved `[fermix_channels.imessage]`
  section: its normalized owner and every recipient
  (`FermixCore.IMessage.policy_handles/1`). The posture is the helper's to
  derive, so it is not part of the request.
  """
  @spec policy_for_config(keyword()) :: {:ok, policy_request()} | {:error, :owner_missing}
  def policy_for_config(config) when is_list(config) do
    case Keyword.get(config, :owner_user_id) do
      owner when is_binary(owner) ->
        {:ok,
         %{
           owner_handle: IMessage.normalize_handle!(owner),
           handles: IMessage.policy_handles(config)
         }}

      _missing ->
        {:error, :owner_missing}
    end
  end

  # A handle the helper returned is already normalized; one it could not be
  # normalized from compares as itself, so a corrupt item never matches.
  defp normalized_or_raw(handle) do
    case IMessage.normalize_handle(handle) do
      {:ok, normalized} -> normalized
      {:error, :invalid_handle} -> handle
    end
  end

  @doc """
  Whether the helper's stored policy (a `policy_get/1` result) names exactly
  the saved section's owner and recipients. The posture it carries is the
  helper's own derivation, so it is not compared. A mismatch is the state
  "Awaiting confirmation" (§10.1); it is resolved by a confirmation, never by
  the engine rewriting the helper's item.
  """
  @spec policy_matches_config?(policy() | nil, keyword()) :: boolean()
  def policy_matches_config?(nil, config) when is_list(config), do: false

  def policy_matches_config?(%{owner_handle: owner, handles: handles}, config)
      when is_list(config) do
    case policy_for_config(config) do
      {:ok, expected} ->
        owner == expected.owner_handle and
          Enum.sort(Enum.map(handles, &normalized_or_raw/1)) == Enum.sort(expected.handles)

      {:error, :owner_missing} ->
        false
    end
  end

  @doc """
  Parses the one JSON object a call printed (pure). An error object maps onto
  the closed helper vocabulary; anything outside it is a protocol error rather
  than a word passed through.
  """
  @spec parse(kind(), binary()) :: {:ok, term()} | {:error, error()}
  def parse(kind, stdout) when kind in [:probe, :grant, :policy_get, :policy_set] do
    case Jason.decode(String.trim(stdout)) do
      {:ok, %{"error" => error}} -> helper_error(error)
      {:ok, decoded} -> result(kind, decoded)
      {:error, _reason} -> {:error, {:helper_protocol, :invalid_json}}
    end
  end

  @doc """
  The typed probe from one decoded JSON object (pure). The serving helper's
  `probe` result and the one-shot command's stdout share this shape, so the
  channel's Listener and the one-shot callers gate on the same words.
  """
  @spec decode_probe(map()) :: {:ok, probe()} | {:error, error()}
  def decode_probe(decoded) when is_map(decoded), do: parse_probe(decoded)

  @doc """
  The typed stored policy from one decoded `policy.get` result (pure). The
  serving helper's answer and the one-shot command's stdout share this shape,
  so the channel's Listener reads the derived posture the way setup does.
  """
  @spec decode_policy(map()) :: {:ok, policy()} | {:error, error()}
  def decode_policy(decoded) when is_map(decoded), do: parse_policy(decoded)

  @doc "The typed class of a non-zero helper exit (pure)."
  @spec exit_error(integer()) :: {:helper_exit, exit_class()}
  def exit_error(status) when is_integer(status),
    do: {:helper_exit, Map.get(@exit_classes, status, {:unexpected, status})}

  defp helper_error(%{"kind" => kind} = error) do
    case Map.fetch(@error_kinds, kind) do
      {:ok, atom} -> {:error, {:helper_error, atom, error_text(Map.get(error, "message"))}}
      :error -> {:error, {:helper_protocol, {:unknown_error_kind, kind}}}
    end
  end

  defp helper_error(_error), do: {:error, {:helper_protocol, :invalid_error}}

  defp error_text(message) when is_binary(message), do: message
  defp error_text(_absent), do: ""

  defp result(kind, decoded) when kind in [:probe, :grant] and is_map(decoded),
    do: parse_probe(decoded)

  defp result(:policy_get, nil), do: {:ok, nil}
  defp result(:policy_get, decoded) when is_map(decoded), do: parse_policy(decoded)

  defp result(:policy_set, decoded) when is_map(decoded) do
    with {:ok, confirmed_at} <- string_field(decoded, "confirmed_at"),
         {:ok, posture} <- posture(Map.get(decoded, "posture")) do
      {:ok, %{confirmed_at: confirmed_at, posture: posture}}
    end
  end

  defp result(_kind, _decoded), do: {:error, {:helper_protocol, :invalid_json}}

  defp parse_probe(decoded) do
    with {:ok, words} <- probe_words(decoded),
         {:ok, booleans} <- probe_booleans(decoded),
         {:ok, signed_in} <- signed_in(Map.get(decoded, "signed_in")),
         {:ok, version} <- string_field(decoded, "helper_version"),
         {:ok, aliases} <- aliases(Map.get(decoded, "self_aliases")) do
      {:ok,
       words
       |> Map.merge(booleans)
       |> Map.merge(%{signed_in: signed_in, helper_version: version, self_aliases: aliases})}
    end
  end

  defp probe_words(decoded) do
    Enum.reduce_while(@probe_words, {:ok, %{}}, fn {field, words}, {:ok, acc} ->
      value = Map.get(decoded, Atom.to_string(field))

      case Map.fetch(words, value) do
        {:ok, word} -> {:cont, {:ok, Map.put(acc, field, word)}}
        :error -> {:halt, invalid(Atom.to_string(field), value)}
      end
    end)
  end

  defp probe_booleans(decoded) do
    Enum.reduce_while(@probe_booleans, {:ok, %{}}, fn field, {:ok, acc} ->
      case Map.get(decoded, Atom.to_string(field)) do
        value when is_boolean(value) -> {:cont, {:ok, Map.put(acc, field, value)}}
        other -> {:halt, invalid(Atom.to_string(field), other)}
      end
    end)
  end

  defp signed_in(value) when is_boolean(value), do: {:ok, value}
  defp signed_in("unknown"), do: {:ok, :unknown}
  defp signed_in(other), do: invalid("signed_in", other)

  defp aliases(nil), do: {:ok, nil}

  defp aliases(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1), do: {:ok, list}, else: invalid("self_aliases", list)
  end

  defp aliases(other), do: invalid("self_aliases", other)

  defp parse_policy(decoded) do
    with {:ok, posture} <- posture(Map.get(decoded, "posture")),
         {:ok, owner} <- string_field(decoded, "owner_handle"),
         {:ok, handles} <- handles(Map.get(decoded, "handles")),
         {:ok, confirmed_at} <- string_field(decoded, "confirmed_at") do
      {:ok,
       %{posture: posture, owner_handle: owner, handles: handles, confirmed_at: confirmed_at}}
    end
  end

  defp posture("dedicated_account"), do: {:ok, :dedicated_account}
  defp posture("own_account"), do: {:ok, :own_account}
  defp posture(other), do: invalid("posture", other)

  defp handles(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1), do: {:ok, list}, else: invalid("handles", list)
  end

  defp handles(other), do: invalid("handles", other)

  defp string_field(decoded, field) do
    case Map.get(decoded, field) do
      value when is_binary(value) and value != "" -> {:ok, value}
      other -> invalid(field, other)
    end
  end

  defp invalid(field, value), do: {:error, {:helper_protocol, {:invalid_field, field, value}}}

  defp run(kind, args, timeout_ms, opts) do
    with {:ok, binary} <- binary(opts), do: spawn_and_wait(binary, args, timeout_ms, kind)
  end

  defp binary(opts) do
    path =
      case Keyword.fetch(opts, :binary_path) do
        {:ok, path} -> {:ok, path}
        :error -> HelperInstaller.binary_path()
      end

    case path do
      {:ok, binary} when is_binary(binary) -> present(binary)
      {:error, :not_installed} -> {:error, :not_installed}
    end
  end

  defp present(binary),
    do: if(File.regular?(binary), do: {:ok, binary}, else: {:error, :not_installed})

  defp home_args(opts), do: ["--home", Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)]

  defp timeout(opts, default), do: Keyword.get(opts, :timeout_ms, default)

  defp spawn_and_wait(binary, args, timeout_ms, kind) do
    port = Port.open({:spawn_executable, binary}, [:binary, :exit_status, :hide, {:args, args}])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    try do
      collect(port, deadline, "", kind)
    after
      teardown(port, os_pid)
    end
  rescue
    error in ErlangError -> {:error, {:spawn_failed, error.original}}
  end

  # One receive loop, bounded by the call's deadline and by the stdout ceiling.
  defp collect(port, deadline, acc, kind) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} -> more(port, deadline, acc <> chunk, kind)
      {^port, {:exit_status, 0}} -> parse(kind, acc)
      {^port, {:exit_status, status}} -> {:error, exit_error(status)}
    after
      remaining -> {:error, :timeout}
    end
  end

  defp more(_port, _deadline, acc, _kind) when byte_size(acc) > @max_stdout_bytes,
    do: {:error, {:helper_protocol, :output_too_large}}

  defp more(port, deadline, acc, kind), do: collect(port, deadline, acc, kind)

  # Close the port, then kill the helper's process group: at the bound it is a
  # call nobody is waiting for. `:esrch` (already gone) is silent success.
  defp teardown(port, os_pid) do
    if Port.info(port), do: Port.close(port)
    ProcessGroup.signal(os_pid, :sigkill)
  end
end
