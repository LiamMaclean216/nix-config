"""Exercise the real Rust/GLES pass in a surfaceless EGL context, with no desktop.

Usage: python3 tests/render.py libEGL.so.1 libGLESv2.so.2 target/release/libliquid_glass.so
Use LIBGL_ALWAYS_SOFTWARE=1 and the pinned Mesa EGL vendor for a headless check.
"""
import ctypes as c
import math
from pathlib import Path
import sys

I, U, F, P = c.c_int, c.c_uint, c.c_float, c.c_void_p


def function(lib, name, result, *args):
    fn = getattr(lib, name)
    fn.restype, fn.argtypes = result, args
    return fn


egl, gl, rust = (c.CDLL(path) for path in sys.argv[1:4])
display = function(egl, "eglGetPlatformDisplay", P, U, P, P)(0x31DD, None, None)
assert function(egl, "eglInitialize", U, P, P, P)(display, None, None), "EGL init failed"
assert function(egl, "eglBindAPI", U, U)(0x30A0)
attributes = (I * 13)(0x3033, 1, 0x3040, 0x40, 0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, 0x3038)
config, count = P(), I()
assert function(egl, "eglChooseConfig", U, P, P, P, I, P)(display, attributes, c.byref(config), 1, c.byref(count)) and count.value
context = function(egl, "eglCreateContext", P, P, P, P, P)(display, config, None, (I * 3)(0x3098, 3, 0x3038))
assert context, "GLES 3 context failed"
assert function(egl, "eglMakeCurrent", U, P, P, P, P)(display, None, None, context)
print("Renderer:", function(gl, "glGetString", c.c_char_p, U)(0x1F01).decode())


def shader(kind, source):
    handle = function(gl, "glCreateShader", U, U)(kind)
    text = c.c_char_p(source)
    function(gl, "glShaderSource", None, U, I, P, P)(handle, 1, c.byref(text), None)
    function(gl, "glCompileShader", None, U)(handle)
    ok = I()
    function(gl, "glGetShaderiv", None, U, U, P)(handle, 0x8B81, c.byref(ok))
    log = c.create_string_buffer(8192)
    function(gl, "glGetShaderInfoLog", None, U, I, P, P)(handle, len(log), None, log)
    assert ok.value, log.value.decode()
    return handle


vertex = shader(0x8B31, b"""#version 300 es
out vec2 v_texcoord;
void main() {
    vec2 p = vec2(float(gl_VertexID & 1), float((gl_VertexID >> 1) & 1));
    v_texcoord = p;
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
""")
fragment = shader(0x8B30, function(rust, "liquid_glass_shader", c.c_char_p)())
program = function(gl, "glCreateProgram", U)()
for handle in [vertex, fragment]:
    function(gl, "glAttachShader", None, U, U)(program, handle)
function(gl, "glLinkProgram", None, U)(program)
ok = I()
function(gl, "glGetProgramiv", None, U, U, P)(program, 0x8B82, c.byref(ok))
assert ok.value, "Shader link failed"
function(gl, "glUseProgram", None, U)(program)


def uniform(name, *values, integer=False):
    loc = function(gl, "glGetUniformLocation", I, U, c.c_char_p)(program, name.encode())
    suffix = "i" if integer else "f"
    function(gl, f"glUniform{len(values)}{suffix}", None, I, *([I if integer else F] * len(values)))(loc, *values)


W, H = 320, 96


def texture(unit, data):
    handle = U()
    function(gl, "glGenTextures", None, I, P)(1, c.byref(handle))
    function(gl, "glActiveTexture", None, U)(0x84C0 + unit)
    function(gl, "glBindTexture", None, U, U)(0x0DE1, handle)
    for name, value in [(0x2801, 0x2601), (0x2800, 0x2601), (0x2802, 0x812F), (0x2803, 0x812F)]:
        function(gl, "glTexParameteri", None, U, U, I)(0x0DE1, name, value)
    pixels = (c.c_ubyte * len(data)).from_buffer_copy(data) if data else None
    function(gl, "glTexImage2D", None, U, I, I, I, I, I, U, U, P)(0x0DE1, 0, 0x1908, W, H, 0, 0x1908, 0x1401, pixels)
    return handle


