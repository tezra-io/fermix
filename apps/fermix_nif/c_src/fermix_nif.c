// C NIF for fermix_nif. First native code in this app.
//
// Exposes two POSIX shims:
//
//   * kill(2) on a process group, used by the subprocess-lifecycle sweep. The
//     sweep must not allocate an OS process (spawning `kill` fails precisely
//     under the fd/process-table exhaustion the sweep exists to contain), so
//     the signal is delivered by a direct syscall.
//   * the terminal driver's ECHO flag on stdin, used by the CLI's hidden
//     secret entry. The ERTS a shipped binary runs is built without termcap,
//     so OTP's own no-echo mode (`shell:start_interactive({noshell, raw})`)
//     answers enotsup on every terminal, and a port child cannot do it either:
//     it has no controlling terminal and sits in its own process group. The
//     VM itself is in the terminal's foreground group, so it flips the flag.

// kill(2) and the termios calls are POSIX, not ISO C: request the POSIX.1-2008
// declarations so the headers declare them under -std=c99. The release build's
// zig cross-compile for aarch64-linux hard-errors on an implicit declaration
// (native macOS headers are lenient), which broke the v0.6.0 release build.
// Must precede every #include so the feature macro is set before the system
// headers load.
#define _POSIX_C_SOURCE 200809L

#include <erl_nif.h>
#include <signal.h>
#include <errno.h>
#include <string.h>
#include <sys/types.h>
#include <termios.h>
#include <unistd.h>

static ERL_NIF_TERM mk_atom(ErlNifEnv *env, const char *name)
{
    return enif_make_atom(env, name);
}

static ERL_NIF_TERM mk_error(ErlNifEnv *env, ERL_NIF_TERM reason)
{
    return enif_make_tuple2(env, mk_atom(env, "error"), reason);
}

// kill_pgid_nif(pgid, signal) -> :ok | {:error, reason}
//
// Callers reach this only through FermixNif.kill_pgid/2, whose guards have
// already asserted pgid is a positive integer and signal is :sigterm/:sigkill.
// The validation here is defense-in-depth: a bad argument fails loud with
// badarg rather than signalling the wrong target.
static ERL_NIF_TERM kill_pgid_nif(ErlNifEnv *env, int argc,
                                  const ERL_NIF_TERM argv[])
{
    long pgid;
    char sig_atom[16];
    int sig;

    if (argc != 2) {
        return enif_make_badarg(env);
    }

    if (!enif_get_long(env, argv[0], &pgid) || pgid <= 0) {
        return enif_make_badarg(env);
    }

    if (!enif_get_atom(env, argv[1], sig_atom, sizeof(sig_atom),
                       ERL_NIF_LATIN1)) {
        return enif_make_badarg(env);
    }

    if (strcmp(sig_atom, "sigterm") == 0) {
        sig = SIGTERM;
    } else if (strcmp(sig_atom, "sigkill") == 0) {
        sig = SIGKILL;
    } else {
        return enif_make_badarg(env);
    }

    if (kill(-(pid_t)pgid, sig) == 0) {
        return mk_atom(env, "ok");
    }

    switch (errno) {
    case ESRCH:
        return mk_error(env, mk_atom(env, "esrch"));
    case EPERM:
        return mk_error(env, mk_atom(env, "eperm"));
    case EINVAL:
        return mk_error(env, mk_atom(env, "einval"));
    default:
        return mk_error(env, enif_make_tuple2(env, mk_atom(env, "errno"),
                                              enif_make_int(env, errno)));
    }
}

static ERL_NIF_TERM errno_error(ErlNifEnv *env, int err)
{
    switch (err) {
    case ENOTTY:
        return mk_error(env, mk_atom(env, "enotty"));
    case EBADF:
        return mk_error(env, mk_atom(env, "ebadf"));
    case EIO:
        return mk_error(env, mk_atom(env, "eio"));
    case EINTR:
        return mk_error(env, mk_atom(env, "eintr"));
    default:
        return mk_error(env, enif_make_tuple2(env, mk_atom(env, "errno"),
                                              enif_make_int(env, err)));
    }
}

// set_stdin_echo_nif(echo) -> {:ok, previous_echo} | {:error, reason}
//
// Turns the terminal driver's ECHO flag on stdin on or off and answers whether
// it was on before, so the caller restores exactly what it found. Only ECHO
// moves: canonical line editing stays on, so the kernel still assembles the
// line and Enter still ends it. Callers reach this only through
// FermixNif.set_stdin_echo/1, whose guard has already asserted a boolean.
static ERL_NIF_TERM set_stdin_echo_nif(ErlNifEnv *env, int argc,
                                       const ERL_NIF_TERM argv[])
{
    struct termios mode;
    char echo_atom[8];
    int echo;
    int previous;

    if (argc != 1 || !enif_get_atom(env, argv[0], echo_atom, sizeof(echo_atom),
                                    ERL_NIF_LATIN1)) {
        return enif_make_badarg(env);
    }

    if (strcmp(echo_atom, "true") == 0) {
        echo = 1;
    } else if (strcmp(echo_atom, "false") == 0) {
        echo = 0;
    } else {
        return enif_make_badarg(env);
    }

    if (tcgetattr(STDIN_FILENO, &mode) != 0) {
        return errno_error(env, errno);
    }

    previous = (mode.c_lflag & ECHO) != 0;

    if (echo) {
        mode.c_lflag |= ECHO;
    } else {
        mode.c_lflag &= ~(tcflag_t)ECHO;
    }

    if (tcsetattr(STDIN_FILENO, TCSANOW, &mode) != 0) {
        return errno_error(env, errno);
    }

    return enif_make_tuple2(env, mk_atom(env, "ok"),
                            mk_atom(env, previous ? "true" : "false"));
}

static ErlNifFunc nif_funcs[] = {
    {"kill_pgid_nif", 2, kill_pgid_nif, 0},
    {"set_stdin_echo_nif", 1, set_stdin_echo_nif, 0},
};

// Hot-code-upgrade acceptance. A dev recompile under a live daemon hot-swaps
// this module, and a NIF library without an upgrade callback makes the VM
// refuse the swap — the module then loses its native binding and every
// process-group sweep crashes until the daemon restarts. This NIF keeps no
// private state, so carrying it across a swap needs nothing beyond saying yes.
static int upgrade(ErlNifEnv *env, void **priv_data, void **old_priv_data,
                   ERL_NIF_TERM load_info)
{
    (void)env;
    (void)priv_data;
    (void)old_priv_data;
    (void)load_info;
    return 0;
}

ERL_NIF_INIT(Elixir.FermixNif, nif_funcs, NULL, NULL, upgrade, NULL)
