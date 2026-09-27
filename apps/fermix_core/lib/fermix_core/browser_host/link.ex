defmodule FermixCore.BrowserHost.Link do
  @moduledoc """
  The messages between a pane task and the connection of the app it runs on.

  A pane task is `Browser.HostServer` inside one `ProfileServer`; the connection
  is `FermixChannels.BrowserHost.Connection`, the one process that owns
  `browser_host.sock`'s client. Core never compiles against channels, so the
  two meet in these messages and nowhere else. Every one of them is sent by a
  function here, and the receiving side matches the tuple this module
  documents.

  Task to connection:
  - `{:browser_host_request, task_pid, ref, task_id, type, payload}`: one wire
    request, answered with `{:browser_host_answer, ref, answer}`.
  - `{:browser_host_release, task_pid, task_id}`: the task is over. The
    connection writes its `task.release` at most once, behind every request the
    task sent, because both travel from the same process in order.

  Connection to task:
  - `{:browser_host_answer, ref, {:ok, result} | {:error, %{"reason", "message"}}}`
  - `{:browser_host_event, connection, type, payload}`: an app event about a tab
    (`tab.closed`, `dialog.opened`, `download.*`).
  - `{:browser_host_stopping, connection}`: the app is quitting; the connection
    has already written the task's `task.release`.
  """

  @typedoc "What a request is answered with."
  @type answer :: {:ok, map()} | {:error, %{String.t() => String.t()}}

  @doc "Send one request for `task_id` on `connection`; the answer carries the returned ref."
  @spec request(pid(), String.t(), String.t(), map()) :: reference()
  def request(connection, task_id, type, payload)
      when is_pid(connection) and is_binary(task_id) and is_binary(type) and is_map(payload) do
    ref = make_ref()
    send(connection, {:browser_host_request, self(), ref, task_id, type, payload})
    ref
  end

  @doc "Tell `connection` that `task_id` is over, so its tabs are released."
  @spec release(pid(), String.t()) :: :ok
  def release(connection, task_id) when is_pid(connection) and is_binary(task_id) do
    send(connection, {:browser_host_release, self(), task_id})
    :ok
  end

  @doc "Answer a task's request."
  @spec answer(pid(), reference(), answer()) :: :ok
  def answer(task, ref, {status, _body} = answer)
      when is_pid(task) and is_reference(ref) and status in [:ok, :error] do
    send(task, {:browser_host_answer, ref, answer})
    :ok
  end

  @doc "Forward an app event about a tab to a task."
  @spec event(pid(), pid(), String.t(), map()) :: :ok
  def event(task, connection, type, payload)
      when is_pid(task) and is_pid(connection) and is_binary(type) and is_map(payload) do
    send(task, {:browser_host_event, connection, type, payload})
    :ok
  end

  @doc "Tell a task that its app is quitting."
  @spec stopping(pid(), pid()) :: :ok
  def stopping(task, connection) when is_pid(task) and is_pid(connection) do
    send(task, {:browser_host_stopping, connection})
    :ok
  end
end
