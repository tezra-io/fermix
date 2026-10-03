defmodule FermixCore.Auth.ChatGPT.HostId do
  @moduledoc """
  This install's `ext_agent_host_id` for Sign in with ChatGPT (M57 D2).

  One per home: `chatgpt_host.json` beside `auth.json`, holding
  `{"version":1,"id":"urn:uuid:<v4>"}` with mode 0600. It is created on the
  first sign-in attempt, before the browser opens, and never rewritten; a
  sign-out keeps it. It is opaque and identifies nothing about the person.

  The file is created with a hard link from a private temporary file, which
  fails when the name exists, so two first attempts racing each other agree on
  one id instead of the second overwriting the first. A stored file that is a
  symlink, is readable by others, or holds anything but a v4 id is refused,
  never repaired: a replaced id would make this install a new host to OpenAI.
  """

  @file_name "chatgpt_host.json"
  @v4 ~r/\Aurn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  @type error ::
          {:host_id_symlink, Path.t()}
          | {:host_id_not_a_file, Path.t()}
          | {:host_id_insecure_permissions, Path.t(), non_neg_integer()}
          | {:host_id_invalid, Path.t()}
          | {:host_id_unreadable, Path.t(), term()}

  @doc "The host id file for the home whose `auth.json` is `auth_path`."
  @spec path(Path.t()) :: Path.t()
  def path(auth_path) when is_binary(auth_path),
    do: Path.join(Path.dirname(auth_path), @file_name)

  @doc "Reads this home's host id, creating it on first use."
  @spec fetch_or_create(Path.t()) :: {:ok, String.t()} | {:error, error()}
  def fetch_or_create(auth_path) when is_binary(auth_path) do
    file = path(auth_path)

    case File.lstat(file) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> read_existing(file, mode)
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:host_id_symlink, file}}
      {:ok, %File.Stat{}} -> {:error, {:host_id_not_a_file, file}}
      {:error, :enoent} -> create(file)
      {:error, reason} -> {:error, {:host_id_unreadable, file, reason}}
    end
  end

  @doc "Whether `id` is a host id this module would have written."
  @spec valid?(term()) :: boolean()
  def valid?(id), do: is_binary(id) and Regex.match?(@v4, id)

  defp read_existing(file, mode) do
    case Bitwise.band(mode, 0o777) do
      0o600 -> decode(file)
      loose -> {:error, {:host_id_insecure_permissions, file, loose}}
    end
  end

  defp decode(file) do
    with {:ok, raw} <- File.read(file),
         {:ok, %{"version" => 1, "id" => id}} <- Jason.decode(raw),
         true <- valid?(id) do
      {:ok, id}
    else
      {:error, reason} when is_atom(reason) -> {:error, {:host_id_unreadable, file, reason}}
      _invalid -> {:error, {:host_id_invalid, file}}
    end
  end

  # Written private and whole to a temporary name, then linked into place: the
  # link refuses an existing name, so a concurrent first attempt's id wins and
  # is read back. The temporary name is removed on every path.
  defp create(file) do
    id = "urn:uuid:" <> uuid_v4()
    tmp = "#{file}.tmp.#{System.unique_integer([:positive, :monotonic])}"

    result =
      with :ok <- File.mkdir_p(Path.dirname(file)),
           :ok <- write_private(tmp, Jason.encode!(%{"version" => 1, "id" => id})) do
        link(tmp, file, id)
      end

    _ = File.rm(tmp)
    result
  end

  defp link(tmp, file, id) do
    case File.ln(tmp, file) do
      :ok -> {:ok, id}
      {:error, :eexist} -> fetch_existing(file)
      {:error, reason} -> {:error, {:host_id_unreadable, file, reason}}
    end
  end

  defp fetch_existing(file) do
    case File.lstat(file) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> read_existing(file, mode)
      {:ok, %File.Stat{}} -> {:error, {:host_id_not_a_file, file}}
      {:error, reason} -> {:error, {:host_id_unreadable, file, reason}}
    end
  end

  # Created empty, made private, then filled through the descriptor that
  # created it (the order `Auth.Store` uses), so the id never sits in a file
  # another account could read.
  defp write_private(file, bytes) do
    case File.open(file, [:write, :exclusive, :binary], &chmod_then_write(&1, file, bytes)) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp chmod_then_write(device, file, bytes) do
    with :ok <- File.chmod(file, 0o600), do: IO.binwrite(device, bytes)
  end

  defp uuid_v4 do
    <<a::48, _version::4, b::12, _variant::2, c::62>> = :crypto.strong_rand_bytes(16)
    <<u0::32, u1::16, u2::16, u3::16, u4::48>> = <<a::48, 4::4, b::12, 2::2, c::62>>

    [<<u0::32>>, <<u1::16>>, <<u2::16>>, <<u3::16>>, <<u4::48>>]
    |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
  end
end
