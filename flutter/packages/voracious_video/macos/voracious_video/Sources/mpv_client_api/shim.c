// This target is the vendored libmpv client API headers and nothing else.
// SwiftPM will not accept a target with no compilable source, so here is one.
//
// Deliberately empty of declarations: every libmpv entry point this package
// uses is resolved with dlsym at runtime, never linked. See the README beside
// this file.

#include <mpv/render_gl.h>

// Compile-time assurance that the vendored headers still describe the ABI the
// Swift side assumes. If a future header revision changes either struct, this
// stops the build instead of corrupting a render call's arguments.
_Static_assert(sizeof(mpv_opengl_fbo) == 16, "mpv_opengl_fbo layout changed");
_Static_assert(sizeof(mpv_render_param) == 16, "mpv_render_param layout changed");
