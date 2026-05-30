defmodule FermixCore.Realtime.DeviceIdentity do
  @moduledoc """
  Stable local device identity and privacy-preserving OpenAI safety IDs.
  """

  @device_id_file "device_id"
  @safety_version "fermix-realtime-safety-v1"

  @spec ensure_device_id(String.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure_device_id(realtime_dir) when is_binary(realtime_dir) do
    path = Path.join(realtime_dir, @device_id_file)

    if File.exists?(path) do
      read_device_id(path)
    else
      write_device_id(path)
    end
  end

  @spec safety_identifier(String.t(), String.t()) :: String.t()
  def safety_identifier(owner_id, device_id) when is_binary(owner_id) and is_binary(device_id) do
    payload = [@safety_version, 0, owner_id, 0, device_id]

    :crypto.hash(:sha256, IO.iodata_to_binary(payload))
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 32)
  end

  defp read_device_id(path) do
    with {:ok, contents} <- File.read(path) do
      {:ok, String.trim(contents)}
    end
  end

  defp write_device_id(path) do
    device_id = generate_uuid()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, device_id),
         :ok <- File.chmod(path, 0o600) do
      {:ok, device_id}
    end
  end

  defp generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    [
      hex(a, 8),
      "-",
      hex(b, 4),
      "-",
      hex(c, 4),
      "-",
      hex(d, 4),
      "-",
      hex(e, 12)
    ]
    |> IO.iodata_to_binary()
  end

  defp hex(value, width) do
    value
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(width, "0")
  end
end
