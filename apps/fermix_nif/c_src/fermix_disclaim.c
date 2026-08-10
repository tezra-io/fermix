/* disclaim — macOS-only exec shim.
 *
 * Usage: disclaim <executable> [args...]
 *        disclaim --check
 *
 * Sets responsibility_spawnattrs_setdisclaim(attr, 1) + POSIX_SPAWN_SETEXEC and
 * posix_spawn()s the target IN PLACE (same pid, same fds), so the exec'd child
 * becomes its own TCC "responsible process" instead of inheriting the daemon's.
 * Without this, macOS attributes a spawned browser's bundle-probing to fermix
 * and raises App Management prompts keyed to the versioned install path — one
 * per release. Fails loud (nonzero exit, stderr message) rather than ever
 * launching undisclaimed; exit codes match the compux sidecar's contract.
 *
 * _DARWIN_C_SOURCE is required: under strict -std=c99 header gating both
 * RTLD_DEFAULT and POSIX_SPAWN_SETEXEC are invisible without it. The private
 * API has no header and must be dlsym'd.
 */
#define _DARWIN_C_SOURCE 1

#include <dlfcn.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>

extern char **environ;

typedef int (*setdisclaim_fn)(posix_spawnattr_t *, int);

static setdisclaim_fn resolve_setdisclaim(void) {
  return (setdisclaim_fn)dlsym(RTLD_DEFAULT, "responsibility_spawnattrs_setdisclaim");
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "disclaim: usage: disclaim <executable> [args...]\n");
    return 64; /* EX_USAGE */
  }

  setdisclaim_fn set_disclaim = resolve_setdisclaim();

  if (argc == 2 && strcmp(argv[1], "--check") == 0) {
    if (set_disclaim == NULL) {
      fprintf(stderr, "disclaim: responsibility_spawnattrs_setdisclaim unavailable\n");
      return 70;
    }
    printf("disclaim: ok\n");
    return 0;
  }

  if (set_disclaim == NULL) {
    fprintf(stderr,
            "disclaim: responsibility_spawnattrs_setdisclaim unavailable on this "
            "macOS; refusing to launch undisclaimed\n");
    return 70; /* EX_SOFTWARE — matches compux's exit code for this condition */
  }

  posix_spawnattr_t attr;
  if (posix_spawnattr_init(&attr) != 0) {
    fprintf(stderr, "disclaim: posix_spawnattr_init failed\n");
    return 74;
  }
  if (set_disclaim(&attr, 1) != 0) {
    fprintf(stderr, "disclaim: responsibility_spawnattrs_setdisclaim returned nonzero\n");
    return 71;
  }
  if (posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETEXEC) != 0) {
    fprintf(stderr, "disclaim: posix_spawnattr_setflags failed\n");
    return 75;
  }

  /* SETEXEC: replaces this image in place; returns only on failure. */
  int rc = posix_spawn(NULL, argv[1], NULL, &attr, &argv[1], environ);
  fprintf(stderr, "disclaim: exec of %s failed (posix_spawn rc=%d)\n", argv[1], rc);
  return 72;
}
