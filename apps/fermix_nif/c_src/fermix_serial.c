/* fermix_serial: the accessory link's USB serial port, for the BEAM (macOS only).
 *
 * Usage: fermix_serial list
 *        fermix_serial open <path>
 *
 * A port program, spawned through the disclaim exec shim. It talks to the BEAM
 * over stdin and stdout in packets that each start with a 4-byte big-endian
 * length ({packet, 4}). Every buffer is fixed; nothing is allocated.
 *
 * list: enumerates the IOSerialBSDClient ports through IOKit and CoreFoundation,
 *   both loaded at run time with dlopen, so the binary links no framework: the
 *   release cross-builds macOS on Linux with zig, which has no Apple frameworks.
 *   One packet per port, at most 64 ports:
 *     "P" flags:8 vid:16 pid:16 path_len:16 path serial_len:16 serial
 *   flags bit 0: the USB vendor and product IDs are present (both, or neither);
 *   bit 1: the USB serial string is present. An absent value is written as 0 or
 *   empty. A port whose callout path is over 1,024 bytes, or whose serial is
 *   over 255, is skipped. Then "Z" count:16 and exit 0.
 *
 * open: opens <path> for the link alone and without resetting the accessory,
 *   then relays bytes both ways. The ESP32-S3's USB-Serial-JTAG controller resets
 *   the chip from the host's DTR and RTS lines, so the order the lines change in
 *   is part of the contract (PROTOCOL.md, "Opening the port"): never clear DTR
 *   while RTS is asserted, and leave the lines alone once open. This replicates
 *   pyserial 3.5's open with dsrdtr=True, rts=False, exclusive=True followed by
 *   dtr = False (A0's "rts-first", 100 opens and closes without a reset), step
 *   for step:
 *     1. open(O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC). macOS asserts DTR and
 *        RTS at open, as for every tty. O_NONBLOCK keeps open from waiting for
 *        carrier, and makes close flush instead of draining output.
 *     2. flock(LOCK_EX | LOCK_NB), pyserial's exclusive=True: a second opener
 *        is refused "busy" instead of sharing the bytes.
 *     3. ioctl(TIOCEXCL): the driver then refuses any later non-root open with
 *        EBUSY, whether or not that opener locks. It changes no line.
 *     4. tcgetattr/tcsetattr(TCSANOW): raw 8N1 at 115200 with the flags pyserial
 *        clears, no flow control, VMIN 0 and VTIME 0. Never B0, which drops DTR.
 *        HUPCL is left as it is, as pyserial leaves it.
 *     5. ioctl(TIOCMBIC, RTS): RTS goes low first, while DTR is still high. A
 *        device without modem-control lines (a pseudo-terminal answers ENOTTY)
 *        answers ENOTTY or EINVAL: then DTR is not touched and the lines are
 *        reported absent.
 *     6. tcflush(TCIFLUSH), pyserial's reset_input_buffer.
 *     7. ioctl(TIOCMBIC, DTR), only after step 5 cleared RTS: both lines are low.
 *     8. "O" lines:8 (1 cleared, 0 absent).
 *   Every refusal is "E" code (busy, not_found, permission, not_a_tty, io:<errno>,
 *   lock:<errno>, exclusive:<errno>, termios:<errno>, lines:<errno>,
 *   flush:<errno>) and exit 66, with whatever was opened closed first.
 *
 *   Then: bytes read from the tty, at most 4,096 at a time, go out as "D" bytes.
 *   Each packet from the BEAM (1 to 16,384 bytes) is written whole to the tty,
 *   waiting for room for at most 2,000 ms per packet in all. Stdin closing closes
 *   the tty and exits 0; closing changes no line, since both are already low.
 *   select() waits on both: macOS's poll(2) does not support devices.
 *
 *   After an "E" once open (vanished, write_stall, io:<errno>, bad_packet,
 *   host_io:<errno>), the tty is closed first and the helper then reads and
 *   discards stdin until it closes before it exits with its code, so the BEAM
 *   never writes into a closed pipe: that EPIPE would end the port's owner.
 *
 * Exit codes: 0 done (stdin closed, or the list sent), 64 usage, 65 a bad packet
 * from the host, 66 open refused, 67 the port gone or a read error, 68 a write
 * stall, 69 stdout gone, 73 enumeration unavailable. 70 to 75 are the disclaim
 * shim's, before this program runs, and never used here.
 *
 * _DARWIN_C_SOURCE keeps the BSD and Darwin declarations this needs (flock and
 * LOCK_*, CRTSCTS, B115200, ECHOCTL, ECHOKE) visible whatever POSIX feature-test
 * macro a toolchain defines: with _POSIX_C_SOURCE set they vanish. The disclaim
 * shim defines it for the same reason.
 */
