#version 300 es
precision highp float;

// Original screen-space optical material. All distances are framebuffer pixels.
// tex is the live scene BEFORE the layer; maskTex is the unwarped GTK surface.
uniform sampler2D tex;
uniform sampler2D maskTex;
uniform vec2 fullSize, uvPadding, maskUVOffset, maskUVScale;
uniform float radius, roundingPower;
uniform float refractionStrength, chromaticAberration, fresnelStrength;
uniform float specularStrength, glassOpacity, edgeThickness, lensDistortion;
uniform vec3 tintColor;
uniform float tintAlpha, brightness, contrast, saturation, vibrancy;
uniform float vibrancyDarkness, adaptiveDim, adaptiveBoost, maskAlphaThreshold;
uniform float surfaceOpacity, layerAlpha;
uniform int useMask, maskMode, regionRectCount;
uniform vec4 regionRects[16];
in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;

vec4 surfaceAt(vec2 uv) {
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0))))
        return vec4(0.0);
    return texture(maskTex, uv * maskUVScale + maskUVOffset);
}

float boxDistance(vec2 p, vec2 size, float r) {
    r = clamp(r, 0.0, min(size.x, size.y) * 0.5);
    vec2 q = abs(p) - size * 0.5 + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

bool inMaterial(vec2 uv) {
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0))))
        return false;
    if (useMask == 0)
        return boxDistance((uv - 0.5) * fullSize, fullSize, radius) < 0.0;
    if (maskMode == 1) {
        vec2 p = uv * fullSize;
        for (int i = 0; i < min(regionRectCount, 16); ++i) {
            vec4 r = regionRects[i];
            if (all(greaterThanEqual(p, r.xy)) && all(lessThanEqual(p, r.xy + r.zw)))
                return true;
        }
        return false;
    }
    return surfaceAt(uv).a >= max(maskAlphaThreshold, 0.0001);
}

// Exact distance and gradient for the launcher and naturally sized clock layer.
vec3 roundedContour(vec2 uv) {
    vec2 p = (uv - 0.5) * fullSize;
    float r = min(radius, min(fullSize.x, fullSize.y) * 0.5);
    vec2 q = abs(p) - fullSize * 0.5 + r;
    vec2 outside = max(q, 0.0);
    float len = length(outside);
    vec2 gradient = len > 0.0001 ? outside / len
        : (q.x > q.y ? vec2(1.0, 0.0) : vec2(0.0, 1.0));
    return vec3(gradient * sign(p), len + min(max(q.x, q.y), 0.0) - r);
}

// Only irregular multi-card layers use contour sampling. More refinement and
// angular samples reduce quantization; the main widgets take the cheap exact path.
vec3 contour(vec2 uv, float reach) {
    float nearest = reach;
    vec2 normal = vec2(0.0);
    for (int i = 0; i < 24; ++i) {
        float angle = float(i) * 0.2617993878;
        vec2 ray = vec2(cos(angle), sin(angle));
        if (inMaterial(uv + ray * reach / fullSize)) continue;
        float lo = 0.0, hi = reach;
        for (int j = 0; j < 8; ++j) {
            float mid = (lo + hi) * 0.5;
            if (inMaterial(uv + ray * mid / fullSize)) lo = mid;
            else hi = mid;
        }
        float distance = (lo + hi) * 0.5;
        nearest = min(nearest, distance);
        float weight = pow(max(1.0 - distance / reach, 0.0), 3.0);
        normal += ray * weight;
    }
    float n = length(normal);
    return vec3(n > 0.0001 ? normal / n : vec2(0.0), nearest);
}

vec3 scene(vec2 uv) {
    vec2 padded = uv * (1.0 - 2.0 * uvPadding) + uvPadding;
    vec2 halfTexel = 0.5 / vec2(textureSize(tex, 0));
    return texture(tex, clamp(padded, halfTexel, 1.0 - halfTexel)).rgb;
}

vec2 refractedOffset(vec3 normal, float ior, float thickness) {
    vec3 ray = refract(vec3(0.0, 0.0, -1.0), normal, 1.0 / ior);
    return ray.xy * thickness / max(-ray.z, 0.25) / fullSize;
}

// A low-frequency spectral envelope: the old subpixel sin^2 fringe aliased.
// Each band spans many pixels, keeping it stable at the native display scale.
vec3 diffraction(float distance, float incidence) {
    vec3 frequency = vec3(0.32, 0.40, 0.46);
    vec3 phase = distance * frequency + incidence * 1.5 + vec3(0.0, 2.1, 4.2);
    return 0.5 + 0.5 * cos(phase);
}

