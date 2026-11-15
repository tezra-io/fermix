defmodule FermixCore.Home.ComputerKey do
  @moduledoc """
  A linked computer's own key (M97 §7.5, D13): the X25519 key it proves
  itself to its server with, kept in the engine's secret store and never in a
  file of its own, so a copy of the home's folder, or of a disk without
  FileVault, is not the computer.

  **Where.** The store is the home's own (`[fermix_core] secret_store` in its
  `config.toml`): the Keychain on a Mac, the keyring on Linux where one
  answers, the file store under the home's `secrets/` where the owner chose
  it. The item is `SecretWriter`'s `{:device_key, :desktop}`, named by the
  home's profile (`[fermix_core] profile`), as every keychain item is, never
  by the home. Its value is the 32 bytes in standard base64: one printable
  line, which the keychain gives back as it was written. Which store holds it
  is recorded in `device/desktop.json` (`FermixCore.Home.DesktopLink`'s
  `key`), and every read goes to the store a record names: a link, or the
  move's own phase while no link exists yet. Nothing ever guesses it.

  **Two homes, one profile.** Two homes under one profile on one computer
  (a development home and the app's, say) share the item. So `create/2` and
  `migrate/2` never overwrite an item that holds another key: they refuse by
  name (`{:in_use, store}`), and `delete/3` given the key it made leaves
  another computer's alone.

  **The file store never travels.** The file `secrets/device.desktop_key`
  is device-local (`FermixCore.Home.DeviceLocal`): no archive, snapshot or
  move carries it, so a home moved from a file-store computer arrives
  without its key.

  **The migration** (`migrate/2`). An engine before this one kept the key in
  `device/desktop_key`, a raw file at mode `0600`, behind a version 1 link.
  The relay moves it when it starts, in this order, each step safe to stop
  after: the file is read; the key is stored, unless the store holds it
  already; it is read back and compared; the store is recorded in the link;
  the file is deleted. A store that already holds another key, one that
  will not answer, or a key that does not read back leaves the file and the
  link as they were, and the relay refuses by name: nothing reads the file
  instead. Nobody is at a start to answer an unlock prompt, so each store
  call it makes waits at most 10 s.

  `opts` everywhere: `:supervised` (false for a caller with no supervision
  tree), and `:impl`, `:command_runner` and `:find_executable`, the secret
  writer's own test seams.
  """

  alias FermixCore.Home.Archive.ConfigText
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.MoveSecrets
  alias FermixCore.Setup.SecretWriter

  @item {:device_key, :desktop}
  @config "config.toml"
  @legacy_file "device/desktop_key"
  @file_mode 0o600
  @unattended_timeout_ms 10_000
  @passed [:impl, :supervised, :command_runner, :find_executable]

  @type store :: SecretWriter.store()
  @type keypair :: DesktopLink.keypair()

  @type error ::
          :not_moved
          | {:missing, store()}
          | {:in_use, store()}
          | {:unusable, SecretWriter.verdict()}
          | {:store, store(), term()}
          | {:read_back, store()}
          | {:invalid, store()}
          | {:file_key, Path.t()}
          | {:file, Path.t(), File.posix()}
          | {:key_mode, Path.t(), non_neg_integer()}
          | {:invalid_key, Path.t(), atom()}
          | {:config, {:file, Path.t(), File.posix()} | String.t()}
          | {:link, DesktopLink.error()}

  @doc """
  This computer's key, from the store `opts[:store]` names, or else the one
  `device/desktop.json` records. A link from before the key moved is
  `:not_moved`: its file is never read here.
  """
  @spec read(Path.t(), keyword()) :: {:ok, keypair()} | {:error, error()}
  def read(home, opts \\ []) when is_binary(home) and home != "" and is_list(opts) do
    with {:ok, store} <- recorded_store(home, opts),
         {:ok, secret} <- secret_opts(home, store, opts),
         :ok <- usable(secret) do
      fetch(secret)
    end
  end

  @doc """
  Stores a key for this computer in the home's own store and reads it back:
  `opts[:keypair]` when the caller chose it, else a new one. `opts[:store]`
  names the store when the caller recorded it first. Refuses an item that
  holds another key (`{:in_use, store}`), and while the file an older Fermix
  kept the key in is still here (`{:file_key, path}`): that key is moved,
  never replaced.
  """
  @spec create(Path.t(), keyword()) :: {:ok, keypair(), store()} | {:error, error()}
  def create(home, opts \\ []) when is_binary(home) and home != "" and is_list(opts) do
    keypair = Keyword.get_lazy(opts, :keypair, &generate/0)

    with :ok <- no_file_key(home),
         {:ok, store} <- given_or_configured(home, opts),
         {:ok, secret} <- secret_opts(home, store, opts),
         :ok <- usable(secret),
         :ok <- store_key(keypair, secret) do
      {:ok, keypair, store}
    end
  end

  @doc """
  The store a key made now goes to: `[fermix_core] secret_store` in the
  home's `config.toml`, the keyring when it names none.
  """
  @spec store(Path.t()) :: {:ok, store()} | {:error, error()}
  def store(home) when is_binary(home) and home != "" do
    with {:ok, text} <- settings(home), do: configured_store(text)
  end

  @doc """
  Deletes this computer's key from `store` (nil when no record names one)
  and the file an older Fermix kept it in, if that is still here: no copy is
  left behind. With `opts[:public]`, the item goes only when it holds that
  key, so another computer's under the same profile stays.
  """
  @spec delete(Path.t(), store() | nil, keyword()) :: :ok | {:error, error()}
  def delete(home, store, opts \\ [])
      when is_binary(home) and home != "" and store in [:keyring, :file, nil] and is_list(opts) do
    with :ok <- delete_item(home, store, opts), do: remove_file_key(home)
  end

  @doc """
  Moves a key an older Fermix kept in `device/desktop_key` into the store
  (see the moduledoc): `:migrated`, `:nothing` when there is no link or the
  key moved already, or the error that left the file and the link as they
  were.
  """
  @spec migrate(Path.t(), keyword()) :: :migrated | :nothing | {:error, error()}
  def migrate(home, opts \\ []) when is_binary(home) and home != "" and is_list(opts) do
    case {DesktopLink.read(home), file_key(home)} do
      {{:error, {:file, _path, :enoent}}, _file} -> :nothing
      {{:error, reason}, _file} -> {:error, {:link, reason}}
      {{:ok, _link}, {:error, reason}} -> {:error, reason}
      {{:ok, %{key: store}}, {:ok, :absent}} when store != nil -> :nothing
      {{:ok, link}, {:ok, _present_or_absent}} -> move_file(home, link, opts)
    end
  end

  @doc "The sentence a person is shown for an error of this module."
  @spec error_sentence(error()) :: String.t()
  def error_sentence(:not_moved),
    do:
      "This computer's key is still in the file an older Fermix kept it in. Fermix moves " <>
        "it into the keychain when it starts, and had not yet."

  def error_sentence({:missing, store}),
    do: "This computer's key is not in #{where(store)}, so Fermix cannot use it."

  def error_sentence({:in_use, store}),
    do:
      "#{capital(where(store))} already holds another computer key under this home's profile: " <>
        "another Fermix home on this computer uses the same profile. Give each home a " <>
        "profile of its own."

  def error_sentence({:unusable, %{sentence: sentence}}),
    do: "Fermix cannot use this computer's key: #{String.trim_trailing(sentence, ".")}."

  def error_sentence({:store, store, reason}),
    do: "Fermix could not use this computer's key: #{where(store)} #{store_failure(reason)}."

  def error_sentence({:read_back, store}),
    do:
      "Fermix stored this computer's key in #{where(store)} but could not read it back the " <>
        "same, so it left the key where it was."

  def error_sentence({:invalid, store}),
    do: "#{capital(where(store))} holds something for this computer's key that is not a key."

  def error_sentence({:file_key, _path}),
    do:
      "This computer still keeps its key in the file an older Fermix kept it in, so Fermix " <>
        "made no new one."

  def error_sentence({:file, _path, :enoent}),
    do: "This computer's key file is missing from this home's device folder."

  def error_sentence({:file, _path, reason}),
    do: "Fermix could not use this computer's key file (#{:file.format_error(reason)})."

  def error_sentence({:key_mode, _path, mode}),
    do:
      "This computer's key file is mode #{octal(mode)}, readable by others; Fermix uses it " <>
        "only at 0600."

  def error_sentence({:invalid_key, _path, _detail}),
    do: "This computer's key file is not a key Fermix wrote."

  def error_sentence({:config, {:file, _path, reason}}),
    do: "Fermix could not read this home's settings (#{:file.format_error(reason)})."

  def error_sentence({:config, _sentence}),
    do: "This home's settings name a secret store Fermix does not know."

  def error_sentence({:link, reason}), do: DesktopLink.error_sentence(reason)

  defp where(:keyring), do: "the keychain"
  defp where(:file), do: "this home's secrets folder"

  defp capital(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  defp store_failure({:helper_timeout, _command, _ms}), do: "did not answer in time"
  defp store_failure({:helper_failed, _command, _code, _output}), do: "refused the request"
  defp store_failure({:file_store, _reason}), do: "could not be written or read"
  defp store_failure(_reason), do: "could not be used"

  defp octal(mode),
    do: mode |> Bitwise.band(0o777) |> Integer.to_string(8) |> String.pad_leading(4, "0")

  # -- the store ---------------------------------------------------------------

  defp recorded_store(home, opts) do
    case Keyword.get(opts, :store) do
      nil -> linked_store(home)
      store when store in [:keyring, :file] -> {:ok, store}
    end
  end

  defp linked_store(home) do
    case DesktopLink.read(home) do
      {:ok, %{key: nil}} -> {:error, :not_moved}
      {:ok, %{key: store}} -> {:ok, store}
      {:error, reason} -> {:error, {:link, reason}}
    end
  end

  defp given_or_configured(home, opts) do
    case Keyword.get(opts, :store) do
      nil -> store(home)
      store when store in [:keyring, :file] -> {:ok, store}
    end
  end

  defp settings(home) do
    file = Path.join(home, @config)

    case File.read(file) do
      {:ok, text} -> {:ok, text}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, {:config, {:file, file, reason}}}
    end
  end

  defp configured_store(text) do
    raw =
      case ConfigText.value(text, "fermix_core", "secret_store") do
        :absent -> nil
        {:ok, raw} -> unquoted(raw)
      end

    case SecretWriter.parse_store(raw) do
      {:ok, store} -> {:ok, store}
      {:error, sentence} -> {:error, {:config, sentence}}
    end
  end

  defp unquoted(raw) do
    case ConfigText.string(raw) do
      {:ok, value} -> value
      :error -> raw
    end
  end

  # What every secret writer call is given: the home (the file store's
  # folder), its profile (the keychain item's name), the store, and the
  # caller's own seams.
  defp secret_opts(home, store, opts) do
    with {:ok, text} <- settings(home) do
      {:ok,
       [home: home, profile: MoveSecrets.profile(text), store: store] ++
         Keyword.take(opts, [:timeout_ms | @passed])}
    end
  end

  # A store that cannot be used now (a locked keyring, no keyring client) is
  # refused before it is asked, so no call waits on a prompt nobody answers.
  defp usable(secret) do
    verdict = SecretWriter.probe(secret)
    if SecretWriter.usable?(verdict), do: :ok, else: {:error, {:unusable, verdict}}
  end

  defp fetch(secret) do
    store = Keyword.fetch!(secret, :store)

    case SecretWriter.get(@item, secret) do
      {:ok, value} -> decode(value, store)
      {:error, reason} -> unread(reason, store)
    end
  end

  # A store that holds no key yet says so in its own helper's words
  # (`SecretWriter.absent?/1`): that is a missing key, never a refusal, or a
  # fresh keychain could hold no computer's key at all.
  defp unread(reason, store) do
    if SecretWriter.absent?(reason),
      do: {:error, {:missing, store}},
      else: {:error, {:store, store, reason}}
  end

  defp decode(value, store) do
    case Base.decode64(value) do
      {:ok, <<_::256>> = private} -> {:ok, keypair(private)}
      _not_a_key -> {:error, {:invalid, store}}
    end
  end

  # The item this key is in already is kept; one that holds another key is
  # another computer's, and never overwritten.
  defp store_key(%{private: private, public: public}, secret) do
    store = Keyword.fetch!(secret, :store)

    case fetch(secret) do
      {:ok, %{public: ^public}} -> :ok
      {:ok, _another} -> {:error, {:in_use, store}}
      {:error, {:missing, ^store}} -> put_and_check(private, secret)
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_and_check(private, secret) do
    store = Keyword.fetch!(secret, :store)

    with :ok <- put(private, secret) do
      case fetch(secret) do
        {:ok, %{private: ^private}} -> :ok
        _other -> {:error, {:read_back, store}}
      end
    end
  end

  defp put(private, secret) do
    case SecretWriter.put(@item, Base.encode64(private), secret) do
      :ok -> :ok
      {:error, reason} -> {:error, {:store, Keyword.fetch!(secret, :store), reason}}
    end
  end

  defp delete_item(_home, nil, _opts), do: :ok

  defp delete_item(home, store, opts) do
    with {:ok, secret} <- secret_opts(home, store, opts),
         :ok <- usable(secret),
         {:ok, :ours} <- ours(secret, Keyword.get(opts, :public)) do
      case SecretWriter.delete(@item, secret) do
        :ok -> :ok
        {:error, reason} -> {:error, {:store, store, reason}}
      end
    else
      {:ok, :not_ours} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp ours(_secret, nil), do: {:ok, :ours}

  defp ours(secret, <<_::256>> = public) do
    case fetch(secret) do
      {:ok, %{public: ^public}} -> {:ok, :ours}
      {:ok, _another} -> {:ok, :not_ours}
      {:error, {:missing, _store}} -> {:ok, :not_ours}
      {:error, {:invalid, _store}} -> {:ok, :not_ours}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- the file an older Fermix kept ------------------------------------------------

  defp move_file(home, link, opts) do
    store = link.key
    opts = Keyword.put_new(opts, :timeout_ms, @unattended_timeout_ms)

    with {:ok, keypair} <- read_file_key(home),
         {:ok, store} <- recorded_or_configured(home, store),
         {:ok, secret} <- secret_opts(home, store, opts),
         :ok <- usable(secret),
         :ok <- store_key(keypair, secret),
         :ok <- record(home, link, store),
         :ok <- remove_file_key(home) do
      :migrated
    end
  end

  defp recorded_or_configured(home, nil), do: store(home)
  defp recorded_or_configured(_home, store), do: {:ok, store}

  defp record(_home, %{key: store}, store), do: :ok

  defp record(home, link, store) do
    case DesktopLink.write(home, %{link | key: store}) do
      :ok -> :ok
      {:error, reason} -> {:error, {:link, reason}}
    end
  end

  defp file_key_path(home), do: Path.join(home, @legacy_file)

  defp file_key(home) do
    file = file_key_path(home)

    case File.lstat(file) do
      {:ok, _stat} -> {:ok, :present}
      {:error, :enoent} -> {:ok, :absent}
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  defp no_file_key(home) do
    case file_key(home) do
      {:ok, :absent} -> :ok
      {:ok, :present} -> {:error, {:file_key, file_key_path(home)}}
      {:error, _reason} = error -> error
    end
  end

  # A regular file of exactly 32 bytes at mode 0600, as the engine that
  # wrote it read it.
  defp read_file_key(home) do
    file = file_key_path(home)

    with :ok <- file_key_entry(file),
         {:ok, private} <- read_bytes(file) do
      case private do
        <<_::256>> -> {:ok, keypair(private)}
        _other -> {:error, {:invalid_key, file, :length}}
      end
    end
  end

  defp file_key_entry(file) do
    case File.lstat(file) do
      {:ok, %{type: :regular, mode: mode}} -> file_key_mode(Bitwise.band(mode, 0o777), file)
      {:ok, %{type: type}} -> {:error, {:invalid_key, file, type}}
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  defp file_key_mode(@file_mode, _file), do: :ok
  defp file_key_mode(mode, file), do: {:error, {:key_mode, file, mode}}

  defp read_bytes(file) do
    case File.read(file) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  defp remove_file_key(home) do
    file = file_key_path(home)

    case File.rm(file) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  # -- keys --------------------------------------------------------------------

  defp generate do
    {public, private} = :crypto.generate_key(:ecdh, :x25519)
    %{private: private, public: public}
  end

  defp keypair(<<_::256>> = private) do
    {public, ^private} = :crypto.generate_key(:ecdh, :x25519, private)
    %{private: private, public: public}
  end
end
