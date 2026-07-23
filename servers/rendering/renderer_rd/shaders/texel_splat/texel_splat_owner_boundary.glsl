#[compute]

#version 450

#VERSION_DEFINES

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D native_color;
layout(set = 0, binding = 1) uniform sampler2D native_depth;
layout(set = 0, binding = 2) uniform usampler2D native_meta;
layout(set = 0, binding = 3) uniform sampler2D native_camera_depth;
layout(set = 0, binding = 4) uniform sampler2D native_albedo;
layout(set = 0, binding = 5) uniform sampler2D native_normal;

layout(set = 0, binding = 6, std430) restrict readonly buffer DrawState {
	mat4 view_projection;
	mat4 inverse_view_projection;
	mat4 probe_transforms[18];
	mat4 probe_inverse_transforms[18];
	vec4 params;
	vec4 grid_params;
	vec4 debug_params;
	vec4 directional_light_direction;
	vec4 directional_light_color;
	vec4 camera_position;
	vec4 transition_params;
	uvec4 probe_masks;
	vec4 reprojection_params;
	vec4 reprojection_control;
}
draw_state;

layout(rgba16f, set = 0, binding = 7) uniform restrict writeonly image2D grid_color;
layout(r32f, set = 0, binding = 8) uniform restrict writeonly image2D grid_depth;
layout(rg32ui, set = 0, binding = 9) uniform restrict writeonly uimage2D grid_meta;

const uint META_VALID = 1u;
const uint FLAG_DEBUG_EDGE = 2u;
const uint FLAG_OWNER_RAW = 8u;
const uint FLAG_OWNER_PRIMARY = 16u;
const uint FLAG_OWNER_BOUNDARY = 32u;
const uint DEBUG_VIEW_EDGE = 1u;
const uint DEBUG_VIEW_CAMERA_DISTANCE = 2u;
const uint DEBUG_VIEW_OWNER_BOUNDARY_ROLE = 15u;

// Frozen Phase 3A candidate: owner_boundary_nxn:p4:n2:agenone.
const int OWNER_PIXEL_SCALE = 4;
const int OWNER_SUBDIVISIONS = 2;
const float OWNER_DEPTH_TOLERANCE = 0.03983636695193127;
const float OWNER_NORMAL_DOT_MIN = 0.85;
const float OWNER_OKLAB_DELTA_MIN = 0.08;

struct NativeSample {
	bool valid;
	ivec2 coord;
	vec4 color;
	float clip_depth;
	float camera_depth;
	uint packed_meta;
	uint object_id;
	vec4 albedo;
	vec4 encoded_normal;
};

int ceil_div(int p_value, int p_divisor) {
	return (p_value + p_divisor - 1) / p_divisor;
}

void axis_interval(int p_presentation, int p_length, out int r_start, out int r_end, out int r_sample) {
	int coarse = p_presentation / OWNER_SUBDIVISIONS;
	int sub = p_presentation % OWNER_SUBDIVISIONS;
	int origin = coarse * OWNER_PIXEL_SCALE;
	int extent = max(min(OWNER_PIXEL_SCALE, p_length - origin), 0);
	int start_local = ceil_div(sub * extent, OWNER_SUBDIVISIONS);
	int end_local = ceil_div((sub + 1) * extent, OWNER_SUBDIVISIONS);
	r_start = origin + start_local;
	r_end = origin + end_local;
	r_sample = r_start + max(r_end - r_start - 1, 0) / 2;
}

int primary_sample(int p_presentation, int p_length) {
	int coarse = p_presentation / OWNER_SUBDIVISIONS;
	int origin = coarse * OWNER_PIXEL_SCALE;
	int extent = max(min(OWNER_PIXEL_SCALE, p_length - origin), 0);
	return origin + max(extent - 1, 0) / 2;
}

