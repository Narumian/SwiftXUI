#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/// Create a WebGPU instance + Xlib-backed surface for the given Display/Window.
/// On failure both out pointers are set to NULL.
void xrender_linux_create_surface(
    void *x11_display,
    unsigned long x11_window,
    void **out_instance,
    void **out_surface
);

#ifdef __cplusplus
}
#endif
