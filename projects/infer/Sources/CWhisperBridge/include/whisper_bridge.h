// Narrow C surface over whisper.cpp. This bridge exists because
// llama.framework and whisper.framework each ship their own copy of ggml.h,
// and importing both Swift modules ('llama' and 'whisper') into one target
// produces a Clang "X has different definitions in different modules" error
// on the shared ggml types. By compiling all whisper.h usage inside this
// C target and exposing only primitive-typed functions here, Swift never
// sees whisper's ggml declarations.
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
