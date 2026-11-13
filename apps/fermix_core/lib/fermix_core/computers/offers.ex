defmodule FermixCore.Computers.Offers do
  @moduledoc """
  What a computer offers its server (M97 §3.2), worked out and put on the
  wire. Pure.

  `compute/3` asks each offer module (`Computers.Offer`) for its state on
  this computer. The words around a switch are here, so every offer says
  them the same way (`switched/4`): an offer is off while the switches wait
  for the owner's review (a computer that moved before M97), while the
  master is off, or while its own consent is off: the switch that decides it
  (`Switches.on?/2`), and for history its recorder's setting
  (`Switches.history_on?/2`, M97 D27).

  On the wire (`offers`, the mobile protocol's *Desktop sessions*) the list
  travels as one JSON payload, `{"v":1,"offers":[…]}`, each offer
  `{id, state, sentence?, detail?}`, and its revision `rev`, the first 8
  bytes of the payload's SHA-256 in lowercase hex (`encode/1`). `decode/1`
  is the one check either end makes, and names the first thing it refuses:

    * at most 32 offers, each `id` matching `^[a-z][a-z0-9_]{0,31}$` and
      named once;
    * `state` one of `on`, `off` and `unavailable`;
    * `sentence` present unless the state is `on`, 1 to 300 bytes of
      printable UTF-8;
    * `detail`, when present, 1 to 64 bytes of printable text;
    * `helper`, when present (the `computer_use` offer, M97 §6.4: what this
      computer's screen helper offers, which the server's `computer_use` tool
      follows), `{actions, input_methods}`: 1 to #{64} action names and 0 to
      #{8} input methods, each `^[a-z][a-z0-9_]{0,31}$`;
    * `roots`, when present (the `files` offer, M97 §6.4: the folders files
      and commands reach on this computer), 1 to #{32} absolute paths, each
      1 to #{1024} bytes of printable UTF-8. A computer sends only the
      folders the wire can carry (`wire_roots/1`): any other is left out,
      and the first #{32} are sent, so one odd folder never stops the rest
      of what it offers;
    * `home`, when present beside `roots`, the folder a path's `~` stands
      for on this computer, one absolute path as a root is.

  An id this engine has no module for is kept as it came: a newer computer
  may offer more, and the home lists only what it was told.
  """

  alias FermixCore.Computers.Facts
  alias FermixCore.Computers.Switches

  @version 1
  @max_offers 32
  @max_sentence_bytes 300
  @max_detail_bytes 64
  @id ~r/\A[a-z][a-z0-9_]{0,31}\z/
  @controls ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u
  @max_helper_actions 64
  @max_input_methods 8
  @max_roots 32
  @max_root_bytes 1024
  @states %{"on" => :on, "off" => :off, "unavailable" => :unavailable}
  # Every offer a computer makes, in the order it lists them. What reaches
  # the server from a computer (calls, attachments, a robot, notifications)
  # is no offer (M97 D27).
  @modules [
    FermixCore.Computers.Offers.Files,
    FermixCore.Computers.Offers.Shell,
    FermixCore.Computers.Offers.Browser,
    FermixCore.Computers.Offers.ComputerUse,
    FermixCore.Computers.Offers.IMessage,
    FermixCore.Computers.Offers.History
  ]
  @no_system_sentence "Fermix offers this only on a Mac or a Linux computer."

  @typedoc "One offer as the home records it."
  @type offer :: %{
          required(:id) => String.t(),
          required(:state) => :on | :off | :unavailable,
          required(:sentence) => String.t() | nil,
          required(:detail) => String.t() | nil,
          optional(:helper) => %{actions: [String.t()], input_methods: [String.t()]},
          optional(:roots) => [String.t(), ...],
          optional(:home) => String.t()
        }

  @doc "The most offers one computer sends."
  @spec max_offers() :: pos_integer()
  def max_offers, do: @max_offers

  @doc "Every offer module, in the order a computer lists them."
  @spec modules() :: [module()]
  def modules, do: @modules

  @doc "The module of the offer `id`."
  @spec module(Switches.offer()) :: module()
  def module(id) when is_atom(id) do
    case Enum.find(@modules, &(&1.id() == id)) do
      nil -> raise ArgumentError, "#{inspect(id)} is no offer"
      module -> module
    end
  end

  @doc "An offer's sentence on a system Fermix offers nothing on."
  @spec no_system_sentence() :: String.t()
  def no_system_sentence, do: @no_system_sentence

  @doc """
  The words the offer `id` goes by ("commands", "the browser"), from its
  offer module. Nil for an id this engine has no module for: another
  computer may offer more, or an earlier one an offer this engine retired.
  """
  @spec label(String.t()) :: String.t() | nil
  def label(id) when is_binary(id) do
    Enum.find_value(@modules, fn module ->
      if Atom.to_string(module.id()) == id, do: module.label()
    end)
  end

  @doc "Each module's offer on this computer, in the modules' order."
  @spec compute([module()], Switches.t(), Facts.t()) :: [offer()]
  def compute(modules, switches, facts)
      when is_list(modules) and is_list(switches) and is_map(facts) do
    for module <- modules do
      case module.state(switches, facts) do
        {:on, detail} ->
          offer(module.id(), :on, nil, detail)

        {:on, detail, more} ->
          module.id() |> offer(:on, nil, detail) |> Map.merge(more)

        {state, sentence} when state in [:off, :unavailable] ->
          offer(module.id(), state, sentence)
      end
    end
  end

  defp offer(id, state, sentence, detail \\ nil),
    do: %{id: Atom.to_string(id), state: state, sentence: sentence, detail: detail}

  @doc """
  An offer that its consent decides, on a machine that can have it: on with
  `detail`, or off with the sentence that says why (the moduledoc).
  """
  @spec switched(Switches.t(), Switches.offer(), Facts.t(), String.t() | nil) ::
          {:on, String.t() | nil} | {:off, String.t()}
  def switched(switches, id, facts, detail) when is_list(switches) and is_map(facts) do
    machine = Facts.machine(facts)

    cond do
      not Switches.reviewed?(switches) -> {:off, waiting_sentence(machine)}
      not Switches.enabled?(switches) -> {:off, master_off_sentence(machine)}
      consented?(switches, id, facts) -> {:on, detail}
      true -> {:off, switched_off_sentence(machine)}
    end
  end

  # The one rule (`Computers.Switches`): history follows its recorder, every
  # other offer the switch that decides it.
  defp consented?(switches, :history, facts),
    do: Switches.history_on?(switches, Map.fetch!(facts, :recording))

  defp consented?(switches, id, _facts), do: Switches.on?(switches, id)

  @doc "An offer's sentence while the switches wait for the owner's review."
  @spec waiting_sentence(String.t()) :: String.t()
  def waiting_sentence(machine) when is_binary(machine),
    do: "Waiting for you to review what Fermix on your server may use on this #{machine}."

  @doc "An offer's sentence while this computer's master switch is off."
  @spec master_off_sentence(String.t()) :: String.t()
  def master_off_sentence(machine) when is_binary(machine),
    do: "Everything Fermix on your server may use is switched off on this #{machine}."

  @doc "An offer's sentence while its own switch is off."
  @spec switched_off_sentence(String.t()) :: String.t()
  def switched_off_sentence(machine) when is_binary(machine),
    do: "Switched off on this #{machine}. Only someone at this #{machine} can switch it on."

  @doc """
  The wire payload of `offers` and its revision (the moduledoc), or the first
  thing `decode/1` would refuse in it.
  """
  @spec encode([offer()]) :: {:ok, binary(), String.t()} | {:error, {:invalid_offers, String.t()}}
  def encode(offers) when is_list(offers) do
    payload = Jason.encode!(%{"v" => @version, "offers" => Enum.map(offers, &to_wire/1)})

    with {:ok, _offers} <- decode(payload), do: {:ok, payload, rev(payload)}
  end

  @doc """
  The folders of `roots` the wire carries (the moduledoc), in their order:
  each an absolute path of 1 to #{@max_root_bytes} bytes of printable text,
  the first #{@max_roots} of them.
  """
  @spec wire_roots([String.t()]) :: [String.t()]
  def wire_roots(roots) when is_list(roots),
    do: roots |> Enum.filter(&wire_root?/1) |> Enum.uniq() |> Enum.take(@max_roots)

  @doc "Whether the wire carries `path` as a folder: an absolute path of printable text."
  @spec wire_root?(term()) :: boolean()
  def wire_root?(path),
    do: printable?(path, @max_root_bytes) and String.starts_with?(path, "/")

  @doc "The revision of a payload: the first 8 bytes of its SHA-256, lowercase hex."
  @spec rev(binary()) :: String.t()
  def rev(payload) when is_binary(payload),
    do: :sha256 |> :crypto.hash(payload) |> binary_part(0, 8) |> Base.encode16(case: :lower)

  @doc "Whether `rev` is a revision's shape: 16 lowercase hex digits."
  @spec rev?(term()) :: boolean()
  def rev?(rev), do: is_binary(rev) and Regex.match?(~r/\A[0-9a-f]{16}\z/, rev)

  @doc "The offers a payload carries, or the first thing it breaks (the moduledoc)."
  @spec decode(binary()) :: {:ok, [offer()]} | {:error, {:invalid_offers, String.t()}}
  def decode(payload) when is_binary(payload) do
    with {:ok, document} <- json(payload),
         {:ok, list} <- list(document),
         {:ok, offers} <- each_offer(list),
         :ok <- unique(offers) do
      {:ok, offers}
    end
  end

  @doc """
  An offer as `home.status` lists it: string keys, absent ones null.
  """
  @spec view(offer()) :: map()
  def view(%{id: id, state: state} = offer) do
    %{
      "id" => id,
      "state" => Atom.to_string(state),
      "sentence" => Map.get(offer, :sentence),
      "detail" => Map.get(offer, :detail)
    }
  end

  @doc """
  An offer as the wire carries it and the home records it on disk
  (`Computers.Store`): string keys, absent ones left out, the screen's
  helper included, so `decode/1` reads it back whole.
  """
  @spec to_wire(offer()) :: map()
  def to_wire(%{id: id, state: state} = offer) do
    %{"id" => id, "state" => Atom.to_string(state)}
    |> put_some("sentence", Map.get(offer, :sentence))
    |> put_some("detail", Map.get(offer, :detail))
    |> put_some("helper", helper_wire(Map.get(offer, :helper)))
    |> put_some("roots", Map.get(offer, :roots))
    |> put_some("home", Map.get(offer, :home))
  end

  defp helper_wire(%{actions: actions, input_methods: methods}),
    do: %{"actions" => actions, "input_methods" => methods}

  defp helper_wire(nil), do: nil

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  defp json(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = document} -> {:ok, document}
      {:ok, _other} -> refuse("the payload is not a JSON object")
      {:error, _reason} -> refuse("the payload is not JSON")
    end
  end

  defp list(%{"v" => @version, "offers" => offers}) when is_list(offers) do
    if length(offers) <= @max_offers,
      do: {:ok, offers},
      else: refuse("it lists more than #{@max_offers} offers")
  end

  defp list(%{"v" => @version}), do: refuse("offers is not a list")
  defp list(_document), do: refuse("v is not #{@version}")

  defp each_offer(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      case one(item) do
        {:ok, offer} -> {:cont, {:ok, [offer | acc]}}
        {:error, what} -> {:halt, refuse("offer #{index}: #{what}")}
      end
    end)
    |> then(fn
      {:ok, offers} -> {:ok, Enum.reverse(offers)}
      error -> error
    end)
  end

  defp one(%{"id" => id, "state" => state} = item) do
    with :ok <- id(id),
         {:ok, state} <- state(state),
         {:ok, sentence} <- sentence(Map.get(item, "sentence"), state),
         {:ok, detail} <- detail(Map.get(item, "detail")),
         {:ok, helper} <- helper(Map.get(item, "helper")),
         {:ok, roots} <- roots(Map.get(item, "roots")),
         {:ok, home} <- home(Map.get(item, "home")) do
      offer = %{id: id, state: state, sentence: sentence, detail: detail}

      {:ok,
       offer |> put_some(:helper, helper) |> put_some(:roots, roots) |> put_some(:home, home)}
    end
  end

  defp one(%{}), do: {:error, "it names no id or no state"}
  defp one(_item), do: {:error, "it is not an object"}

  defp helper(nil), do: {:ok, nil}

  defp helper(%{"actions" => actions, "input_methods" => methods}) do
    if names?(actions, 1, @max_helper_actions) and names?(methods, 0, @max_input_methods),
      do: {:ok, %{actions: actions, input_methods: methods}},
      else:
        {:error,
         "its helper is not 1 to #{@max_helper_actions} actions and 0 to " <>
           "#{@max_input_methods} input methods, each a name"}
  end

  defp helper(_other), do: {:error, "its helper names no actions or no input methods"}

  defp roots(nil), do: {:ok, nil}

  defp roots(roots) do
    if is_list(roots) and length(roots) in 1..@max_roots and Enum.all?(roots, &wire_root?/1),
      do: {:ok, roots},
      else:
        {:error,
         "its roots are not 1 to #{@max_roots} absolute paths, each 1 to " <>
           "#{@max_root_bytes} bytes of printable text"}
  end

  defp home(nil), do: {:ok, nil}

  defp home(home) do
    if wire_root?(home),
      do: {:ok, home},
      else:
        {:error,
         "its home is not an absolute path of 1 to #{@max_root_bytes} bytes of printable text"}
  end

  defp names?(list, min, max) when is_list(list),
    do:
      length(list) in min..max and
        Enum.all?(list, &(is_binary(&1) and Regex.match?(@id, &1)))

  defp names?(_not_a_list, _min, _max), do: false

  defp id(id) do
    if is_binary(id) and Regex.match?(@id, id), do: :ok, else: {:error, "its id is not an id"}
  end

  defp state(state) do
    case Map.fetch(@states, state) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, "its state is not on, off or unavailable"}
    end
  end

  defp sentence(nil, :on), do: {:ok, nil}
  defp sentence(nil, _state), do: {:error, "it has no sentence"}

  defp sentence(sentence, _state) do
    if printable?(sentence, @max_sentence_bytes),
      do: {:ok, sentence},
      else: {:error, "its sentence is not 1 to #{@max_sentence_bytes} bytes of printable text"}
  end

  defp detail(nil), do: {:ok, nil}

  defp detail(detail) do
    if printable?(detail, @max_detail_bytes),
      do: {:ok, detail},
      else: {:error, "its detail is not 1 to #{@max_detail_bytes} bytes of printable text"}
  end

  defp printable?(value, max) when is_binary(value),
    do: byte_size(value) in 1..max and String.valid?(value) and not Regex.match?(@controls, value)

  defp printable?(_value, _max), do: false

  defp unique(offers) do
    ids = Enum.map(offers, & &1.id)

    case ids -- Enum.uniq(ids) do
      [] -> :ok
      [id | _more] -> refuse("#{id} is named more than once")
    end
  end

  defp refuse(what), do: {:error, {:invalid_offers, "The offers were refused: #{what}."}}
end
