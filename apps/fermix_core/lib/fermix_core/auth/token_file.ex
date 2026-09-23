defmodule FermixCore.Auth.TokenFile do
  @moduledoc """
  The daemon-owned access-token projection a local `mcp` plugin child reads
  (M8 §9.3).

  The hard case this solves: a long-lived child process needs a short-lived
  OAuth bearer. Injecting the token once at spawn goes stale; injecting the
  *refresh* token would hand the long-lived credential to every plugin process
  and duplicate `TokenManager` in every plugin language. So the daemon projects
  only the current access token into one file per auth profile, rewrites it on
  every refresh, and deletes it the moment the grant stops being servable. The
  child is handed the path in `FERMIX_PLUGIN_TOKEN_FILE` and re-reads it per
  request.

  The shape is the wire between the daemon and every vendored helper:

      {
        "access_token": "…",
        "expires_at": "2026-09-13T09:41:07Z",
        "region": "eu",
        "auth_profile": "tesla:primary",
        "generation": 3
      }

  `expires_at` (ISO 8601 UTC) and `region` are always present and may be
  `null`; a helper that treats an absent key differently from a null one is
  reading a shape this module never emits. `generation` counts writes of THIS
  file: it starts at 1 when a profile is first projected and increments on
  every rewrite, so a child can tell a renewed token from a re-read of the same
  one. A daemon restart starts a fresh file at 1, because the plugin store's
  boot sweep removes every stale projection before any child spawns.

  Writes are atomic: a `0600` temp file in the same directory, then a rename.
  The file is created empty and made private *before* the token is written, so
  an access token never exists in a world-readable file even for an instant.
  The directory is never created here — `Plugins.Dist.Store.ensure!/1` owns
  `run/` and creates it `0700`, so a missing directory is reported rather than
  silently re-made under the wrong mode.

  Only the daemon writes this file. A tree-less CLI VM has no per-profile
  manager and therefore nothing that could keep a projection fresh, so it
  refuses instead — see `needs_daemon_sentence/0`.
  """

  @type projection :: %{
          access_token: String.t(),
          expires_at: DateTime.t() | nil,
          region: String.t() | nil,
          auth_profile: String.t(),
          generation: pos_integer()
        }

  @doc """
  Atomically write `projection` to `path` as a `0600` file.

  A blank access token is a caller bug, not a file to write: a child handed an
  empty credential 401s every call, and the honest answer is no file at all.
  """
  @spec write(Path.t(), projection()) :: :ok | {:error, term()}
  def write(path, %{access_token: token, auth_profile: profile, generation: generation} = fields)
      when is_binary(path) and is_binary(token) and token != "" and is_binary(profile) and
             profile != "" and is_integer(generation) and generation > 0 do
    tmp = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

    with :ok <- create_private(tmp),
         :ok <- File.write(tmp, encode(fields), [:binary]),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  @doc """
  Remove the projection at `path`.

  An already-absent file is the state the caller asked for, not a failure.
  """
  @spec delete(Path.t()) :: :ok | {:error, term()}
  def delete(path) when is_binary(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  What a person reads when a token projection was asked for outside the daemon.

  Every `fermix` CLI verb runs in a tree-less VM: it mutates config and the
  plugin store on disk and asks the running daemon to re-apply, so it neither
  spawns plugin children nor writes their token files. A CLI VM that reached
  this path anyway refuses with `:token_file_needs_daemon` and this sentence,
  rather than writing a token it could never rewrite.
  """
  @spec needs_daemon_sentence() :: String.t()
  def needs_daemon_sentence do
    "Only the running Fermix daemon can keep a plugin's access token file fresh. " <>
      "Start the daemon, then its plugin helpers receive their tokens."
  end

  # Created empty, then made private, then filled: the only ordering in which
  # the token never lands in a file another account could read.
  defp create_private(tmp) do
    with :ok <- File.touch(tmp), do: File.chmod(tmp, 0o600)
  end

  defp encode(fields) do
    Jason.encode!(%{
      "access_token" => fields.access_token,
      "expires_at" => iso8601(fields.expires_at),
      "region" => fields.region,
      "auth_profile" => fields.auth_profile,
      "generation" => fields.generation
    })
  end

  defp iso8601(%DateTime{} = expires_at), do: DateTime.to_iso8601(expires_at)
  defp iso8601(nil), do: nil
end
