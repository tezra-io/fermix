defmodule FermixCore.Home.Snapshot.Config do
  @moduledoc """
  `[fermix_core.snapshots]` (M75 §8, §16): where and how often a primary writes
  its encrypted snapshots.

      [fermix_core.snapshots]
      recipient = "fxsnap1.<salt>.<public key>"   # set from the recovery passphrase
      interval_hours = 6                          # 1 to 168
      s3_bucket = "invented-fermix-snapshots"
      s3_region = "eu-west-1"
      s3_prefix = "fermix"                        # the default
      s3_endpoint = "https://s3.example.net"      # S3-compatible hosts only
      s3_access_key_id = "@keyring"               # the snapshot_s3_* secret
      s3_secret_access_key = "@keyring"           # references

  The S3 target is on when `recipient` and `s3_bucket` are both set. Absent
  keys read as their defaults (`interval_hours` 6, `s3_prefix` `fermix`) and
  are never written for the owner. The two key fields hold the references
  `SecretPaths` keeps for the secrets `snapshot_s3_access_key_id` and
  `snapshot_s3_secret_access_key`, never typed by hand.

  `normalize/1` turns the parsed file into the keyword application environment
  holds, refusing an unknown key or a bad value by name with a sentence that
  names the fix (`ArgumentError`, which the settings writer shows under the
  control that sent it), and an empty text value reads as absent;
  `to_keyword/1` is its inverse, the spellings `config.toml` holds (the
  "Config round-trips" rule).
  """

  alias FermixCore.Home.Snapshot.Recipient

  @section "[fermix_core.snapshots]"
  @keys ~w(recipient interval_hours s3_bucket s3_region s3_prefix s3_endpoint
           s3_access_key_id s3_secret_access_key)
  @default_interval_hours 6
  @default_prefix "fermix"
  @interval 1..168
  @bucket ~r/\A[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\z/
  @region ~r/\A[a-z0-9][a-z0-9-]{0,31}\z/
  @prefix ~r/\A[A-Za-z0-9._-]+(\/[A-Za-z0-9._-]+)*\z/
  @max_prefix_bytes 256
  @max_secret_bytes 4_096

  @type t :: keyword()
  @type s3 :: %{
          bucket: String.t(),
          region: String.t(),
          prefix: String.t(),
          endpoint: String.t() | nil,
          access_key_id: String.t() | nil,
          secret_access_key: String.t() | nil
        }

  @doc "The interval when none is set, in hours."
  @spec default_interval_hours() :: pos_integer()
  def default_interval_hours, do: @default_interval_hours

  @doc """
  The section in the shape application environment holds. Accepts the parsed
  file (string keys), its own output and `to_keyword/1`'s; raises naming the
  key on anything else.
  """
  @spec normalize(keyword() | map() | nil) :: t()
  def normalize(nil), do: []

  def normalize(config) when is_map(config) or is_list(config) do
    entries = entries!(config)

    Enum.flat_map(@keys, fn key ->
      with {^key, raw} <- List.keyfind(entries, key, 0),
           value when value != nil <- value!(key, raw) do
        [{String.to_existing_atom(key), value}]
      else
        _absent -> []
      end
    end)
  end

  @doc """
  The inverse of `normalize/1`, in the spellings `config.toml` holds: every
  value `normalize/1` keeps is already one.
  """
  @spec to_keyword(keyword() | map() | nil) :: keyword()
  def to_keyword(config) when is_list(config) or is_map(config) or is_nil(config),
    do: normalize(config)

  @doc "The recipient, `:absent` when none is set."
  @spec recipient(t()) :: {:ok, Recipient.t()} | :absent
  def recipient(config) when is_list(config) do
    case Keyword.get(config, :recipient) do
      nil -> :absent
      text -> Recipient.decode(text)
    end
  end

  @doc "How often a snapshot is written, in hours."
  @spec interval_hours(t()) :: pos_integer()
  def interval_hours(config) when is_list(config),
    do: Keyword.get(config, :interval_hours, @default_interval_hours)

  @doc "Whether a recovery recipient is set."
  @spec recipient?(t()) :: boolean()
  def recipient?(config) when is_list(config), do: Keyword.has_key?(config, :recipient)

  @doc "The S3 target's settings, `:not_configured` without a recipient and a bucket."
  @spec s3(t()) :: {:ok, s3()} | :not_configured
  def s3(config) when is_list(config) do
    case {Keyword.get(config, :recipient), Keyword.get(config, :s3_bucket)} do
      {recipient, bucket} when is_binary(recipient) and is_binary(bucket) ->
        {:ok,
         %{
           bucket: bucket,
           region: Keyword.get(config, :s3_region, "us-east-1"),
           prefix: Keyword.get(config, :s3_prefix, @default_prefix),
           endpoint: Keyword.get(config, :s3_endpoint),
           access_key_id: Keyword.get(config, :s3_access_key_id),
           secret_access_key: Keyword.get(config, :s3_secret_access_key)
         }}

      _not_both ->
        :not_configured
    end
  end

  defp entries!(config) do
    entries = Enum.map(config, &entry!/1)
    unknown = for {key, _value} <- entries, key not in @keys, do: key

    if unknown != [] do
      raise ArgumentError,
            "config.toml #{@section} has unknown key(s): #{Enum.join(Enum.sort(unknown), ", ")}. " <>
              "Allowed keys: #{Enum.join(@keys, ", ")}. Remove or fix the key(s); " <>
              "the daemon will not boot until this is fixed."
    end

    entries
  end

  defp entry!({key, value}) when is_binary(key) or is_atom(key), do: {to_string(key), value}

  defp entry!(other),
    do: raise(ArgumentError, "config.toml #{@section} is not a table: #{inspect(other)}")

  # An empty text value is a cleared field: absent, so its default applies.
  defp value!(_key, ""), do: nil
  defp value!("recipient", value), do: recipient!(value)
  defp value!("interval_hours", value), do: interval!(value)
  defp value!("s3_bucket", value), do: matching!("s3_bucket", value, @bucket, bucket_rule())
  defp value!("s3_region", value), do: matching!("s3_region", value, @region, region_rule())
  defp value!("s3_prefix", value), do: prefix!(value)
  defp value!("s3_endpoint", value), do: endpoint!(value)
  defp value!(key, value), do: secret!(key, value)

  defp recipient!(value) do
    case Recipient.decode(value) do
      {:ok, _recipient} ->
        value

      {:error, :invalid_recipient} ->
        refuse(
          "recipient",
          "is not a recovery key Fermix wrote. Set the recovery passphrase again in Always " <>
            "On, which writes a new one"
        )
    end
  end

  defp interval!(value) when is_integer(value) and value in @interval, do: value

  defp interval!(value) do
    refuse(
      "interval_hours",
      "takes a whole number of hours from 1 to 168, and #{inspect(value)} is not"
    )
  end

  defp matching!(key, value, pattern, rule) when is_binary(value) do
    if String.match?(value, pattern), do: value, else: refuse(key, rule)
  end

  defp matching!(key, _value, _pattern, rule), do: refuse(key, rule)

  defp bucket_rule,
    do: "takes a bucket name: 3 to 63 lowercase letters, digits, dots and hyphens"

  defp region_rule, do: "takes a region name such as `eu-west-1`"

  defp prefix!(value) when is_binary(value) and byte_size(value) <= @max_prefix_bytes do
    if String.match?(value, @prefix),
      do: value,
      else: refuse("s3_prefix", prefix_rule())
  end

  defp prefix!(_value), do: refuse("s3_prefix", prefix_rule())

  defp prefix_rule,
    do:
      "takes letters, digits, dots, hyphens and underscores, in parts joined by a slash, " <>
        "with no slash at either end"

  defp endpoint!(value) when is_binary(value) do
    uri = URI.parse(value)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         uri.userinfo == nil and uri.query == nil and uri.fragment == nil and
         uri.path in [nil, "", "/"],
       do: String.trim_trailing(value, "/"),
       else: refuse("s3_endpoint", endpoint_rule())
  end

  defp endpoint!(_value), do: refuse("s3_endpoint", endpoint_rule())

  defp endpoint_rule,
    do: "takes the storage service's address, such as `https://s3.example.net`, with no path"

  defp secret!(key, value) when is_binary(value) and byte_size(value) <= @max_secret_bytes do
    if String.match?(value, ~r/[\x00-\x1F\x7F]/),
      do: refuse(key, "takes a single line"),
      else: value
  end

  defp secret!(key, _value), do: refuse(key, "takes a single line of text")

  defp refuse(key, rule) do
    raise ArgumentError, "config.toml #{@section} #{key} #{rule}. Fix it and save again."
  end
end