#define _DARWIN_C_SOURCE 1

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

enum {
  EXIT_DONE = 0,
  EXIT_USAGE = 64,
  EXIT_BAD_PACKET = 65,
  EXIT_REFUSED = 66,
  EXIT_GONE = 67,
  EXIT_STALL = 68,
  EXIT_STDOUT = 69,
  EXIT_NO_ENUM = 73
};

/* A relay step that keeps the relay going; every other value is an exit code. */
#define RELAY_CONTINUE (-1)

#define MAX_READ 4096
#define MAX_WRITE 16384
#define MAX_PATH_BYTES 1024
#define MAX_SERIAL_BYTES 255
#define MAX_PORTS 64
#define WRITE_STALL_MS 2000
#define MAX_EINTR 64
#define CODE_BYTES 48

#define LINES_ABSENT 0
#define LINES_CLEARED 1

static uint8_t out_buf[4 + 1 + MAX_READ];
static uint8_t in_buf[MAX_WRITE];

/* -- packets to the BEAM ---------------------------------------------------- */

/* Writes all of buf to a blocking fd. 0, or -1 when the fd is gone. */
static int write_all(int fd, const uint8_t *buf, size_t len) {
  size_t off = 0;
  int interrupted = 0;

  while (off < len) {
    ssize_t n = write(fd, buf + off, len - off);
    if (n > 0) {
      off += (size_t)n;
      interrupted = 0;
    } else if (n < 0 && errno == EINTR && interrupted < MAX_EINTR) {
      interrupted++;
    } else {
      return -1;
    }
  }
  return 0;
}

static void put_u16(uint8_t *at, unsigned value) {
  at[0] = (uint8_t)((value >> 8) & 0xFF);
  at[1] = (uint8_t)(value & 0xFF);
}

static void put_u32(uint8_t *at, size_t value) {
  at[0] = (uint8_t)((value >> 24) & 0xFF);
  at[1] = (uint8_t)((value >> 16) & 0xFF);
  at[2] = (uint8_t)((value >> 8) & 0xFF);
  at[3] = (uint8_t)(value & 0xFF);
}

/* Sends out_buf[5 .. 5 + len) as one packet tagged `tag`. 0, or -1: stdout gone. */
static int send_body(char tag, size_t len) {
  put_u32(out_buf, len + 1);
  out_buf[4] = (uint8_t)tag;
  return write_all(STDOUT_FILENO, out_buf, len + 5);
}

static int send_text(char tag, const char *text) {
  size_t len = strlen(text);
  if (len > MAX_READ) return -1;
  memcpy(out_buf + 5, text, len);
  return send_body(tag, len);
}

/* -- packets from the BEAM -------------------------------------------------- */

/* 1 when all of len arrived, 0 on EOF before any byte, -1 on EOF part way
 * (errno 0) or a read error (errno set). */
static int read_full(int fd, uint8_t *buf, size_t len) {
  size_t off = 0;
  int interrupted = 0;

  while (off < len) {
    ssize_t n = read(fd, buf + off, len - off);
    if (n > 0) {
      off += (size_t)n;
      interrupted = 0;
    } else if (n == 0) {
      errno = 0;
      return off == 0 ? 0 : -1;
    } else if (errno != EINTR || interrupted++ >= MAX_EINTR) {
      return -1;
    }
  }
  return 1;
}

/* Reads and discards stdin until the BEAM closes it (or it fails). */
static void drain_stdin(void) {
  int interrupted = 0;

  for (;;) {
    ssize_t n = read(STDIN_FILENO, in_buf, sizeof in_buf);
    if (n > 0) continue;
    if (n < 0 && errno == EINTR && interrupted++ < MAX_EINTR) continue;
    return;
  }
}

/* -- ending once open --------------------------------------------------------- */

