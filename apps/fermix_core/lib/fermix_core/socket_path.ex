defmodule FermixCore.SocketPath do
  @moduledoc """
  The `sun_path` pre-flight every Fermix Unix-domain listener runs before bind.

  `struct sockaddr_un.sun_path` is a fixed char array and the address has to fit
  inside it with its NUL terminator: 104 bytes on macOS/BSD, 108 on Linux. A
  longer path fails the bind with a bare `:einval`, which reads as a Fermix bug
  rather than as "your `FERMIX_HOME` is too long" — and the client that then
  cannot connect reports the daemon as not running.

  So every listener measures the path STRING first, touches no filesystem
  object, and refuses with one sentence naming the socket, both numbers and the
  fix (M38 §4.4.6). One module, because an operator who hits the limit on one
  socket has to recognise it on the next.

  The limit is resolved at runtime, not compiled in: a release cross-built on
  one OS must measure against the OS it actually runs on. Linux gets its own
  four bytes; every other OS is measured against the smaller macOS/BSD array,
  because erring small can only over-refuse by four bytes with a message that
  still names the true fix, while erring large hands back the `:einval` this
  check exists to translate.
  """

  @sun_path_bytes_darwin 104
  @sun_path_bytes_linux 108

  @type refusal :: {:path_too_long, pos_integer(), pos_integer()}

  @doc "The longest socket path this OS accepts, in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes do
    case :os.type() do
      {:unix, :linux} -> @sun_path_bytes_linux - 1
      _other -> @sun_path_bytes_darwin - 1
    end
  end

  @doc "Whether `path` fits this OS's socket address, measured in bytes."
  @spec check(Path.t()) :: :ok | {:error, refusal()}
  def check(path) when is_binary(path) do
    limit = max_bytes()
    bytes = byte_size(path)

    if bytes > limit, do: {:error, {:path_too_long, bytes, limit}}, else: :ok
  end

  @doc """
  The operator sentence for an over-long socket path.

  `subject` names the socket the way its own surface names it, so the caller
  decides between `daemon.sock` and "the ACP socket" without a second sentence
  shape existing.
  """
  @spec refusal(String.t(), pos_integer(), pos_integer()) :: String.t()
  def refusal(subject, bytes, limit)
      when is_binary(subject) and is_integer(bytes) and is_integer(limit) do
    "the #{subject} path is #{bytes} bytes, over the #{limit}-byte limit this OS allows " <>
      "for a unix socket address — set a shorter FERMIX_HOME and restart"
  end
end
