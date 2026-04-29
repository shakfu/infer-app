// Narrow C surface over whisper.cpp. Originally a workaround for a
// Clang module redefinition error: the upstream llama.framework and
// whisper.framework each shipped their own copy of ggml.h, and importing
// both Swift modules into one target produced "X has different definitions
// in different modules" diagnostics on the shared ggml types. The combined
// Ggml + LlamaCpp + Whisper xcframework set now shares one Ggml module so
// that collision is gone — the bridge stays for now because its narrow C
// surface is convenient (Swift doesn't have to thread `whisper_full_params`
// or sampling enums through), and removing it is a separate refactor.
#ifndef WHISPER_BRIDGE_H
#define WHISPER_BRIDGE_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct whisper_bridge_context whisper_bridge_context;

whisper_bridge_context * whisper_bridge_init_from_file(const char * path_model);
void whisper_bridge_free(whisper_bridge_context * ctx);

// Returns 0 on success, non-zero whisper_full error code otherwise.
int whisper_bridge_transcribe(
    whisper_bridge_context * ctx,
    const float * samples,
    int n_samples,
    bool translate,
    int n_threads
);

int whisper_bridge_n_segments(whisper_bridge_context * ctx);

// Borrowed pointer; valid until the next transcribe call or free.
const char * whisper_bridge_segment_text(whisper_bridge_context * ctx, int i);

#ifdef __cplusplus
}
#endif

#endif
