defmodule FermixCore.Home.Provision.FirstBoot do
  @moduledoc """
  The cloud-init user data of a server Fermix creates (M75 lean v1 §4.3): the
  provider-neutral first boot, `packaging/cloud/first-boot.sh`, run once as
  root with the enrollment code in `FERMIX_ENROLL_CODE`, as
  `packaging/cloud/README.md` says cloud-init passes it, and `--version` the
  release the desktop that creates it runs, which first boot installs: a
  server always runs exactly its desktop's Fermix, so the home can move back
  (Always On's move back, `FermixCore.Home.EngineCeiling`).

  The script is the one the release was built from, embedded at compile
  time: gzip-compressed and base64-encoded inside a `#!/bin/sh` user data
  that cloud-init runs, which unpacks it to
  `/usr/local/lib/fermix-always-on/first-boot.sh`, checks its SHA-256, and
  runs it. The code appears once, as the value of `FERMIX_ENROLL_CODE` on the
  line that runs the script: never on a command line, and first boot
  `unset`s it before anything else runs. It is accepted only as
  `fxenroll1.` and base64url characters, so it cannot leave its quotes; the
  release only as a plain `MAJOR.MINOR.PATCH`.

  User data stays readable through the provider's metadata service for the
  server's life, which is why first boot blocks that service for every
  account but root (L17) and why the code is single use. Each provider takes
  at most so many bytes of user data, which its module passes in; a larger
  one is refused, never cut.

  Pure.
  """

  @script_path Path.expand("../../../../../../packaging/cloud/first-boot.sh", __DIR__)
  @external_resource @script_path
  @script File.read!(@script_path)
  @sha256 :sha256 |> :crypto.hash(@script) |> Base.encode16(case: :lower)
  # Lines of 76, as `base64` writes them; `base64 -d` reads them whole.
  @blob ~r/.{1,76}/
        |> Regex.scan(Base.encode64(:zlib.gzip(@script)))
        |> Enum.map_join("\n", &hd/1)
  @install_path "/usr/local/lib/fermix-always-on/first-boot.sh"
  @code ~r/\Afxenroll1\.[A-Za-z0-9_-]{1,2048}\z/
  @release ~r/\A[0-9]+\.[0-9]+\.[0-9]+\z/

  @doc "The SHA-256 of the embedded first boot, which the server checks before running it."
  @spec script_sha256() :: String.t()
  def script_sha256, do: @sha256

  @doc """
  The user data for a server that enrolls with `code` and installs Fermix
  `release`, for a provider that takes at most `max_bytes` of it: `{:ok,
  user_data}`, `{:error, :invalid_code}` for anything but an enrollment code,
  `{:error, :invalid_version}` for anything but a release, and `{:error,
  :too_large}` past `max_bytes`.
  """
  @spec user_data(term(), term(), pos_integer()) ::
          {:ok, String.t()} | {:error, :invalid_code | :invalid_version | :too_large}
  def user_data(code, release, max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    cond do
      not (is_binary(code) and Regex.match?(@code, code)) -> {:error, :invalid_code}
      not (is_binary(release) and Regex.match?(@release, release)) -> {:error, :invalid_version}
      true -> bounded(render(code, release), max_bytes)
    end
  end

  defp render(code, release) do
    """
    #!/bin/sh
    # Fermix Always On: unpack the first boot, check it, and run it once.
    set -eu
    umask 077
    mkdir -p -m 0700 #{Path.dirname(@install_path)}
    base64 -d <<'FERMIX_FIRST_BOOT' | gzip -dc >#{@install_path}
    #{@blob}
    FERMIX_FIRST_BOOT
    printf '%s  %s\\n' #{@sha256} #{@install_path} | sha256sum -c --quiet
    FERMIX_ENROLL_CODE='#{code}' sh #{@install_path} --version #{release}
    """
  end

  defp bounded(user_data, max_bytes) when byte_size(user_data) <= max_bytes, do: {:ok, user_data}
  defp bounded(_user_data, _max_bytes), do: {:error, :too_large}
end
