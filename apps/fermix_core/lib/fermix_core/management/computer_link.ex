defmodule FermixCore.Management.ComputerLink do
  @moduledoc """
  A computer's own link to a home (M97 §3.1, §3.3), answered on the computer
  itself (device-class, `Management.Placement`), each an owner decision:

    * `computer.join.start {code}`: this computer joins the home the code
      names (`Home.Join.start/3`) and the engine restarts as its computer,
      which then dials the server and waits for the owner to add it. A code
      that is not a computer's, that expired or that Fermix did not open is
      `invalid_params` on `code`; a computer with a home of its own, or one
      already joining, is `unavailable` with its sentence.
    * `computer.join.cancel`: the join ends wherever it stands
      (`Home.Join.cancel/2`) and this computer is its own home again.
    * `computer.disconnect {confirmed?}`: this computer leaves the home it is
      linked to (`Home.Leave.disconnect/2`): the server is told over the
      link, then the key, the link and what the server may use here go,
      and the engine restarts. A server that cannot be told is `unavailable`
      with the sentence that asks to confirm, marked `details.confirm`, and
      nothing changes; `confirmed: true` disconnects anyway and answers
      `server_told: false`.

  Seams in `opts`: `:home`, `:now`, `:restart`, `:key_opts`, `:link_status`
  and `:primary_forward` (the link, on a linked computer).
  """

  alias FermixCore.Home.Join
  alias FermixCore.Home.Leave
  alias FermixCore.Setup.ConfigStore

  @capability "computer"
  @code_errors [:code_expired]
  @joining_sentence "This computer is joining your Fermix. It restarts, then waits for you " <>
                      "to add it on a computer already in your Fermix."
  @cancelled_sentence "This computer is its own Fermix again."
  @not_linked_sentence "This computer is not connected to a Fermix."

  @doc "`computer.join.start`: this computer joins the home `code` names."
  @spec join_start(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def join_start(code, opts \\ []) when is_list(opts) do
    with {:ok, code} <- code_param(code) do
      case Join.start(home(opts), code, join_opts(opts)) do
        :ok -> {:ok, %{"joining" => true, "sentence" => @joining_sentence}}
        {:error, reason} -> refused(reason)
      end
    end
  end

  @doc "`computer.join.cancel`: the join ends, and this computer is its own home again."
  @spec join_cancel(keyword()) :: {:ok, map()} | {:error, term()}
  def join_cancel(opts \\ []) when is_list(opts) do
    case Join.cancel(home(opts), join_opts(opts)) do
      :ok -> {:ok, %{"cancelled" => true, "sentence" => @cancelled_sentence}}
      {:error, reason} -> refused(reason)
    end
  end

  @doc "`computer.disconnect`: this computer leaves the home it is linked to."
  @spec disconnect(boolean(), keyword()) :: {:ok, map()} | {:error, term()}
  def disconnect(confirmed?, opts \\ []) when is_boolean(confirmed?) and is_list(opts) do
    case Keyword.fetch(opts, :primary_forward) do
      {:ok, forward} -> leave(forward, confirmed?, opts)
      :error -> {:error, {:unavailable, @capability, @not_linked_sentence}}
    end
  end

  defp leave(forward, confirmed?, opts) do
    leave_opts =
      [forward: forward, confirmed: confirmed?] ++
        Keyword.take(opts, [:restart, :key_opts, :link_status])

    case Leave.disconnect(home(opts), leave_opts) do
      {:ok, told?} ->
        {:ok,
         %{"disconnected" => true, "server_told" => told?, "sentence" => left_sentence(told?)}}

      # A refusal that is a question: `confirmed` turns it into the act.
      {:error, :not_told} ->
        {:error, {:confirm, @capability, Leave.error_sentence(:not_told)}}

      {:error, reason} ->
        {:error, {:unavailable, @capability, Leave.error_sentence(reason)}}
    end
  end

  defp left_sentence(true), do: "This computer left your Fermix."

  defp left_sentence(false),
    do: "This computer left your Fermix. Remove it on your server too, which still lists it."

  @doc "Every fixed sentence this module answers, for the copy rules."
  @spec sentences() :: [String.t()]
  def sentences,
    do: [
      @joining_sentence,
      @cancelled_sentence,
      @not_linked_sentence,
      left_sentence(true),
      left_sentence(false)
    ]

  defp code_param(code) when is_binary(code) and byte_size(code) in 1..4_096, do: {:ok, code}

  defp code_param(_code),
    do: {:error, {:invalid_params, "code", Join.error_sentence({:invalid_code, "code"})}}

  defp refused({kind, _detail} = reason) when kind in [:invalid_code, :code_purpose],
    do: {:error, {:invalid_params, "code", Join.error_sentence(reason)}}

  defp refused(reason) when reason in @code_errors,
    do: {:error, {:invalid_params, "code", Join.error_sentence(reason)}}

  defp refused(reason), do: {:error, {:unavailable, @capability, Join.error_sentence(reason)}}

  defp join_opts(opts), do: Keyword.take(opts, [:now, :restart, :key_opts])
  defp home(opts), do: Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)
end
