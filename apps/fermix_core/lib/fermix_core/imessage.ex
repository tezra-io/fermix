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

  **Where it runs** (M97 §6.4) is `carrier/1`, the one answer the channel
  registry, the channel's own helper on a server, the owner-inbox choice for
  approvals, health and readiness all read: this host when it is a Mac, else
  the one computer of the home whose Messages carry it, and only on a build
  that offers Always On (`carried_off_mac?/0`, the one check of that).
  """

  alias FermixCore.Computers
  alias FermixCore.Computers.Computer
  alias FermixCore.Home.AlwaysOnRelease

  @unsupported_platform_message "imessage runs only on the Mac whose Messages it reads"
  @mac_only_sentence "iMessage runs only on the Mac whose Messages it reads."
  @phone_separators ~r/[\s\-().]/
  @e164 ~r/^\+[1-9]\d{6,14}$/
  @email ~r/^[^@\s]+@[^@\s]+$/
  @offer "imessage"

  @type unsupported_platform :: {:unsupported_platform, :imessage}

  @typedoc """
  Where the channel runs: this host, the one computer that carries it,
  every computer that offers it when more than one does, nowhere, or only
  on a Mac, on a build where no Mac of the home can carry it.
  """
  @type carrier ::
          :here
          | {:computer, Computer.t()}
          | {:conflict, [Computer.t(), ...]}
          | :none
          | :mac_only

  @doc "Whether this host is a Mac."
  @spec macos?() :: boolean()
  def macos?, do: :os.type() == {:unix, :darwin}

  @doc """
  Whether a Mac of the home can carry iMessage for this engine when it is no
  Mac (M97 §6.4): only on a build that offers Always On, since only there
  does a home have computers. The one check the channel registry and
  `carrier/1` read.
  """
  @spec carried_off_mac?() :: boolean()
  def carried_off_mac?, do: AlwaysOnRelease.available?()

  @doc """
  Where this home's iMessage runs (M97 §6.4): `:here` on a Mac, whose own
  Messages the channel reads; elsewhere, on a build a Mac of the home can
  carry it for (`carried_off_mac?/0`), the one computer of the home that
  offers `imessage` as it last said (`{:computer, computer}`, away or not:
  `connected` says which), each of them when more than one does
  (`{:conflict, computers}`, since one home has one Messages bridge), or
  `:none`; on any other build `:mac_only`, which speaks of no server.

  `opts`: `:macos?`, `:carried?` (in place of `carried_off_mac?/0`) and
  `:computers` (the home's computers, in place of
  `FermixCore.Computers.list/1`'s), so a test names the host, the build and
  the home.
  """
  @spec carrier(keyword()) :: carrier()
  def carrier(opts \\ []) when is_list(opts) do
    cond do
      Keyword.get_lazy(opts, :macos?, &macos?/0) -> :here
      Keyword.get_lazy(opts, :carried?, &carried_off_mac?/0) -> computer_carrier(opts)
      true -> :mac_only
    end
  end

  defp computer_carrier(opts) do
    case Enum.filter(Keyword.get_lazy(opts, :computers, &Computers.list/0), &offers?/1) do
      [] -> :none
      [computer] -> {:computer, computer}
      computers -> {:conflict, computers}
    end
  end

  @doc "Whether `computer` offers `imessage` as it last said."
  @spec offers?(Computer.t()) :: boolean()
  def offers?(%Computer{offers: offers}),
    do: Enum.any?(offers, &match?(%{id: @offer, state: :on}, &1))

  @doc "The sentence for a carrier that is asleep or offline."
  @spec away_sentence(String.t()) :: String.t()
  def away_sentence(name) when is_binary(name),
    do: "#{name}, the Mac that carries Messages, is asleep or offline."

  @doc "The sentence for more than one Mac offering Messages, naming each."
  @spec conflict_sentence([String.t(), ...]) :: String.t()
  def conflict_sentence([_, _ | _] = names) do
    {last, rest} = names |> Enum.sort() |> List.pop_at(-1)

    "#{Enum.join(rest, ", ")} and #{last} each offer Messages, and one home has one " <>
      "Messages bridge, so switch Messages off on all but one of them."
  end

  @doc "The sentence for a second Mac offering Messages while `bridge` carries it."
  @spec second_bridge_sentence(String.t(), String.t()) :: String.t()
  def second_bridge_sentence(second, bridge) when is_binary(second) and is_binary(bridge),
    do:
      "#{second} offers Messages too, and one home has one Messages bridge, so Fermix " <>
        "goes on using #{bridge} and refuses #{second}."

  @doc "The sentence for a build off a Mac where no Mac of the home can carry Messages."
  @spec mac_only_sentence() :: String.t()
  def mac_only_sentence, do: @mac_only_sentence

  @doc "The sentence for a home off a Mac where no Mac of its carries Messages."
  @spec none_sentence() :: String.t()
  def none_sentence,
    do:
      "No Mac of yours carries Messages. On the Mac you text from, let Fermix on your " <>
        "server use Messages."

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
  The recipients a policy for this section names: the owner and every guest,
  normalized and listed once each. An empty guest list means "no guests",
  never "no owner" (M53 OWN-3). The account posture is not the section's: the
  helper derives it when it confirms these recipients.
  """
  @spec policy_handles(keyword()) :: [String.t()]
  def policy_handles(section) when is_list(section) do
    owner = section |> Keyword.get(:owner_user_id) |> List.wrap()
    guests = Keyword.get(section, :allowed_sender_ids, [])

    (owner ++ guests)
    |> Enum.map(&normalize_handle!/1)
    |> Enum.uniq()
  end
end
