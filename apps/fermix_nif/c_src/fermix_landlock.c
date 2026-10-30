/* fermix_landlock — Linux-only exec shim that runs one command under Landlock.
 *
 * Usage: fermix_landlock RULE... -- <executable> [args...]
 *        fermix_landlock --abi
 *
 * Each RULE is ACCESS:PATH and adds one path_beneath rule: ACCESS is granted
 * on PATH and everything beneath it. PATH is absolute and is never followed
 * through a symlink. ACCESS is one or more of
 *
 *   x  execute a file
 *   r  read a file
 *   l  list a directory (open it, read its entries)
 *   w  write a file, and truncate it from ABI 3
 *   c  create, remove, rename and link entries in a directory, across
 *      directories too (REFER)
 *
 * Every other filesystem access the running ABI knows (up to TRUNCATE) is
 * denied wherever no rule grants it. Device ioctls, network access and signals
 * are left as they are. Directory rights on a rule for a file are dropped,
 * since the kernel refuses them there.
 *
 * The shim checks the Landlock ABI (below 2, i.e. Linux before 5.19, is
 * refused: ABI 1 refuses every rename and link across directories), sets
 * no_new_privs (which also disables setuid helpers), adds the rules, restricts
 * itself and execs the command in place: same pid, same fds, same environment.
 * Any step that fails exits non-zero with one line on stderr and the command
 * never runs; there is no unconfined path. One exception is not a failure: a
 * rule whose path no longer exists (an entry removed between the caller's
 * listing and this open) grants nothing, so it is skipped.
 *
 * `--abi` prints the ABI and exits 0, or prints the refusal and exits 69.
 *
 * Exit codes of the shim itself, before the command runs:
 *   64   usage: no `--`, no executable, or a malformed rule
 *   65   a rule's path cannot be opened or added (a symlink included)
 *   69   Landlock is unavailable here, or its ABI is below 2
 *   71   a step that must succeed failed (ruleset, no_new_privs, restrict)
 *   126  the executable could not be run; 127 it does not exist
 *
 * The syscalls are made by number (444 to 446, the same on every Linux
 * architecture) and the structures are declared here, so no kernel header is
 * needed: the release builds cross-compile with zig against musl.
 *
 * FERMIX_LANDLOCK_TEST_ABI, defined at compile time only, replaces the
 * kernel's answer to the ABI query so a test build can prove the refusal on a
 * kernel that has Landlock. The shipped binary has no such seam.
 */
#define _GNU_SOURCE 1

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#define FX_SYS_CREATE_RULESET 444
#define FX_SYS_ADD_RULE 445
#define FX_SYS_RESTRICT_SELF 446

#define FX_CREATE_RULESET_VERSION (1U << 0)
#define FX_RULE_PATH_BENEATH 1

#ifndef PR_SET_NO_NEW_PRIVS
#define PR_SET_NO_NEW_PRIVS 38
#endif

#define FX_EXECUTE (1ULL << 0)
#define FX_WRITE_FILE (1ULL << 1)
#define FX_READ_FILE (1ULL << 2)
#define FX_READ_DIR (1ULL << 3)
#define FX_REMOVE_DIR (1ULL << 4)
#define FX_REMOVE_FILE (1ULL << 5)
#define FX_MAKE_DIR (1ULL << 7)
#define FX_MAKE_REG (1ULL << 8)
#define FX_MAKE_SOCK (1ULL << 9)
#define FX_MAKE_FIFO (1ULL << 10)
#define FX_MAKE_SYM (1ULL << 12)
#define FX_REFER (1ULL << 13)
#define FX_TRUNCATE (1ULL << 14)

/* Every access right of ABI 2 (bits 0 to 13) and of ABI 3 (TRUNCATE added). */
#define FX_HANDLED_ABI2 ((1ULL << 14) - 1)
#define FX_HANDLED_ABI3 ((1ULL << 15) - 1)

#define FX_FILE_ACCESS (FX_EXECUTE | FX_WRITE_FILE | FX_READ_FILE | FX_TRUNCATE)
#define FX_CHANGE_ACCESS                                                              \
  (FX_REMOVE_DIR | FX_REMOVE_FILE | FX_MAKE_DIR | FX_MAKE_REG | FX_MAKE_SOCK |       \
   FX_MAKE_FIFO | FX_MAKE_SYM | FX_REFER)

#define EXIT_USAGE 64
#define EXIT_RULE 65
#define EXIT_UNAVAILABLE 69
#define EXIT_OSERR 71

struct fx_ruleset_attr {
  uint64_t handled_access_fs;
};

struct fx_path_beneath_attr {
  uint64_t allowed_access;
  int32_t parent_fd;
} __attribute__((packed));

#ifdef FERMIX_LANDLOCK_TEST_ABI
static int landlock_abi(void) { return FERMIX_LANDLOCK_TEST_ABI; }
#else
static int landlock_abi(void) {
  return (int)syscall(FX_SYS_CREATE_RULESET, NULL, 0, FX_CREATE_RULESET_VERSION);
}
#endif

