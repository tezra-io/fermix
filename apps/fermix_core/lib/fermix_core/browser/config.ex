defmodule FermixCore.Browser.Config do
  @moduledoc """
  Single source of truth for every browser timeout, interval, and bound.

  All durations are milliseconds. None of these are user-facing; they are
  system tunables overridable through `config :fermix_core, :browser, ...`.
  Keeping them here (instead of as literals scattered across the runtime)
  makes every browser timeout greppable, documentable, and adjustable in one
  place.

  ## Capacity

    * `max_live_profiles` — hard ceiling on concurrent live Chrome instances.
      A cold start beyond this evicts the least-recently-used profile.
    * `max_tabs` — hard ceiling on live tabs per managed Chrome. Each `open`
      spawns a new tab; opening past this closes the oldest non-active tabs so
      a long session can't accumulate tabs and grow Chrome's memory unbounded.
      Managed profiles only — a user-attached Chrome's tabs are never closed.
    * `idle_profile_ttl_ms` — a profile with no activity for this long is
      stopped by the manager's idle sweep (frees its Chrome process).
    * `idle_sweep_interval_ms` — how often the manager scans for idle profiles.

  ## Per-operation CDP timeouts

    * `action_timeout_ms` — default timeout for a single CDP command.
    * `navigation_timeout_ms` — timeout for `Page.navigate`.
    * `cdp_keepalive_ms` — WebSocket ping interval.
    * `cdp_response_grace_ms` — extra slack the caller waits beyond the
      server-side command timer before giving up (so the server-side timeout
      fires first with a precise error).

  ## Launch / readiness

    * `launch_timeout_ms` — total budget for spawn → CDP endpoint ready.
    * `cdp_ready_poll_interval_ms` — poll cadence while waiting for CDP.
    * `cdp_version_probe_timeout_ms` — per `/json/version` HTTP probe timeout.

  ## Teardown

    * `stop_grace_ms` — wait for graceful Chrome exit (SIGTERM) before SIGKILL.
    * `kill_grace_ms` — wait after SIGKILL before giving up.

  ## Launch-failure cooldown

    * `start_failure_threshold` — consecutive launch failures before cooldown.
    * `start_cooldown_ms` — initial cooldown, doubled per extra failure.
    * `start_cooldown_max_ms` — cooldown ceiling.
    * `start_retries` — cold-start retries on a transient registry race (a
      not-yet-cleared dead registration). Distinct from `start_failure_threshold`.

  ## Supervision

    * `shutdown_slack_ms` — headroom added to `stop_grace_ms + kill_grace_ms`
      for a ProfileServer's child-spec shutdown budget and `GenServer.stop`
      timeout, so `terminate/2` can finish killing Chrome before a brutal kill.

  ## Waits / downloads

    * `wait_default_ms` / `wait_max_ms` — default and capped `act:wait` timeout.
    * `wait_poll_interval_ms` — poll cadence for wait/download conditions.
    * `download_default_ms` / `download_max_ms` — default and capped download wait.
    * `download_max_bytes` — byte ceiling for a single download. Chrome streams
      straight to disk, so this is the only bound on a runaway transfer: past it
      the download is canceled, the partial deleted, and the waiter told why.
      Same family as `screenshot_max_bytes` — a cap on bytes the browser
      produces, set high enough that real downloads survive.

  ## Buffers

    * `console_buffer_limit` — retained console/error entries per profile.
    * `dialog_buffer_limit` — retained open-dialog entries per profile.

  ## Snapshot bounds

    * `snapshot_default_depth` / `snapshot_max_depth` — default and hard-cap AX depth.
    * `snapshot_max_children` — max children walked per node.
    * `snapshot_max_chars` — max characters of snapshot text (UTF-8 safe).

  ## Screenshot bounds

    * `screenshot_max_side_px` — clamp on full-page capture width/height.
    * `screenshot_max_bytes` — reject captures larger than this.
  """

  alias FermixCore.Browser.Error
  alias FermixCore.Browser.Policy

  @default_allowed_hosts ["localhost", "127.0.0.1", "::1"]

  # The only key of this struct an operator sets from `config.toml`. Everything
  # else here is a timeout, a cap, a buffer size or a profile shape — tuning,
  # which is an internal constant rather than a config surface. `allowed_hosts`
  # is different in kind: it is the documented recovery for every host the policy
  # refuses (`browser_guidance` SKILL.md tells the operator to list the host
  # there), so a refusal without it is a refusal with no way out.
  #
  # The config store rejects any other key in the section BY NAME, so an operator
  # reaching for `action_timeout_ms` is told it is not settable instead of
  # editing a line that silently does nothing.
  @config_keys [:allowed_hosts]
  @default_profiles %{
    "fermix" => %{mode: :managed, headless: :auto, cdp_port: :auto},
    "fermix_visible" => %{mode: :managed, headless: false, cdp_port: :auto},
    "fermix_headless" => %{mode: :managed, headless: true, cdp_port: :auto}
  }

  @type profile :: %{
          required(:mode) => :managed | :existing_session | :remote_cdp,
          required(:headless) => boolean() | :auto,
          required(:cdp_port) => :auto | pos_integer(),
          optional(:cdp_url) => String.t(),
          optional(:executable_path) => String.t()
        }

  @type t :: %__MODULE__{
          default_profile: String.t(),
          allow_private_network: boolean(),
          allowed_hosts: [String.t()],
          max_live_profiles: pos_integer(),
          max_tabs: pos_integer(),
          idle_profile_ttl_ms: pos_integer(),
          idle_sweep_interval_ms: pos_integer(),
          action_timeout_ms: pos_integer(),
          navigation_timeout_ms: pos_integer(),
          cdp_keepalive_ms: pos_integer(),
          cdp_response_grace_ms: pos_integer(),
          launch_timeout_ms: pos_integer(),
          cdp_ready_poll_interval_ms: pos_integer(),
          cdp_version_probe_timeout_ms: pos_integer(),
          stop_grace_ms: pos_integer(),
          kill_grace_ms: pos_integer(),
          start_failure_threshold: pos_integer(),
          start_cooldown_ms: pos_integer(),
          start_cooldown_max_ms: pos_integer(),
          start_retries: pos_integer(),
          shutdown_slack_ms: pos_integer(),
          wait_default_ms: pos_integer(),
          wait_max_ms: pos_integer(),
          wait_poll_interval_ms: pos_integer(),
          download_default_ms: pos_integer(),
          download_max_ms: pos_integer(),
          download_max_bytes: pos_integer(),
          console_buffer_limit: pos_integer(),
          dialog_buffer_limit: pos_integer(),
          snapshot_default_depth: pos_integer(),
          snapshot_max_depth: pos_integer(),
          snapshot_max_children: pos_integer(),
          snapshot_max_chars: pos_integer(),
          screenshot_max_side_px: pos_integer(),
          screenshot_max_bytes: pos_integer(),
          profiles: %{String.t() => profile()}
        }

  defstruct default_profile: "fermix",
            allow_private_network: false,
            allowed_hosts: @default_allowed_hosts,
            max_live_profiles: 6,
            max_tabs: 10,
            idle_profile_ttl_ms: 900_000,
            idle_sweep_interval_ms: 60_000,
            action_timeout_ms: 8_000,
            navigation_timeout_ms: 30_000,
            cdp_keepalive_ms: 30_000,
            cdp_response_grace_ms: 250,
            launch_timeout_ms: 15_000,
            cdp_ready_poll_interval_ms: 100,
            cdp_version_probe_timeout_ms: 500,
            stop_grace_ms: 2_000,
            kill_grace_ms: 2_000,
            start_failure_threshold: 3,
            start_cooldown_ms: 30_000,
            start_cooldown_max_ms: 300_000,
            start_retries: 3,
            shutdown_slack_ms: 2_000,
            wait_default_ms: 5_000,
            wait_max_ms: 120_000,
            wait_poll_interval_ms: 100,
            download_default_ms: 30_000,
            download_max_ms: 120_000,
            download_max_bytes: 500_000_000,
            console_buffer_limit: 100,
            dialog_buffer_limit: 10,
            snapshot_default_depth: 5,
            snapshot_max_depth: 20,
            snapshot_max_children: 200,
            snapshot_max_chars: 50_000,
            screenshot_max_side_px: 4_000,
            screenshot_max_bytes: 8_000_000,
            profiles: @default_profiles

  @positive_fields ~w(
    max_live_profiles max_tabs idle_profile_ttl_ms idle_sweep_interval_ms action_timeout_ms
    navigation_timeout_ms cdp_keepalive_ms cdp_response_grace_ms launch_timeout_ms
    cdp_ready_poll_interval_ms cdp_version_probe_timeout_ms stop_grace_ms kill_grace_ms
    start_failure_threshold start_cooldown_ms start_cooldown_max_ms start_retries
    shutdown_slack_ms wait_default_ms
    wait_max_ms wait_poll_interval_ms download_default_ms download_max_ms download_max_bytes
    console_buffer_limit dialog_buffer_limit snapshot_default_depth snapshot_max_depth
    snapshot_max_children snapshot_max_chars screenshot_max_side_px screenshot_max_bytes
  )a

  @doc """
  Canonical list of allowed `[fermix_core.browser]` keys, used by the config
  store to reject unsettable keys at the parse boundary.
  """
  @spec config_keys() :: [atom()]
  def config_keys, do: @config_keys

  @doc """
  `[fermix_core.browser]` as a keyword list, keeping only the settable keys.

  Value validation is NOT repeated here — `validate_allowed_hosts/1` already runs
  on every read through `current/1`, and the `fermix doctor` browser row renders
  its refusal with the offending entry. This is the parse boundary: shape only.
  """
  @spec normalize(nil | map() | keyword()) :: keyword()
  def normalize(nil), do: []

  def normalize(config) when is_map(config) or is_list(config) do
    Enum.reduce(@config_keys, [], fn key, acc ->
      case fetch_key(config, key) do
        {:ok, value} -> Keyword.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp fetch_key(config, key) when is_map(config) do
    case Map.fetch(config, Atom.to_string(key)) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(config, key)
    end
  end

  defp fetch_key(config, key) when is_list(config) do
    case Keyword.fetch(config, key) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  @spec current() :: {:ok, t()} | {:error, Error.t()}
  def current do
    :fermix_core
    |> Application.get_env(:browser, [])
    |> current()
  end

  @spec current(keyword() | map()) :: {:ok, t()} | {:error, Error.t()}
  def current(raw) when is_list(raw) or is_map(raw) do
    raw_map = to_map(raw)

    %__MODULE__{}
    |> merge(raw_map)
    |> validate()
  end

  @spec profile(t(), String.t() | nil) :: {:ok, profile(), String.t()} | {:error, Error.t()}
  def profile(%__MODULE__{} = config, name) do
    profile_name = name || config.default_profile

    case Map.fetch(config.profiles, profile_name) do
      {:ok, profile} -> {:ok, profile, profile_name}
      :error -> {:error, Error.new("unknown_profile", "Unknown browser profile: #{profile_name}")}
    end
  end

  @spec snapshot_options(map(), t()) :: {:ok, map()} | {:error, Error.t()}
  def snapshot_options(args, %__MODULE__{} = config \\ %__MODULE__{}) when is_map(args) do
    opts = %{
      interactive: Map.get(args, "interactive", true),
      compact: Map.get(args, "compact", true),
      depth: Map.get(args, "depth", config.snapshot_default_depth),
      include_urls: Map.get(args, "include_urls", false),
      max_children: config.snapshot_max_children,
      max_chars: config.snapshot_max_chars
    }

    validate_snapshot_options(opts, config)
  end

  defp merge(%__MODULE__{} = config, raw) do
    scalar = Map.drop(raw, [:profiles])

    config
    |> struct(Map.take(scalar, known_keys()))
    |> Map.put(:profiles, profiles(Map.get(raw, :profiles, config.profiles)))
  end

  defp known_keys, do: __MODULE__.__struct__() |> Map.keys() |> List.delete(:__struct__)

  defp profiles(raw) when is_map(raw) do
    Map.new(raw, fn {name, profile} -> {to_string(name), normalize_profile(profile)} end)
  end

  defp normalize_profile(raw) when is_list(raw) or is_map(raw) do
    raw = to_map(raw)

    %{
      mode: Map.get(raw, :mode, :managed),
      headless: Map.get(raw, :headless, :auto),
      cdp_port: Map.get(raw, :cdp_port, :auto)
    }
    |> maybe_put(:cdp_url, Map.get(raw, :cdp_url))
    |> maybe_put(:executable_path, Map.get(raw, :executable_path))
  end

  defp validate(%__MODULE__{} = config) do
    with :ok <- validate_positive_fields(config),
         :ok <- validate_depth_bounds(config),
         :ok <- validate_allowed_hosts(config.allowed_hosts),
         :ok <- validate_profiles(config.profiles) do
      {:ok, config}
    end
  end

  # `allowed_hosts` is a string-equality membership test against the canonical
  # host spelling `Policy.canonical_host/1` produces, so an entry outside that
  # alphabet can never match anything an operator would type. Refused by name
  # here — not silently dropped, which would leave a list that reads as if it
  # were in force, and not silently kept, which would be a rule that never fires.
  # The integer-tunable enumeration in the test suite filters `is_integer/1`, so
  # a list-valued tunable is invisible to it and had no validation at all.
  defp validate_allowed_hosts(hosts) when is_list(hosts) do
    Enum.reduce_while(hosts, :ok, fn host, :ok ->
      case allowed_host(host) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_allowed_hosts(_hosts) do
    {:error, Error.new("invalid_config", "allowed_hosts must be a list of host strings")}
  end

  defp allowed_host(host) when is_binary(host) do
    case Policy.canonical_host(host) do
      {:ok, _canonical} ->
        :ok

      :error ->
        {:error,
         Error.new(
           "invalid_config",
           "allowed_hosts entry #{inspect(host)} is not a canonical host spelling: use ASCII " <>
             "letters, digits, '-', '.' and '_', or an IP address (punycode 'xn--' for an " <>
             "internationalised domain)"
         )}
    end
  end

  defp allowed_host(host) do
    {:error, Error.new("invalid_config", "allowed_hosts entry #{inspect(host)} must be a string")}
  end

  defp validate_positive_fields(config) do
    Enum.reduce_while(@positive_fields, :ok, fn field, :ok ->
      case positive(field, Map.fetch!(config, field)) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_depth_bounds(%__MODULE__{} = config) do
    if config.snapshot_default_depth <= config.snapshot_max_depth do
      :ok
    else
      {:error,
       Error.new("invalid_config", "snapshot_default_depth must be <= snapshot_max_depth")}
    end
  end

  defp validate_snapshot_options(opts, %__MODULE__{} = config) do
    with :ok <- boolean(:interactive, opts.interactive),
         :ok <- boolean(:compact, opts.compact),
         :ok <- boolean(:include_urls, opts.include_urls),
         :ok <- depth(opts.depth, config.snapshot_max_depth) do
      {:ok, opts}
    end
  end

  defp validate_profiles(profiles) when is_map(profiles) and map_size(profiles) > 0 do
    Enum.reduce_while(profiles, :ok, fn {_name, profile}, :ok ->
      case validate_profile(profile) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_profile(%{mode: :managed, headless: headless, cdp_port: port})
       when headless in [true, false, :auto] and
              (port == :auto or (is_integer(port) and port > 0)),
       do: :ok

  defp validate_profile(%{mode: mode, headless: :auto, cdp_port: :auto, cdp_url: url})
       when mode in [:existing_session, :remote_cdp] and is_binary(url) and url != "",
       do: :ok

  defp validate_profile(%{mode: mode, cdp_url: _url})
       when mode in [:existing_session, :remote_cdp] do
    {:error, Error.new("invalid_config", "#{mode} profiles cannot set headless or cdp_port")}
  end

  defp validate_profile(%{mode: mode}) when mode in [:existing_session, :remote_cdp] do
    {:error, Error.new("invalid_config", "#{mode} profiles require cdp_url")}
  end

  defp validate_profile(_profile) do
    {:error, Error.new("invalid_config", "Invalid browser profile configuration")}
  end

  defp positive(_key, value) when is_integer(value) and value > 0, do: :ok

  defp positive(key, _value) do
    {:error, Error.new("invalid_config", "#{key} must be a positive integer")}
  end

  defp boolean(_key, value) when is_boolean(value), do: :ok

  defp boolean(key, _value) do
    {:error, Error.new("invalid_config", "#{key} must be true or false")}
  end

  defp depth(value, max) when is_integer(value) and value > 0 and value <= max, do: :ok
  defp depth(_value, max), do: {:error, Error.new("invalid_config", "depth must be 1..#{max}")}

  defp to_map(value) when is_map(value), do: Map.new(value, &normalize_key/1)
  defp to_map(value) when is_list(value), do: value |> Map.new() |> to_map()

  defp normalize_key({key, value}) when is_binary(key), do: {String.to_atom(key), value}
  defp normalize_key({key, value}) when is_atom(key), do: {key, value}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
