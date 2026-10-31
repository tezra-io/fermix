defmodule FermixCore.Home.MoveSecrets do
  @moduledoc """
  The keychain's secrets travel with a move (M75): a home in keyring mode,
  which every Mac home is by default, keeps in `config.toml` only an
  `@keyring` reference per secret, and the value in the keychain, which no
  archive or snapshot holds.

  **On the source.** Before the move's capture, the move worker reads the
  value of every `@keyring` reference in the home's `config.toml`
  (`references/1`, then `read/3`) through `SecretWriter`, the engine's one
  keyring path, and hands them to the capture as files of the file secret
  store (`extra_files/1`: `secrets/<name>`, the name the file store keeps
  that secret under). They ride only inside the move's stream, encrypted to
  the candidate's one-time recipient, and are never written to the source's
  disk, a log, a status file or the phase file. A reference whose value
  cannot be read stops the move before anything is captured, and the move's
  readiness report names it as a block, as its settings row labels it
  (`described/2`), never by its id or its value.

  **On the candidate.** The restored home holds them in its file store, and
  each `@keyring` reference whose file arrived becomes `@file`
  (`adopt/2`), so the new primary resolves every secret the source had. A
  reference whose file did not arrive is left as it is.

  **Everywhere.** `missing/1` names the registry's references that did not
  resolve on this host (a sentinel still in the live settings), which
  `home.status` answers as `secrets_missing`.

  A reference is one of the registry's (`SecretPaths`: providers, channels,
  tools, plugin tokens, sign-in clients, snapshot keys) or a cue source's
  secret field; its id is the one `secret.set` takes. A `@keyring` reference
  at any other key is refused by that key (`{:unknown, keys}`): Fermix cannot
  tell which keychain item it names.
  """

  alias FermixCore.Cues.Config, as: CuesConfig
  alias FermixCore.Home.Archive.ConfigText
  alias FermixCore.Setup.SecretPaths
  alias FermixCore.Setup.SecretStore
  alias FermixCore.Setup.SecretWriter

  @cue_prefix "fermix_core.cues.sources."

  @type ref :: %{
          id: String.t(),
          section: String.t(),
          key: String.t(),
          secret: SecretWriter.secret_key(),
          file: String.t()
        }

  @doc "Every `@keyring` reference in `config_text`, in file order."
  @spec references(String.t()) :: {:ok, [ref()]} | {:error, {:unknown, [String.t()]}}
  def references(config_text) when is_binary(config_text) do
    {known, unknown} =
      config_text
      |> ConfigText.keyring_keys()
      |> Enum.map(fn {section, key} -> reference(section, key) end)
      |> Enum.split_with(&match?(%{}, &1))

    case unknown do
      [] -> {:ok, known}
      _some -> {:error, {:unknown, Enum.map(unknown, fn {:unknown, dotted} -> dotted end)}}
    end
  end

  @doc "The keychain profile `config_text` names (`[fermix_core] profile`), `general` when none."
  @spec profile(String.t()) :: String.t()
  def profile(config_text) when is_binary(config_text) do
    with {:ok, raw} <- ConfigText.value(config_text, "fermix_core", "profile"),
         {:ok, name} when name != "" <- ConfigText.string(raw) do
      name
    else
      _unset -> SecretWriter.default_profile()
    end
  end

  @doc """
  Reads every reference's value from the keychain under `profile`. `opts`
  go to `SecretWriter.get/2` (`:supervised` for a tree-less caller). Answers
  each reference with its value, or names every one it could not read.
  """
  @spec read([ref()], String.t(), keyword()) ::
          {:ok, [{ref(), String.t()}]} | {:error, {:unreadable, [String.t()]}}
  def read(references, profile, opts \\ [])
      when is_list(references) and is_binary(profile) and is_list(opts) do
    read_opts =
      Keyword.merge(Keyword.take(opts, [:supervised]), profile: profile, store: :keyring)

    {read, unreadable} =
      references
      |> Enum.map(fn ref -> {ref, SecretWriter.get(ref.secret, read_opts)} end)
      |> Enum.split_with(&match?({_ref, {:ok, value}} when value != "", &1))

    case unreadable do
      [] -> {:ok, Enum.map(read, fn {ref, {:ok, value}} -> {ref, value} end)}
      _some -> {:error, {:unreadable, Enum.map(unreadable, fn {ref, _error} -> ref.id end)}}
    end
  end

  @doc """
  The secrets `ids` are, as an owner reads them: each by what the settings
  call it (`names`, `Management.Settings.secret_names/1`), "your Anthropic
  key", then the ones no setting shows, counted ("1 other secret"), never by
  their ids.
  """
  @spec described([String.t(), ...], %{String.t() => String.t()}) :: String.t()
  def described([_ | _] = ids, names) when is_map(names) do
    {named, unnamed} = Enum.split_with(ids, &Map.has_key?(names, &1))
    words = Enum.map(named, &"your #{Map.fetch!(names, &1)}") ++ counted(named, length(unnamed))

    case words do
      [one] -> one
      _many -> Enum.join(Enum.drop(words, -1), ", ") <> " and " <> List.last(words)
    end
  end

  defp counted(_named, 0), do: []
  defp counted([], 1), do: ["1 secret"]
  defp counted([], count), do: ["#{count} secrets"]
  defp counted(_named, 1), do: ["1 other secret"]
  defp counted(_named, count), do: ["#{count} other secrets"]

  @doc """
  The keychain items no setting Fermix knows names (`references/1`'s
  `{:unknown, keys}`), as an owner reads them: "a keychain item belongs",
  "2 keychain items belong", never by their keys.
  """
  @spec unknown_items([String.t(), ...]) :: String.t()
  def unknown_items([_one]), do: "a keychain item belongs"
  def unknown_items([_ | _] = keys), do: "#{length(keys)} keychain items belong"

  @doc "The values as files of the file secret store, for `Snapshot.write/4`'s `:extra_files`."
  @spec extra_files([{ref(), String.t()}]) :: [{String.t(), binary()}]
  def extra_files(values) when is_list(values),
    do: Enum.map(values, fn {ref, value} -> {ref.file, value} end)

  @doc """
  Turns each `@keyring` reference of `config_text` whose file the staged home
  at `staging` holds into `@file`, every other byte kept. Answers the text and
  the ids it turned.
  """
  @spec adopt(String.t(), Path.t()) :: {:ok, String.t(), [String.t()]}
  def adopt(config_text, staging) when is_binary(config_text) and is_binary(staging) do
    carried =
      config_text
      |> ConfigText.keyring_keys()
      |> Enum.map(fn {section, key} -> reference(section, key) end)
      |> Enum.filter(&(match?(%{}, &1) and File.regular?(Path.join(staging, &1.file))))

    text =
      Enum.reduce(carried, config_text, fn ref, text ->
        ConfigText.put(text, ref.section, ref.key, Jason.encode!(SecretWriter.file_sentinel()))
      end)

    {:ok, text, Enum.map(carried, & &1.id)}
  end

  @doc """
  The ids of the registry's references in `snapshot` (the live settings,
  `ConfigStore.current_snapshot/0`) that did not resolve on this host: a
  sentinel still where the boot or the last save would have put the value.
  """
  @spec missing(map()) :: [String.t()]
  def missing(snapshot) when is_map(snapshot) do
    for secret <- SecretPaths.all(),
        SecretWriter.sentinel?(SecretStore.get_snapshot_value(snapshot, secret.path)),
        do: Atom.to_string(secret.key)
  end

  # -- references -------------------------------------------------------------

  defp reference(section, key) do
    plain = String.replace(section, "\"", "")
    dotted = plain <> "." <> key

    case registry(dotted) || cue(plain, key) do
      nil -> {:unknown, dotted}
      {id, secret} -> %{id: id, section: section, key: key, secret: secret, file: file(secret)}
    end
  end

  defp registry(dotted) do
    case Enum.find(
           SecretPaths.all(),
           &(Enum.map_join(&1.path, ".", fn part -> "#{part}" end) == dotted)
         ) do
      nil -> nil
      secret -> {Atom.to_string(secret.key), secret.key}
    end
  end

  defp cue(@cue_prefix <> ref, key) do
    field = Enum.find(SecretWriter.cue_secret_fields(), &(Atom.to_string(&1) == key))

    if field && CuesConfig.valid_name?(ref),
      do: {"cue_source:#{ref}:#{key}", {:cue_source, ref, field}}
  end

  defp cue(_section, _key), do: nil

  defp file(secret), do: "secrets/" <> SecretWriter.File.file_name(secret)
end