/* The ABI, or EXIT_UNAVAILABLE after one line saying why there is none. */
static int checked_abi(int *abi) {
  *abi = landlock_abi();
  if (*abi < 0) {
    fprintf(stderr, "fermix_landlock: Landlock is unavailable on this kernel (%s)\n",
            strerror(errno));
    return EXIT_UNAVAILABLE;
  }
  if (*abi < 2) {
    fprintf(stderr, "fermix_landlock: Landlock ABI %d is below 2 (Linux before 5.19)\n", *abi);
    return EXIT_UNAVAILABLE;
  }
  return 0;
}

static int parse_access(const char *letters, size_t length, uint64_t *access) {
  *access = 0;
  if (length == 0) return -1;
  for (size_t i = 0; i < length; i++) {
    switch (letters[i]) {
      case 'x': *access |= FX_EXECUTE; break;
      case 'r': *access |= FX_READ_FILE; break;
      case 'l': *access |= FX_READ_DIR; break;
      case 'w': *access |= FX_WRITE_FILE | FX_TRUNCATE; break;
      case 'c': *access |= FX_CHANGE_ACCESS; break;
      default: return -1;
    }
  }
  return 0;
}

/* Opens the rule's path itself (never a symlink's target) and adds the rule.
 * Returns 0, or the exit code after one line on stderr. */
static int add_rule(int ruleset, const char *rule, uint64_t handled) {
  const char *colon = strchr(rule, ':');
  uint64_t access;
  if (colon == NULL || colon[1] != '/' || parse_access(rule, (size_t)(colon - rule), &access) != 0) {
    fprintf(stderr, "fermix_landlock: malformed rule: %s\n", rule);
    return EXIT_USAGE;
  }
  const char *path = colon + 1;

  int fd = open(path, O_PATH | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0 && errno == ENOENT) return 0;
  if (fd < 0) {
    fprintf(stderr, "fermix_landlock: cannot open %s: %s\n", path, strerror(errno));
    return EXIT_RULE;
  }

  struct stat st;
  int status = 0;
  if (fstat(fd, &st) != 0) {
    fprintf(stderr, "fermix_landlock: cannot stat %s: %s\n", path, strerror(errno));
    status = EXIT_RULE;
  } else if (S_ISLNK(st.st_mode)) {
    fprintf(stderr, "fermix_landlock: %s is a symlink; rules name resolved paths\n", path);
    status = EXIT_RULE;
  } else {
    access &= handled;
    if (!S_ISDIR(st.st_mode)) access &= FX_FILE_ACCESS;
    struct fx_path_beneath_attr beneath = {.allowed_access = access, .parent_fd = fd};
    if (access != 0 &&
        syscall(FX_SYS_ADD_RULE, ruleset, FX_RULE_PATH_BENEATH, &beneath, 0) != 0) {
      fprintf(stderr, "fermix_landlock: cannot add the rule for %s: %s\n", path, strerror(errno));
      status = EXIT_RULE;
    }
  }
  close(fd);
  return status;
}

static int restrict_self(int ruleset) {
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
    fprintf(stderr, "fermix_landlock: cannot set no_new_privs: %s\n", strerror(errno));
    return EXIT_OSERR;
  }
  if (syscall(FX_SYS_RESTRICT_SELF, ruleset, 0) != 0) {
    fprintf(stderr, "fermix_landlock: cannot restrict itself: %s\n", strerror(errno));
    return EXIT_OSERR;
  }
  return 0;
}

/* Builds the ruleset from argv[1..separator) and restricts this process. */
static int confine(char **argv, int separator, int abi) {
  uint64_t handled = abi >= 3 ? FX_HANDLED_ABI3 : FX_HANDLED_ABI2;
  struct fx_ruleset_attr attr = {.handled_access_fs = handled};
  int ruleset = (int)syscall(FX_SYS_CREATE_RULESET, &attr, sizeof(attr), 0);
  if (ruleset < 0) {
    fprintf(stderr, "fermix_landlock: cannot create the ruleset: %s\n", strerror(errno));
    return EXIT_OSERR;
  }

  int status = 0;
  for (int i = 1; i < separator && status == 0; i++) status = add_rule(ruleset, argv[i], handled);
  if (status == 0) status = restrict_self(ruleset);
  close(ruleset);
  return status;
}

int main(int argc, char **argv) {
  int abi;

  if (argc == 2 && strcmp(argv[1], "--abi") == 0) {
    int status = checked_abi(&abi);
    if (status == 0) printf("fermix_landlock: abi %d\n", abi);
    return status;
  }

  int separator = -1;
  for (int i = 1; i < argc && separator < 0; i++) {
    if (strcmp(argv[i], "--") == 0) separator = i;
  }
  if (separator < 0 || separator + 1 >= argc) {
    fprintf(stderr, "fermix_landlock: usage: fermix_landlock RULE... -- <executable> [args...]\n");
    return EXIT_USAGE;
  }

  int status = checked_abi(&abi);
  if (status == 0) status = confine(argv, separator, abi);
  if (status != 0) return status;

  /* Replaces this image in place; returns only on failure. */
  execv(argv[separator + 1], &argv[separator + 1]);
  int error = errno;
  fprintf(stderr, "fermix_landlock: cannot run %s: %s\n", argv[separator + 1], strerror(error));
  return error == ENOENT ? 127 : 126;
}
