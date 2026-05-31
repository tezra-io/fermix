defmodule FermixCore.Setup.AccessToken do
  @moduledoc """
  Local setup authorization tokens.

  `setup-token` is the durable local operator secret. It never appears in
  URLs. `setup-launch-token.json` is the short-lived one-time URL token
  minted by `fermix setup` to authorize a browser session.
  """

  alias FermixCore.Setup.ConfigStore

  import Bitwise

  @setup_token_file "setup-token"
  @launch_token_file "setup-launch-token.json"
  @default_ttl_ms 15 * 60 * 1_000
  @token_bytes 32

  @type launch_token :: %{token: String.t(), expires_at_ms: non_neg_integer()}

  @spec ensure_setup_token(keyword()) :: {:ok, String.t()} | {:error, term()}
  def ensure_setup_token(opts \\ []) when is_list(opts) do
    path = paths(opts).setup_token

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      read_or_create_setup_token(path, opts)
    end
  end

  @spec rotate_setup_token(keyword()) :: {:ok, String.t()} | {:error, term()}
  def rotate_setup_token(opts \\ []) when is_list(opts) do
    paths = paths(opts)
    token = random_token(opts)

    with :ok <- File.mkdir_p(Path.dirname(paths.setup_token)),
         :ok <- write_private(paths.setup_token, token),
         :ok <- remove_if_present(paths.launch_token) do
      {:ok, token}
    end
  end

  @spec mint_launch_token(keyword()) :: {:ok, launch_token()} | {:error, term()}
  def mint_launch_token(opts \\ []) when is_list(opts) do
    paths = paths(opts)
    token = random_token(opts)
    expires_at_ms = now_ms(opts) + Keyword.get(opts, :ttl_ms, @default_ttl_ms)

    with {:ok, setup_token} <- ensure_setup_token(opts),
         body <- launch_body(token, expires_at_ms, setup_token),
         :ok <- write_private(paths.launch_token, body) do
      {:ok, %{token: token, expires_at_ms: expires_at_ms}}
    end
  end

  @spec consume_launch_token(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, atom() | term()}
  def consume_launch_token(token, opts \\ []) when is_binary(token) and is_list(opts) do
    path = paths(opts).launch_token

    with {:ok, data} <- read_launch_token(path),
         :ok <- reject_expired(data, path, opts),
         :ok <- compare_launch_token(token, Map.fetch!(data, "token")),
         {:ok, fingerprint} <- compare_setup_fingerprint(data, opts),
         :ok <- remove_if_present(path) do
      {:ok, fingerprint}
    end
  end

  @spec session_authorized?(term(), keyword()) :: boolean()
  def session_authorized?(fingerprint, opts \\ [])
  def session_authorized?(fingerprint, _opts) when fingerprint in [nil, ""], do: false

  def session_authorized?(fingerprint, opts) when is_binary(fingerprint) and is_list(opts) do
    case setup_fingerprint(opts) do
      {:ok, current} -> secure_equal?(fingerprint, current)
      {:error, _reason} -> false
    end
  end

  def session_authorized?(_fingerprint, _opts), do: false

  @spec setup_fingerprint(keyword()) :: {:ok, String.t()} | {:error, term()}
  def setup_fingerprint(opts \\ []) when is_list(opts) do
    with {:ok, token} <- ensure_setup_token(opts) do
      {:ok, fingerprint(token)}
    end
  end

  @spec paths(keyword()) :: %{setup_token: Path.t(), launch_token: Path.t()}
  def paths(opts \\ []) when is_list(opts) do
    home = Keyword.get(opts, :home, ConfigStore.fermix_home())

    %{
      setup_token: Path.join(home, @setup_token_file),
      launch_token: Path.join(home, @launch_token_file)
    }
  end

  defp read_or_create_setup_token(path, opts) do
    case File.read(path) do
      {:ok, token} -> normalize_existing_token(path, token, opts)
      {:error, :enoent} -> rotate_setup_token(opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_existing_token(path, token, opts) do
    case String.trim(token) do
      "" ->
        rotate_setup_token(opts)

      value ->
        with :ok <- File.chmod(path, 0o600), do: {:ok, value}
    end
  end

  defp read_launch_token(path) do
    case File.read(path) do
      {:ok, body} -> decode_launch_token(body)
      {:error, :enoent} -> {:error, :missing_launch_token}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_launch_token(body) do
    case Jason.decode(body) do
      {:ok, %{"token" => token, "expires_at_ms" => ms, "setup_fingerprint" => fingerprint}}
      when is_binary(token) and is_integer(ms) and is_binary(fingerprint) ->
        {:ok, %{"token" => token, "expires_at_ms" => ms, "setup_fingerprint" => fingerprint}}

      {:ok, _invalid} ->
        {:error, :invalid_launch_token_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reject_expired(%{"expires_at_ms" => expires_at_ms}, path, opts) do
    if expires_at_ms < now_ms(opts) do
      _ = remove_if_present(path)
      {:error, :expired_launch_token}
    else
      :ok
    end
  end

  defp compare_launch_token(provided, stored) do
    if secure_equal?(provided, stored), do: :ok, else: {:error, :invalid_launch_token}
  end

  defp compare_setup_fingerprint(%{"setup_fingerprint" => expected}, opts) do
    with {:ok, current} <- setup_fingerprint(opts) do
      if secure_equal?(expected, current), do: {:ok, current}, else: {:error, :stale_launch_token}
    end
  end

  defp launch_body(token, expires_at_ms, setup_token) do
    Jason.encode!(%{
      "token" => token,
      "expires_at_ms" => expires_at_ms,
      "setup_fingerprint" => fingerprint(setup_token)
    })
  end

  defp write_private(path, body) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, body),
         :ok <- File.chmod(path, 0o600) do
      :ok
    end
  end

  defp remove_if_present(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp random_token(opts) do
    random = Keyword.get(opts, :random, &:crypto.strong_rand_bytes/1)
    @token_bytes |> random.() |> Base.url_encode64(padding: false)
  end

  defp now_ms(opts), do: Keyword.get(opts, :now_ms, System.system_time(:millisecond))

  defp fingerprint(token) do
    :sha256
    |> :crypto.hash(token)
    |> Base.url_encode64(padding: false)
  end

  # fermix_core has no runtime Plug.Crypto dependency; keep equal-length
  # comparisons bytewise and constant-time here.
  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and zero_diff?(:crypto.exor(left, right))
  end

  defp secure_equal?(_left, _right), do: false

  defp zero_diff?(binary) do
    binary
    |> :binary.bin_to_list()
    |> Enum.reduce(0, &bor/2)
    |> Kernel.==(0)
  end
end
