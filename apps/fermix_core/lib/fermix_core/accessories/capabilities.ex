defmodule FermixCore.Accessories.Capabilities do
  @moduledoc """
  The capability bits of the accessory link (`priv/accessory/PROTOCOL.md`,
  *Capabilities*). Both ends send a u32 bit set in the HELLO exchange: the
  accessory what it has, the host what it can drive. A capability is in use
  only when both ends set it, and a bit neither end knows is ignored, so a new
  capability needs no new wire version. Pure.
  """

  import Bitwise

  @bits [
    mic: 0,
    speaker: 1,
    screen: 2,
    touch: 3,
    pet: 4,
    motion: 5,
    battery: 6,
    wake_word: 7,
    link_update: 8
  ]

  # What this host can drive. `wake_word` and `link_update` are defined and
  # never set in M91 (D12, D25).
  @host [:mic, :speaker, :screen, :touch, :pet, :motion, :battery]

  @type name ::
          :mic
          | :speaker
          | :screen
          | :touch
          | :pet
          | :motion
          | :battery
          | :wake_word
          | :link_update

  @doc "Every defined capability and its bit, in bit order."
  @spec bits() :: [{name(), 0..31}]
  def bits, do: @bits

  @doc "The bit set for these capabilities."
  @spec mask([name()]) :: non_neg_integer()
  def mask(names) when is_list(names) do
    Enum.reduce(names, 0, fn name, acc -> acc ||| 1 <<< Keyword.fetch!(@bits, name) end)
  end

  @doc "The defined capabilities a bit set holds, in bit order; unknown bits are ignored."
  @spec names(non_neg_integer()) :: [name()]
  def names(mask) when is_integer(mask) and mask >= 0 do
    for {name, bit} <- @bits, (mask >>> bit &&& 1) == 1, do: name
  end

  @doc "The bit set this host sends in `hello`."
  @spec host() :: non_neg_integer()
  def host, do: mask(@host)

  @doc "The capabilities both ends set: the ones in use on this link."
  @spec effective(non_neg_integer(), non_neg_integer()) :: [name()]
  def effective(host_mask, accessory_mask)
      when is_integer(host_mask) and is_integer(accessory_mask),
      do: names(host_mask &&& accessory_mask)

  @doc "Which of `required` a bit set lacks, in bit order."
  @spec missing(non_neg_integer(), [name()]) :: [name()]
  def missing(mask, required) when is_integer(mask) and is_list(required) do
    present = names(mask)
    for {name, _bit} <- @bits, name in required, name not in present, do: name
  end
end
