#pragma once

#ifdef __cplusplus
extern "C" {
#endif

void xrender_apple_create_surface(
    void *metal_layer,
    void **out_instance,
    void **out_surface
);

#ifdef __cplusplus
}
#endif
