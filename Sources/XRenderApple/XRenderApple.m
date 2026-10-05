#import "XRenderApple.h"
#import <CWGPU.h>

void xrender_apple_create_surface(
    void *metal_layer,
    void **out_instance,
    void **out_surface
) {
    if (out_instance) *out_instance = NULL;
    if (out_surface) *out_surface = NULL;
    if (!metal_layer || !out_instance || !out_surface) return;

    WGPUInstance instance = wgpuCreateInstance(NULL);
    if (!instance) return;

    WGPUSurfaceSourceMetalLayer source = WGPU_SURFACE_SOURCE_METAL_LAYER_INIT;
    source.layer = metal_layer;
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
