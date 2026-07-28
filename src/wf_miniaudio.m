// The Apple build of miniaudio's implementation unit.
//
// Identical to `wf_miniaudio.c` and deliberately so: clang selects a source
// language from the file extension, and miniaudio reaches AVAudioSession on
// Apple platforms, so it must be compiled as Objective-C or it fails inside
// Foundation's own headers. `Language.objectiveC` in the build hook only adds
// the `-framework` flags; the extension is what actually selects compiler mode.
//
// Including rather than duplicating, so there is exactly one copy of the
// configuration.

#include "wf_miniaudio.c"
