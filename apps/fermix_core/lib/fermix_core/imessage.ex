defmodule FermixCore.IMessage do
  @moduledoc """
  The facts about the iMessage channel that every engine surface shares (M54).

  The channel exists only on the Mac whose Messages it reads: the signed
  **Fermix Messages** helper holds Full Disk Access and Automation, and nothing
  in the BEAM opens `chat.db` or sends an Apple Event. This module owns the
  platform gate, the one handle normalizer and the recipient set a confirmed
  policy names, so the config loader, setup, settings, Doctor and the
  management wire answer those questions the same way.

  `macos?/0` reads the host once per call; every consumer takes a `macos?:`
  option so a test names the platform it means instead of inheriting the CI
  host's.
  """

  @unsupported_platform_message "imessage runs only on the Mac whose Messages it reads"
  @phone_separators ~r/[\s\-().]/
  @e164 ~r/^\+[1-9]\d{6,14}$/
  @email ~r/^[^@\s]+@[^@\s]+$/

  @type unsupported_platform :: {:unsupported_platform, :imessage}

  @doc "Whether this host is a Mac."
  @spec macos?() :: boolean()
  def macos?, do: :os.type() == {:unix, :darwin}

  @doc """
  The platform gate for one parsed `[fermix_channels.imessage]` section.

  An enabled section off a Mac refuses; a disabled or absent one is accepted
  everywhere, so a settings file copied from a Mac still loads on Linux as long
  as the channel is off.
  """
  @spec check_platform(keyword(), keyword()) :: :ok | {:error, unsupported_platform()}
  def check_platform(section, opts \\ []) when is_list(section) and is_list(opts) do
    macos? = Keyword.get_lazy(opts, :macos?, &macos?/0)

    if Keyword.get(section, :enabled) == true and not macos? do
      {:error, {:unsupported_platform, :imessage}}
    else
      :ok
    end
  end

  @doc "The operator sentence for an iMessage refusal."
  @spec error_message(unsupported_platform()) :: String.t()
  def error_message({:unsupported_platform, :imessage}), do: @unsupported_platform_message

  @doc """
  The one handle normalizer (M54 §7.4): a phone number becomes E.164 with its
  leading `+` kept and every separator removed, an email is lower-cased.
  Anything else, a number without its country code included, is refused and
  never guessed. The helper applies the same rule, so a handle the owner typed
  and the one the confirmed policy holds compare equal.
  """
  @spec normalize_handle(term()) :: {:ok, String.t()} | {:error, :invalid_handle}
  def normalize_handle(handle) when is_binary(handle) do
    trimmed = String.trim(handle)

    if String.contains?(trimmed, "@"),
      do: normalize_email(trimmed),
      else: normalize_phone(trimmed)
  end

  def normalize_handle(_handle), do: {:error, :invalid_handle}

  @doc "`normalize_handle/1` for a value the config loader already refused if invalid."
  @spec normalize_handle!(String.t()) :: String.t()
  def normalize_handle!(handle) when is_binary(handle) do
    case normalize_handle(handle) do
      {:ok, normalized} ->
        normalized

      {:error, :invalid_handle} ->
        raise ArgumentError, "not an iMessage handle: #{inspect(handle)}"
    end
  end

  defp normalize_email(value) do
    if Regex.match?(@email, value),
      do: {:ok, String.downcase(value)},
      else: {:error, :invalid_handle}
  end

  defp normalize_phone(value) do
    digits = String.replace(value, @phone_separators, "")
    if Regex.match?(@e164, digits), do: {:ok, digits}, else: {:error, :invalid_handle}
  end

  @doc """
  The recipients a policy for this section names: the owner and, in the
  dedicated posture, every guest, normalized and listed once each. An empty
  guest list means "no guests", never "no owner" (M53 OWN-3).
  """
  @spec policy_handles(keyword()) :: [String.t()]
  def policy_handles(section) when is_list(section) do
    owner = section |> Keyword.get(:owner_user_id) |> List.wrap()
    guests = guest_handles(Keyword.get(section, :posture), section)

    (owner ++ guests)
    |> Enum.map(&normalize_handle!/1)
    |> Enum.uniq()
  end

  defp guest_handles(:own_account, _section), do: []
  defp guest_handles(_posture, section), do: Keyword.get(section, :allowed_sender_ids, [])
end
