defmodule FermixCore.Home.DeviceLocal do
  # Each entry is a pattern relative to the home and the one-line reason it
  # stays on this machine. A pattern matches the path it names and everything
  # beneath it; `*` matches within one name, and a leading `**/` matches the
  # name at any depth.
  @entries [
    {"logs", "this machine's daemon, service and MCP server logs"},
    {"traces", "this machine's run traces, full request bodies included"},
    {"**/*.sock", "a socket belongs to the process listening on this machine"},
    {"*.lock", "config.toml and auth.json locks, held by processes on this machine"},
    {"plugins/.lock", "the plugin store's lock, held by a process on this machine"},
    {"auth.json.tmp.*", "an interrupted write of the token file"},
    {"auth.json.broken.*",
     "a token file this machine quarantined as unreadable, kept here for recovery"},
    {"config.toml.pre-m5", "a backup taken by a secret migration on this machine"},
    {"moved.json", "the marker that retires this copy; a restored home is the new primary"},
    {"device",
     "a desktop's own key, its link to the primary and the receipts of the actions it ran"},
    {"snapshots",
     "this machine's snapshot status and capture staging, and a desktop's copies of the " <>
       "primary's snapshots"},
    {".move",
     "the move this machine started as its source: its request, phase and the snapshot " <>
       "it sends"},
    {"candidate",
     "a candidate primary's enrollment code, keys, phase and the move it is receiving; " <>
       "removed once the move makes it the primary"},
    {"engine-owner.json", "which engine last booted on this machine"},
    {"setup-token", "the setup page's secret on this machine"},
    {"setup-launch-token.json", "a one-time setup link on this machine"},
    {"secret_key_base", "signs this machine's web listener cookies; a new host makes its own"},
    {"upgrades.jsonl", "this machine's self-upgrade log"},
    {"upgrade.staging", "a self-upgrade download in progress"},
    {".previous", "the previous engine binary, kept for rollback on this machine"},
    {"bin", "browser-bridge wrappers with this machine's paths written into them"},
    {"grants", "sandbox directory grants approved for this machine's own paths"},
    {"browser/profiles",
     "Chrome profiles of this machine; a signed-in session moves only by consented hand-off (M75 D18)"},
    {"browser/handoffs.json",
     "the record of the hand-offs stored in this machine's Chrome profile, which stays with it"},
    {"browser/handoffs.json.tmp", "an interrupted write of the hand-off record"},
    {"imessage", "the cursor into this Mac's Messages database and its helper's state"},
    {"harness/runs", "coding-harness spools of runs on this machine"},
    {"models", "downloaded speech weights, fetched again by checksum on a new host"},
    {"companion/media", "copies handed to this Mac's app, cleared at every start"},
    {"workspace/.cache", "package-manager caches of sandboxed commands"},
    {"mobile/.identity-transaction",
     "exists only while this machine generates an identity, and its boot recovers from it"},
    {"mobile/candidates.json",
     "the candidate primaries enrolled with this primary, which only this machine can move to"},
    {"mobile/enrollment.json",
     "the enrollment window this primary opened, with its secret, which only this machine serves"},
    {"mobile/uploads", "phone uploads still arriving"},
    {"mobile/materialized", "disposable copies of timeline media"},
    {"mobile/*.tmp*", "an interrupted write of an identity, device or epoch file"},
    {"mobile/*.part", "an interrupted write of the media manifest"},
    {"mobile/media/*.part", "an interrupted write of timeline media"},
    {"secrets/.*", "the file secret store's staging for an interrupted write"},
    {"acp_identities/*.tmp.*", "an interrupted write of an ACP identity"},
    {"acp_identities/*.broken.*", "an ACP identity this machine quarantined as unreadable"},
    {"bootstrap/*/*.tmp-*", "an interrupted write of a prompt file"},
    {"plugins/.staging", "plugin install scratch"},
    {"plugins/run", "token copies handed to running plugin children"},
    {"plugins/compux", "the computer-use helper app built for this machine"},
    {"plugins/stt", "the speech helper binary for this machine"},
    {"plugins/meetbot",
     "the meeting bot's binary and the browser profile it signed in with here"},
    {"plugins/imessage_helper", "the Messages helper app for this Mac"},
    {"plugins/installed/*/current.tmp", "an interrupted switch of a plugin's current version"},
    {"plugins/installed/*/.*.replacing", "a plugin version being replaced"},
    {"plugins/evidence/*/.*.staging", "plugin provenance being staged"}
  ]

  @moduledoc """
  What stays on the machine a home was created on: the paths a home archive
  (`FermixCore.Home.Archive`) leaves out, and a restore refuses to write.

  Everything else in the home travels: `config.toml`, `memory.db` with its
  `-wal` and `-shm` files, `auth.json` and `chatgpt_host.json`, the file secret
  store under `secrets/`, the identity bundle, device list, media and
  `primary_epoch` under `mobile/`, `memory/`, `bootstrap/`, `skills/`,
  `journals/`, `workspace/`, `job_runs/`, `acp_identities/`,
  `realtime/device_id` (it keys the local voice conversation), the plugin
  lockfile, installed trees, provenance and skills under `plugins/`, and the
  browser's artifacts and downloads. Cues and open loops live in `memory.db`.

  Not listed because it is not in the home: the service binding
  (`$XDG_CONFIG_HOME/fermix/service.json`), the launchd and systemd units, and
  keyring-held secrets. A home whose secrets sit in the OS keyring archives
  their `@keyring` references only.

  A pattern matches the path it names and everything beneath it; `*` matches
  within one name, and a leading `**/` matches a name at any depth.

  | Pattern | Why it stays |
  |---|---|
  #{Enum.map_join(@entries, "\n", fn {pattern, reason} -> "| `#{pattern}` | #{reason} |" end)}
  """

  @matchers for {pattern, _reason} <- @entries,
                do:
                  for(
                    segment <- String.split(pattern, "/"),
                    do: if(segment == "**", do: :any, else: String.split(segment, "*"))
                  )

  @type entry :: %{pattern: String.t(), reason: String.t()}

  @doc "The device-local list: each pattern with its one-line reason."
  @spec excluded() :: [entry()]
  def excluded,
    do: Enum.map(@entries, fn {pattern, reason} -> %{pattern: pattern, reason: reason} end)

  @doc "Whether `path`, relative to the home, stays on this machine."
  @spec excluded?(String.t()) :: boolean()
  def excluded?(path) when is_binary(path) do
    segments = String.split(path, "/")
    Enum.any?(@matchers, &matches?(&1, segments))
  end

  defp matches?([:any, name_pattern], segments), do: Enum.any?(segments, &name?(&1, name_pattern))

  defp matches?(pattern, segments) when length(segments) >= length(pattern) do
    pattern
    |> Enum.zip(segments)
    |> Enum.all?(fn {name_pattern, name} -> name?(name, name_pattern) end)
  end

  defp matches?(_pattern, _segments), do: false

  # `name_pattern` is the name split on `*`: the first part anchors the start,
  # the last the end, and each part between must follow in order.
  defp name?(name, [exact]), do: name == exact

  defp name?(name, [first | rest]) do
    String.starts_with?(name, first) and
      rest?(binary_part(name, byte_size(first), byte_size(name) - byte_size(first)), rest)
  end

  defp rest?(remaining, [last]), do: String.ends_with?(remaining, last)
  defp rest?(remaining, ["" | rest]), do: rest?(remaining, rest)

  defp rest?(remaining, [part | rest]) do
    case :binary.match(remaining, part) do
      {at, length} ->
        rest?(binary_part(remaining, at + length, byte_size(remaining) - at - length), rest)

      :nomatch ->
        false
    end
  end
end
