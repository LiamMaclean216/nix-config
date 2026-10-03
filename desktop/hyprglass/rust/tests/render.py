"""Exercise the Rust/GLES pass in surfaceless EGL, and save visual review images.

Usage: python3 tests/render.py EGL.so GLES.so libliquid_glass.so [--artifacts DIR]
Use LIBGL_ALWAYS_SOFTWARE=1 and the pinned Mesa EGL vendor for build checks.
--shader-file allows a saved earlier shader to be reviewed through the same draw
ABI. --record-only reports regression metrics without failing the baseline run.
Images use only the Python standard library; no desktop or font capture is needed.
"""
import argparse
import ctypes as c
import json
import math
import os
from pathlib import Path
import statistics
import struct
import time
import zlib

I, U, F, P = c.c_int, c.c_uint, c.c_float, c.c_void_p
SURFACE_OPACITY = float(os.environ.get("LIQUID_GLASS_SURFACE_OPACITY", ".22"))


def function(lib, name, result, *args):
    fn = getattr(lib, name)
    fn.restype, fn.argtypes = result, args
    return fn


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("egl")
parser.add_argument("gles")
parser.add_argument("renderer")
parser.add_argument("--artifacts", type=Path)
parser.add_argument("--label", default="review")
parser.add_argument("--shader-file", type=Path)
parser.add_argument("--record-only", action="store_true")
parser.add_argument("--benchmark", type=int, default=0, metavar="FRAMES")
parser.add_argument("--egl-device", type=int, metavar="INDEX", help="use an EGL device instead of surfaceless platform")
args = parser.parse_args()
egl, gl, rust = (c.CDLL(path) for path in (args.egl, args.gles, args.renderer))


def procedure(lib, name, result, *arguments):
    try:
        return function(lib, name, result, *arguments)
    except AttributeError:
        address = function(egl, "eglGetProcAddress", P, c.c_char_p)(name.encode())
        assert address, f"Missing GL/EGL procedure: {name}"
        return c.CFUNCTYPE(result, *arguments)(address)


if args.egl_device is None:
    display = function(egl, "eglGetPlatformDisplay", P, U, P, P)(0x31DD, None, None)
else:
    devices, device_count = (P * 16)(), I()
    assert procedure(egl, "eglQueryDevicesEXT", U, I, P, P)(16, devices, c.byref(device_count)), "EGL device enumeration failed"
    assert 0 <= args.egl_device < device_count.value, f"Requested EGL device is absent ({device_count.value} available)"
    display = procedure(egl, "eglGetPlatformDisplayEXT", P, U, P, P)(0x313F, devices[args.egl_device], None)
assert function(egl, "eglInitialize", U, P, P, P)(display, None, None), "EGL init failed; try --egl-device 0 for a device-only driver"
assert function(egl, "eglBindAPI", U, U)(0x30A0)
attributes = (I * 13)(0x3033, 1, 0x3040, 0x40, 0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, 0x3038)
config, count = P(), I()
assert function(egl, "eglChooseConfig", U, P, P, P, I, P)(display, attributes, c.byref(config), 1, c.byref(count)) and count.value
context = function(egl, "eglCreateContext", P, P, P, P, P)(display, config, None, (I * 3)(0x3098, 3, 0x3038))
assert context, "GLES 3 context failed"
assert function(egl, "eglMakeCurrent", U, P, P, P, P)(display, None, None, context)
renderer_name = function(gl, "glGetString", c.c_char_p, U)(0x1F01).decode()
print("Renderer:", renderer_name)


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
source = args.shader_file.read_bytes() if args.shader_file else function(rust, "liquid_glass_shader", c.c_char_p)()
fragment = shader(0x8B30, source)
program = function(gl, "glCreateProgram", U)()
for handle in (vertex, fragment):
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


class Material(c.Structure):
    _fields_ = [(name, F) for name in ("refraction", "dispersion", "fresnel", "specular", "opacity", "edge", "lens", "layer_alpha")]


