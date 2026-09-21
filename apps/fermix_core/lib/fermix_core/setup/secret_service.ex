defmodule FermixCore.Setup.SecretWriter.SecretService do
  @moduledoc """
  What the Secret Service on this session bus can do right now.

  A locked collection and an absent one are not the same refusal, and they
  cannot be told apart by watching `secret-tool`: a locked collection makes it
  block on a password prompt rather than exit, so the timeout it eventually
  hits says nothing about which of the two happened. The lock state is a
  readable property instead, so this asks.

  Both reads are passive. Neither unlocks anything nor raises a prompt on the
  owner's screen, which matters because the caller may be a headless daemon
  and the owner may not be at the machine.

  `busctl` is systemd's, and the service path already requires a systemd user
  manager, so it is present wherever `fermix service install` can succeed. The
  package declares no dependency on it, so its absence is answered rather than
  assumed: with no way to read the property, this reports `:unavailable` and
  never claims a lock it did not observe.
  """

  alias FermixCore.CommandRunner

  @service "org.freedesktop.secrets"
  @service_path "/org/freedesktop/secrets"
  @service_interface "org.freedesktop.Secret.Service"
  @collection_interface "org.freedesktop.Secret.Collection"
  @default_alias "default"
  # Two calls to a bus daemon on the same machine. Neither waits for a human,
  # so a probe that has not answered in two seconds is a bus that cannot
  # answer, and the caller is told `:unavailable` rather than made to wait.
  @probe_timeout_ms 2_000

  @type state :: :ready | :locked | :unavailable

  @doc "The bound each bus probe runs under."
  @spec probe_timeout_ms() :: pos_integer()
  def probe_timeout_ms, do: @probe_timeout_ms

  @doc """
  `:ready` when a secret can be written now, `:locked` when the default
  collection is locked, `:unavailable` when no Secret Service answers.
  """
  @spec state(keyword()) :: state()
  def state(opts \\ []) when is_list(opts) do
    case busctl(opts) do
      nil -> :unavailable
      binary -> collection_state(binary, opts)
    end
  end

  defp collection_state(binary, opts) do
    case default_collection(binary, opts) do
      {:ok, path} -> locked_state(binary, path, opts)
      :error -> :unavailable
    end
  end

  # The collection the write will actually hit. GNOME names it `login`;
  # KWallet and KeePassXC do not, so the name is resolved rather than assumed.
  defp default_collection(binary, opts) do
    args = [
      "--user",
      "call",
      @service,
      @service_path,
      @service_interface,
      "ReadAlias",
      "s",
      @default_alias
    ]

    case probe(binary, args, opts) do
      {:ok, output} -> parse_object_path(output)
      :error -> :error
    end
  end

  defp locked_state(binary, path, opts) do
    args = ["--user", "get-property", @service, path, @collection_interface, "Locked"]

    case probe(binary, args, opts) do
      {:ok, output} -> parse_locked(output)
      :error -> :unavailable
    end
  end

  defp parse_object_path(output) do
    case Regex.run(~r/^o\s+"([^"]+)"/, String.trim(output)) do
      [_match, path] -> {:ok, path}
      nil -> :error
    end
  end

  # Anything but the two words the property can hold is a bus answering
  # something this does not understand, which is not evidence of a lock.
  defp parse_locked(output) do
    case String.trim(output) do
      "b true" -> :locked
      "b false" -> :ready
      _unreadable -> :unavailable
    end
  end

  defp probe(binary, args, opts) do
    case runner(opts).(binary, args, timeout_ms: @probe_timeout_ms) do
      {:ok, %{exit: 0, stdout: output, truncated?: false}} -> {:ok, output}
      _refused -> :error
    end
  end

  defp busctl(opts) do
    Keyword.get_lazy(opts, :busctl, fn -> System.find_executable("busctl") end)
  end

  defp runner(opts) do
    Keyword.get(opts, :runner, &CommandRunner.run/3)
  end
end