NativeSample load_native(ivec2 p_coord, ivec2 p_size) {
	NativeSample result;
	result.valid = false;
	result.coord = p_coord;
	result.color = vec4(0.0);
	result.clip_depth = 0.0;
	result.camera_depth = 0.0;
	result.packed_meta = 0u;
	result.object_id = 0u;
	result.albedo = vec4(0.0);
	result.encoded_normal = vec4(0.5, 0.5, 0.5, 0.5);
	if (any(lessThan(p_coord, ivec2(0))) || any(greaterThanEqual(p_coord, p_size))) {
		return result;
	}
	uvec2 meta = texelFetch(native_meta, p_coord, 0).rg;
	result.packed_meta = meta.x;
	result.object_id = meta.y;
	result.valid = (meta.x & META_VALID) != 0u;
	result.color = texelFetch(native_color, p_coord, 0);
	result.clip_depth = texelFetch(native_depth, p_coord, 0).r;
	result.camera_depth = texelFetch(native_camera_depth, p_coord, 0).r;
	result.albedo = texelFetch(native_albedo, p_coord, 0);
	result.encoded_normal = texelFetch(native_normal, p_coord, 0);
	return result;
}

vec3 octahedral_decode(vec2 p_encoded) {
	vec2 encoded = p_encoded * 2.0 - 1.0;
	vec3 normal = vec3(encoded, 1.0 - abs(encoded.x) - abs(encoded.y));
	if (normal.z < 0.0) {
		vec2 sign_not_zero = vec2(normal.x >= 0.0 ? 1.0 : -1.0, normal.y >= 0.0 ? 1.0 : -1.0);
		normal.xy = (vec2(1.0) - abs(normal.yx)) * sign_not_zero;
	}
	return normalize(normal);
}

vec3 linear_rgb_to_oklab(vec3 p_rgb) {
	vec3 lms = vec3(
			0.4122214708 * p_rgb.r + 0.5363325363 * p_rgb.g + 0.0514459929 * p_rgb.b,
			0.2119034982 * p_rgb.r + 0.6806995451 * p_rgb.g + 0.1073969566 * p_rgb.b,
			0.0883024619 * p_rgb.r + 0.2817188376 * p_rgb.g + 0.6299787005 * p_rgb.b);
	vec3 root = pow(max(lms, vec3(0.0)), vec3(1.0 / 3.0));
	return vec3(
			0.2104542553 * root.x + 0.7936177850 * root.y - 0.0040720468 * root.z,
			1.9779984951 * root.x - 2.4285922050 * root.y + 0.4505937099 * root.z,
			0.0259040371 * root.x + 0.7827717662 * root.y - 0.8086757660 * root.z);
}

bool samples_form_boundary(NativeSample p_a, NativeSample p_b) {
	if (p_a.valid != p_b.valid) {
		return true;
	}
	if (!p_a.valid) {
		return false;
	}
	if (p_a.object_id != p_b.object_id) {
		return true;
	}
	if (abs(p_a.camera_depth - p_b.camera_depth) > 2.0 * OWNER_DEPTH_TOLERANCE) {
		return true;
	}
	vec3 normal_a = octahedral_decode(p_a.encoded_normal.rg);
	vec3 normal_b = octahedral_decode(p_b.encoded_normal.rg);
	if (dot(normal_a, normal_b) < OWNER_NORMAL_DOT_MIN) {
		return true;
	}
	vec3 oklab_a = linear_rgb_to_oklab(clamp(p_a.albedo.rgb, vec3(0.0), vec3(1.0)));
	vec3 oklab_b = linear_rgb_to_oklab(clamp(p_b.albedo.rgb, vec3(0.0), vec3(1.0)));
	return distance(oklab_a, oklab_b) >= OWNER_OKLAB_DELTA_MIN;
}

bool native_pixel_is_boundary(ivec2 p_coord, ivec2 p_size) {
	NativeSample center = load_native(p_coord, p_size);
	if (center.valid && (p_coord.x == 0 || p_coord.y == 0 || p_coord.x == p_size.x - 1 || p_coord.y == p_size.y - 1)) {
		return true;
	}
	const ivec2 offsets[4] = ivec2[](ivec2(-1, 0), ivec2(1, 0), ivec2(0, -1), ivec2(0, 1));
	for (int index = 0; index < 4; index++) {
		ivec2 neighbor_coord = p_coord + offsets[index];
		if (any(lessThan(neighbor_coord, ivec2(0))) || any(greaterThanEqual(neighbor_coord, p_size))) {
			continue;
		}
		if (samples_form_boundary(center, load_native(neighbor_coord, p_size))) {
			return true;
		}
	}
	return false;
}