/* Closes the tty, says why, waits for the BEAM to close stdin, exits `status`. */
static int finish(int tty, const char *code, int status) {
  close(tty);
  if (send_text('E', code) != 0) return EXIT_STDOUT;
  drain_stdin();
  return status;
}

static int finish_errno(int tty, const char *what, int err, int status) {
  char code[CODE_BYTES];
  snprintf(code, sizeof code, "%s:%d", what, err);
  return finish(tty, code, status);
}

static int gone_errno(int err) { return err == EIO || err == ENXIO || err == ENODEV; }

/* -- opening -------------------------------------------------------------------- */

/* A refusal before the relay: nothing to drain, since the BEAM sends nothing
 * until it has the "O". */
static int refuse(int fd, const char *code) {
  if (fd >= 0) close(fd);
  if (send_text('E', code) != 0) return EXIT_STDOUT;
  return EXIT_REFUSED;
}

static int refuse_errno(int fd, const char *what, int err) {
  char code[CODE_BYTES];
  snprintf(code, sizeof code, "%s:%d", what, err);
  return refuse(fd, code);
}

static int refuse_open(int err) {
  if (err == EBUSY) return refuse(-1, "busy");
  if (err == ENOENT || err == ENXIO || err == ENODEV) return refuse(-1, "not_found");
  if (err == EACCES || err == EPERM) return refuse(-1, "permission");
  return refuse_errno(-1, "io", err);
}

/* Step 4: raw 8N1 at 115200 with the flags pyserial 3.5 sets and clears. */
static int make_raw(int fd) {
  struct termios t;

  if (tcgetattr(fd, &t) != 0) return errno;
  t.c_cflag |= (tcflag_t)(CLOCAL | CREAD);
  t.c_cflag &= ~(tcflag_t)(CSIZE | CSTOPB | PARENB | PARODD | CRTSCTS);
  t.c_cflag |= (tcflag_t)CS8;
  t.c_lflag &= ~(tcflag_t)(ICANON | ECHO | ECHOE | ECHOK | ECHONL | ISIG | IEXTEN | ECHOCTL |
                           ECHOKE);
  t.c_oflag &= ~(tcflag_t)(OPOST | ONLCR | OCRNL);
  t.c_iflag &= ~(tcflag_t)(INLCR | IGNCR | ICRNL | IGNBRK | PARMRK | INPCK | ISTRIP | IXON |
                           IXOFF | IXANY);
  t.c_cc[VMIN] = 0;
  t.c_cc[VTIME] = 0;
  if (cfsetispeed(&t, B115200) != 0 || cfsetospeed(&t, B115200) != 0) return errno;
  if (tcsetattr(fd, TCSANOW, &t) != 0) return errno;
  return 0;
}

static int clear_line(int fd, int line) { return ioctl(fd, TIOCMBIC, &line) == 0 ? 0 : errno; }

/* Steps 5 to 7. LINES_CLEARED or LINES_ABSENT, or -1 after a refusal was sent
 * (its exit code in *status). */
static int settle_lines(int fd, int *status) {
  int err = clear_line(fd, TIOCM_RTS);
  int lines = err == 0 ? LINES_CLEARED : LINES_ABSENT;

  if (err != 0 && err != ENOTTY && err != EINVAL) {
    *status = refuse_errno(fd, "lines", err);
    return -1;
  }
  if (tcflush(fd, TCIFLUSH) != 0) {
    *status = refuse_errno(fd, "flush", errno);
    return -1;
  }
  if (lines == LINES_CLEARED && (err = clear_line(fd, TIOCM_DTR)) != 0) {
    *status = refuse_errno(fd, "lines", err);
    return -1;
  }
  return lines;
}

/* Steps 1 to 4. The open fd, or -1 after a refusal was sent (*status). */
static int open_exclusive(const char *path, int *status) {
  int fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC);
  int err;

  if (fd < 0) {
    *status = refuse_open(errno);
    return -1;
  }
  if (fd >= FD_SETSIZE) {
    *status = refuse(fd, "io:fd_setsize");
    return -1;
  }
  if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
    err = errno;
    *status = err == EWOULDBLOCK ? refuse(fd, "busy") : refuse_errno(fd, "lock", err);
    return -1;
  }
  if (ioctl(fd, TIOCEXCL) != 0) {
    err = errno;
    *status = err == ENOTTY ? refuse(fd, "not_a_tty") : refuse_errno(fd, "exclusive", err);
    return -1;
  }
  if ((err = make_raw(fd)) != 0) {
    *status = err == ENOTTY ? refuse(fd, "not_a_tty") : refuse_errno(fd, "termios", err);
    return -1;
  }
  return fd;
}