renderer = function(rust, "liquid_glass_create", P, U)(program)
draw = function(rust, "liquid_glass_draw", None, P, P, U)
framebuffer, vao = U(), U()
function(gl, "glGenFramebuffers", None, I, P)(1, c.byref(framebuffer))
function(gl, "glBindFramebuffer", None, U, U)(0x8D40, framebuffer)
function(gl, "glGenVertexArrays", None, I, P)(1, c.byref(vao))
textures = []
W, H = 0, 0


def texture(unit, data):
    handle = U()
    function(gl, "glGenTextures", None, I, P)(1, c.byref(handle))
    textures.append(handle)
    function(gl, "glActiveTexture", None, U)(0x84C0 + unit)
    function(gl, "glBindTexture", None, U, U)(0x0DE1, handle)
    for name, value in ((0x2801, 0x2601), (0x2800, 0x2601), (0x2802, 0x812F), (0x2803, 0x812F)):
        function(gl, "glTexParameteri", None, U, U, I)(0x0DE1, name, value)
    pixels = (c.c_ubyte * len(data)).from_buffer_copy(data) if data else None
    function(gl, "glTexImage2D", None, U, I, I, I, I, I, U, U, P)(0x0DE1, 0, 0x1908, W, H, 0, 0x1908, 0x1401, pixels)
    return handle


def setup(width, height, background, mask, *, mask_enabled=True, radius=0):
    global W, H
    for handle in textures:
        function(gl, "glDeleteTextures", None, I, P)(1, c.byref(handle))
    textures.clear()
    W, H = width, height
    scene_texture = texture(0, background)
    texture(1, mask)
    target = texture(2, None)
    function(gl, "glFramebufferTexture2D", None, U, U, U, U, I)(0x8D40, 0x8CE0, 0x0DE1, target, 0)
    assert function(gl, "glCheckFramebufferStatus", U, U)(0x8D40) == 0x8CD5
    function(gl, "glViewport", None, I, I, I, I)(0, 0, W, H)
    for name, value in {"tex": 0, "maskTex": 1, "useMask": int(mask_enabled), "maskMode": 0, "regionRectCount": 0}.items():
        uniform(name, value, integer=True)
    uniform("fullSize", W, H)
    uniform("maskUVScale", 1, 1)
    uniform("maskUVOffset", 0, 0)
    uniform("uvPadding", 0, 0)
    uniform("maskAlphaThreshold", 0.05)
    uniform("radius", radius)
    uniform("surfaceOpacity", SURFACE_OPACITY)
    for name in ("brightness", "contrast", "saturation"):
        uniform(name, 1)
    for name in ("tintAlpha", "vibrancy", "vibrancyDarkness", "adaptiveDim", "adaptiveBoost"):
        uniform(name, 0)
    return scene_texture


def render(refraction=0.65, dispersion=0.18, opacity=1.0, fresnel=0.55, specular=0.7, edge=0.12, layer_alpha=1.0):
    material = Material(refraction, dispersion, fresnel, specular, opacity, edge, 0.0, layer_alpha)
    draw(renderer, c.byref(material), vao)
    result = (c.c_ubyte * (W * H * 4))()
    function(gl, "glReadPixels", None, I, I, I, I, U, U, P)(0, 0, W, H, 0x1908, 0x1401, result)
    assert function(gl, "glGetError", U)() == 0, "GLES error"
    return bytes(result)


def pixel(data, x, y, width=None):
    start = (y * (width or W) + x) * 4
    return data[start:start + 4]


def rounded_distance(x, y, rect, radius):
    left, bottom, width, height = rect
    qx = abs(x - left - width / 2) - width / 2 + radius
    qy = abs(y - bottom - height / 2) - height / 2 + radius
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius


def rounded_mask(width, height, rect, radius, opacity=SURFACE_OPACITY):
    """8x8 area reference only at the one-pixel contour, premultiplied GTK tint."""
    data, coverage = bytearray(), []
    for y in range(height):
        for x in range(width):
            d = rounded_distance(x + 0.5, y + 0.5, rect, radius)
            if abs(d) > 0.75:
                area = float(d < 0)
            else:
                area = sum(rounded_distance(x + (sx + .5) / 8, y + (sy + .5) / 8, rect, radius) < 0
                           for sy in range(8) for sx in range(8)) / 64
            coverage.append(area)
            alpha = round(255 * opacity * area)
            data.extend((round(alpha * .045), round(alpha * .05), round(alpha * .065), alpha))
    return data, coverage


