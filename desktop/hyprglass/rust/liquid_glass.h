#pragma once
#include <cstdint>

// Must match Rust's repr(C) Material. No C++ objects cross this boundary.
struct LiquidGlassMaterial {
    float refraction, dispersion, fresnel, specular, opacity, edge, lens;
    float layer_alpha;
};
static_assert(sizeof(LiquidGlassMaterial) == 32);
static_assert(alignof(LiquidGlassMaterial) == 4);
inline constexpr float LIQUID_GLASS_RADIUS = 28.0f;

extern "C" {
const char* liquid_glass_shader();
void* liquid_glass_create(uint32_t program);
void liquid_glass_destroy(void* handle);
void liquid_glass_draw(const void* handle, const LiquidGlassMaterial* material, uint32_t vao);
}