/* -- relaying ------------------------------------------------------------------- */

static int64_t now_ms(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return -1;
  return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

enum { WAIT_READY, WAIT_STALLED, WAIT_FAILED };

/* Waits until the tty takes more bytes or the deadline passes. */
static int await_writable(int tty, int64_t deadline) {
  int64_t now = now_ms();
  int64_t left = deadline - now;
  fd_set writable;
  struct timeval tv;

  if (now < 0) return WAIT_FAILED;
  if (left <= 0) return WAIT_STALLED;
  FD_ZERO(&writable);
  FD_SET(tty, &writable);
  tv.tv_sec = (time_t)(left / 1000);
  tv.tv_usec = (suseconds_t)((left % 1000) * 1000);
  int ready = select(tty + 1, NULL, &writable, NULL, &tv);
  if (ready < 0) return errno == EINTR ? WAIT_READY : WAIT_FAILED;
  return ready == 0 ? WAIT_STALLED : WAIT_READY;
}

/* Writes one packet from the BEAM to the tty, all of it, within the stall bound.
 * Every pass either moves bytes or waits towards the one deadline. */
static int to_tty(int tty, const uint8_t *buf, size_t len) {
  int64_t start = now_ms();
  size_t off = 0;

  if (start < 0) return finish_errno(tty, "io", errno, EXIT_GONE);
  while (off < len) {
    ssize_t n = write(tty, buf + off, len - off);
    if (n > 0) {
      off += (size_t)n;
      continue;
    }
    if (n < 0 && gone_errno(errno)) return finish(tty, "vanished", EXIT_GONE);
    if (n < 0 && errno != EAGAIN && errno != EINTR) return finish_errno(tty, "io", errno, EXIT_GONE);
    int waited = await_writable(tty, start + WRITE_STALL_MS);
    if (waited == WAIT_STALLED) return finish(tty, "write_stall", EXIT_STALL);
    if (waited == WAIT_FAILED) return finish_errno(tty, "io", errno, EXIT_GONE);
  }
  return RELAY_CONTINUE;
}

static uint32_t get_u32(const uint8_t *at) {
  return ((uint32_t)at[0] << 24) | ((uint32_t)at[1] << 16) | ((uint32_t)at[2] << 8) | at[3];
}

/* One packet from the BEAM, or its EOF. */
static int from_host(int tty) {
  uint8_t header[4];
  int got = read_full(STDIN_FILENO, header, sizeof header);

  if (got == 0) {
    close(tty);
    return EXIT_DONE;
  }
  if (got < 0 && errno != 0) return finish_errno(tty, "host_io", errno, EXIT_BAD_PACKET);
  if (got < 0) return finish(tty, "bad_packet", EXIT_BAD_PACKET);

  uint32_t len = get_u32(header);
  if (len == 0 || len > MAX_WRITE) return finish(tty, "bad_packet", EXIT_BAD_PACKET);

  got = read_full(STDIN_FILENO, in_buf, len);
  if (got < 0 && errno != 0) return finish_errno(tty, "host_io", errno, EXIT_BAD_PACKET);
  if (got != 1) return finish(tty, "bad_packet", EXIT_BAD_PACKET);
  return to_tty(tty, in_buf, len);
}

/* What the tty has, as one "D" packet. A readable tty that reads nothing has
 * hung up: select() reports a hangup as readable. */
static int from_tty(int tty) {
  ssize_t n = read(tty, out_buf + 5, MAX_READ);

  if (n > 0) return send_body('D', (size_t)n) == 0 ? RELAY_CONTINUE : EXIT_STDOUT;
  if (n == 0) return finish(tty, "vanished", EXIT_GONE);
  if (errno == EAGAIN || errno == EINTR) return RELAY_CONTINUE;
  if (gone_errno(errno)) return finish(tty, "vanished", EXIT_GONE);
  return finish_errno(tty, "io", errno, EXIT_GONE);
}

/* Runs until stdin closes or the port goes: the program's lifetime, bounded by
 * those two events. The tty is served first, so bytes that arrived before a
 * hangup still reach the BEAM. */
static int relay(int tty) {
  int status = RELAY_CONTINUE;

  while (status == RELAY_CONTINUE) {
    fd_set readable;
    FD_ZERO(&readable);
    FD_SET(STDIN_FILENO, &readable);
    FD_SET(tty, &readable);

    int ready = select(tty + 1, &readable, NULL, NULL, NULL);
    if (ready < 0 && errno == EINTR) continue;
    if (ready < 0) return finish_errno(tty, "io", errno, EXIT_GONE);
    if (FD_ISSET(tty, &readable)) status = from_tty(tty);
    if (status == RELAY_CONTINUE && FD_ISSET(STDIN_FILENO, &readable)) status = from_host(tty);
  }
  return status;
}

static int run_open(const char *path) {
  int status = EXIT_REFUSED;
  int fd = open_exclusive(path, &status);
  if (fd < 0) return status;

  int lines = settle_lines(fd, &status);
  if (lines < 0) return status;

  out_buf[5] = (uint8_t)lines;
  if (send_body('O', 1) != 0) {
    close(fd);
    return EXIT_STDOUT;
  }
  return relay(fd);
}

/* -- listing ---------------------------------------------------------------------- */

/* The few IOKit and CoreFoundation declarations listing needs, written here
 * because the headers are not available to the release's zig cross-build. */
typedef unsigned int fx_io_object; /* io_object_t, io_iterator_t: a mach port name */
typedef int fx_kern_return;
typedef const void *fx_cf_ref;
typedef unsigned long fx_cf_type_id;
typedef long fx_cf_index;
typedef unsigned char fx_cf_boolean;

#define FX_MAIN_PORT_DEFAULT 0u               /* kIOMainPortDefault */
#define FX_ITERATE_RECURSIVELY 0x00000001u    /* kIORegistryIterateRecursively */
#define FX_ITERATE_PARENTS 0x00000002u        /* kIORegistryIterateParents */
#define FX_UTF8 0x08000100u                   /* kCFStringEncodingUTF8 */
#define FX_SINT32 3L                          /* kCFNumberSInt32Type */
#define FX_ALLOCATOR_DEFAULT ((const void *)0) /* kCFAllocatorDefault */

struct iokit {
  void *iokit_lib;
  void *cf_lib;
  void *(*service_matching)(const char *);
  fx_kern_return (*matching_services)(unsigned int, const void *, fx_io_object *);
  fx_io_object (*iterator_next)(fx_io_object);
  fx_cf_ref (*create_property)(fx_io_object, fx_cf_ref, const void *, unsigned int);
  fx_cf_ref (*search_property)(fx_io_object, const char *, fx_cf_ref, const void *, unsigned int);
  fx_kern_return (*object_release)(fx_io_object);
  fx_cf_ref (*string_create)(const void *, const char *, unsigned int);
  fx_cf_boolean (*string_get)(fx_cf_ref, char *, fx_cf_index, unsigned int);
  fx_cf_boolean (*number_get)(fx_cf_ref, fx_cf_index, void *);
  fx_cf_type_id (*get_type_id)(fx_cf_ref);
  fx_cf_type_id (*string_type_id)(void);
  fx_cf_type_id (*number_type_id)(void);
  void (*release)(fx_cf_ref);
  fx_cf_ref key_callout;
  fx_cf_ref key_vendor;
  fx_cf_ref key_product;
  fx_cf_ref key_serial;
};

struct port_desc {
  char path[MAX_PATH_BYTES + 1];
  char serial[MAX_SERIAL_BYTES + 1];
  unsigned vendor;
  unsigned product;
  int has_ids;
  int has_serial;
};

/* dlsym answers a void pointer; it is copied into the typed function pointer
 * rather than cast, which ISO C leaves undefined. The copy needs both to be
 * the same size, which this typedef fails to compile without. */
typedef char fx_pointer_sizes_match[sizeof(void *) == sizeof(void (*)(void)) ? 1 : -1];

#define RESOLVE(lib, field, name)                                                    \
  do {                                                                               \
    void *symbol = dlsym(k->lib, name);                                              \
    if (symbol == NULL) return -1;                                                   \
    memcpy(&k->field, &symbol, sizeof symbol);                                       \
  } while (0)

static int resolve_symbols(struct iokit *k) {
  RESOLVE(iokit_lib, service_matching, "IOServiceMatching");
  RESOLVE(iokit_lib, matching_services, "IOServiceGetMatchingServices");
  RESOLVE(iokit_lib, iterator_next, "IOIteratorNext");
  RESOLVE(iokit_lib, create_property, "IORegistryEntryCreateCFProperty");
  RESOLVE(iokit_lib, search_property, "IORegistryEntrySearchCFProperty");
  RESOLVE(iokit_lib, object_release, "IOObjectRelease");
  RESOLVE(cf_lib, string_create, "CFStringCreateWithCString");
  RESOLVE(cf_lib, string_get, "CFStringGetCString");
  RESOLVE(cf_lib, number_get, "CFNumberGetValue");
  RESOLVE(cf_lib, get_type_id, "CFGetTypeID");
  RESOLVE(cf_lib, string_type_id, "CFStringGetTypeID");
  RESOLVE(cf_lib, number_type_id, "CFNumberGetTypeID");
  RESOLVE(cf_lib, release, "CFRelease");
  return 0;
}

static fx_cf_ref make_key(struct iokit *k, const char *text) {
  return k->string_create(FX_ALLOCATOR_DEFAULT, text, FX_UTF8);
}

/* Releases whatever load_iokit got, on every path. */
static void unload_iokit(struct iokit *k) {
  if (k->release != NULL) {
    if (k->key_callout != NULL) k->release(k->key_callout);
    if (k->key_vendor != NULL) k->release(k->key_vendor);
    if (k->key_product != NULL) k->release(k->key_product);
    if (k->key_serial != NULL) k->release(k->key_serial);
  }
  if (k->iokit_lib != NULL) dlclose(k->iokit_lib);
  if (k->cf_lib != NULL) dlclose(k->cf_lib);
}

static int load_iokit(struct iokit *k) {
  memset(k, 0, sizeof *k);
  k->iokit_lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
  k->cf_lib = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
                     RTLD_LAZY | RTLD_LOCAL);
  if (k->iokit_lib == NULL || k->cf_lib == NULL) return -1;
  if (resolve_symbols(k) != 0) return -1;
  k->key_callout = make_key(k, "IOCalloutDevice");
  k->key_vendor = make_key(k, "idVendor");
  k->key_product = make_key(k, "idProduct");
  k->key_serial = make_key(k, "USB Serial Number");
  if (k->key_callout == NULL || k->key_vendor == NULL || k->key_product == NULL ||
      k->key_serial == NULL)
    return -1;
  return 0;
}