metrics = {"renderer": renderer_name, "label": args.label}
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)
        if not args.record_only:
            raise AssertionError(message)


def regression_checks():
    width, height = 320, 96
    background = bytearray()
    for y in range(height):
        for x in range(width):
            gray = 210 if (x // 7 + y // 7) % 2 else 45
            background.extend((gray, gray, gray, 255))
    mask, coverage = rounded_mask(width, height, (187.35, 18.25, 120, 60), 18)
    for y in range(40, 55):
        for x in range(220, 225):
            start = (y * width + x) * 4
            mask[start:start + 4] = bytes((244, 233, 218, 255))
    scene_texture = setup(width, height, background, mask)
    result = render()
    check(pixel(result, 50, 48) == bytes((0, 0, 0, 0)), "Glass leaked outside clock")
    check(pixel(result, 188, 19) == bytes((0, 0, 0, 0)), "Glass filled rounded corner")
    check(pixel(result, 222, 45) == bytes((244, 233, 218, 255)), "Foreground glyph distorted")
    plain = render(refraction=0.0)
    check(sum(a != b for a, b in zip(result, plain)) > 200, "Refraction did not move backdrop")
    achromatic = render(dispersion=0.0)
    check(sum(a != b for a, b in zip(result, achromatic)) > 100, "Spectral effects missing")
    faded = render(opacity=0.25)
    expected_alpha = 255 * (SURFACE_OPACITY + .25 * (1 - SURFACE_OPACITY))
    check(abs(pixel(faded, 247, 48)[3] - expected_alpha) < 3, "Material opacity is not premultiplied")
    zero = render(opacity=0.0)
    check(zero == bytes(mask), "Zero opacity changed surface")
    errors = [abs(result[i * 4 + 3] / 255 - area) for i, area in enumerate(coverage) if .05 < area < .95]
    metrics["mask_boundary_alpha_mean_error"] = round(statistics.mean(errors), 5)
    metrics["mask_boundary_alpha_max_error"] = round(max(errors), 5)
    metrics["mask_boundary_samples"] = len(errors)
    check(statistics.mean(errors) < .10, "Masked glass discarded GTK antialias coverage")
    check(max(errors) < .25, "Masked glass has an opaque step on its silhouette")
    # Updating the scene texture must change the material on the very next draw.
    function(gl, "glActiveTexture", None, U)(0x84C0)
    function(gl, "glBindTexture", None, U, U)(0x0DE1, scene_texture)
    dark = (c.c_ubyte * (width * height * 4))(*([20, 20, 20, 255] * (width * height)))
    function(gl, "glTexSubImage2D", None, U, I, I, I, I, I, U, U, P)(0x0DE1, 0, 0, 0, width, height, 0x1908, 0x1401, dark)
    check(pixel(render(), 247, 48) != pixel(result, 247, 48), "Stale scene texture")
    # Analytic rounded windows must also integrate the subpixel boundary.
    setup(width, height, background, bytes(width * height * 4), mask_enabled=False, radius=24)
    analytic = render()
    _, analytic_coverage = rounded_mask(width, height, (0, 0, width, height), 24)
    errors = [abs(analytic[i * 4 + 3] / 255 - area) for i, area in enumerate(analytic_coverage) if .05 < area < .95]
    metrics["analytic_boundary_alpha_mean_error"] = round(statistics.mean(errors), 5)
    check(statistics.mean(errors) < .10, "Analytic rounded glass has an aliased boundary")
    # GTK CSS animation fades the entire pre-rendered foreground and silhouette.
    # Completing pane opacity must respect that animation, including its glyphs.
    full_mask, _ = rounded_mask(width, height, (0, 0, width, height), 24)
    for y in range(40, 55):
        for x in range(220, 225):
            start = (y * width + x) * 4
            full_mask[start:start + 4] = bytes((244, 233, 218, 255))
    quarter_mask = bytes(round(value * .25) for value in full_mask)
    setup(width, height, background, quarter_mask, radius=24)
    gtk_fade = render()
    check(62 <= pixel(gtk_fade, 160, 48)[3] <= 66, "Glass bypassed GTK's CSS fade")
    check(pixel(gtk_fade, 222, 45) == pixel(quarter_mask, 222, 45), "GTK faded foreground gained a glass ghost")
    # Hyprland's compositor fade enters both the surface and material uniforms.
    # Applying it twice would reduce the pane to 6% instead of the intended 25%.
    compositor_fade = render(opacity=.25, layer_alpha=.25)
    check(62 <= pixel(compositor_fade, 160, 48)[3] <= 66, "Compositor fade was applied twice or ignored")
    check(pixel(compositor_fade, 222, 45) == pixel(quarter_mask, 222, 45), "Compositor faded foreground gained a glass ghost")
    setup(width, height, background, bytes(width * height * 4), radius=24)
    check(render() == bytes(width * height * 4), "Glass remained after GTK faded to zero")
    check(render(opacity=0, layer_alpha=0) == bytes(width * height * 4), "Glass remained after compositor faded to zero")


# A small vector-like bitmap font with fractional rectangle edges. Rendering text
# to the mask exercises foreground compositing without platform font dependencies.
FONT = {
    '0': '01110 10001 10011 10101 11001 10001 01110', '1': '00100 01100 00100 00100 00100 00100 01110',
    '2': '01110 10001 00001 00010 00100 01000 11111', '3': '11110 00001 00001 01110 00001 00001 11110',
    '4': '00010 00110 01010 10010 11111 00010 00010', '5': '11111 10000 10000 11110 00001 00001 11110',
    '6': '01110 10000 10000 11110 10001 10001 01110', '7': '11111 00001 00010 00100 01000 01000 01000',
    '8': '01110 10001 10001 01110 10001 10001 01110', '9': '01110 10001 10001 01111 00001 00001 01110',
    ':': '00000 00100 00100 00000 00100 00100 00000', 'A': '01110 10001 10001 11111 10001 10001 10001',
    'B': '11110 10001 10001 11110 10001 10001 11110', 'C': '01111 10000 10000 10000 10000 10000 01111',
    'D': '11110 10001 10001 10001 10001 10001 11110', 'E': '11111 10000 10000 11110 10000 10000 11111',
    'F': '11111 10000 10000 11110 10000 10000 10000', 'G': '01111 10000 10000 10111 10001 10001 01111',
    'H': '10001 10001 10001 11111 10001 10001 10001', 'I': '01110 00100 00100 00100 00100 00100 01110',
    'J': '00001 00001 00001 00001 10001 10001 01110', 'K': '10001 10010 10100 11000 10100 10010 10001',
    'L': '10000 10000 10000 10000 10000 10000 11111', 'M': '10001 11011 10101 10101 10001 10001 10001',
    'N': '10001 11001 10101 10011 10001 10001 10001', 'O': '01110 10001 10001 10001 10001 10001 01110',
    'P': '11110 10001 10001 11110 10000 10000 10000', 'Q': '01110 10001 10001 10001 10101 10010 01101',
    'R': '11110 10001 10001 11110 10100 10010 10001', 'S': '01111 10000 10000 01110 00001 00001 11110',
    'T': '11111 00100 00100 00100 00100 00100 00100', 'U': '10001 10001 10001 10001 10001 10001 01110',
    'V': '10001 10001 10001 10001 10001 01010 00100', 'W': '10001 10001 10001 10101 10101 10101 01010',
    'X': '10001 10001 01010 00100 01010 10001 10001', 'Y': '10001 10001 01010 00100 00100 00100 00100',
    'Z': '11111 00001 00010 00100 01000 10000 11111', '.': '00000 00000 00000 00000 00000 00100 00100',
    '>': '00000 10000 01000 00100 01000 10000 00000', '/': '00001 00010 00010 00100 01000 01000 10000',
    '-': '00000 00000 00000 11111 00000 00000 00000', ' ': '00000 00000 00000 00000 00000 00000 00000',
}


def overlay_rect(data, width, height, rect, color, radius=0):
    left, bottom, rw, rh = rect
    for y in range(max(0, math.floor(bottom - 1)), min(height, math.ceil(bottom + rh + 1))):
        for x in range(max(0, math.floor(left - 1)), min(width, math.ceil(left + rw + 1))):
            coverage = max(0, min(1, .5 - rounded_distance(x + .5, y + .5, rect, radius)))
            alpha = coverage * color[3] / 255
            start = (y * width + x) * 4
            for channel in range(3):
                data[start + channel] = round(color[channel] * alpha + data[start + channel] * (1 - alpha))
            data[start + 3] = round(255 * alpha + data[start + 3] * (1 - alpha))


def text(data, width, height, content, x, y, scale=2, color=(235, 237, 243, 255)):
    for char in content.upper():
        for row, cells in enumerate(FONT.get(char, FONT[' ']).split()):
            for column, cell in enumerate(cells):
                if cell == '1':
                    overlay_rect(data, width, height, (x + column * scale, y + (6 - row) * scale, scale, scale), color)
        x += scale * 6


def desktop_background(width, height):
    data = bytearray()
    for y in range(height):
        for x in range(width):
            u, v = x / width, y / height
            blue = math.exp(-((u - .18) ** 2 + (v - .4) ** 2) / .11)
            violet = math.exp(-((u - .55) ** 2 + (v - .8) ** 2) / .2)
            amber = math.exp(-((u - .9) ** 2 + (v - .15) ** 2) / .055)
            wave = .5 + .5 * math.sin(u * 10 + v * 5 + 2 * math.sin(v * 4))
            data.extend((int(15 + violet * 74 + amber * 137 + wave * 9),
                         int(24 + blue * 78 + amber * 66 + wave * 9),
                         int(38 + blue * 101 + violet * 88 + wave * 16), 255))
    overlay_rect(data, width, height, (55, 100, 600, 335), (18, 23, 34, 228), 16)
    overlay_rect(data, width, height, (55, 402, 600, 33), (32, 39, 54, 242), 12)
    for i, color in enumerate(((236, 111, 114, 255), (233, 197, 109, 255), (118, 203, 150, 255))):
        overlay_rect(data, width, height, (73 + i * 17, 414, 9, 9), color, 4.5)
    text(data, width, height, 'NIX CONFIG / DESKTOP', 165.2, 413.6, 1.5, (158, 169, 188, 255))
    lines = (
        ('> CARGO BUILD --RELEASE', (120, 210, 178, 255)),
        ('COMPILING LIQUID GLASS', (116, 166, 214, 255)),
        ('FINISHED OPTIMIZED TARGET', (158, 173, 188, 255)),
        ('> GPU LIVE BACKDROP', (120, 210, 178, 255)),
        ('REFRACTION / DISPERSION', (206, 159, 229, 255)),
        ('> SHADER READY', (120, 210, 178, 255)),
    )
    for i, (line, color) in enumerate(lines):
        text(data, width, height, line, 79.3, 365.4 - i * 39, 2.1, color)
    return data


def backdrop_blur(data, width, height, radius=4, passes=3):
    """Three separable box passes approximate the compositor's backdrop blur."""
    data = bytes(data)
    for _ in range(passes):
        horizontal, vertical = bytearray(len(data)), bytearray(len(data))
        for channel in range(4):
            for y in range(height):
                row = data[(y * width) * 4 + channel:((y + 1) * width) * 4:4]
                padded = bytes((row[0],)) * radius + row + bytes((row[-1],)) * radius
                total = sum(padded[:radius * 2 + 1])
                for x in range(width):
                    horizontal[(y * width + x) * 4 + channel] = round(total / (radius * 2 + 1))
                    if x + 1 < width:
                        total += padded[x + radius * 2 + 1] - padded[x]
            for x in range(width):
                column = horizontal[x * 4 + channel::width * 4]
                padded = bytes((column[0],)) * radius + column + bytes((column[-1],)) * radius
                total = sum(padded[:radius * 2 + 1])
                for y in range(height):
                    vertical[(y * width + x) * 4 + channel] = round(total / (radius * 2 + 1))
                    if y + 1 < height:
                        total += padded[y + radius * 2 + 1] - padded[y]
        data = vertical
    return data


def crop(data, width, rect):
    left, bottom, rw, rh = rect
    return b''.join(data[((bottom + row) * width + left) * 4:((bottom + row) * width + left + rw) * 4] for row in range(rh))


def composite(surface, background):
    out = bytearray(len(surface))
    for i in range(0, len(surface), 4):
        alpha = surface[i + 3] / 255
        for channel in range(3):
            out[i + channel] = min(255, round(surface[i + channel] + background[i + channel] * (1 - alpha)))
        out[i + 3] = 255
    return out


def paste(data, width, image, iw, ih, left, bottom):
    for row in range(ih):
        start = ((bottom + row) * width + left) * 4
        data[start:start + iw * 4] = image[row * iw * 4:(row + 1) * iw * 4]


def scale_nearest(data, width, height, scale):
    out = bytearray()
    for y in range(height):
        row = b''.join(data[(y * width + x) * 4:(y * width + x + 1) * 4] * scale for x in range(width))
        out.extend(row * scale)
    return out


def png(path, width, height, data):
    def chunk(kind, payload):
        return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload))
    # GL rows are bottom-up; PNG rows are top-down.
    scanlines = b''.join(b'\0' + data[y * width * 4:(y + 1) * width * 4] for y in range(height - 1, -1, -1))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(scanlines, 6)) + chunk(b'IEND', b''))