void main() {
    vec2 uv = v_texcoord;
    vec4 surface = useMask == 1 ? surfaceAt(uv) : vec4(0.0);
    bool analytic = useMask == 0 || radius > 0.0;
    vec3 shape = roundedContour(uv);
    // Derivatives are evaluated before any per-fragment early return.
    float pixelWidth = max(fwidth(shape.z), 1.0);
    float geometricCoverage = clamp(0.5 - shape.z / pixelWidth, 0.0, 1.0);
    float groupFade = 1.0;
    if (analytic && useMask == 1) {
        // Empty border padding measures GTK's CSS opacity independently of the
        // compositor fade. These locations avoid labels, glyphs and input wells.
        float inset = min(8.0, min(fullSize.x, fullSize.y) * 0.18);
        float base = min(surfaceAt(vec2(inset / fullSize.x, 0.5)).a,
                         surfaceAt(vec2(1.0 - inset / fullSize.x, 0.5)).a);
        groupFade = clamp(base / max(surfaceOpacity * layerAlpha, 0.0001), 0.0, 1.0);
    }
    float coverage = analytic ? geometricCoverage * groupFade
        : clamp(surface.a / max(surfaceOpacity * layerAlpha, 0.0001), 0.0, 1.0);
    if (coverage <= 0.0001 || (!analytic && maskMode == 1 && !inMaterial(uv))) {
        fragColor = surface;
        return;
    }
    float bevel = clamp(min(fullSize.x, fullSize.y) * edgeThickness, 4.0, 32.0);
    vec3 edge = analytic ? vec3(shape.xy, max(-shape.z, 0.0)) : contour(uv, bevel);
    float rim = 1.0 - smoothstep(0.0, bevel, edge.z);
    // Convex glass slab: flat center, tilted surface normal at the curved edge.
    float slope = rim * rim * 0.78;
    vec3 normal = normalize(vec3(edge.xy * slope, sqrt(max(1.0 - slope * slope, 0.01))));
    float thickness = bevel * 1.8 * refractionStrength;
    vec2 dome = analytic ? (0.5 - uv) * lensDistortion * 0.018 * (1.0 - rim) : vec2(0.0);
    float spread = chromaticAberration * 0.12;
    vec2 red = refractedOffset(normal, 1.50 - spread, thickness);
    vec2 green = refractedOffset(normal, 1.50, thickness);
    vec2 blue = refractedOffset(normal, 1.50 + spread, thickness);
    vec3 color = vec3(scene(uv + dome + red).r,
                      scene(uv + dome + green).g,
                      scene(uv + dome + blue).b);

    float luminance = dot(color, vec3(0.2126, 0.7152, 0.0722));
    color = mix(vec3(luminance), color, saturation);
    float adaptation = smoothstep(0.25, 0.8, luminance);
    color *= brightness * (1.0 - adaptiveDim * adaptation);
    color += adaptiveBoost * (1.0 - adaptation) * 0.25;
    color = mix(vec3(0.5), color, contrast);
    float chroma = max(color.r, max(color.g, color.b)) - min(color.r, min(color.g, color.b));
    color = mix(vec3(dot(color, vec3(0.2126, 0.7152, 0.0722))), color,
                1.0 + vibrancy * chroma * (1.0 - vibrancyDarkness * (1.0 - luminance)));
    color = mix(color, tintColor, clamp(tintAlpha, 0.0, 1.0));

    // Keep reflections at the boundary. Scaling a narrow specular/caustic lobe
    // with bevel depth produced separate bright stripes inside large panes.
    float fresnel = 0.04 + 0.96 * pow(1.0 - normal.z, 5.0);
    float facing = dot(edge.xy, normalize(vec2(-0.45, -0.65))) * 0.5 + 0.5;
    float illumination = smoothstep(0.05, 0.95, facing);
    float lip = 1.0 - smoothstep(0.0, max(1.6, pixelWidth), edge.z);
    float reflection = 1.0 - smoothstep(0.0, 7.0, edge.z);
    color += fresnelStrength * fresnel * rim * vec3(0.80, 0.90, 1.0);
    color += specularStrength * illumination * (lip * 0.10 + reflection * 0.035);
    color += diffraction(edge.z, facing) * chromaticAberration * rim * 0.12;
    color *= 1.0 - rim * (1.0 - facing) * 0.09;
    color = clamp(color, 0.0, 1.0);

    // The GTK surface already includes edge coverage and group opacity. Complete
    // the pane's alpha once instead of putting another covered layer over it.
    float materialOpacity = glassOpacity / max(layerAlpha, 0.0001);
    float remaining = clamp(materialOpacity, 0.0, 1.0)
        * max(coverage * layerAlpha - surface.a, 0.0);
    fragColor = surface + vec4(color * remaining, remaining);
}