void store_invalid(ivec2 p_coord, uint p_object_id) {
	imageStore(grid_color, p_coord, vec4(0.0));
	imageStore(grid_depth, p_coord, vec4(0.0));
	imageStore(grid_meta, p_coord, uvec4(0u, p_object_id, 0u, 0u));
}

void main() {
	ivec2 grid_coord = ivec2(gl_GlobalInvocationID.xy);
	ivec2 grid_size = ivec2(draw_state.grid_params.xy);
	if (any(greaterThanEqual(grid_coord, grid_size))) {
		return;
	}

	ivec2 native_size = ivec2(draw_state.params.yz);
	int start_x;
	int end_x;
	int raw_x;
	int start_y;
	int end_y;
	int raw_y;
	axis_interval(grid_coord.x, native_size.x, start_x, end_x, raw_x);
	axis_interval(grid_coord.y, native_size.y, start_y, end_y, raw_y);
	if (start_x >= end_x || start_y >= end_y) {
		store_invalid(grid_coord, 0u);
		return;
	}

	NativeSample raw = load_native(ivec2(raw_x, raw_y), native_size);
	if (!raw.valid) {
		store_invalid(grid_coord, raw.object_id);
		return;
	}
	NativeSample primary = load_native(ivec2(primary_sample(grid_coord.x, native_size.x), primary_sample(grid_coord.y, native_size.y)), native_size);

	bool boundary_active = false;
	for (int y = 0; y < OWNER_PIXEL_SCALE; y++) {
		int native_y = start_y + y;
		if (native_y >= end_y) {
			break;
		}
		for (int x = 0; x < OWNER_PIXEL_SCALE; x++) {
			int native_x = start_x + x;
			if (native_x >= end_x) {
				break;
			}
			boundary_active = boundary_active || native_pixel_is_boundary(ivec2(native_x, native_y), native_size);
		}
	}

	bool same_continuous_surface = primary.valid &&
			raw.object_id == primary.object_id &&
			abs(raw.camera_depth - primary.camera_depth) <= 2.0 * OWNER_DEPTH_TOLERANCE;
	bool use_raw = !same_continuous_surface || boundary_active;
	NativeSample owner = use_raw ? raw : primary;
	if (!owner.valid) {
		owner = raw;
		use_raw = true;
	}

	uint owner_flag = use_raw ? FLAG_OWNER_RAW : FLAG_OWNER_PRIMARY;
	if (boundary_active) {
		owner_flag |= FLAG_OWNER_BOUNDARY;
	}
	uint packed_meta = raw.packed_meta | (owner_flag << 12u);
	uint debug_view = uint(clamp(round(draw_state.debug_params.x), 0.0, 15.0));
	vec4 color = owner.color;
	if (debug_view == DEBUG_VIEW_OWNER_BOUNDARY_ROLE) {
		if (!same_continuous_surface) {
			color = vec4(1.0, 0.08, 0.08, 1.0);
		} else if (boundary_active) {
			color = vec4(1.0, 0.48, 0.04, 1.0);
		} else if (use_raw) {
			color = vec4(0.0, 0.82, 1.0, 1.0);
		} else {
			color = vec4(0.1, 1.0, 0.25, 1.0);
		}
	} else if (debug_view == DEBUG_VIEW_EDGE) {
		uint selected_flags = (owner.packed_meta >> 12u) & 63u;
		if ((selected_flags & FLAG_DEBUG_EDGE) == 0u && !boundary_active) {
			store_invalid(grid_coord, raw.object_id);
			return;
		}
		color = vec4(1.0, 0.35, 0.05, 1.0);
	} else if (debug_view == DEBUG_VIEW_CAMERA_DISTANCE) {
		// Presentation depth belongs to the raw subcell, not its selected owner.
		color = raw.color;
	}

	imageStore(grid_color, grid_coord, color);
	imageStore(grid_depth, grid_coord, vec4(raw.clip_depth));
	imageStore(grid_meta, grid_coord, uvec4(packed_meta, raw.object_id, 0u, 0u));
}