def benchmark(frames):
    """GPU elapsed query when available; draw+finish wall time is also reported."""
    material = Material(.65, .18, .55, .7, 1, .12, 0, 1)
    finish = function(gl, "glFinish", None)
    extensions = function(gl, "glGetString", c.c_char_p, U)(0x1F03).decode().split()
    timer = 'GL_EXT_disjoint_timer_query' in extensions
    query = U()
    if timer:
        generate = procedure(gl, "glGenQueriesEXT", None, I, P)
        begin = procedure(gl, "glBeginQueryEXT", None, U, U)
        end = procedure(gl, "glEndQueryEXT", None, U)
        result = procedure(gl, "glGetQueryObjectui64vEXT", None, U, U, P)
        remove = procedure(gl, "glDeleteQueriesEXT", None, I, P)
        generate(1, c.byref(query))
    for _ in range(5):
        draw(renderer, c.byref(material), vao)
    finish()
    timings, gpu_timings = [], []
    for _ in range(frames):
        start = time.perf_counter()
        if timer:
            begin(0x88BF, query)
        draw(renderer, c.byref(material), vao)
        if timer:
            end(0x88BF)
        finish()
        timings.append((time.perf_counter() - start) * 1000)
        if timer:
            nanoseconds, disjoint = c.c_uint64(), I()
            result(query, 0x8866, c.byref(nanoseconds))
            function(gl, "glGetIntegerv", None, U, P)(0x8FBB, c.byref(disjoint))
            if not disjoint.value:
                gpu_timings.append(nanoseconds.value / 1_000_000)
    report = {"median_draw_finish_wall_ms": round(statistics.median(timings), 3),
              "p95_draw_finish_wall_ms": round(sorted(timings)[min(len(timings) - 1, int(len(timings) * .95))], 3),
              "frames": frames, "surface_size": [W, H],
              "timer": 'GL_EXT_disjoint_timer_query' if gpu_timings else 'draw+glFinish wall clock fallback'}
    if gpu_timings:
        report['median_gpu_ms'] = round(statistics.median(gpu_timings), 3)
        report['p95_gpu_ms'] = round(sorted(gpu_timings)[min(len(gpu_timings) - 1, int(len(gpu_timings) * .95))], 3)
        report['valid_gpu_samples'] = len(gpu_timings)
    if timer:
        remove(1, c.byref(query))
    return report


