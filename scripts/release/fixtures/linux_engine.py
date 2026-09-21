"""Synthetic Linux app-engine fixtures shared by the release script tests.

The real artifact is a Burrito wrapper, a musl loader and a cosign binary, none
of which a hermetic test may build. What the packaging and verification code
actually reads out of those files is small and exact — the ELF class, the
machine, and the `PT_INTERP` string — so these builders produce files that
carry precisely that and nothing else.
"""

import hashlib

ELF_MACHINES = {"x86_64": 62, "arm64": 183}
ELF_HEADER_BYTES = 64
ELF_PROGRAM_HEADER_BYTES = 56
PT_INTERP = 3


def elf_bytes(architecture, *, interpreter=None, padding=b""):
    """One 64-bit little-endian ELF for `architecture`, optionally with PT_INTERP."""

    if architecture not in ELF_MACHINES:
        raise ValueError(f"unsupported fixture architecture: {architecture}")

    segments = 1 if interpreter else 0
    payload = f"{interpreter}\0".encode("utf-8") if interpreter else b""
    payload_offset = ELF_HEADER_BYTES + segments * ELF_PROGRAM_HEADER_BYTES

    header = bytearray(ELF_HEADER_BYTES)
    header[0:4] = b"\x7fELF"
    header[4] = 2
    header[5] = 1
    header[6] = 1
    header[16:18] = (2).to_bytes(2, "little")
    header[18:20] = ELF_MACHINES[architecture].to_bytes(2, "little")
    header[20:24] = (1).to_bytes(4, "little")
    header[32:40] = ELF_HEADER_BYTES.to_bytes(8, "little")
    header[52:54] = ELF_HEADER_BYTES.to_bytes(2, "little")
    header[54:56] = ELF_PROGRAM_HEADER_BYTES.to_bytes(2, "little")
    header[56:58] = segments.to_bytes(2, "little")

    return bytes(header) + _program_header(payload_offset, len(payload)) + payload + padding


def _program_header(offset, size):
    if not size:
        return b""

    entry = bytearray(ELF_PROGRAM_HEADER_BYTES)
    entry[0:4] = PT_INTERP.to_bytes(4, "little")
    entry[4:8] = (4).to_bytes(4, "little")
    entry[8:16] = offset.to_bytes(8, "little")
    entry[32:40] = size.to_bytes(8, "little")
    entry[40:48] = size.to_bytes(8, "little")
    return bytes(entry)


def loader_bytes(architecture):
    """The musl loader payload, and the file name its digest earns it."""

    payload = elf_bytes(architecture, padding=b"musl loader\n")
    return payload, f"libc-musl-{hashlib.sha256(payload).hexdigest()}.so"


def trusted_interpreter(loader_name):
    """The address every packaged interpreter names once the payload is staged."""

    digest = loader_name.removeprefix("libc-musl-").removesuffix(".so")
    return f"/var/lib/fermix/runtimes/{digest}/libc-musl.so"
