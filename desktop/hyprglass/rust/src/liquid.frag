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

// Local contour search, entirely on GPU. The alpha silhouette, rather than the
// layer's bounding box, defines the lens (Waybar and Wlogout have empty regions).
// Interior pixels need only 12 probes; binary refinement is confined to the rim.
// Angular sampling approximates the distance field; no readback or capture loop.
vec3 contour(vec2 uv, float reach) {
    float nearest = reach;
    vec2 normal = vec2(0.0);
    for (int i = 0; i < 12; ++i) {
        float angle = float(i) * 0.5235987756;
        vec2 ray = vec2(cos(angle), sin(angle));
        if (inMaterial(uv + ray * reach / fullSize)) continue;
        float lo = 0.0, hi = reach;
        for (int j = 0; j < 5; ++j) {
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
    // Sample inward at the bezel: do not pull cleared off-monitor padding into
    // the bottom-right clock. Padding still supports the background blur kernel.
    vec2 lower = max(uvPadding, halfTexel);
    vec2 upper = min(1.0 - uvPadding, 1.0 - halfTexel);
    return texture(tex, clamp(padded, lower, upper)).rgb;
}

vec2 refractedOffset(vec3 normal, float ior, float thickness) {
    vec3 ray = refract(vec3(0.0, 0.0, -1.0), normal, 1.0 / ior);
    return ray.xy * thickness / max(-ray.z, 0.25) / fullSize;
}

// Fraunhofer slit envelope evaluated for red/green/blue wavelengths. This is
// an artistic screen-space approximation of edge diffraction, not a wave solver.
vec3 diffraction(float distance, float incidence) {
    vec3 wavelength = vec3(0.650, 0.510, 0.475); // micrometres
    vec3 phase = 3.14159265 * (distance + 0.3) * (0.8 + incidence) / wavelength;
    vec3 amplitude = sin(phase) / phase;
    return amplitude * amplitude;
}

void main() {
    vec2 uv = v_texcoord;
    vec4 surface = useMask == 1 ? surfaceAt(uv) : vec4(0.0);
    if (!inMaterial(uv)) {
        // Preserve anti-aliased GTK edges and content outside protocol regions.
        fragColor = surface;
        return;
    }
    float bevel = clamp(min(fullSize.x, fullSize.y) * edgeThickness, 4.0, 32.0);
    vec3 edge = contour(uv, bevel);
    float rim = 1.0 - smoothstep(0.0, bevel, edge.z);
    // Convex glass slab: flat center, tilted surface normal at the curved edge.
    float slope = rim * rim * 0.96;
    vec3 normal = normalize(vec3(edge.xy * slope, sqrt(max(1.0 - slope * slope, 0.01))));
    float thickness = 48.0 * refractionStrength;
    vec2 dome = (0.5 - uv) * lensDistortion * 0.025 * (1.0 - rim);
    float spread = chromaticAberration * 0.25;
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

    // Schlick Fresnel plus broad studio reflection and a narrow polished lip.
    float fresnel = 0.04 + 0.96 * pow(1.0 - normal.z, 5.0);
    vec3 light = normalize(vec3(-0.45, -0.65, 0.62));
    vec3 halfVector = normalize(light + vec3(0.0, 0.0, 1.0));
    float spec = pow(max(dot(normal, halfVector), 0.0), 44.0);
    float lip = exp(-edge.z * 1.8);
    float facing = dot(edge.xy, normalize(vec2(-0.45, -0.65))) * 0.5 + 0.5;
    color += fresnelStrength * fresnel * rim * vec3(0.80, 0.90, 1.0);
    color += specularStrength * (spec * rim * 0.55 + lip * (0.10 + facing * 0.48));
    color += diffraction(edge.z, facing) * chromaticAberration * rim * 1.8;
    // Weak caustic immediately inside the bevel, illuminated from upper left.
    color += vec3(1.0, 0.96, 0.88) * exp(-pow((edge.z - bevel * 0.68) / 1.5, 2.0))
             * facing * refractionStrength * 0.055;
    color *= 1.0 - rim * (1.0 - facing) * 0.09;
    color = clamp(color, 0.0, 1.0);

    float coverage = useMask == 1 && maskMode == 0
        ? smoothstep(0.0, max(maskAlphaThreshold * 2.0, 0.0002), surface.a) : 1.0;
    float alpha = glassOpacity * coverage;
    // Both inputs are premultiplied. Never distort or color-fringe foreground text.
    fragColor = surface + vec4(color * alpha, alpha) * (1.0 - surface.a);
}