def benchmark_cases(frames):
    # Include the old transparent screen-wide Waybar and the tightened clock
    # viewport, because the expensive pixels differ from the GTK buffer size.
    for label, width, height, rect, radius, analytic in (
        ('wofi', 620, 460, (0, 0, 620, 460), 28, True),
        ('waybar_full_surface', 3435, 40, (3211, 0, 224, 40), 20, False),
        ('waybar_tight_pill', 224, 40, (0, 0, 224, 40), 20, True),
    ):
        background = bytes((53, 78, 110, 255)) * (width * height)
        mask, _ = rounded_mask(width, height, rect, radius)
        setup(width, height, background, mask, radius=radius if analytic else 0)
        metrics[f'{label}_benchmark'] = benchmark(frames)


def visual_artifacts():
    args.artifacts.mkdir(parents=True, exist_ok=True)
    background = desktop_background(960, 540)
    blurred_background = backdrop_blur(background, 960, 540)
    overview = bytearray(background)
    scenes = (
        ('wofi', (220, 108, 520, 390), (18, 18, 484, 354), 26),
        ('clock', (0, 0, 960, 112), (716, 24, 224, 66), 24),
    )
    for label, scene_rect, shape, radius in scenes:
        left, bottom, width, height = scene_rect
        backdrop = crop(background, 960, scene_rect)
        mask, _ = rounded_mask(width, height, shape, radius)
        if label == 'clock':
            text(mask, width, height, '15:48', 761.3, 50.4, 3.6)
            text(mask, width, height, 'SAT OCT 3', 764.6, 34.3, 1.6, (196, 202, 217, 255))
        else:
            overlay_rect(mask, width, height, (39.2, 303.4, 443, 48), (226, 235, 249, 16), 12)
            text(mask, width, height, 'TYPE TO SEARCH...', 59.4, 320.2, 2.5, (180, 188, 204, 255))
            overlay_rect(mask, width, height, (39.2, 233.4, 443, 53), (196, 215, 248, 30), 12)
            for i, (label_text, color) in enumerate((('FIREFOX', (225, 139, 70, 255)), ('TERMINAL', (126, 211, 159, 255)), ('FILES', (110, 163, 221, 255)), ('SETTINGS', (183, 169, 217, 255)))):
                y = 251.3 - i * 56
                overlay_rect(mask, width, height, (56.3, y - 6.5, 25, 25), color, 7)
                text(mask, width, height, label_text, 100.4, y - 2.4, 2.5)
            text(mask, width, height, '4 APPLICATIONS', 57.4, 43.6, 1.6, (161, 171, 190, 255))
        sx, sy, sw, sh = shape
        tight_backdrop = crop(blurred_background, 960, (left + sx, bottom + sy, sw, sh))
        tight_mask = crop(mask, width, shape)
        setup(sw, sh, tight_backdrop, tight_mask, radius=radius)
        tight_surface = render()
        surface = bytearray(width * height * 4)
        paste(surface, width, tight_surface, sw, sh, sx, sy)
        image = composite(surface, backdrop)
        png(args.artifacts / f'{args.label}-{label}.png', width, height, image)
        png(args.artifacts / f'{args.label}-{label}-surface.png', width, height, surface)
        paste(overview, 960, image, width, height, left, bottom)
        edge_rect = (700, 14, 96, 88) if label == 'clock' else (9, 271, 96, 108)
        edge = crop(image, width, edge_rect)
        ew, eh = edge_rect[2:]
        png(args.artifacts / f'{args.label}-{label}-edge-4x.png', ew * 4, eh * 4, scale_nearest(edge, ew, eh, 4))
    png(args.artifacts / f'{args.label}-overview.png', 960, 540, overview)
    png(args.artifacts / 'desktop-background.png', 960, 540, background)
    png(args.artifacts / 'desktop-blurred-background.png', 960, 540, blurred_background)


regression_checks()
if args.artifacts:
    visual_artifacts()
if args.benchmark:
    benchmark_cases(args.benchmark)
metrics['failures'] = failures
print(json.dumps(metrics, indent=2))
if args.artifacts:
    (args.artifacts / f'{args.label}-metrics.json').write_text(json.dumps(metrics, indent=2) + '\n')
    print('Visual artifacts:', args.artifacts)
function(rust, "liquid_glass_destroy", None, P)(renderer)
function(egl, "eglMakeCurrent", U, P, P, P, P)(display, None, None, None)
function(egl, "eglDestroyContext", U, P, P)(display, context)
function(egl, "eglTerminate", U, P)(display)
print('PASS: rounded coverage, sharp glyphs, refraction, dispersion, GTK/compositor fades, live scene' if not failures else 'BASELINE REGRESSIONS RECORDED')
