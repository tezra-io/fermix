defmodule FermixCore.Home.DeviceLocal do
  # Each entry is a pattern relative to the home, whether a return keeps it,
  # and the one-line reason it stays on this machine. A pattern matches the
  # path it names and everything beneath it; `*` matches within one name, and a
  # leading `**/` matches the name at any depth. A return (Always On's move
  # back) `:keep`s what this machine's hardware, account and apps own and
  # `:drop`s the ended tenure's bookkeeping and every interrupted write.
  @entries [
    {"logs", :keep, "this machine's daemon, service and MCP server logs"},
    {"traces", :keep, "this machine's run traces, full request bodies included"},
    {"**/*.sock", :drop, "a socket belongs to the process listening on this machine"},
    {"*.lock", :keep, "config.toml and auth.json locks, held by processes on this machine"},
    {"plugins/.lock", :keep, "the plugin store's lock, held by a process on this machine"},
    {"auth.json.tmp.*", :drop, "an interrupted write of the token file"},
    {"auth.json.broken.*", :keep,
     "a token file this machine quarantined as unreadable, kept here for recovery"},
    {"config.toml.pre-m5", :keep, "a backup taken by a secret migration on this machine"},
    {"moved.json", :drop,
     "the marker that retires this copy; a restored home is the new primary"},
    {"device", :keep,
     "this machine's own Always On records: the provision ledger with its provider token, " <>
       "and a return's"},
    {"device/desktop.json", :drop, "a desktop's link to its primary"},
    {"device/desktop_key", :drop, "a desktop's own key"},
    {"snapshots", :keep,
     "this machine's snapshot status and capture staging, and a desktop's copies of the " <>
       "primary's snapshots"},
    {".move", :drop,
     "the move this machine started as its source: its request, phase and the snapshot " <>
       "it sends"},
    {"candidate", :drop,
     "a candidate primary's enrollment code, keys, phase and the move it is receiving; " <>
       "removed once the move makes it the primary"},
    {"engine-owner.json", :keep, "which engine last booted on this machine"},
    {"setup-token", :keep, "the setup page's secret on this machine"},
    {"setup-launch-token.json", :keep, "a one-time setup link on this machine"},
    {"secret_key_base", :keep,
     "signs this machine's web listener cookies; a new host makes its own"},
    {"upgrades.jsonl", :keep, "this machine's self-upgrade log"},
    {"upgrade.staging", :keep, "a self-upgrade download in progress"},
    {".previous", :keep, "the previous engine binary, kept for rollback on this machine"},
    {"bin", :keep, "browser-bridge wrappers with this machine's paths written into them"},
    {"grants", :keep, "sandbox directory grants approved for this machine's own paths"},
    {"browser/profiles", :keep,
     "Chrome profiles of this machine, with the sessions signed in to them"},
    {"imessage", :keep, "the cursor into this Mac's Messages database and its helper's state"},
    {"harness/runs", :keep, "coding-harness spools of runs on this machine"},
    {"models", :keep, "downloaded speech weights, fetched again by checksum on a new host"},
    {"companion/media", :keep, "copies handed to this Mac's app, cleared at every start"},
    {"workspace/.cache", :keep, "package-manager caches of sandboxed commands"},
    {"mobile/.identity-transaction", :drop,
     "exists only while this machine generates an identity, and its boot recovers from it"},
    {"mobile/candidates.json", :drop,
     "the candidate primaries enrolled with this primary, which only this machine can move to"},
    {"mobile/enrollment.json", :drop,
     "the enrollment window this primary opened, with its secret, which only this machine serves"},
    {"mobile/uploads", :drop, "phone uploads still arriving"},
    {"mobile/materialized", :drop, "disposable copies of timeline media"},
    {"mobile/*.tmp*", :drop, "an interrupted write of an identity, device or epoch file"},
    {"mobile/*.part", :drop, "an interrupted write of the media manifest"},
    {"mobile/media/*.part", :drop, "an interrupted write of timeline media"},
    {"secrets/.*", :drop, "the file secret store's staging for an interrupted write"},
    {"acp_identities/*.tmp.*", :drop, "an interrupted write of an ACP identity"},
    {"acp_identities/*.broken.*", :keep,
     "an ACP identity this machine quarantined as unreadable"},
    {"bootstrap/*/*.tmp-*", :drop, "an interrupted write of a prompt file"},
    {"plugins/.staging", :drop, "plugin install scratch"},
    {"plugins/reinstall.json", :drop,
     "the plugins a move brought here from another system, installed again for this machine"},
    {"plugins/run", :drop, "token copies handed to running plugin children"},
    {"plugins/compux", :keep, "the computer-use helper app built for this machine"},
    {"plugins/stt", :keep, "the speech helper binary for this machine"},
    {"plugins/meetbot", :keep,
     "the meeting bot's binary and the browser profile it signed in with here"},
    {"plugins/imessage_helper", :keep, "the Messages helper app for this Mac"},
    {"plugins/installed/*/current.tmp", :drop,
     "an interrupted switch of a plugin's current version"},
    {"plugins/installed/*/.*.replacing", :drop, "a plugin version being replaced"},
    {"plugins/evidence/*/.*.staging", :drop, "plugin provenance being staged"}
  ]

  for {pattern, return, _reason} <- @entries, return not in [:keep, :drop] do
    raise CompileError,
      description: "device-local #{pattern}: a return either :keep's or :drop's it"
  end

  for {"**/" <> _rest = pattern, :keep, _reason} <- @entries do
    raise CompileError,
      description: "device-local #{pattern}: a kept pattern names its depth, never any depth"
  end

  # How many names deep a kept path's own pattern reaches: anything deeper is
  # kept only as part of a kept parent, so a walk for kept paths stops there.
  @return_depth @entries
                |> Enum.filter(&match?({_pattern, :keep, _reason}, &1))
                |> Enum.map(fn {pattern, _keep, _reason} ->
                  length(String.split(pattern, "/"))
                end)
                |> Enum.max()

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

  **Through a return.** When the home moves back to this computer from its
  server (Always On's move back), the server's copy replaces the retired one
  here in place, and every entry says whether the return keeps this machine's
  own copy (`keep`: what its hardware, account and apps own) or drops it
  (`drop`: the ended tenure's bookkeeping, sockets and interrupted writes).
  `kept_through_return?/1` is the one reader: a path is kept when a `keep`
  entry matches it and no `drop` entry does, so `device/` is kept while the
  desktop link and key inside it are not. Nothing that travels is kept: it
  comes back from the server's copy.

  | Pattern | Through a return | Why it stays |
  |---|---|---|
  #{Enum.map_join(@entries, "\n", fn {pattern, return, reason} -> "| `#{pattern}` | #{return} | #{reason} |" end)}
  """

  @matchers for {pattern, return, _reason} <- @entries,
                do:
                  {return,
                   for(
                     segment <- String.split(pattern, "/"),
                     do: if(segment == "**", do: :any, else: String.split(segment, "*"))
                   )}

  @type return :: :keep | :drop
  @type entry :: %{pattern: String.t(), return: return(), reason: String.t()}

  @doc "The device-local list: each pattern, what a return does with it, and its reason."
  @spec excluded() :: [entry()]
  def excluded,
    do:
      Enum.map(@entries, fn {pattern, return, reason} ->
        %{pattern: pattern, return: return, reason: reason}
      end)

  @doc "Whether `path`, relative to the home, stays on this machine."
  @spec excluded?(String.t()) :: boolean()
  def excluded?(path) when is_binary(path) do
    segments = String.split(path, "/")
    Enum.any?(@matchers, fn {_return, pattern} -> matches?(pattern, segments) end)
  end

  @doc """
  How many names deep a kept path's own pattern reaches (`kept_through_return?/1`):
  a path deeper than this is kept only beneath a kept one, so a walk for the
  kept paths of a home goes no deeper.
  """
  @spec return_depth() :: pos_integer()
  def return_depth, do: @return_depth

  @doc """
  Whether a return keeps this machine's own `path` (relative to the home), at
  any depth: a `keep` entry matches it and no `drop` entry does.
  """
  @spec kept_through_return?(String.t()) :: boolean()
  def kept_through_return?(path) when is_binary(path) do
    segments = String.split(path, "/")
    returns = for {return, pattern} <- @matchers, matches?(pattern, segments), do: return
    :keep in returns and :drop not in returns
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
