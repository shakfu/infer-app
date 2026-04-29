#include "whisper_bridge.h"
#include <stdlib.h>
#include <Whisper/whisper.h>

struct whisper_bridge_context {
    struct whisper_context * ctx;
};

whisper_bridge_context * whisper_bridge_init_from_file(const char * path_model) {
    struct whisper_context_params cparams = whisper_context_default_params();
    struct whisper_context * c = whisper_init_from_file_with_params(path_model, cparams);
    if (!c) return NULL;
    whisper_bridge_context * wrap = (whisper_bridge_context *)malloc(sizeof(whisper_bridge_context));
    if (!wrap) {
        whisper_free(c);
        return NULL;
    }
    wrap->ctx = c;
    return wrap;
}

void whisper_bridge_free(whisper_bridge_context * ctx) {
    if (!ctx) return;
    if (ctx->ctx) whisper_free(ctx->ctx);
    free(ctx);
}

int whisper_bridge_transcribe(
    whisper_bridge_context * ctx,
    const float * samples,
    int n_samples,
    bool translate,
    int n_threads
) {
    if (!ctx || !ctx->ctx) return -1;
    struct whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    p.print_progress = false;
    p.print_realtime = false;
    p.print_timestamps = false;
    p.print_special = false;
    p.no_timestamps = true;
    p.suppress_blank = true;
    p.translate = translate;
    p.n_threads = n_threads;
    return whisper_full(ctx->ctx, p, samples, n_samples);
}

int whisper_bridge_n_segments(whisper_bridge_context * ctx) {
    if (!ctx || !ctx->ctx) return 0;
    return whisper_full_n_segments(ctx->ctx);
}

const char * whisper_bridge_segment_text(whisper_bridge_context * ctx, int i) {
    if (!ctx || !ctx->ctx) return NULL;
    return whisper_full_get_segment_text(ctx->ctx, i);
}
