#pragma once
#include <cstdint>

// Must match Rust's repr(C) Material. No C++ objects cross this boundary.
struct LiquidGlassMaterial {
    float refraction, dispersion, fresnel, specular, opacity, edge, lens;
};
static_assert(sizeof(LiquidGlassMaterial) == 28);
static_assert(alignof(LiquidGlassMaterial) == 4);

extern "C" {
const char* liquid_glass_shader();
void* liquid_glass_create(uint32_t program);
void liquid_glass_destroy(void* handle);
void liquid_glass_draw(const void* handle, const LiquidGlassMaterial* material, uint32_t vao);
}