/* 1 when value is a CFString that fits in cap bytes (with its terminator) as
 * UTF-8, else 0. Releases value. */
static int take_string(struct iokit *k, fx_cf_ref value, char *buf, size_t cap) {
  int ok = 0;
  if (value == NULL) return 0;
  if (k->get_type_id(value) == k->string_type_id())
    ok = k->string_get(value, buf, (fx_cf_index)cap, FX_UTF8) != 0;
  k->release(value);
  return ok;
}

/* 1 with *out set when value is a CFNumber in 0..65535, else 0. Releases value. */
static int take_u16(struct iokit *k, fx_cf_ref value, unsigned *out) {
  int32_t number = -1;
  int ok = 0;
  if (value == NULL) return 0;
  if (k->get_type_id(value) == k->number_type_id())
    ok = k->number_get(value, FX_SINT32, &number) != 0 && number >= 0 && number <= 0xFFFF;
  k->release(value);
  if (ok) *out = (unsigned)number;
  return ok;
}

static fx_cf_ref search_up(struct iokit *k, fx_io_object entry, fx_cf_ref key) {
  return k->search_property(entry, "IOService", key, FX_ALLOCATOR_DEFAULT,
                            FX_ITERATE_RECURSIVELY | FX_ITERATE_PARENTS);
}

