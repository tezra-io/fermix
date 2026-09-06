defmodule FermixCore.Setup.Coexistence do
  @moduledoc """
  Facts about another Fermix install sharing this home (M34 native setup §15.2).

  Both install paths are supported and both are expected to appear on the same
  machine, so these are reported rather than refused. Three facts, each with one
  owner:

    * `legacy_service_unit/0` — a launchd unit at either scope whose program is
      not inside the running bundle. The scope is published because a
      system-scope unit needs administrator rights to remove and therefore has
      its own sentence and its own action; neither front-end can choose between
      them from a bare boolean.
    * `secret_acl_restricted/0` — keychain items this daemon cannot read
      without a prompt, because their ACL names an older binary path. Items
      written before the `-A` flag arrived are the population; the usual case is
      unaffected, so the answer is measured rather than guessed. Measuring costs
      one `security` subprocess per stored sentinel and prompts on exactly the
      population it names, so only Doctor measures; the measurement is recorded
      in `Setup.SecretAclState` and `last_secret_acl_restricted/0` is what a
      polled read publishes.
    * `config_state/0` — the persisted file's relationship to the baseline this
      VM recorded, delegated whole to `RestartState` so there is one comparison.
  """

  alias FermixCore.Setup.RestartState
  alias FermixCore.Setup.SecretAclState
  alias FermixCore.Setup.SecretPaths
  alias FermixCore.Setup.SecretStore
  alias FermixCore.Setup.SecretWriter

  @label "io.tezra.fermix"
  @system_unit_path "/Library/LaunchDaemons/#{@label}.plist"
  @user_unit_relative "Library/LaunchAgents/#{@label}.plist"
  @max_reported_keys 200

  @type legacy_unit :: %{present: boolean(), scope: :user | :system | nil, path: String.t() | nil}
  @type secret_acl :: %{present: boolean(), keys: [String.t()]}

  @doc """
  Whether a launchd unit this bundle does not own is installed, and at which
  scope.

  Checked at both scopes because the un-upgraded formula binary can reinstall
  either one after activation, and a unit whose program is inside the running
  bundle is this engine's own and is not a coexistence fact. The user scope is
  reported first: it is the one an operator can remove without administrator
  rights.
  """
  @spec legacy_service_unit(keyword()) :: legacy_unit()
  def legacy_service_unit(opts \\ []) when is_list(opts) do
    Enum.find_value(unit_paths(opts), absent_unit(), fn {scope, path} ->
      if foreign_unit?(path, opts), do: %{present: true, scope: scope, path: path}
    end)
  end

  @doc """
  Keychain items whose ACL keeps this daemon from reading them unprompted.

  Only paths holding the keyring sentinel are consulted, because a path holding
  a plaintext value or nothing at all has no keychain item to read. A reader
  that is unavailable on this host reports nothing rather than reporting every
  key as restricted: "there is no keychain here" is not "the ACL refuses".

  **This reads every stored secret and therefore prompts.** It is a Doctor
  action, not a poll: the measurement is recorded in `Setup.SecretAclState` and
  every other reader takes `last_secret_acl_restricted/1` instead.
  """
  @spec secret_acl_restricted(keyword()) :: secret_acl()
  def secret_acl_restricted(opts \\ []) when is_list(opts) do
    reader = Keyword.get(opts, :secret_reader, &SecretWriter.get/2)
    available? = Keyword.get(opts, :secret_writer_available?, &SecretWriter.available?/1)

    measurement =
      if available?.([]), do: restricted(sentinel_keys(opts), reader), else: absent_acl()

    :ok = SecretAclState.record(measurement, opts)
    measurement
  end

  @doc """
  The last recorded ACL measurement, `present: nil` until Doctor has run one.

  This is what a polled read publishes. `nil` is "not measured yet", which is a
  different fact from "measured, nothing restricted" and is published as a
  different value rather than collapsed into `false`.
  """
  @spec last_secret_acl_restricted(keyword()) :: SecretAclState.measurement()
  def last_secret_acl_restricted(opts \\ []) when is_list(opts), do: SecretAclState.last(opts)

  @doc "The persisted file's relationship to the baseline this VM recorded."
  @spec config_state(keyword()) :: RestartState.config_state()
  def config_state(opts \\ []) when is_list(opts), do: RestartState.config_state(opts)

  @doc "The public word for one config state."
  @spec config_state_word(RestartState.config_state()) :: String.t()
  def config_state_word(:clear), do: "clear"
  def config_state_word({:external_change, _sections}), do: "external_change"
  def config_state_word({:config_unreadable, _sentence}), do: "config_unreadable"

  defp absent_acl, do: %{present: false, keys: []}

  defp restricted(keys, reader) do
    unreadable =
      keys
      |> Enum.filter(fn key -> match?({:error, _reason}, reader.(key, [])) end)
      |> Enum.map(&Atom.to_string/1)
      |> Enum.take(@max_reported_keys)

    %{present: unreadable != [], keys: unreadable}
  end

  defp sentinel_keys(opts) do
    snapshot = Keyword.get_lazy(opts, :snapshot, &persisted_snapshot/0)
    sentinel = SecretWriter.sentinel()

    SecretPaths.all()
    |> Enum.filter(&(SecretStore.get_snapshot_value(snapshot, &1.path) == sentinel))
    |> Enum.map(& &1.key)
  end

  defp persisted_snapshot do
    case RestartState.load_persisted() do
      {:ok, persisted} -> persisted
      {:error, _sentence} -> %{}
    end
  end

  defp unit_paths(opts) do
    [
      {:user, Keyword.get(opts, :user_unit_path) || default_user_unit_path()},
      {:system, Keyword.get(opts, :system_unit_path) || @system_unit_path}
    ]
  end

  defp default_user_unit_path, do: Path.join(System.user_home!(), @user_unit_relative)

  # A unit whose program cannot be read is reported present: it is a unit this
  # bundle did not write and cannot account for, which is exactly the condition
  # the row exists to name.
  defp foreign_unit?(path, opts) do
    case File.read(path) do
      {:ok, body} -> not owned_by_bundle?(unit_program(body), opts)
      {:error, _reason} -> false
    end
  end

  defp owned_by_bundle?(nil, _opts), do: false

  defp owned_by_bundle?(program, opts) do
    case Keyword.get(opts, :bundle_dir) || bundle_dir() do
      nil -> false
      dir -> String.starts_with?(program, dir <> "/")
    end
  end

  # The running bundle is the directory the engine executable sits in, walked up
  # to the `.app`. Absent outside a bundle, which is the standalone engine, and
  # there every unit is by definition not this bundle's.
  defp bundle_dir do
    case :code.root_dir() |> to_string() |> String.split("/Contents/") do
      [bundle | _rest] -> if String.ends_with?(bundle, ".app"), do: bundle, else: nil
      _no_bundle -> nil
    end
  end

  defp unit_program(body) do
    case Regex.run(
           ~r{<key>ProgramArguments</key>\s*<array>\s*<string>([^<]+)</string>},
           body
         ) do
      [_full, program] -> program
      _no_match -> nil
    end
  end

  defp absent_unit, do: %{present: false, scope: nil, path: nil}
end
