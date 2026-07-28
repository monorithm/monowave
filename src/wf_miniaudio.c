// miniaudio's implementation, isolated in its own translation unit.
//
// It is 95,000 lines, so it gets compiled once and on its own rather than being
// dragged into every file that needs a device handle.
//
// Everything above the device layer is switched off. monowave needs miniaudio
// for one thing - a capture callback fed by the platform's audio backend - and
// its decoding, encoding, resource manager, node graph and engine would all be
// dead weight in an artifact that ships on six targets. Decoding in particular
// is already handled by dr_libs in `wf_decode.c`.

// Outside the guard below, so clang does not read the guard plus a following
// `#define` as a malformed header guard.
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE

#ifndef WF_NO_DEVICE
#define MINIAUDIO_IMPLEMENTATION
#include "vendor/miniaudio.h"
#endif