/* 1 when entry is a port to report (its values in *d), 0 to skip it. */
static int describe_port(struct iokit *k, fx_io_object entry, struct port_desc *d) {
  fx_cf_ref callout = k->create_property(entry, k->key_callout, FX_ALLOCATOR_DEFAULT, 0);
  if (!take_string(k, callout, d->path, sizeof d->path) || d->path[0] == '\0') return 0;

  int has_vendor = take_u16(k, search_up(k, entry, k->key_vendor), &d->vendor);
  int has_product = take_u16(k, search_up(k, entry, k->key_product), &d->product);
  d->has_ids = has_vendor && has_product;
  if (!d->has_ids) d->vendor = d->product = 0;

  fx_cf_ref serial = search_up(k, entry, k->key_serial);
  d->has_serial = serial != NULL;
  if (d->has_serial && !take_string(k, serial, d->serial, sizeof d->serial)) return 0;
  if (!d->has_serial) d->serial[0] = '\0';
  return 1;
}

static int send_port(const struct port_desc *d) {
  size_t path_len = strlen(d->path);
  size_t serial_len = strlen(d->serial);
  uint8_t *at = out_buf + 5;

  at[0] = (uint8_t)((d->has_ids ? 1 : 0) | (d->has_serial ? 2 : 0));
  put_u16(at + 1, d->vendor);
  put_u16(at + 3, d->product);
  put_u16(at + 5, (unsigned)path_len);
  memcpy(at + 7, d->path, path_len);
  put_u16(at + 7 + path_len, (unsigned)serial_len);
  memcpy(at + 9 + path_len, d->serial, serial_len);
  return send_body('P', 9 + path_len + serial_len);
}

