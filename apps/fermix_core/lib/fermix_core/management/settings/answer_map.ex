defmodule FermixCore.Management.Settings.AnswerMap do
  @moduledoc """
  The one place a descriptor row key becomes a write (M34 native setup §7.7).

  `settings.get` and `settings.apply` speak two vocabularies: rows are a
  projection of the configuration snapshot, and writes go through a finite
  answer vocabulary. Without one owner for the translation a pane can render a
  control whose save always answers `invalid_params`, which is the failure the
  round-trip gate exists to catch.

  The translation is driven by the **published row**, never by a second table:
  the row carries its kind and its read-only mark, so a row that cannot be
  written is refused here rather than silently dropped, and a row added to a
  section is writable the moment it is published.
  """

  alias FermixCore.Management.Settings.Row
  alias FermixCore.Providers.Descriptor

  @providers_prefix "providers."
  # The widest list the published parameter ceiling leaves room for, and the
  # same bound the schema declares on a list value.
  @max_list_items 200
  @meetings_prefix "meetings_"

  # The one writer that takes positional arguments rather than an answer list,
  # so its three keys are named here rather than resolved from the row key.
  @sandbox_answers %{
    "sandbox_mode" => :sandbox_mode,
    "sandbox_profile" => :sandbox_profile,
    "sandbox_env_allow" => :sandbox_env_allow
  }

  @type writer :: :wizard | :sandbox | :meetings
  @type answer :: {atom(), term()}

  @doc """
  Which writer owns a section.

  One writer per section, never a mix: a write that split across two tails
  would land half of an operator's change under one external-change gate and
  half under the other.
  """
  @spec writer(String.t()) :: writer()
  def writer("sandbox"), do: :sandbox
  def writer("meetings"), do: :meetings
  def writer(section) when is_binary(section), do: :wizard

  @doc """
  Answers this section always carries, whatever the operator changed.

  A provider section names which provider is being edited, because the model,
  effort and fast keys are shared across providers and target whichever one the
  answer set names.
  """
  @spec context(String.t()) :: [answer()]
  def context(@providers_prefix <> id), do: [edit_provider: String.to_existing_atom(id)]
  def context(section) when is_binary(section), do: []

  @doc """
  Translates one published row and its new value into an answer.

  Refuses a secret row (secrets cross the socket in exactly one method), a
  read-only row, and a value whose type does not match the row's kind.
  """
  @spec answer(String.t(), Row.t(), term()) :: {:ok, answer()} | {:error, String.t()}
  def answer(section, row, value) when is_binary(section) and is_map(row) do
    with :ok <- writable(row),
         {:ok, coerced} <- coerce(row, value) do
      {:ok, {answer_key(section, row["key"]), coerced}}
    end
  end

  defp writable(%{"kind" => "secret"}),
    do: {:error, "This is a secret. Store it with secret.set instead."}

  defp writable(%{"read_only" => true}),
    do: {:error, "This setting is shown here and changed elsewhere."}

  defp writable(_row), do: :ok

  # `null` has no meaning for any key this slice publishes: every clearable row
  # already has a blank spelling of its own (an empty string, or the blank
  # option a choice row publishes). Accepting null by translating it into that
  # blank would be a second spelling for one act.
  defp coerce(_row, nil), do: {:error, "This setting cannot be cleared."}

  defp coerce(%{"kind" => "toggle"}, value) when is_boolean(value), do: {:ok, value}
  defp coerce(%{"kind" => "number"}, value) when is_number(value), do: {:ok, value}

  defp coerce(%{"kind" => "text"}, value) when is_binary(value), do: {:ok, value}

  # A choice row's `options` are its value space unless it declares them
  # suggestions. Accepting any string for every choice row is what let an
  # off-list word reach `String.to_existing_atom/1` in the sandbox writer and
  # come back as "errors were found at the given arguments: * 1st argument: not
  # an already existing atom", published verbatim as the refusal under the
  # control the operator had just used — and an off-list word that happened to
  # be an existing atom reached a guard instead and surfaced as
  # `internal_error`.
  defp coerce(%{"kind" => "choice", "suggestions" => true}, value) when is_binary(value),
    do: {:ok, value}

  defp coerce(%{"kind" => "choice"} = row, value) when is_binary(value) do
    if value in option_values(row) do
      {:ok, value}
    else
      {:error, "This setting takes one of its published values."}
    end
  end

  # Bounded, and refused above the bound rather than truncated: a request that
  # carried more than this would approach the published parameter ceiling and
  # land as a bare "parameters are invalid" with nothing naming the field.
  defp coerce(%{"kind" => "list"}, value) when is_list(value) and length(value) > @max_list_items,
    do: {:error, "This setting takes at most #{@max_list_items} values."}

  defp coerce(%{"kind" => "list"}, value) when is_list(value) do
    if Enum.all?(value, &is_binary/1) do
      {:ok, value}
    else
      {:error, "This setting takes a list of text values."}
    end
  end

  defp coerce(%{"kind" => kind}, _value), do: {:error, "This setting takes #{expected(kind)}."}

  defp option_values(row), do: row |> Map.get("options", []) |> Enum.map(& &1["value"])

  defp expected("toggle"), do: "true or false"
  defp expected("number"), do: "a number"
  defp expected("choice"), do: "one of its published values"
  defp expected("text"), do: "text"
  defp expected("list"), do: "a list of text values"

  # A provider's auth mode is per provider on the write side and one row on the
  # read side, because a section already names its provider. Every other row key
  # is its own answer key, which is what makes the round trip a fact.
  defp answer_key(@providers_prefix <> id, "auth_mode") do
    descriptor = Descriptor.fetch!(String.to_existing_atom(id))
    :"#{descriptor.id}_auth_mode"
  end

  defp answer_key("meetings", @meetings_prefix <> key), do: String.to_existing_atom(key)
  defp answer_key("sandbox", key), do: Map.fetch!(@sandbox_answers, key)
  defp answer_key(_section, key), do: String.to_existing_atom(key)
end
