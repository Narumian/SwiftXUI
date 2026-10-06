#include "XRenderLinux.h"
#include "webgpu.h"
#include "wgpu.h"

void xrender_linux_create_surface(
    void *x11_display,
    unsigned long x11_window,
    void **out_instance,
    void **out_surface
) {
    if (out_instance) *out_instance = NULL;
    if (out_surface) *out_surface = NULL;
    if (!x11_display || !x11_window || !out_instance || !out_surface) return;

    WGPUInstance instance = wgpuCreateInstance(NULL);
    if (!instance) return;

    WGPUSurfaceSourceXlibWindow source = WGPU_SURFACE_SOURCE_XLIB_WINDOW_INIT;
    source.display = x11_display;
    source.window = (uint64_t)x11_window;

    WGPUSurfaceDescriptor descriptor = WGPU_SURFACE_DESCRIPTOR_INIT;
    descriptor.nextInChain = &source.chain;

    WGPUSurface surface = wgpuInstanceCreateSurface(instance, &descriptor);
    if (!surface) {
        wgpuInstanceRelease(instance);
        return;
    }

    *out_instance = instance;
    *out_surface = surface;
}
