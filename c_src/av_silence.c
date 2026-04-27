/*
 * Tiny NIF that turns down libav's stderr log level so FFmpeg's INFO and
 * WARNING chatter (`[mp3 @ ...] Estimating duration from bitrate`,
 * `Could not update timestamps for skipped samples`, etc.) doesn't bleed
 * into Shazza's own output during ingest.
 *
 * This is a thin wrapper around `av_log_set_level()` from libavutil, the
 * same function the `ffmpeg` CLI uses internally to honour `-loglevel`.
 * Loaded on demand by `Shazza.Audio.Silence`.
 */
#include <erl_nif.h>
#include <libavutil/log.h>

static ERL_NIF_TERM set_quiet(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    av_log_set_level(AV_LOG_QUIET);
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM set_error(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    av_log_set_level(AV_LOG_ERROR);
    return enif_make_atom(env, "ok");
}

static ErlNifFunc nif_funcs[] = {
    {"set_quiet", 0, set_quiet, 0},
    {"set_error", 0, set_error, 0}
};

ERL_NIF_INIT(Elixir.Shazza.Audio.Silence, nif_funcs, NULL, NULL, NULL, NULL)
