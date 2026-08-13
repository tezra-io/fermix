defmodule FermixChannels.Mobile.Identity do
  @moduledoc """
  Durable gateway identity for the mobile transport.

  `ensure/1` creates the X25519 Noise key and the pinned P-256 TLS identity
  only when all three artifacts are absent. Any partial or invalid identity is
  refused rather than silently rotated. Tests inject `:root`; production uses
  `FERMIX_HOME` (or `~/.fermix`).
  """

  @enforce_keys [
    :gateway_private_key,
    :gateway_public_key,
    :tls_private_key,
    :tls_certificate,
    :tls_fingerprint,
    :tls_key_path,
    :tls_cert_path
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          gateway_private_key: binary(),
          gateway_public_key: binary(),
          tls_private_key: X509.PrivateKey.t(),
          tls_certificate: X509.Certificate.t(),
          tls_fingerprint: <<_::256>>,
          tls_key_path: Path.t(),
          tls_cert_path: Path.t()
        }

  @type error :: {:error, term()}

  @gateway_filename "gateway_key"
  @tls_key_filename "tls.key"
  @tls_cert_filename "tls.crt"
  @transaction_filename ".identity-transaction"
  @transaction_contents "v1\n"
  @p256_oid {1, 2, 840, 10_045, 3, 1, 7}
  @tls_validity_days 3_650
  @file_mode 0o600
  @dir_mode 0o700

  @doc "Create the identity on first pair, or strictly load the existing one."
  @spec ensure(keyword()) :: {:ok, t()} | error()
  def ensure(opts \\ []) when is_list(opts) do
    with {:ok, paths} <- resolve_paths(opts),
         {:ok, transaction} <- transaction_state(paths),
         :ok <- recover_if_interrupted(transaction, paths),
         {:ok, state} <- identity_state(paths) do
      ensure_state(state, paths, opts)
    end
  end

  @doc "Strictly load existing identity material without generating replacements."
  @spec load(keyword()) :: {:ok, t()} | error()
  def load(opts \\ []) when is_list(opts) do
    with {:ok, paths} <- resolve_paths(opts),
         {:ok, :clean} <- transaction_state(paths) do
      load_paths(paths)
    else
      {:ok, :interrupted} -> {:error, :identity_transaction_incomplete}
      {:error, _reason} = error -> error
    end
  end

  @doc "Resolve the canonical mobile identity paths."
  @spec paths(keyword()) ::
          {:ok,
           %{
             dir: Path.t(),
             gateway_key: Path.t(),
             tls_key: Path.t(),
             tls_cert: Path.t(),
             transaction: Path.t()
           }}
          | error()
  def paths(opts \\ []) when is_list(opts), do: resolve_paths(opts)

  defp ensure_state(:missing, paths, opts), do: generate(paths, opts)
  defp ensure_state(:present, paths, _opts), do: load_paths(paths)

  defp ensure_state({:partial, missing}, _paths, _opts),
    do: {:error, {:identity_incomplete, missing}}

  defp generate(paths, opts) do
    with :ok <- create_identity_dir(paths.dir) do
      generate_transaction(paths, opts)
    end
  end

  defp generate_transaction(paths, opts) do
    with :ok <- begin_transaction(paths),
         {:ok, material} <- generate_material(),
         :ok <- persist_material(paths, material, opts),
         :ok <- finish_transaction(paths),
         {:ok, identity} <- load_paths(paths) do
      {:ok, identity}
    else
      {:error, reason} -> rollback_generation(paths, reason)
    end
  end

  defp generate_material do
    {gateway_public, gateway_private} = :crypto.generate_key(:ecdh, :x25519)
    tls_private = X509.PrivateKey.new_ec(:secp256r1)

    tls_certificate =
      X509.Certificate.self_signed(tls_private, "/CN=Fermix Mobile",
        template: :server,
        validity: @tls_validity_days
      )

    {:ok,
     %{
       gateway_key: gateway_private,
       tls_key: X509.PrivateKey.to_pem(tls_private),
       tls_cert: X509.Certificate.to_pem(tls_certificate),
       gateway_public: gateway_public
     }}
  end

  defp persist_material(paths, material, opts) do
    artifacts = [
      {paths.gateway_key, material.gateway_key},
      {paths.tls_key, material.tls_key},
      {paths.tls_cert, material.tls_cert}
    ]

    write_artifacts(artifacts, Keyword.get(opts, :rename, &File.rename/2))
  end

  defp write_artifacts(artifacts, rename) do
    staged = Enum.map(artifacts, fn {path, contents} -> {path, temp_path(path), contents} end)

    with :ok <- stage_all(staged),
         :ok <- publish_all(staged, rename) do
      :ok
    else
      {:error, reason} -> cleanup_staged(staged, reason)
    end
  end

  defp stage_all(staged) do
    Enum.reduce_while(staged, :ok, fn {path, temp, contents}, :ok ->
      case write_temp(temp, contents) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:identity_write_failed, path, reason}}}
      end
    end)
  end

  defp publish_all(staged, rename) do
    Enum.reduce_while(staged, :ok, fn {path, temp, _contents}, :ok ->
      case rename.(temp, path) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:identity_write_failed, path, reason}}}
      end
    end)
  end

  defp write_temp(temp, contents) do
    with :ok <- File.write(temp, contents, [:binary, :exclusive]),
         :ok <- File.chmod(temp, @file_mode) do
      :ok
    end
  end

  defp cleanup_staged(staged, original_reason) do
    errors =
      staged
      |> Enum.map(fn {_path, temp, _contents} -> remove_temp(temp) end)
      |> Enum.reject(&(&1 == :ok))

    case errors do
      [] -> {:error, original_reason}
      _nonempty -> {:error, {:identity_cleanup_failed, original_reason, errors}}
    end
  end

  defp remove_temp(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {path, reason}}
    end
  end

  defp begin_transaction(paths) do
    temp = temp_path(paths.transaction)

    with :ok <- File.write(temp, @transaction_contents, [:binary, :exclusive]),
         :ok <- File.chmod(temp, @file_mode),
         :ok <- File.rename(temp, paths.transaction) do
      :ok
    else
      {:error, reason} ->
        _ = remove_temp(temp)
        {:error, {:identity_transaction_start_failed, reason}}
    end
  end

  defp finish_transaction(paths) do
    case File.rm(paths.transaction) do
      :ok -> :ok
      {:error, reason} -> {:error, {:identity_transaction_finish_failed, reason}}
    end
  end

  defp transaction_state(paths) do
    case File.lstat(paths.transaction) do
      {:error, :enoent} ->
        {:ok, :clean}

      {:ok, %{type: :regular, mode: mode}} ->
        with :ok <- validate_mode(paths.transaction, mode, @file_mode),
             {:ok, @transaction_contents} <- File.read(paths.transaction) do
          {:ok, :interrupted}
        else
          {:ok, _other} -> {:error, {:invalid_identity_transaction, paths.transaction}}
          {:error, reason} -> {:error, {:identity_unreadable, paths.transaction, reason}}
        end

      {:ok, %{type: type}} ->
        {:error, {:unsafe_file_type, paths.transaction, type, :regular}}

      {:error, reason} ->
        {:error, {:identity_unreadable, paths.transaction, reason}}
    end
  end

  defp recover_if_interrupted(:clean, _paths), do: :ok
  defp recover_if_interrupted(:interrupted, paths), do: cleanup_generation(paths)

  defp rollback_generation(paths, reason) do
    case cleanup_generation(paths) do
      :ok -> {:error, reason}
      {:error, cleanup_reason} -> {:error, {:identity_cleanup_failed, reason, cleanup_reason}}
    end
  end

  defp cleanup_generation(paths) do
    with {:ok, cleanup_paths} <- cleanup_paths(paths) do
      remove_cleanup_paths(cleanup_paths)
    end
  end

  defp remove_cleanup_paths(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case remove_temp(path) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp cleanup_paths(paths) do
    temporary =
      [@gateway_filename, @tls_key_filename, @tls_cert_filename, @transaction_filename]
      |> Enum.flat_map(&Path.wildcard(Path.join(paths.dir, "#{&1}.tmp.*")))

    if length(temporary) <= 32 do
      {:ok, identity_files(paths) ++ temporary ++ [paths.transaction]}
    else
      {:error, {:identity_cleanup_limit_exceeded, length(temporary), 32}}
    end
  end

  defp load_paths(paths) do
    with :ok <- validate_entry(paths.dir, :directory, @dir_mode),
         :ok <- validate_entry(paths.gateway_key, :regular, @file_mode),
         :ok <- validate_entry(paths.tls_key, :regular, @file_mode),
         :ok <- validate_entry(paths.tls_cert, :regular, @file_mode),
         {:ok, gateway_private} <- read_gateway_key(paths.gateway_key),
         {:ok, tls_private} <- read_tls_key(paths.tls_key),
         {:ok, tls_certificate} <- read_tls_cert(paths.tls_cert),
         :ok <- validate_tls_pair(tls_private, tls_certificate, paths) do
      build_identity(gateway_private, tls_private, tls_certificate, paths)
    end
  end

  defp read_gateway_key(path) do
    with {:ok, key} <- read_file(path),
         :ok <- validate_gateway_key(key, path) do
      {:ok, key}
    end
  end

  defp validate_gateway_key(key, _path) when byte_size(key) == 32, do: :ok

  defp validate_gateway_key(_key, path),
    do: {:error, {:invalid_gateway_key, path, :invalid_length}}

  defp read_tls_key(path) do
    with {:ok, pem} <- read_file(path),
         {:ok, key} <- normalize_parse_result(X509.PrivateKey.from_pem(pem), path, :tls_key),
         :ok <- validate_p256_private_key(key, path) do
      {:ok, key}
    end
  end

  defp read_tls_cert(path) do
    with {:ok, pem} <- read_file(path),
         {:ok, cert} <- normalize_parse_result(X509.Certificate.from_pem(pem), path, :tls_cert),
         :ok <- validate_p256_certificate(cert, path) do
      {:ok, cert}
    end
  end

  defp normalize_parse_result({:ok, value}, _path, _kind), do: {:ok, value}

  defp normalize_parse_result({:error, reason}, path, kind),
    do: {:error, {:invalid_identity_artifact, kind, path, reason}}

  defp validate_p256_private_key({:ECPrivateKey, _, _, {:namedCurve, @p256_oid}, _, _}, _path),
    do: :ok

  defp validate_p256_private_key(_key, path), do: {:error, {:invalid_tls_key, path, :not_p256}}

  defp validate_p256_certificate(cert, path) do
    case X509.Certificate.public_key(cert) do
      {{:ECPoint, _point}, {:namedCurve, @p256_oid}} -> :ok
      _other -> {:error, {:invalid_tls_certificate, path, :not_p256}}
    end
  end

  defp validate_tls_pair(private_key, certificate, paths) do
    private_public = X509.PublicKey.derive(private_key)
    certificate_public = X509.Certificate.public_key(certificate)

    cond do
      private_public != certificate_public ->
        {:error, {:tls_key_mismatch, paths.tls_key, paths.tls_cert}}

      not :public_key.pkix_is_self_signed(certificate) ->
        {:error, {:invalid_tls_certificate, paths.tls_cert, :not_self_signed}}

      not :public_key.pkix_verify(X509.Certificate.to_der(certificate), certificate_public) ->
        {:error, {:invalid_tls_certificate, paths.tls_cert, :invalid_signature}}

      true ->
        :ok
    end
  end

  defp build_identity(gateway_private, tls_private, tls_certificate, paths) do
    {gateway_public, ^gateway_private} =
      :crypto.generate_key(:ecdh, :x25519, gateway_private)

    fingerprint = tls_certificate |> X509.Certificate.to_der() |> then(&:crypto.hash(:sha256, &1))

    {:ok,
     %__MODULE__{
       gateway_private_key: gateway_private,
       gateway_public_key: gateway_public,
       tls_private_key: tls_private,
       tls_certificate: tls_certificate,
       tls_fingerprint: fingerprint,
       tls_key_path: paths.tls_key,
       tls_cert_path: paths.tls_cert
     }}
  end

  defp identity_state(paths) do
    results = Enum.map(identity_files(paths), &entry_presence/1)

    case Enum.find(results, &match?({:error, _reason}, &1)) do
      {:error, reason} -> {:error, reason}
      nil -> classify_presence(paths, results)
    end
  end

  defp classify_presence(_paths, [:missing, :missing, :missing]), do: {:ok, :missing}
  defp classify_presence(_paths, [:present, :present, :present]), do: {:ok, :present}

  defp classify_presence(paths, results) do
    missing =
      paths
      |> identity_files()
      |> Enum.zip(results)
      |> Enum.flat_map(fn
        {path, :missing} -> [path]
        {_path, :present} -> []
      end)

    {:ok, {:partial, missing}}
  end

  defp entry_presence(path) do
    case File.lstat(path) do
      {:ok, _stat} -> :present
      {:error, :enoent} -> :missing
      {:error, reason} -> {:error, {:identity_unreadable, path, reason}}
    end
  end

  defp create_identity_dir(dir) do
    case File.lstat(dir) do
      {:error, :enoent} -> create_new_dir(dir)
      {:ok, _stat} -> validate_entry(dir, :directory, @dir_mode)
      {:error, reason} -> {:error, {:identity_dir_unwritable, dir, reason}}
    end
  end

  defp create_new_dir(dir) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, @dir_mode) do
      :ok
    else
      {:error, reason} -> {:error, {:identity_dir_unwritable, dir, reason}}
    end
  end

  defp validate_entry(path, expected_type, expected_mode) do
    case File.lstat(path) do
      {:ok, %{type: ^expected_type, mode: mode}} -> validate_mode(path, mode, expected_mode)
      {:ok, %{type: type}} -> {:error, {:unsafe_file_type, path, type, expected_type}}
      {:error, :enoent} -> {:error, {:identity_artifact_missing, path}}
      {:error, reason} -> {:error, {:identity_unreadable, path, reason}}
    end
  end

  defp validate_mode(path, mode, expected) do
    actual = Bitwise.band(mode, 0o777)
    if actual == expected, do: :ok, else: {:error, {:unsafe_permissions, path, actual, expected}}
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:identity_unreadable, path, reason}}
    end
  end

  defp resolve_paths(opts) do
    with :ok <- validate_options(opts),
         {:ok, root} <- resolve_root(opts) do
      dir = Path.join(root, "mobile")

      {:ok,
       %{
         dir: dir,
         gateway_key: Path.join(dir, @gateway_filename),
         tls_key: Path.join(dir, @tls_key_filename),
         tls_cert: Path.join(dir, @tls_cert_filename),
         transaction: Path.join(dir, @transaction_filename)
       }}
    end
  end

  defp validate_options(opts) do
    case Keyword.keys(opts) -- [:root, :rename] do
      [] -> validate_rename(Keyword.get(opts, :rename, &File.rename/2))
      unknown -> {:error, {:invalid_identity_options, unknown}}
    end
  end

  defp validate_rename(rename) when is_function(rename, 2), do: :ok
  defp validate_rename(rename), do: {:error, {:invalid_identity_rename, rename}}

  defp resolve_root(opts) do
    root = Keyword.get(opts, :root) || default_root()

    if is_binary(root) and root != "",
      do: {:ok, Path.expand(root)},
      else: {:error, {:invalid_identity_root, root}}
  end

  defp default_root do
    System.get_env("FERMIX_HOME") || Path.join(System.user_home!(), ".fermix")
  end

  defp identity_files(paths), do: [paths.gateway_key, paths.tls_key, paths.tls_cert]

  defp temp_path(path) do
    suffix = System.unique_integer([:positive, :monotonic])
    "#{path}.tmp.#{suffix}"
  end
end
