#[compute]

#version 450

#VERSION_DEFINES

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2DArray probe_albedo;
layout(set = 0, binding = 1) uniform sampler2DArray probe_normal;
layout(set = 0, binding = 2) uniform sampler2DArray probe_radial;
layout(set = 0, binding = 3) uniform usampler2DArray probe_object_id;

layout(set = 0, binding = 4, std430) restrict readonly buffer SplatFlags {
	uint data[];
}
splat_flags;

layout(set = 0, binding = 5, std430) restrict readonly buffer DrawState {
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

layout(rgba16f, set = 0, binding = 6) uniform restrict writeonly image2D grid_color;
layout(r32f, set = 0, binding = 7) uniform restrict writeonly image2D grid_depth;
layout(rg32ui, set = 0, binding = 8) uniform restrict writeonly uimage2D grid_meta;
layout(r32f, set = 0, binding = 9) uniform restrict writeonly image2D native_camera_depth;
layout(rgba16f, set = 0, binding = 10) uniform restrict writeonly image2D native_albedo;
layout(rgba16f, set = 0, binding = 11) uniform restrict writeonly image2D native_normal;

const uint FLAG_DEBUG_EDGE = 2u;
const uint FLAG_ALTERNATE_ROLE_FILL = 4u;
const uint META_VALID = 1u;
const uint SOURCE_EYE = 0u;
const uint SOURCE_CURRENT = 1u;
const uint SOURCE_PREVIOUS = 2u;

const uint SOURCE_MODE_COMPOSED = 0u;
const uint SOURCE_MODE_EYE_ONLY = 1u;
const uint SOURCE_MODE_CURRENT_ONLY = 2u;
const uint SOURCE_MODE_PREVIOUS_ONLY = 3u;

const uint FALLBACK_NONE = 0u;
const uint FALLBACK_EYE_DIRECT = 1u;
const uint FALLBACK_CURRENT_INACTIVE = 2u;
const uint FALLBACK_CURRENT_SAMPLE_INVALID = 3u;
const uint FALLBACK_CURRENT_NO_NEGATIVE_SIDE = 4u;
const uint FALLBACK_CURRENT_NO_BRACKET = 5u;
const uint FALLBACK_CURRENT_OBJECT_DISCONTINUITY = 6u;
const uint FALLBACK_CURRENT_NON_MONOTONIC = 7u;
const uint FALLBACK_CURRENT_OBJECT_MISMATCH_EYE = 8u;
const uint FALLBACK_CURRENT_DEPTH_IN_FRONT = 9u;
const uint FALLBACK_CURRENT_DEPTH_BEHIND = 10u;
const uint FALLBACK_EYE_INVALID = 11u;
const uint FALLBACK_CURRENT_OUT_OF_RANGE = 12u;
const uint FALLBACK_CURRENT_NONFINITE = 13u;
const uint FALLBACK_PREVIOUS_UNAVAILABLE = 14u;
const uint FALLBACK_GRID_NORMAL_MISMATCH = 15u;

struct ProbeSample {
	bool valid;
	uint layer;
	vec2 uv;
	vec3 probe_ray;
	ivec2 probe_coord;
	uint object_id;
	float radial_depth;
};

vec3 hash_color(uint value) {
	value ^= value >> 16;
	value *= 0x7feb352du;
	value ^= value >> 15;
	value *= 0x846ca68bu;
	value ^= value >> 16;
	return vec3(
			float(value & 255u),
			float((value >> 8) & 255u),
			float((value >> 16) & 255u)) / 255.0;
}

vec3 srgb_code_to_linear(vec3 p_srgb) {
	return mix(p_srgb / 12.92, pow((p_srgb + 0.055) / 1.055, vec3(2.4)), greaterThan(p_srgb, vec3(0.04045)));
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

bool finite_vec2(vec2 p_value) {
	return !any(isnan(p_value)) && !any(isinf(p_value));
}

bool finite_vec3(vec3 p_value) {
	return !any(isnan(p_value)) && !any(isinf(p_value));
}

bool finite_vec4(vec4 p_value) {
	return !any(isnan(p_value)) && !any(isinf(p_value));
}

uint texel_index(uint p_layer, ivec2 p_coord, uint p_probe_size) {
	return (p_layer * p_probe_size + uint(p_coord.y)) * p_probe_size + uint(p_coord.x);
}

float max_abs(vec3 p_value) {
	return max(abs(p_value.x), max(abs(p_value.y), abs(p_value.z)));
}

uint pack_meta(bool p_valid, uint p_layer, uint p_source_role, uint p_fallback_reason, uint p_flags, uint p_step_count) {
	return (p_valid ? META_VALID : 0u) |
			((p_layer & 31u) << 1u) |
			((p_source_role & 3u) << 6u) |
			((p_fallback_reason & 15u) << 8u) |
			((p_flags & 63u) << 12u) |
			((p_step_count & 255u) << 18u);
}

void store_invalid(ivec2 p_grid_coord, uint p_fallback_reason, uint p_object_id, uint p_step_count) {
	imageStore(grid_color, p_grid_coord, vec4(0.0));
	imageStore(grid_depth, p_grid_coord, vec4(0.0));
	imageStore(grid_meta, p_grid_coord, uvec4(pack_meta(false, 0u, SOURCE_EYE, p_fallback_reason, 0u, p_step_count), p_object_id, 0u, 0u));
}

ProbeSample invalid_probe_sample() {
	ProbeSample result;
	result.valid = false;
	result.layer = 0u;
	result.uv = vec2(0.0);
	result.probe_ray = vec3(0.0, 0.0, -1.0);
	result.probe_coord = ivec2(0);
	result.object_id = 0u;
	result.radial_depth = 0.0;
	return result;
}

bool select_probe_face(vec3 p_world_direction, uint p_probe_index, uint p_active_face_mask, out uint r_layer, out vec2 r_uv, out vec3 r_probe_ray) {
	float best_score = -1.0;
	bool found = false;
	r_layer = p_probe_index * 6u;
	r_uv = vec2(0.0);
	r_probe_ray = vec3(0.0, 0.0, -1.0);

	for (uint face = 0u; face < 6u; face++) {
		if ((p_active_face_mask & (1u << face)) == 0u) {
			continue;
		}
		uint layer = p_probe_index * 6u + face;
		vec3 probe_ray = (draw_state.probe_inverse_transforms[layer] * vec4(p_world_direction, 0.0)).xyz;
		if (!finite_vec3(probe_ray)) {
			continue;
		}
		float forward = -probe_ray.z;
		if (forward <= 0.0) {
			continue;
		}
		float major = max(abs(probe_ray.x), max(abs(probe_ray.y), abs(probe_ray.z)));
		if (major <= 0.0 || abs(probe_ray.z) + 0.000001 < major) {
			continue;
		}
		vec2 face_xy = probe_ray.xy / forward;
		if (any(lessThan(face_xy, vec2(-1.000001))) || any(greaterThan(face_xy, vec2(1.000001)))) {
			continue;
		}
		float score = forward / major;
		if (score > best_score) {
			best_score = score;
			r_layer = layer;
			r_uv = clamp(face_xy * 0.5 + 0.5, vec2(0.0), vec2(0.999999));
			r_probe_ray = normalize(probe_ray);
			found = true;
		}
	}

	return found;
}

ProbeSample sample_probe_direction(vec3 p_world_direction, uint p_probe_index, uint p_active_face_mask) {
	ProbeSample result = invalid_probe_sample();
	if (!finite_vec3(p_world_direction) || dot(p_world_direction, p_world_direction) <= 0.000001) {
		return result;
	}
	if (!select_probe_face(normalize(p_world_direction), p_probe_index, p_active_face_mask, result.layer, result.uv, result.probe_ray)) {
		return result;
	}

	uint probe_size = uint(draw_state.params.x);
	result.probe_coord = ivec2(clamp(floor(result.uv * float(probe_size)), vec2(0.0), vec2(float(probe_size - 1u))));
	ivec3 sample_coord = ivec3(result.probe_coord, int(result.layer));
	result.object_id = texelFetch(probe_object_id, sample_coord, 0).r;
	result.radial_depth = texelFetch(probe_radial, sample_coord, 0).r;
	result.valid = result.object_id != 0u && result.radial_depth > 0.0 && !isnan(result.radial_depth) && !isinf(result.radial_depth);
	return result;
}

bool resolve_eye(vec3 p_world_ray, out ProbeSample r_sample, out float r_t_hit) {
	r_sample = sample_probe_direction(p_world_ray, 0u, draw_state.probe_masks.x & 0x3fu);
	r_t_hit = 0.0;
	if (!r_sample.valid) {
		return false;
	}
	float denom = max_abs(r_sample.probe_ray);
	r_t_hit = r_sample.radial_depth / max(denom, 0.000001);
	return r_t_hit > 0.0 && !isnan(r_t_hit) && !isinf(r_t_hit);
}

float grid_tolerance_for_radial(float p_radial_depth) {
	float min_tolerance = max(draw_state.reprojection_params.x, 0.0001);
	float grid_cap = max(min_tolerance, max(draw_state.grid_params.w, 0.001) * 0.25);
	float max_tolerance = max(min_tolerance, min(draw_state.reprojection_params.y, grid_cap));
	float texel_tolerance = p_radial_depth / max(draw_state.params.x, 1.0) * max(draw_state.reprojection_params.z, 0.25);
	return clamp(max(min_tolerance, texel_tolerance), min_tolerance, max_tolerance);
}

bool evaluate_grid_probe(vec3 p_world_ray, float p_t, uint p_probe_index, uint p_face_mask, out ProbeSample r_sample, out float r_residual, out float r_tolerance) {
	vec3 probe_origin = draw_state.probe_transforms[p_probe_index * 6u][3].xyz;
	vec3 probe_offset = draw_state.camera_position.xyz + p_world_ray * p_t - probe_origin;
	float radial_position = max_abs(probe_offset);
	r_residual = 0.0;
	r_tolerance = max(draw_state.reprojection_params.x, 0.0001);
	r_sample = invalid_probe_sample();
	if (radial_position <= 0.000001 || !finite_vec3(probe_offset)) {
		return false;
	}
	r_sample = sample_probe_direction(probe_offset, p_probe_index, p_face_mask & 0x3fu);
	if (!r_sample.valid) {
		return false;
	}
	r_residual = radial_position - r_sample.radial_depth;
	r_tolerance = grid_tolerance_for_radial(r_sample.radial_depth);
	return !isnan(r_residual) && !isinf(r_residual) && !isnan(r_tolerance) && !isinf(r_tolerance);
}

bool resolve_grid_probe(vec3 p_world_ray, float p_t_near, ProbeSample p_eye_sample, float p_eye_t_hit, uint p_probe_index, uint p_face_mask, out ProbeSample r_sample, out float r_t_hit, out float r_tolerance, out uint r_failure_reason, out uint r_step_count) {
	r_sample = invalid_probe_sample();
	r_t_hit = 0.0;
	r_tolerance = max(draw_state.reprojection_params.x, 0.0001);
	r_failure_reason = FALLBACK_CURRENT_NO_BRACKET;
	r_step_count = 0u;

	if (p_probe_index == 0u || p_probe_index >= 3u || (p_face_mask & 0x3fu) == 0u) {
		r_failure_reason = FALLBACK_CURRENT_INACTIVE;
		return false;
	}

	vec3 probe_origin = draw_state.probe_transforms[p_probe_index * 6u][3].xyz;
	vec3 eye_hit_offset = draw_state.camera_position.xyz + p_world_ray * p_eye_t_hit - probe_origin;
	if (!finite_vec3(eye_hit_offset)) {
		r_failure_reason = FALLBACK_CURRENT_NONFINITE;
		return false;
	}
	r_tolerance = grid_tolerance_for_radial(max_abs(eye_hit_offset));
	float search_back_scale = max(draw_state.reprojection_control.z, 1.0);
	float search_forward_scale = max(draw_state.reprojection_params.w, 0.25);
	float search_start = max(p_t_near, p_eye_t_hit - search_back_scale * r_tolerance);
	float search_end = p_eye_t_hit + search_forward_scale * r_tolerance;
	if (isnan(search_start) || isinf(search_start) || isnan(search_end) || isinf(search_end)) {
		r_failure_reason = FALLBACK_CURRENT_NONFINITE;
		return false;
	}
	if (search_end <= search_start + 0.000001) {
		r_failure_reason = FALLBACK_CURRENT_OUT_OF_RANGE;
		return false;
	}

	ProbeSample previous_sample;
	float previous_residual;
	float previous_tolerance;
	if (!evaluate_grid_probe(p_world_ray, search_start, p_probe_index, p_face_mask, previous_sample, previous_residual, previous_tolerance)) {
		r_failure_reason = FALLBACK_CURRENT_SAMPLE_INVALID;
		return false;
	}
	r_step_count++;
	if (previous_sample.object_id != p_eye_sample.object_id) {
		r_failure_reason = FALLBACK_CURRENT_OBJECT_MISMATCH_EYE;
		return false;
	}
	if (previous_residual >= 0.0) {
		r_failure_reason = FALLBACK_CURRENT_NO_NEGATIVE_SIDE;
		return false;
	}

	uint scan_steps = uint(clamp(round(draw_state.reprojection_control.x), 4.0, 64.0));
	uint bisection_steps = uint(clamp(round(draw_state.reprojection_control.y), 1.0, 16.0));
	float previous_t = search_start;
	for (uint iteration = 1u; iteration <= 64u; iteration++) {
		if (iteration > scan_steps) {
			break;
		}
		float next_t = mix(search_start, search_end, float(iteration) / float(scan_steps));
		ProbeSample next_sample;
		float next_residual;
		float next_tolerance;
		if (!evaluate_grid_probe(p_world_ray, next_t, p_probe_index, p_face_mask, next_sample, next_residual, next_tolerance)) {
			r_failure_reason = FALLBACK_CURRENT_SAMPLE_INVALID;
			return false;
		}
		r_step_count++;
		if (next_sample.object_id != p_eye_sample.object_id || next_sample.object_id != previous_sample.object_id) {
			r_failure_reason = FALLBACK_CURRENT_OBJECT_DISCONTINUITY;
			return false;
		}
		float monotonic_tolerance = max(r_tolerance, max(previous_tolerance, next_tolerance));
		if (next_residual + monotonic_tolerance < previous_residual) {
			r_failure_reason = FALLBACK_CURRENT_NON_MONOTONIC;
			return false;
		}

		if (previous_residual < 0.0 && next_residual >= 0.0) {
			float lo = previous_t;
			float hi = next_t;
			float lo_residual = previous_residual;
			float hi_residual = next_residual;
			ProbeSample candidate = previous_sample;
			float candidate_residual = previous_residual;
			float candidate_tolerance = previous_tolerance;
			for (uint refinement = 0u; refinement < 16u; refinement++) {
				if (refinement >= bisection_steps) {
					break;
				}
				float mid = (lo + hi) * 0.5;
				if (!evaluate_grid_probe(p_world_ray, mid, p_probe_index, p_face_mask, candidate, candidate_residual, candidate_tolerance)) {
					r_failure_reason = FALLBACK_CURRENT_SAMPLE_INVALID;
					return false;
				}
				r_step_count++;
				if (candidate.object_id != p_eye_sample.object_id) {
					r_failure_reason = FALLBACK_CURRENT_OBJECT_DISCONTINUITY;
					return false;
				}
				float refinement_tolerance = max(r_tolerance, candidate_tolerance);
				if (candidate_residual + refinement_tolerance < lo_residual || candidate_residual - refinement_tolerance > hi_residual) {
					r_failure_reason = FALLBACK_CURRENT_NON_MONOTONIC;
					return false;
				}
				if (candidate_residual < 0.0) {
					lo = mid;
					lo_residual = candidate_residual;
				} else {
					hi = mid;
					hi_residual = candidate_residual;
				}
			}

			r_t_hit = (lo + hi) * 0.5;
			float final_residual;
			if (!evaluate_grid_probe(p_world_ray, r_t_hit, p_probe_index, p_face_mask, r_sample, final_residual, r_tolerance)) {
				r_failure_reason = FALLBACK_CURRENT_SAMPLE_INVALID;
				return false;
			}
			r_step_count++;
			if (r_sample.object_id != p_eye_sample.object_id) {
				r_failure_reason = FALLBACK_CURRENT_OBJECT_DISCONTINUITY;
				return false;
			}
			r_failure_reason = FALLBACK_NONE;
			return true;
		}

		previous_t = next_t;
		previous_sample = next_sample;
		previous_residual = next_residual;
		previous_tolerance = next_tolerance;
	}

	r_failure_reason = FALLBACK_CURRENT_NO_BRACKET;
	return false;
}

vec3 sample_base_surface_normal(ProbeSample p_sample) {
	vec4 encoded_normals = texelFetch(probe_normal, ivec3(p_sample.probe_coord, int(p_sample.layer)), 0);
	return octahedral_decode(encoded_normals.ba);
}

bool validate_grid_candidate(ProbeSample p_candidate, float p_candidate_t_hit, float p_tolerance, ProbeSample p_eye_sample, float p_eye_t_hit, inout uint r_failure_reason) {
	if (p_candidate.object_id != p_eye_sample.object_id) {
		r_failure_reason = FALLBACK_CURRENT_OBJECT_MISMATCH_EYE;
		return false;
	}
	if (draw_state.debug_params.w <= 0.5) {
		return true;
	}
	if (p_candidate_t_hit < p_eye_t_hit - 2.0 * p_tolerance) {
		r_failure_reason = FALLBACK_CURRENT_DEPTH_IN_FRONT;
		return false;
	}
	if (p_candidate_t_hit > p_eye_t_hit + p_tolerance) {
		r_failure_reason = FALLBACK_CURRENT_DEPTH_BEHIND;
		return false;
	}
	vec3 candidate_normal = sample_base_surface_normal(p_candidate);
	vec3 eye_normal = sample_base_surface_normal(p_eye_sample);
	if (!finite_vec3(candidate_normal) || !finite_vec3(eye_normal) || dot(candidate_normal, eye_normal) < 0.5) {
		r_failure_reason = FALLBACK_GRID_NORMAL_MISMATCH;
		return false;
	}
	return true;
}

float world_dither_threshold(vec3 p_world_position) {
	ivec3 cell = ivec3(floor(p_world_position * 128.0));
	uvec3 bits = uvec3(cell);
	uint value = bits.x * 0x8da6b343u ^ bits.y * 0xd8163841u ^ bits.z * 0xcb1ab31fu;
	value ^= value >> 16;
	value *= 0x7feb352du;
	value ^= value >> 15;
	value *= 0x846ca68bu;
	value ^= value >> 16;
	return (float(value & 255u) + 0.5) / 256.0;
}

float screen_bayer4_threshold(ivec2 p_grid_position) {
	const float bayer[16] = float[](
			0.0 / 16.0, 8.0 / 16.0, 2.0 / 16.0, 10.0 / 16.0,
			12.0 / 16.0, 4.0 / 16.0, 14.0 / 16.0, 6.0 / 16.0,
			3.0 / 16.0, 11.0 / 16.0, 1.0 / 16.0, 9.0 / 16.0,
			15.0 / 16.0, 7.0 / 16.0, 13.0 / 16.0, 5.0 / 16.0);
	ivec2 cell = p_grid_position & ivec2(3);
	return bayer[cell.y * 4 + cell.x];
}

float transition_dither_threshold(ivec2 p_grid_position, vec3 p_eye_world_hit) {
	if (draw_state.probe_masks.w == 0u) {
		return screen_bayer4_threshold(p_grid_position);
	}
	return world_dither_threshold(p_eye_world_hit);
}

vec3 fallback_reason_color(uint p_reason) {
	if (p_reason == FALLBACK_NONE) {
		return vec3(0.1, 1.0, 0.2);
	} else if (p_reason == FALLBACK_EYE_DIRECT) {
		return vec3(0.0, 0.82, 1.0);
	} else if (p_reason == FALLBACK_CURRENT_INACTIVE) {
		return vec3(1.0, 0.9, 0.0);
	} else if (p_reason == FALLBACK_CURRENT_SAMPLE_INVALID) {
		return vec3(0.1, 0.25, 1.0);
	} else if (p_reason == FALLBACK_CURRENT_NO_NEGATIVE_SIDE) {
		return vec3(1.0, 0.45, 0.0);
	} else if (p_reason == FALLBACK_CURRENT_NO_BRACKET) {
		return vec3(1.0, 0.05, 0.05);
	} else if (p_reason == FALLBACK_CURRENT_OBJECT_DISCONTINUITY) {
		return vec3(0.65, 0.1, 1.0);
	} else if (p_reason == FALLBACK_CURRENT_NON_MONOTONIC) {
		return vec3(1.0, 0.0, 0.75);
	} else if (p_reason == FALLBACK_CURRENT_OBJECT_MISMATCH_EYE) {
		return vec3(0.55, 0.0, 0.2);
	} else if (p_reason == FALLBACK_CURRENT_DEPTH_IN_FRONT) {
		return vec3(1.0, 0.2, 0.6);
	} else if (p_reason == FALLBACK_CURRENT_DEPTH_BEHIND) {
		return vec3(0.45, 0.0, 0.9);
	} else if (p_reason == FALLBACK_EYE_INVALID) {
		return vec3(0.15);
	} else if (p_reason == FALLBACK_CURRENT_OUT_OF_RANGE) {
		return vec3(0.8, 0.4, 0.0);
	} else if (p_reason == FALLBACK_CURRENT_NONFINITE) {
		return vec3(1.0, 1.0, 1.0);
	} else if (p_reason == FALLBACK_PREVIOUS_UNAVAILABLE) {
		return vec3(0.0, 0.55, 0.35);
	} else if (p_reason == FALLBACK_GRID_NORMAL_MISMATCH) {
		return vec3(0.65, 0.15, 0.85);
	}
	return vec3(0.9, 0.9, 0.0);
}

vec3 debug_color(uint p_debug_view, vec4 p_albedo, vec4 p_encoded_normals, uint p_object_id, uint p_layer, uint p_flags, vec2 p_uv, float p_t_hit, uint p_source_role, uint p_fallback_reason) {
	vec3 shading_normal = octahedral_decode(p_encoded_normals.rg);
	vec3 base_surface_normal = octahedral_decode(p_encoded_normals.ba);

	if (p_debug_view == 1u) {
		return (p_flags & FLAG_DEBUG_EDGE) != 0u ? vec3(1.0, 0.35, 0.05) : p_albedo.rgb * 0.25;
	} else if (p_debug_view == 2u) {
		float luma = clamp(log2(1.0 + max(p_t_hit, 0.0)) / log2(1.0 + max(draw_state.params.w, 0.001)), 0.0, 1.0);
		return vec3(luma);
	} else if (p_debug_view == 3u) {
		return shading_normal * 0.5 + 0.5;
	} else if (p_debug_view == 4u) {
		return hash_color(p_object_id);
	} else if (p_debug_view == 5u) {
		return hash_color(p_layer + 1u);
	} else if (p_debug_view == 6u) {
		return vec3(0.0, 0.75, 1.0);
	} else if (p_debug_view == 7u) {
		return p_source_role == SOURCE_CURRENT ? vec3(1.0, 0.12, 0.72) : (p_source_role == SOURCE_PREVIOUS ? vec3(1.0, 0.88, 0.05) : vec3(0.0, 0.82, 1.0));
	} else if (p_debug_view == 8u) {
		return base_surface_normal * 0.5 + 0.5;
	} else if (p_debug_view == 9u) {
		// Surface-alignment error belonged to the rejected world-space quad
		// renderer. Magenta makes the unsupported view impossible to mistake for
		// a passing (green) SGTR diagnostic.
		return vec3(1.0, 0.0, 1.0);
	} else if (p_debug_view == 10u) {
		uint encoded_ref = texel_index(p_layer, ivec2(clamp(p_uv * draw_state.params.x, vec2(0.0), vec2(draw_state.params.x - 1.0))), uint(draw_state.params.x)) + 1u;
		uvec3 encoded_bytes = uvec3(encoded_ref & 255u, (encoded_ref >> 8u) & 255u, (encoded_ref >> 16u) & 255u);
		return srgb_code_to_linear(vec3(encoded_bytes) / 255.0);
	} else if (p_debug_view == 11u) {
		// Raster-geometry derivatives do not exist in the screen-grid gather path.
		return vec3(1.0, 0.0, 1.0);
	} else if (p_debug_view == 12u) {
		return vec3(0.0, 1.0, 0.08);
	} else if (p_debug_view == 13u) {
		return vec3(p_uv, float(p_layer % 6u) / 5.0);
	} else if (p_debug_view == 14u) {
		return fallback_reason_color(p_fallback_reason);
	}

	vec3 color = p_albedo.rgb;
	if (draw_state.directional_light_direction.w > 0.5) {
		vec3 light_direction = normalize(draw_state.directional_light_direction.xyz);
		float diffuse = max(dot(shading_normal, light_direction), 0.0);
		vec3 lighting = vec3(draw_state.directional_light_color.a) + draw_state.directional_light_color.rgb * diffuse;
		color = clamp(color * lighting, vec3(0.0), vec3(1.0));
	}
	return color;
}

void main() {
	ivec2 grid_coord = ivec2(gl_GlobalInvocationID.xy);
	bool owner_boundary_mode = draw_state.camera_position.w > 0.5;
	ivec2 grid_size = owner_boundary_mode ? ivec2(draw_state.params.yz) : ivec2(draw_state.grid_params.xy);
	if (grid_coord.x >= grid_size.x || grid_coord.y >= grid_size.y) {
		return;
	}

	vec2 viewport_size = draw_state.params.yz;
	float pixel_scale = owner_boundary_mode ? 1.0 : max(draw_state.grid_params.z, 1.0);
	vec2 pixel_center = min((vec2(grid_coord) + vec2(0.5)) * pixel_scale, max(viewport_size - vec2(0.5), vec2(0.5)));
	vec2 ndc = pixel_center / max(viewport_size, vec2(1.0)) * 2.0 - 1.0;

	vec4 near_world_h = draw_state.inverse_view_projection * vec4(ndc, 1.0, 1.0);
	if (!finite_vec4(near_world_h) || abs(near_world_h.w) <= 0.000001) {
		store_invalid(grid_coord, FALLBACK_CURRENT_NONFINITE, 0u, 0u);
		return;
	}

	vec3 near_world = near_world_h.xyz / near_world_h.w;
	vec3 world_ray = normalize(near_world - draw_state.camera_position.xyz);
	if (!finite_vec3(world_ray) || dot(world_ray, world_ray) < 0.999) {
		store_invalid(grid_coord, FALLBACK_CURRENT_NONFINITE, 0u, 0u);
		return;
	}

	ProbeSample eye_sample;
	float eye_t_hit;
	bool eye_valid = resolve_eye(world_ray, eye_sample, eye_t_hit);

	uint source_mode = uint(clamp(round(draw_state.reprojection_control.w), 0.0, 3.0));
	float t_near = max(length(near_world - draw_state.camera_position.xyz), 0.0001);
	uint current_probe_index = uint(round(draw_state.transition_params.y));
	uint previous_probe_index = uint(round(draw_state.transition_params.z));
	uint current_face_mask = draw_state.probe_masks.y & 0x3fu;
	uint previous_face_mask = draw_state.probe_masks.z & 0x3fu;
	bool transition_active = draw_state.transition_params.w > 0.5 && previous_face_mask != 0u;

	ProbeSample current_sample = invalid_probe_sample();
	float current_t_hit = 0.0;
	float current_tolerance = max(draw_state.reprojection_params.x, 0.0001);
	uint current_failure_reason = eye_valid ? FALLBACK_CURRENT_NO_BRACKET : FALLBACK_EYE_INVALID;
	uint current_step_count = 0u;
	bool current_valid = false;
	if (eye_valid && (source_mode == SOURCE_MODE_COMPOSED || source_mode == SOURCE_MODE_CURRENT_ONLY)) {
		current_valid = resolve_grid_probe(world_ray, t_near, eye_sample, eye_t_hit, current_probe_index, current_face_mask, current_sample, current_t_hit, current_tolerance, current_failure_reason, current_step_count);
		if (current_valid) {
			current_valid = validate_grid_candidate(current_sample, current_t_hit, current_tolerance, eye_sample, eye_t_hit, current_failure_reason);
		}
	}

	ProbeSample previous_sample = invalid_probe_sample();
	float previous_t_hit = 0.0;
	float previous_tolerance = max(draw_state.reprojection_params.x, 0.0001);
	uint previous_failure_reason = eye_valid ? FALLBACK_PREVIOUS_UNAVAILABLE : FALLBACK_EYE_INVALID;
	uint previous_step_count = 0u;
	bool previous_valid = false;
	if (eye_valid && (source_mode == SOURCE_MODE_PREVIOUS_ONLY || (source_mode == SOURCE_MODE_COMPOSED && transition_active))) {
		previous_valid = resolve_grid_probe(world_ray, t_near, eye_sample, eye_t_hit, previous_probe_index, previous_face_mask, previous_sample, previous_t_hit, previous_tolerance, previous_failure_reason, previous_step_count);
		if (previous_valid) {
			previous_valid = validate_grid_candidate(previous_sample, previous_t_hit, previous_tolerance, eye_sample, eye_t_hit, previous_failure_reason);
		} else if (previous_failure_reason == FALLBACK_CURRENT_INACTIVE) {
			previous_failure_reason = FALLBACK_PREVIOUS_UNAVAILABLE;
		}
	}

	ProbeSample selected_sample = invalid_probe_sample();
	float t_hit = 0.0;
	uint source_role = SOURCE_EYE;
	uint fallback_reason = FALLBACK_EYE_INVALID;
	uint selection_flags = 0u;
	uint total_step_count = min(current_step_count + previous_step_count, 255u);
	if (source_mode == SOURCE_MODE_EYE_ONLY) {
		if (!eye_valid) {
			store_invalid(grid_coord, FALLBACK_EYE_INVALID, 0u, total_step_count);
			return;
		}
		selected_sample = eye_sample;
		t_hit = eye_t_hit;
		fallback_reason = FALLBACK_EYE_DIRECT;
	} else if (source_mode == SOURCE_MODE_CURRENT_ONLY) {
		if (!current_valid) {
			store_invalid(grid_coord, current_failure_reason, eye_valid ? eye_sample.object_id : 0u, total_step_count);
			return;
		}
		selected_sample = current_sample;
		t_hit = current_t_hit;
		source_role = SOURCE_CURRENT;
		fallback_reason = FALLBACK_NONE;
	} else if (source_mode == SOURCE_MODE_PREVIOUS_ONLY) {
		if (!previous_valid) {
			store_invalid(grid_coord, previous_failure_reason, eye_valid ? eye_sample.object_id : 0u, total_step_count);
			return;
		}
		selected_sample = previous_sample;
		t_hit = previous_t_hit;
		source_role = SOURCE_PREVIOUS;
		fallback_reason = FALLBACK_NONE;
	} else {
		if (!eye_valid) {
			store_invalid(grid_coord, FALLBACK_EYE_INVALID, 0u, total_step_count);
			return;
		}

		vec3 eye_world_hit = draw_state.camera_position.xyz + world_ray * eye_t_hit;
		float transition_threshold = transition_dither_threshold(grid_coord, eye_world_hit);
		bool prefer_current = !transition_active || transition_threshold < clamp(draw_state.transition_params.x, 0.0, 1.0);
		bool primary_valid = prefer_current ? current_valid : previous_valid;
		bool alternate_valid = prefer_current ? previous_valid : current_valid;
		if (primary_valid) {
			selected_sample = prefer_current ? current_sample : previous_sample;
			t_hit = prefer_current ? current_t_hit : previous_t_hit;
			source_role = prefer_current ? SOURCE_CURRENT : SOURCE_PREVIOUS;
			fallback_reason = FALLBACK_NONE;
		} else if (transition_active && alternate_valid) {
			selected_sample = prefer_current ? previous_sample : current_sample;
			t_hit = prefer_current ? previous_t_hit : current_t_hit;
			source_role = prefer_current ? SOURCE_PREVIOUS : SOURCE_CURRENT;
			fallback_reason = prefer_current ? current_failure_reason : previous_failure_reason;
			selection_flags |= FLAG_ALTERNATE_ROLE_FILL;
		} else {
			selected_sample = eye_sample;
			t_hit = eye_t_hit;
			fallback_reason = prefer_current ? current_failure_reason : previous_failure_reason;
		}
	}

	if (!selected_sample.valid || t_hit <= 0.0 || isnan(t_hit) || isinf(t_hit)) {
		store_invalid(grid_coord, FALLBACK_CURRENT_NONFINITE, selected_sample.object_id, total_step_count);
		return;
	}

	vec3 world_hit = draw_state.camera_position.xyz + world_ray * t_hit;
	vec4 clip = draw_state.view_projection * vec4(world_hit, 1.0);
	if (!finite_vec4(clip) || clip.w <= 0.000001) {
		store_invalid(grid_coord, FALLBACK_CURRENT_NONFINITE, selected_sample.object_id, total_step_count);
		return;
	}

	float clip_depth = clip.z / clip.w;
	if (clip_depth < 0.0 || clip_depth > 1.0 || isnan(clip_depth) || isinf(clip_depth)) {
		store_invalid(grid_coord, FALLBACK_CURRENT_OUT_OF_RANGE, selected_sample.object_id, total_step_count);
		return;
	}

	uint probe_size = uint(draw_state.params.x);
	ivec3 sample_coord = ivec3(selected_sample.probe_coord, int(selected_sample.layer));
	vec4 albedo = texelFetch(probe_albedo, sample_coord, 0);
	vec4 encoded_normals = texelFetch(probe_normal, sample_coord, 0);
	uint flags = splat_flags.data[texel_index(selected_sample.layer, selected_sample.probe_coord, probe_size)] | selection_flags;
	uint debug_view = uint(clamp(round(draw_state.debug_params.x), 0.0, 15.0));
	if (!owner_boundary_mode && debug_view == 1u && (flags & FLAG_DEBUG_EDGE) == 0u) {
		store_invalid(grid_coord, fallback_reason, selected_sample.object_id, total_step_count);
		return;
	}
	vec3 color = debug_color(debug_view, albedo, encoded_normals, selected_sample.object_id, selected_sample.layer, flags, selected_sample.uv, t_hit, source_role, fallback_reason);
	float alpha = min(max(albedo.a, 0.35), 1.0);

	uint meta = pack_meta(true, selected_sample.layer, source_role, fallback_reason, flags, total_step_count);
	imageStore(grid_color, grid_coord, vec4(color, alpha));
	imageStore(grid_depth, grid_coord, vec4(clip_depth));
	imageStore(grid_meta, grid_coord, uvec4(meta, selected_sample.object_id, 0u, 0u));
	if (owner_boundary_mode) {
		vec3 reference_albedo = debug_color(0u, albedo, encoded_normals, selected_sample.object_id, selected_sample.layer, flags, selected_sample.uv, t_hit, source_role, fallback_reason);
		imageStore(native_camera_depth, grid_coord, vec4(t_hit));
		imageStore(native_albedo, grid_coord, vec4(reference_albedo, albedo.a));
		imageStore(native_normal, grid_coord, encoded_normals);
	}
}