/* Walks the iterator, one packet per port. The count sent, -1 when stdout went,
 * -2 past MAX_PORTS. Releases every entry it takes. */
static int send_ports(struct iokit *k, fx_io_object iterator) {
  int count = 0;
  fx_io_object entry;

  while ((entry = k->iterator_next(iterator)) != 0) {
    struct port_desc d;
    int keep = describe_port(k, entry, &d);
    k->object_release(entry);
    if (!keep) continue;
    if (count == MAX_PORTS) return -2;
    if (send_port(&d) != 0) return -1;
    count++;
  }
  return count;
}

static int list_with(struct iokit *k) {
  fx_io_object iterator = 0;
  void *matching = k->service_matching("IOSerialBSDClient");
  if (matching == NULL) return send_text('E', "iokit:matching") == 0 ? EXIT_NO_ENUM : EXIT_STDOUT;

  /* Consumes the matching dictionary, whatever it returns. */
  fx_kern_return kr = k->matching_services(FX_MAIN_PORT_DEFAULT, matching, &iterator);
  if (kr != 0) {
    char code[CODE_BYTES];
    snprintf(code, sizeof code, "iokit:%d", kr);
    return send_text('E', code) == 0 ? EXIT_NO_ENUM : EXIT_STDOUT;
  }

  int count = send_ports(k, iterator);
  k->object_release(iterator);
  if (count == -1) return EXIT_STDOUT;
  if (count == -2) return send_text('E', "too_many_ports") == 0 ? EXIT_NO_ENUM : EXIT_STDOUT;

  put_u16(out_buf + 5, (unsigned)count);
  return send_body('Z', 2) == 0 ? EXIT_DONE : EXIT_STDOUT;
}

static int run_list(void) {
  struct iokit k;
  int status;

  if (load_iokit(&k) != 0)
    status = send_text('E', "iokit_unavailable") == 0 ? EXIT_NO_ENUM : EXIT_STDOUT;
  else
    status = list_with(&k);
  unload_iokit(&k);
  return status;
}

int main(int argc, char **argv) {
  if (signal(SIGPIPE, SIG_IGN) == SIG_ERR) {
    fprintf(stderr, "fermix_serial: cannot ignore SIGPIPE\n");
    return EXIT_STDOUT;
  }
  if (argc == 2 && strcmp(argv[1], "list") == 0) return run_list();
  if (argc == 3 && strcmp(argv[1], "open") == 0 && strlen(argv[2]) > 0 &&
      strlen(argv[2]) <= MAX_PATH_BYTES)
    return run_open(argv[2]);

  fprintf(stderr, "fermix_serial: usage: fermix_serial list | fermix_serial open <path>\n");
  return EXIT_USAGE;
}
