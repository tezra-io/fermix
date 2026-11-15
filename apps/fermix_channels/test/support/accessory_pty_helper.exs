defmodule FermixTestSupport.AccessoryPty do
  @moduledoc """
  A pseudo-terminal double for the accessory serial tests, macOS-only like
  `fermix_serial`: a small Python program opens a pty, sends its slave path
  (`"S" <> path`), relays what the slave side writes as `"R" <> bytes`, and
  takes `"W" <> bytes` (write into the master), `"P"` (stop reading the
  master) and `"C"` (close the master, as an unplug would), all in
  `{:packet, 4}`. The test plays the accessory at the master.
  """

  @script """
  import os, select, struct, sys

  out = sys.stdout.buffer


  def send(data):
      out.write(struct.pack(">I", len(data)) + data)
      out.flush()


  def read_exact(n):
      buf = b""
      while len(buf) < n:
          chunk = os.read(0, n - len(buf))
          if not chunk:
              return None
          buf += chunk
      return buf


  def write_all(fd, data):
      view = memoryview(data)
      while view:
          view = view[os.write(fd, view):]


  # The double keeps its own slave descriptor open for its whole life, so the
  # master never reads end-of-file while no helper has the slave open.
  master, slave = os.openpty()
  send(b"S" + os.ttyname(slave).encode())
  reading = True
  while True:
      watch = [0] + ([master] if reading and master is not None else [])
      ready = select.select(watch, [], [])[0]
      if master is not None and master in ready:
          data = os.read(master, 65536)
          if data:
              send(b"R" + data)
      if 0 in ready:
          header = read_exact(4)
          body = header and read_exact(struct.unpack(">I", header)[0])
          if not body:
              break
          if body[:1] == b"W":
              write_all(master, body[1:])
          elif body[:1] == b"P":
              reading = False
          elif body[:1] == b"C":
              os.close(master)
              master = None
  """

  @doc "The double's Python source."
  def script, do: @script

  @doc "Starts a double owned by the caller and answers its port and the slave path."
  def open!(bound) do
    python = System.find_executable("python3") || raise "python3 is needed for the pty double"

    double =
      Port.open({:spawn_executable, python}, [
        :binary,
        {:packet, 4},
        :exit_status,
        args: ["-I", "-c", @script]
      ])

    receive do
      {^double, {:data, "S" <> slave}} -> %{double: double, slave: slave}
    after
      bound -> raise "the pty double never said its slave path"
    end
  end
end