background = bytearray()
mask = bytearray()
for y in range(H):
    for x in range(W):
        gray = 210 if (x // 7 + y // 7) % 2 else 45
        background.extend([gray, gray, gray, 255])
        # Clock-like pill offset within a much wider, mostly transparent surface.
        qx, qy = abs(x + 0.5 - 247) - 42, abs(y + 0.5 - 48) - 12
        distance = math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - 18
        pixel = [5, 5, 5, 36] if distance < 0 else [0, 0, 0, 0]
        if 220 <= x < 225 and 40 <= y < 55:
            pixel = [244, 233, 218, 255]  # Opaque glyph must remain unwarped.
        mask.extend(pixel)
scene_texture = texture(0, background)
texture(1, mask)
target = texture(2, None)
framebuffer, vao = U(), U()
function(gl, "glGenFramebuffers", None, I, P)(1, c.byref(framebuffer))
function(gl, "glBindFramebuffer", None, U, U)(0x8D40, framebuffer)
function(gl, "glFramebufferTexture2D", None, U, U, U, U, I)(0x8D40, 0x8CE0, 0x0DE1, target, 0)
assert function(gl, "glCheckFramebufferStatus", U, U)(0x8D40) == 0x8CD5
function(gl, "glGenVertexArrays", None, I, P)(1, c.byref(vao))
function(gl, "glViewport", None, I, I, I, I)(0, 0, W, H)
for name, value in {"tex": 0, "maskTex": 1, "useMask": 1, "maskMode": 0}.items():
    uniform(name, value, integer=True)
uniform("fullSize", W, H)
uniform("maskUVScale", 1, 1)
uniform("maskAlphaThreshold", 0.05)
for name in ["brightness", "contrast", "saturation"]:
    uniform(name, 1)


class Material(c.Structure):
    _fields_ = [(name, F) for name in ["refraction", "dispersion", "fresnel", "specular", "opacity", "edge", "lens"]]


renderer = function(rust, "liquid_glass_create", P, U)(program)
draw = function(rust, "liquid_glass_draw", None, P, P, U)


def render(refraction=0.65, dispersion=0.18, opacity=1.0):
    material = Material(refraction, dispersion, 0.55, 0.7, opacity, 0.12, 0.0)
    draw(renderer, c.byref(material), vao)
    result = (c.c_ubyte * (W * H * 4))()
    function(gl, "glReadPixels", None, I, I, I, I, U, U, P)(0, 0, W, H, 0x1908, 0x1401, result)
    assert function(gl, "glGetError", U)() == 0, "GLES error"
    return bytes(result)


def pixel(data, x, y):
    start = (y * W + x) * 4
    return data[start:start + 4]


result = render()
assert pixel(result, 50, 48) == bytes([0, 0, 0, 0]), "Glass leaked outside clock"
assert pixel(result, 188, 19) == bytes([0, 0, 0, 0]), "Glass filled rounded corner"
assert pixel(result, 222, 45) == bytes([244, 233, 218, 255]), "Foreground glyph distorted"
plain = render(refraction=0.0)
assert sum(a != b for a, b in zip(result, plain)) > 200, "Refraction did not move backdrop"
achromatic = render(dispersion=0.0)
assert sum(a != b for a, b in zip(result, achromatic)) > 100, "Spectral effects missing"
faded = render(opacity=0.25)
assert 75 < pixel(faded, 247, 48)[3] < 105, "Fade is not premultiplied"
assert pixel(render(opacity=0.0), 247, 48) == pixel(mask, 247, 48), "Zero opacity changed surface"
# Updating the scene texture must change the material on the very next draw.
function(gl, "glActiveTexture", None, U)(0x84C0)
function(gl, "glBindTexture", None, U, U)(0x0DE1, scene_texture)
dark = (c.c_ubyte * (W * H * 4))(*([20, 20, 20, 255] * (W * H)))
function(gl, "glTexSubImage2D", None, U, I, I, I, I, I, U, U, P)(0x0DE1, 0, 0, 0, W, H, 0x1908, 0x1401, dark)
assert pixel(render(), 247, 48) != pixel(result, 247, 48), "Stale scene texture"
function(rust, "liquid_glass_destroy", None, P)(renderer)
function(egl, "eglMakeCurrent", U, P, P, P, P)(display, None, None, None)
function(egl, "eglDestroyContext", U, P, P)(display, context)
function(egl, "eglTerminate", U, P)(display)
print("PASS: rounded alpha mask, sharp glyphs, refraction, dispersion, fade, live scene")
