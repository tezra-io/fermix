// C NIF for fermix_nif. First native code in this app.
//
// Exposes one POSIX kill(2) process-group signal shim used by the
// subprocess-lifecycle sweep. The sweep must not allocate an OS process
// (spawning `kill` fails precisely under the fd/process-table exhaustion the
// sweep exists to contain), so the signal is delivered by a direct syscall.

#include <erl_nif.h>
#include <signal.h>
#include <errno.h>
#include <string.h>
#include <sys/types.h>

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

static ErlNifFunc nif_funcs[] = {
    {"kill_pgid_nif", 2, kill_pgid_nif, 0},
};

ERL_NIF_INIT(Elixir.FermixNif, nif_funcs, NULL, NULL, NULL, NULL)
