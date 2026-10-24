defmodule FermixChannels.Mobile.Push.FcmMessage do
  @moduledoc """
  One FCM HTTP v1 message for one paired Android phone (M51 §10).

  The plaintext is a typed JSON object, `{kind, profile_id, …}`, padded to
  exactly one 2,048-byte bucket (the JSON, one 0x80 byte, then zeros) and
  sealed with the device's push key (`Push.derive_key/3`, the derivation APNs
  uses), so every push is the same size and says only that it happened. It
  rides as a data-only message: with no `notification` block, nothing is shown
  that the app did not decrypt and decide to show.

  A reply's preview that would not fit the bucket is cut at a character and
  ends with "…"; the phone fetches the whole reply when it reconnects.
  """

  alias FermixChannels.Mobile.DeviceStore.Device
  alias FermixChannels.Mobile.Push

  @bucket_bytes 2_048
  @pad_mark 0x80
  @max_data_bytes 4_096
  @nonce_bytes 12
  @tag_bytes 16
  @max_token_bytes 1_024
  @max_id_bytes 255
  @ellipsis "…"
  @envelope_version "2"
  @ttl "86400s"

  @type plaintext :: %{String.t() => String.t() | non_neg_integer() | nil}
  @type t :: %{String.t() => map()}

  @doc "Bytes in the one bucket every plaintext is padded to."
  @spec bucket_bytes() :: pos_integer()
  def bucket_bytes, do: @bucket_bytes

  @doc """
  A reply or proactive row: its sequence number and as much of its preview as
  fits the bucket.
  """
  @spec message(String.t(), pos_integer(), String.t()) :: {:ok, plaintext()} | {:error, term()}
  def message(profile_id, server_seq, preview)
      when is_integer(server_seq) and server_seq > 0 and is_binary(preview) do
    with :ok <- bounded_id(:profile_id, profile_id),
         true <- String.valid?(preview) || {:error, {:invalid_fcm_plaintext, :preview_text}} do
      base = %{"kind" => "message", "profile_id" => profile_id, "server_seq" => server_seq}
      {:ok, fitted_preview(base, preview)}
    end
  end

  def message(_profile_id, server_seq, _preview),
    do: {:error, {:invalid_fcm_plaintext, :server_seq, server_seq}}

  @doc "An approval waiting for the owner: its id and expiry, never its text or token."
  @spec approval(String.t(), String.t(), non_neg_integer()) ::
          {:ok, plaintext()} | {:error, term()}
  def approval(profile_id, approval_id, expires_at)
      when is_integer(expires_at) and expires_at >= 0 do
    with :ok <- bounded_id(:profile_id, profile_id),
         :ok <- bounded_id(:approval_id, approval_id) do
      {:ok,
       %{
         "kind" => "approval",
         "profile_id" => profile_id,
         "approval_id" => approval_id,
         "expires_at" => expires_at
       }}
    end
  end

  def approval(_profile_id, _approval_id, expires_at),
    do: {:error, {:invalid_fcm_plaintext, :expires_at, expires_at}}

  @doc "`plaintext` as one padded bucket: the JSON, one 0x80 byte, then zeros."
  @spec pad(plaintext()) :: {:ok, binary()} | {:error, term()}
  def pad(plaintext) when is_map(plaintext) do
    json = Jason.encode!(plaintext)

    if byte_size(json) < @bucket_bytes,
      do: {:ok, json <> <<@pad_mark>> <> zeros(@bucket_bytes - byte_size(json) - 1)},
      else: {:error, {:fcm_plaintext_too_large, byte_size(json), @bucket_bytes - 1}}
  end

  @doc """
  The FCM v1 request body for `device`, sealed under the key `gateway_private`
  shares with it.
  """
  @spec build(Device.t(), binary(), plaintext(), keyword()) :: {:ok, t()} | {:error, term()}
  def build(%Device{} = device, gateway_private, plaintext, opts \\ []) when is_list(opts) do
    with :ok <- validate_token(device.push_token),
         {:ok, key} <- Push.derive_key(gateway_private, device.noise_pk, device.apns_key_salt),
         {:ok, padded} <- pad(plaintext),
         {:ok, nonce} <- nonce(opts),
         data = sealed_data(key, nonce, padded),
         :ok <- validate_data_size(data) do
      {:ok,
       %{
         "message" => %{
           "token" => device.push_token,
           "data" => data,
           "android" => %{"priority" => "HIGH", "ttl" => @ttl}
         }
       }}
    end
  end

  defp sealed_data(key, nonce, padded) do
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:chacha20_poly1305, key, nonce, padded, <<>>, @tag_bytes, true)

    %{
      "v" => @envelope_version,
      "n" => Base.encode64(nonce),
      "c" => Base.encode64(ciphertext <> tag)
    }
  end

  # FCM counts a data map's keys and values; the phone refuses one past 4 KiB.
  defp validate_data_size(data) do
    size =
      Enum.reduce(data, 0, fn {key, value}, sum -> sum + byte_size(key) + byte_size(value) end)

    if size <= @max_data_bytes, do: :ok, else: {:error, {:fcm_data_too_large, size}}
  end

  defp fitted_preview(base, preview) do
    full = Map.put(base, "preview_text", preview)

    if fits?(full) do
      full
    else
      graphemes = preview |> String.slice(0, @bucket_bytes) |> String.graphemes()
      Map.put(base, "preview_text", longest_cut(base, graphemes))
    end
  end

  # The longest prefix whose cut, ellipsis included, still fits: JSON escapes
  # make the encoded size grow faster than the text, so it is searched for.
  defp longest_cut(base, graphemes) do
    cut = fn count -> Enum.join(Enum.take(graphemes, count)) <> @ellipsis end
    fits_at? = fn count -> fits?(Map.put(base, "preview_text", cut.(count))) end

    case search(fits_at?, 0, length(graphemes)) do
      nil -> nil
      count -> cut.(count)
    end
  end

  # The largest count in low..high for which fits_at? holds, or nil; it holds
  # for every count below one that does.
  defp search(fits_at?, low, high) do
    cond do
      not fits_at?.(low) -> nil
      low == high -> low
      true -> narrow(fits_at?, low, high)
    end
  end

  defp narrow(_fits_at?, low, high) when low >= high, do: low

  defp narrow(fits_at?, low, high) do
    middle = div(low + high + 1, 2)

    if fits_at?.(middle),
      do: narrow(fits_at?, middle, high),
      else: narrow(fits_at?, low, middle - 1)
  end

  defp fits?(plaintext), do: byte_size(Jason.encode!(plaintext)) < @bucket_bytes

  defp bounded_id(_field, value)
       when is_binary(value) and byte_size(value) in 1..@max_id_bytes do
    if String.valid?(value), do: :ok, else: {:error, {:invalid_fcm_plaintext, :invalid_utf8}}
  end

  defp bounded_id(field, _value), do: {:error, {:invalid_fcm_plaintext, field}}

  defp validate_token(token) when is_binary(token) and byte_size(token) in 1..@max_token_bytes,
    do: :ok

  defp validate_token(_token), do: {:error, {:invalid_push_field, :push_token}}

  defp nonce(opts) do
    case Keyword.get(opts, :nonce_fun, &:crypto.strong_rand_bytes/1).(@nonce_bytes) do
      nonce when is_binary(nonce) and byte_size(nonce) == @nonce_bytes -> {:ok, nonce}
      _value -> {:error, :invalid_push_nonce}
    end
  end

  defp zeros(count), do: :binary.copy(<<0>>, count)
end
