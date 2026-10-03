//! The optical render pass runs in Hyprland's existing GLES context.
//! C++ retains compositor-private objects, texture capture and damage tracking;
//! Rust owns the material validation, optical uniforms and GPU draw submission.
use std::ffi::{c_char, c_void};

static SHADER: &str = concat!(include_str!("liquid.frag"), "\0");

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Material {
    pub refraction: f32,
    pub dispersion: f32,
    pub fresnel: f32,
    pub specular: f32,
    pub opacity: f32,
    pub edge: f32,
    pub lens: f32,
}

fn bounded(value: f32, fallback: f32, min: f32, max: f32) -> f32 {
    if value.is_finite() { value.clamp(min, max) } else { fallback }
}

impl Material {
    fn uniforms(self) -> [f32; 7] {
        [
            bounded(self.refraction, 0.65, 0.0, 2.0),
            bounded(self.dispersion, 0.18, 0.0, 1.0),
            bounded(self.fresnel, 0.55, 0.0, 2.0),
            bounded(self.specular, 0.7, 0.0, 2.0),
            bounded(self.opacity, 0.0, 0.0, 1.0),
            bounded(self.edge, 0.12, 0.01, 0.5),
            bounded(self.lens, 0.12, 0.0, 1.0),
        ]
    }
}

#[link(name = "GLESv2")]
extern "C" {
    fn glGetUniformLocation(program: u32, name: *const c_char) -> i32;
    fn glUniform1f(location: i32, value: f32);
    fn glBindVertexArray(array: u32);
    fn glDrawArrays(mode: u32, first: i32, count: i32);
}

struct Renderer {
    locations: [i32; 7],
}

#[no_mangle]
pub extern "C" fn liquid_glass_shader() -> *const c_char {
    SHADER.as_ptr().cast()
}

/// # Safety
/// Call on the compositor render thread with a current GLES context and a linked
/// program using liquid_glass_shader(). The returned handle must be destroyed once.
#[no_mangle]
pub unsafe extern "C" fn liquid_glass_create(program: u32) -> *mut c_void {
    let names: [&[u8]; 7] = [
        b"refractionStrength\0", b"chromaticAberration\0", b"fresnelStrength\0",
        b"specularStrength\0", b"glassOpacity\0", b"edgeThickness\0", b"lensDistortion\0",
    ];
    let locations = names.map(|name| glGetUniformLocation(program, name.as_ptr().cast()));
    Box::into_raw(Box::new(Renderer { locations })).cast()
}

/// # Safety
/// Handle must be null or a live handle from liquid_glass_create, freed only once.
#[no_mangle]
pub unsafe extern "C" fn liquid_glass_destroy(handle: *mut c_void) {
    if !handle.is_null() {
        drop(Box::from_raw(handle.cast::<Renderer>()));
    }
}

/// Draws without allocating, querying GL state, or reading desktop pixels to CPU.
/// # Safety
/// Handle must be live; material must point to an initialized Material. Its program,
/// framebuffer, projection, textures and scissor must already be bound by Hyprland.
/// vao must be Hyprland's four-vertex texture quad in the current GLES context.
#[no_mangle]
pub unsafe extern "C" fn liquid_glass_draw(handle: *const c_void, material: *const Material, vao: u32) {
    if handle.is_null() || material.is_null() {
        return;
    }
    let renderer = &*handle.cast::<Renderer>();
    for (location, value) in renderer.locations.iter().zip((*material).uniforms()) {
        glUniform1f(*location, value);
    }
    glBindVertexArray(vao);
    glDrawArrays(0x0005, 0, 4); // GL_TRIANGLE_STRIP
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn material_rejects_non_finite_and_out_of_range_config() {
        let material = Material { refraction: f32::NAN, dispersion: 9.0,
            fresnel: -1.0, specular: f32::INFINITY, opacity: f32::NAN,
            edge: 0.0, lens: -9.0 };
        assert_eq!(material.uniforms(), [0.65, 1.0, 0.0, 0.7, 0.0, 0.01, 0.0]);
    }

    #[test]
    fn fade_alpha_and_disabled_optics_survive_validation() {
        let material = Material { refraction: 0.0, dispersion: 0.0, fresnel: 0.0,
            specular: 0.0, opacity: 0.25, edge: 0.12, lens: 0.0 };
        assert_eq!(material.uniforms(), [0.0, 0.0, 0.0, 0.0, 0.25, 0.12, 0.0]);
        assert_eq!(std::mem::size_of::<Material>(), 28);
        assert_eq!(std::mem::align_of::<Material>(), 4);
    }

    #[test]
    fn shader_is_a_single_c_string() {
        let source = std::ffi::CStr::from_bytes_with_nul(SHADER.as_bytes()).unwrap();
        assert!(source.to_str().unwrap().starts_with("#version 300 es"));
    }
}
