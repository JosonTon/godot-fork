#[vertex]

#version 450

#VERSION_DEFINES

layout(push_constant, std430) uniform DrawPushConstant {
	uint role;
	uint pad0;
	uint pad1;
	uint pad2;
}
draw_push_constant;

layout(set = 0, binding = 0) uniform sampler2DArray probe_albedo;
layout(set = 0, binding = 1) uniform sampler2DArray probe_normal;
layout(set = 0, binding = 2) uniform sampler2DArray probe_radial;
layout(set = 0, binding = 3) uniform usampler2DArray probe_object_id;

layout(set = 0, binding = 4, std430) restrict readonly buffer VisibleRefs {
	uint data[];
}
visible_refs;

layout(set = 0, binding = 5, std430) restrict readonly buffer SplatFlags {
	uint data[];
}
splat_flags;

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

layout(set = 0, binding = 7, std430) restrict buffer DrawCounters {
	uint visible_count;
	uint classified_count;
	uint edge_count;
	uint cross_face_sample_count;
	uint cross_face_resolved_count;
	uint cross_face_empty_suppressed_count;
	uint cross_face_edge_count;
	uint cross_object_continuity_count;
	uint invalid_base_surface_normal_count;
	uint pre_raster_splat_count;
	uint invalid_or_nonfinite_splat_count;
	uint degenerate_splat_count;
	uint winding_failure_count;
	uint extent_failure_count;
	uint clip_nonfinite_count;
	uint clip_polygon_overflow_count;
	uint clip_divide_invalid_count;
	uint ndc_bbox_invalid_count;
	uint fully_clipped_splat_count;
	uint expected_span_saturated_count;
	uint expected_grazing_strip_count;
	uint rasterized_geometry_pixel_count;
	uint jacobian_measurable_pixel_count;
	uint jacobian_unmeasurable_pixel_count;
	uint unexpected_jacobian_unmeasurable_pixel_count;
	uint ray_structure_failure_count;
	uint max_world_extent_ratio_bits;
	uint max_diagonal_extent_ratio_bits;
	uint max_alignment_error_bits;
}
draw_counters;

layout(location = 0) out vec4 vertex_color;
layout(location = 1) out vec2 footprint_uv;
layout(location = 2) flat out uint debug_view_flat;
layout(location = 3) flat out uint probe_index_flat;
layout(location = 4) flat out uint vertex_valid_flat;
layout(location = 5) flat out vec4 transition_params_flat;
layout(location = 6) out vec3 world_position;
layout(location = 7) flat out uint object_id_flat;
layout(location = 8) flat out vec3 texel_center_world_position;
layout(location = 9) flat out float footprint_exponent_flat;
layout(location = 10) flat out vec3 base_surface_normal_flat;
layout(location = 11) flat out vec2 expected_screen_span_flat;
layout(location = 12) flat out float expected_world_edge_flat;
layout(location = 13) flat out uint texel_ref_flat;
layout(location = 14) flat out vec4 expected_screen_bbox_flat;

const vec2 QUAD[6] = vec2[](
	vec2(-0.5, -0.5),
	vec2(0.5, -0.5),
	vec2(-0.5, 0.5),
	vec2(-0.5, 0.5),
	vec2(0.5, -0.5),
	vec2(0.5, 0.5)
);

const uint FLAG_DEBUG_EDGE = 2u;
const uint FLAG_CONT_LEFT = 16u;
const uint FLAG_CONT_RIGHT = 32u;
const uint FLAG_CONT_BOTTOM = 64u;
const uint FLAG_CONT_TOP = 128u;

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

vec3 probe_view_direction_from_uv(vec2 p_uv) {
	vec2 face_xy = p_uv * 2.0 - 1.0;
	return vec3(face_xy.x, face_xy.y, -1.0);
}

vec4 probe_world_position(uint p_layer, vec2 p_uv, float p_radial_depth) {
	vec3 raw_dir = probe_view_direction_from_uv(p_uv);
	float max_comp = max(abs(raw_dir.x), max(abs(raw_dir.y), abs(raw_dir.z)));
	vec3 probe_view_pos = raw_dir * (p_radial_depth / max(max_comp, 0.00001));
	return draw_state.probe_transforms[p_layer] * vec4(probe_view_pos, 1.0);
}

vec3 stable_surface_tangent(vec3 p_normal) {
	vec3 reference_axis = abs(p_normal.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
	return normalize(cross(reference_axis, p_normal));
}

void bounded_affine_basis(vec3 p_surface_normal, out vec3 r_tangent, out vec3 r_bitangent, out float r_confidence, out float r_footprint_exponent) {
	const vec3 REFERENCE_AXIS = vec3(0.57735026919);
	vec3 projected_axis = REFERENCE_AXIS - p_surface_normal * dot(REFERENCE_AXIS, p_surface_normal);
	r_confidence = clamp(length(projected_axis), 0.0, 1.0);
	r_tangent = r_confidence > 0.00001 ? projected_axis / r_confidence : stable_surface_tangent(p_surface_normal);
	r_bitangent = normalize(cross(p_surface_normal, r_tangent));
	float square_weight = smoothstep(0.10, 0.70, r_confidence);
	r_footprint_exponent = mix(2.0, 8.0, square_weight);
}

const uint CLIP_ERROR_NONFINITE = 1u;
const uint CLIP_ERROR_OVERFLOW = 2u;
const uint CLIP_ERROR_DIVIDE = 4u;
const uint CLIP_ERROR_BBOX = 8u;
const uint CLIP_FULLY_CLIPPED = 16u;
const int MAX_CLIP_VERTICES = 16;

bool finite_vec2(vec2 p_value) {
	return !any(isnan(p_value)) && !any(isinf(p_value));
}

bool finite_vec3(vec3 p_value) {
	return !any(isnan(p_value)) && !any(isinf(p_value));
}

bool finite_vec4(vec4 p_value) {
	return !any(isnan(p_value)) && !any(isinf(p_value));
}

vec4 bounded_affine_corner(vec3 p_center, vec3 p_tangent, vec3 p_bitangent, float p_half_extent, vec2 p_corner) {
	return vec4(p_center + p_tangent * (p_corner.x * p_half_extent) + p_bitangent * (p_corner.y * p_half_extent), 1.0);
}

float homogeneous_clip_distance(vec4 p_position, int p_plane) {
	if (p_plane == 0) {
		return p_position.x + p_position.w;
	} else if (p_plane == 1) {
		return p_position.w - p_position.x;
	} else if (p_plane == 2) {
		return p_position.y + p_position.w;
	} else if (p_plane == 3) {
		return p_position.w - p_position.y;
	} else if (p_plane == 4) {
		return p_position.z;
	}
	return p_position.w - p_position.z;
}

void homogeneous_clipped_metrics(vec4 p_clip_corners[4], out vec2 r_screen_span, out vec4 r_screen_bbox, out uint r_status) {
	r_screen_span = vec2(0.0);
	r_screen_bbox = vec4(0.0);
	r_status = 0u;
	vec4 polygon_a[MAX_CLIP_VERTICES];
	vec4 polygon_b[MAX_CLIP_VERTICES];
	for (int i = 0; i < 4; i++) {
		if (!finite_vec4(p_clip_corners[i])) {
			r_status |= CLIP_ERROR_NONFINITE;
			return;
		}
		polygon_a[i] = p_clip_corners[i];
	}
	int vertex_count = 4;
	for (int plane = 0; plane < 6; plane++) {
		if (vertex_count == 0) {
			break;
		}
		int output_count = 0;
		vec4 previous = polygon_a[vertex_count - 1];
		float previous_distance = homogeneous_clip_distance(previous, plane);
		bool previous_inside = previous_distance >= 0.0;
		for (int i = 0; i < MAX_CLIP_VERTICES; i++) {
			if (i >= vertex_count) {
				break;
			}
			vec4 current = polygon_a[i];
			float current_distance = homogeneous_clip_distance(current, plane);
			bool current_inside = current_distance >= 0.0;
			if (current_inside != previous_inside) {
				float denominator = previous_distance - current_distance;
				if (!finite_vec2(vec2(previous_distance, current_distance)) || abs(denominator) <= 0.0000001) {
					r_status |= CLIP_ERROR_DIVIDE;
					return;
				}
				if (output_count >= MAX_CLIP_VERTICES) {
					r_status |= CLIP_ERROR_OVERFLOW;
					return;
				}
				float weight = previous_distance / denominator;
				vec4 intersection = mix(previous, current, weight);
				if (!finite_vec4(intersection)) {
					r_status |= CLIP_ERROR_NONFINITE;
					return;
				}
				polygon_b[output_count++] = intersection;
			}
			if (current_inside) {
				if (output_count >= MAX_CLIP_VERTICES) {
					r_status |= CLIP_ERROR_OVERFLOW;
					return;
				}
				polygon_b[output_count++] = current;
			}
			previous = current;
			previous_distance = current_distance;
			previous_inside = current_inside;
		}
		vertex_count = output_count;
		for (int i = 0; i < MAX_CLIP_VERTICES; i++) {
			if (i >= vertex_count) {
				break;
			}
			polygon_a[i] = polygon_b[i];
		}
	}
	if (vertex_count < 3) {
		r_status |= CLIP_FULLY_CLIPPED;
		return;
	}
	vec2 bbox_min = vec2(1e30);
	vec2 bbox_max = vec2(-1e30);
	for (int i = 0; i < MAX_CLIP_VERTICES; i++) {
		if (i >= vertex_count) {
			break;
		}
		vec4 clip_position = polygon_a[i];
		if (!finite_vec4(clip_position) || clip_position.w <= 0.0000001) {
			r_status |= CLIP_ERROR_DIVIDE;
			return;
		}
		vec2 ndc = clip_position.xy / clip_position.w;
		// Godot's projection already carries the Vulkan Y convention used by
		// gl_FragCoord, so both axes use the same viewport mapping here.
		vec2 screen_position = (ndc * 0.5 + 0.5) * draw_state.params.zw;
		if (!finite_vec2(screen_position)) {
			r_status |= CLIP_ERROR_BBOX;
			return;
		}
		bbox_min = min(bbox_min, screen_position);
		bbox_max = max(bbox_max, screen_position);
	}
	vec2 span = max(bbox_max - bbox_min, vec2(0.0));
	if (!finite_vec2(span) || any(lessThan(bbox_max, bbox_min))) {
		r_status |= CLIP_ERROR_BBOX;
		return;
	}
	r_screen_span = vec2(max(span.x, span.y), min(span.x, span.y));
	r_screen_bbox = vec4(bbox_min, bbox_max);
}

void main() {
	uint probe_size = uint(draw_state.params.x);
	uint texel_ref = visible_refs.data[gl_InstanceIndex];
	uint layer = texel_ref / (probe_size * probe_size);
	uint layer_texel = texel_ref - layer * probe_size * probe_size;
	uint y = layer_texel / probe_size;
	uint x = layer_texel - y * probe_size;

	ivec3 probe_coord = ivec3(int(x), int(y), int(layer));
	vec4 albedo = texelFetch(probe_albedo, probe_coord, 0);
	vec4 encoded_normals = texelFetch(probe_normal, probe_coord, 0);
	float radial_depth = texelFetch(probe_radial, probe_coord, 0).r;
	uint object_id = texelFetch(probe_object_id, probe_coord, 0).r;
	uint flags = splat_flags.data[texel_ref];
	uint probe_index = layer / 6u;
	int selected_layer = int(round(draw_state.debug_params.y));
	uint current_probe_index = uint(round(draw_state.transition_params.y));
	uint previous_probe_index = uint(round(draw_state.transition_params.z));

	vec2 uv = (vec2(x, y) + vec2(0.5)) / float(probe_size);
	vec4 center_world_pos = probe_world_position(layer, uv, radial_depth);
	vec3 shading_normal = octahedral_decode(encoded_normals.rg);
	vec3 base_surface_normal = octahedral_decode(encoded_normals.ba);
	vec3 tangent;
	vec3 bitangent;
	float tangent_confidence;
	float footprint_exponent;
	bounded_affine_basis(base_surface_normal, tangent, bitangent, tangent_confidence, footprint_exponent);
	float expansion_texels = clamp(draw_state.params.y, 0.0, 2.0);
	float half_extent_uv = (0.5 + expansion_texels) / float(probe_size);
	float half_extent_world = 2.0 * radial_depth * half_extent_uv;
	float expected_world_edge = 2.0 * half_extent_world;
	float expected_world_diagonal = 1.41421356237 * expected_world_edge;
	vec4 world_corners[4];
	world_corners[0] = bounded_affine_corner(center_world_pos.xyz, tangent, bitangent, half_extent_world, vec2(-1.0, -1.0));
	world_corners[1] = bounded_affine_corner(center_world_pos.xyz, tangent, bitangent, half_extent_world, vec2(1.0, -1.0));
	world_corners[2] = bounded_affine_corner(center_world_pos.xyz, tangent, bitangent, half_extent_world, vec2(1.0, 1.0));
	world_corners[3] = bounded_affine_corner(center_world_pos.xyz, tangent, bitangent, half_extent_world, vec2(-1.0, 1.0));
	vec4 clip_corners[4];
	for (int corner_index = 0; corner_index < 4; corner_index++) {
		clip_corners[corner_index] = draw_state.view_projection * world_corners[corner_index];
	}
	vec2 expected_screen_span;
	vec4 expected_screen_bbox;
	uint clip_status;
	homogeneous_clipped_metrics(clip_corners, expected_screen_span, expected_screen_bbox, clip_status);

	bool world_finite = finite_vec4(center_world_pos) && finite_vec3(shading_normal) && finite_vec3(base_surface_normal) &&
			finite_vec3(tangent) && finite_vec3(bitangent) && !isnan(half_extent_world) && !isinf(half_extent_world);
	for (int corner_index = 0; corner_index < 4; corner_index++) {
		world_finite = world_finite && finite_vec4(world_corners[corner_index]);
	}
	vec4 edge_lengths = vec4(
			length(world_corners[1].xyz - world_corners[0].xyz),
			length(world_corners[2].xyz - world_corners[1].xyz),
			length(world_corners[3].xyz - world_corners[2].xyz),
			length(world_corners[0].xyz - world_corners[3].xyz));
	vec2 diagonal_lengths = vec2(
			length(world_corners[2].xyz - world_corners[0].xyz),
			length(world_corners[3].xyz - world_corners[1].xyz));
	vec3 triangle_normal_0 = cross(world_corners[1].xyz - world_corners[0].xyz, world_corners[3].xyz - world_corners[0].xyz);
	vec3 triangle_normal_1 = cross(world_corners[1].xyz - world_corners[3].xyz, world_corners[2].xyz - world_corners[3].xyz);
	float triangle_area_0 = length(triangle_normal_0);
	float triangle_area_1 = length(triangle_normal_1);
	bool degenerate = !world_finite || expected_world_edge <= 0.0 || triangle_area_0 <= 0.0000000001 || triangle_area_1 <= 0.0000000001;
	float signed_alignment_0 = degenerate ? -1.0 : dot(triangle_normal_0 / triangle_area_0, base_surface_normal);
	float signed_alignment_1 = degenerate ? -1.0 : dot(triangle_normal_1 / triangle_area_1, base_surface_normal);
	float min_signed_alignment = min(signed_alignment_0, signed_alignment_1);
	vec4 edge_ratios = expected_world_edge > 0.0 ? edge_lengths / expected_world_edge : vec4(0.0);
	vec2 diagonal_ratios = expected_world_diagonal > 0.0 ? diagonal_lengths / expected_world_diagonal : vec2(0.0);
	float max_edge_ratio = max(max(edge_ratios.x, edge_ratios.y), max(edge_ratios.z, edge_ratios.w));
	float min_edge_ratio = min(min(edge_ratios.x, edge_ratios.y), min(edge_ratios.z, edge_ratios.w));
	float max_diagonal_ratio = max(diagonal_ratios.x, diagonal_ratios.y);
	float min_diagonal_ratio = min(diagonal_ratios.x, diagonal_ratios.y);
	bool winding_failure = !degenerate && min_signed_alignment < 0.95;
	bool extent_failure = !degenerate && (max_edge_ratio > 1.01 || min_edge_ratio < 0.99 || max_diagonal_ratio > 1.01 || min_diagonal_ratio < 0.99);

	vec2 quad_corner = QUAD[gl_VertexIndex] * 2.0;
	vec4 world_pos = bounded_affine_corner(center_world_pos.xyz, tangent, bitangent, half_extent_world, quad_corner);
	bool vertex_valid = world_finite && radial_depth > 0.0 && half_extent_world > 0.0 && !degenerate;
	world_position = world_pos.xyz;
	gl_Position = draw_state.view_projection * world_pos;
	// Godot Forward+ uses reverse-Z. Push the eye role slightly farther so
	// the stable grid role wins near-equal overlaps, and use a deterministic
	// per-face texel bias to resolve same-role cube-face ties. The magnitudes
	// stay close to depth precision and are deliberately much smaller than
	// Dylan's standard-depth 0.001 role offset.
	uint face_texel_ref = (layer % 6u) * probe_size * probe_size + layer_texel;
	uint depth_hash = (face_texel_ref * 2654435761u) >> 24u;
	float tie_break_bias = (float(depth_hash) + 1.0) * 1e-9;
	float eye_role_bias = probe_index == 0u ? 1e-6 : 0.0;
	if (draw_state.debug_params.w > 0.5) {
		gl_Position.z = max(gl_Position.z - (eye_role_bias + tie_break_bias) * gl_Position.w, 0.0);
	}

	uint debug_view = uint(draw_state.debug_params.x);
	footprint_uv = QUAD[gl_VertexIndex] + vec2(0.5);
	debug_view_flat = debug_view;
	probe_index_flat = probe_index;
	vertex_valid_flat = vertex_valid ? 1u : 0u;
	transition_params_flat = draw_state.transition_params;
	object_id_flat = object_id;
	texel_center_world_position = center_world_pos.xyz;
	footprint_exponent_flat = footprint_exponent;
	base_surface_normal_flat = base_surface_normal;
	expected_screen_span_flat = expected_screen_span;
	expected_world_edge_flat = expected_world_edge;
	texel_ref_flat = texel_ref;
	expected_screen_bbox_flat = expected_screen_bbox;

	bool draw_selected = !((selected_layer >= 0 && int(layer) != selected_layer) ||
			(draw_push_constant.role == 0u && probe_index != 0u) ||
			(draw_push_constant.role == 1u && probe_index == 0u) ||
			(selected_layer == -2 && probe_index != 0u) ||
			(selected_layer == -3 && probe_index != current_probe_index) ||
			(selected_layer == -4 && probe_index != previous_probe_index));
	if (gl_VertexIndex == 0 && draw_selected && draw_state.debug_params.z > 0.5) {
		atomicAdd(draw_counters.pre_raster_splat_count, 1u);
		if (!world_finite) {
			atomicAdd(draw_counters.invalid_or_nonfinite_splat_count, 1u);
		}
		if (degenerate) {
			atomicAdd(draw_counters.degenerate_splat_count, 1u);
		}
		if (winding_failure) {
			atomicAdd(draw_counters.winding_failure_count, 1u);
		}
		if (extent_failure) {
			atomicAdd(draw_counters.extent_failure_count, 1u);
		}
		if ((clip_status & CLIP_ERROR_NONFINITE) != 0u) {
			atomicAdd(draw_counters.clip_nonfinite_count, 1u);
		}
		if ((clip_status & CLIP_ERROR_OVERFLOW) != 0u) {
			atomicAdd(draw_counters.clip_polygon_overflow_count, 1u);
		}
		if ((clip_status & CLIP_ERROR_DIVIDE) != 0u) {
			atomicAdd(draw_counters.clip_divide_invalid_count, 1u);
		}
		if ((clip_status & CLIP_ERROR_BBOX) != 0u) {
			atomicAdd(draw_counters.ndc_bbox_invalid_count, 1u);
		}
		if ((clip_status & CLIP_FULLY_CLIPPED) != 0u) {
			atomicAdd(draw_counters.fully_clipped_splat_count, 1u);
		}
		if (expected_screen_span.x > 255.0) {
			atomicAdd(draw_counters.expected_span_saturated_count, 1u);
		}
		if (expected_screen_span.y <= 1.5 && expected_screen_span.x > max(expected_screen_span.y * 8.0, 1.5)) {
			atomicAdd(draw_counters.expected_grazing_strip_count, 1u);
		}
		if (!degenerate) {
			atomicMax(draw_counters.max_world_extent_ratio_bits, floatBitsToUint(max_edge_ratio));
			atomicMax(draw_counters.max_diagonal_extent_ratio_bits, floatBitsToUint(max_diagonal_ratio));
			atomicMax(draw_counters.max_alignment_error_bits, floatBitsToUint(max(1.0 - min_signed_alignment, 0.0)));
		}
	}
	if (!draw_selected) {
		vertex_color = vec4(0.0);
		return;
	}

	bool edge = (flags & FLAG_DEBUG_EDGE) != 0u;
	vec3 color = albedo.rgb;
	if (debug_view == 1u) {
		if (!edge) {
			vertex_color = vec4(0.0);
			return;
		}
		color = vec3(1.0, 0.35, 0.05);
	} else if (debug_view == 2u) {
		float depth_luma = clamp(radial_depth / 32.0, 0.0, 1.0);
		color = vec3(depth_luma);
	} else if (debug_view == 3u) {
		color = shading_normal * 0.5 + 0.5;
	} else if (debug_view == 4u) {
		color = hash_color(object_id);
	} else if (debug_view == 5u) {
		color = hash_color(layer + 1u);
	} else if (debug_view == 6u) {
		vertex_color = vec4(0.0, 0.75, 1.0, 1.0);
		return;
	} else if (debug_view == 7u) {
		if (probe_index == 0u) {
			color = vec3(0.0, 0.82, 1.0);
		} else if (probe_index == current_probe_index) {
			color = vec3(1.0, 0.12, 0.72);
		} else {
			color = vec3(1.0, 0.82, 0.05);
		}
	} else if (debug_view == 8u) {
		color = base_surface_normal * 0.5 + 0.5;
	} else if (debug_view == 9u) {
		vec3 quad_normal = normalize(cross(tangent, bitangent));
		float surface_alignment_error = 1.0 - abs(dot(quad_normal, base_surface_normal));
		color = vec3(surface_alignment_error, 1.0 - surface_alignment_error, 0.08);
	} else if (debug_view == 10u) {
		uint encoded_ref = texel_ref + 1u;
		uvec3 encoded_bytes = uvec3(encoded_ref & 255u, (encoded_ref >> 8u) & 255u, (encoded_ref >> 16u) & 255u);
		float encoded_span = round(clamp(expected_screen_span.x, 0.0, 255.0)) / 255.0;
		vertex_color = vec4(srgb_code_to_linear(vec3(encoded_bytes) / 255.0), encoded_span);
		return;
	} else if (debug_view == 11u) {
		vertex_color = vec4(0.0, 1.0, 0.08, 1.0);
		return;
	}

	if (debug_view == 0u && draw_state.directional_light_direction.w > 0.5) {
		vec3 light_direction = normalize(draw_state.directional_light_direction.xyz);
		float diffuse = max(dot(shading_normal, light_direction), 0.0);
		vec3 lighting = vec3(draw_state.directional_light_color.a) + draw_state.directional_light_color.rgb * diffuse;
		color = clamp(color * lighting, vec3(0.0), vec3(1.0));
	}

	vertex_color = vec4(color, min(max(albedo.a, 0.35), 1.0));
}

#[fragment]

#version 450

#VERSION_DEFINES

layout(set = 0, binding = 2) uniform sampler2DArray probe_radial;
layout(set = 0, binding = 3) uniform usampler2DArray probe_object_id;

layout(set = 0, binding = 6, std430) restrict readonly buffer DrawState {
	mat4 view_projection;
	mat4 probe_transforms[18];
	mat4 probe_inverse_transforms[18];
	vec4 params;
	vec4 debug_params;
	vec4 directional_light_direction;
	vec4 directional_light_color;
	vec4 camera_position;
	vec4 transition_params;
	uvec4 probe_masks;
}
draw_state;

layout(set = 0, binding = 7, std430) restrict buffer DrawCounters {
	uint visible_count;
	uint classified_count;
	uint edge_count;
	uint cross_face_sample_count;
	uint cross_face_resolved_count;
	uint cross_face_empty_suppressed_count;
	uint cross_face_edge_count;
	uint cross_object_continuity_count;
	uint invalid_base_surface_normal_count;
	uint pre_raster_splat_count;
	uint invalid_or_nonfinite_splat_count;
	uint degenerate_splat_count;
	uint winding_failure_count;
	uint extent_failure_count;
	uint clip_nonfinite_count;
	uint clip_polygon_overflow_count;
	uint clip_divide_invalid_count;
	uint ndc_bbox_invalid_count;
	uint fully_clipped_splat_count;
	uint expected_span_saturated_count;
	uint expected_grazing_strip_count;
	uint rasterized_geometry_pixel_count;
	uint jacobian_measurable_pixel_count;
	uint jacobian_unmeasurable_pixel_count;
	uint unexpected_jacobian_unmeasurable_pixel_count;
	uint ray_structure_failure_count;
	uint max_world_extent_ratio_bits;
	uint max_diagonal_extent_ratio_bits;
	uint max_alignment_error_bits;
}
draw_counters;

layout(location = 0) in vec4 vertex_color;
layout(location = 1) in vec2 footprint_uv;
layout(location = 2) flat in uint debug_view_flat;
layout(location = 3) flat in uint probe_index_flat;
layout(location = 4) flat in uint vertex_valid_flat;
layout(location = 5) flat in vec4 transition_params_flat;
layout(location = 6) in vec3 world_position;
layout(location = 7) flat in uint object_id_flat;
layout(location = 8) flat in vec3 texel_center_world_position;
layout(location = 9) flat in float footprint_exponent_flat;
layout(location = 10) flat in vec3 base_surface_normal_flat;
layout(location = 11) flat in vec2 expected_screen_span_flat;
layout(location = 12) flat in float expected_world_edge_flat;
layout(location = 13) flat in uint texel_ref_flat;
layout(location = 14) flat in vec4 expected_screen_bbox_flat;
layout(location = 0) out vec4 frag_color;

const int PROBE_RELATION_UNKNOWN = 0;
const int PROBE_RELATION_MATCH = 1;
const int PROBE_RELATION_DIFFERENT_OBJECT = -1;
const int PROBE_RELATION_SAME_OBJECT_IN_FRONT = -2;
const int PROBE_RELATION_SAME_OBJECT_BEHIND = -3;

uint probe_face_from_direction(vec3 p_direction) {
	vec3 abs_direction = abs(p_direction);
	if (abs_direction.x >= abs_direction.y && abs_direction.x >= abs_direction.z) {
		return p_direction.x >= 0.0 ? 0u : 1u;
	}
	if (abs_direction.y >= abs_direction.z) {
		return p_direction.y >= 0.0 ? 2u : 3u;
	}
	return p_direction.z >= 0.0 ? 4u : 5u;
}

int probe_sample_relation(uint p_probe_index, vec3 p_world_position, uint p_object_id) {
	uint probe_size = uint(draw_state.params.x);
	uint base_layer = p_probe_index * 6u;
	vec3 probe_origin = draw_state.probe_transforms[base_layer][3].xyz;
	uint face = probe_face_from_direction(p_world_position - probe_origin);
	uint layer = base_layer + face;
	if ((draw_state.probe_masks.y & (1u << layer)) == 0u) {
		return 0;
	}
	vec3 probe_view_position = (draw_state.probe_inverse_transforms[layer] * vec4(p_world_position, 1.0)).xyz;
	if (probe_view_position.z >= -0.00001) {
		return 0;
	}
	vec2 probe_uv = probe_view_position.xy / -probe_view_position.z * 0.5 + 0.5;
	if (any(lessThan(probe_uv, vec2(0.0))) || any(greaterThanEqual(probe_uv, vec2(1.0)))) {
		return 0;
	}
	ivec2 probe_coord = ivec2(clamp(probe_uv * float(probe_size), vec2(0.0), vec2(float(probe_size - 1u))));
	uint sampled_object_id = texelFetch(probe_object_id, ivec3(probe_coord, int(layer)), 0).r;
	if (sampled_object_id == 0u) {
		return PROBE_RELATION_UNKNOWN;
	}
	if (sampled_object_id != p_object_id) {
		return PROBE_RELATION_DIFFERENT_OBJECT;
	}
	float sampled_radial_depth = texelFetch(probe_radial, ivec3(probe_coord, int(layer)), 0).r;
	if (sampled_radial_depth <= 0.0) {
		return PROBE_RELATION_UNKNOWN;
	}
	const ivec2 NEIGHBOR_OFFSETS[4] = ivec2[](ivec2(-1, 0), ivec2(1, 0), ivec2(0, -1), ivec2(0, 1));
	float nearest_same_object_depth = sampled_radial_depth;
	for (uint neighbor_index = 0u; neighbor_index < 4u; neighbor_index++) {
		ivec2 neighbor_coord = probe_coord + NEIGHBOR_OFFSETS[neighbor_index];
		if (any(lessThan(neighbor_coord, ivec2(0))) || any(greaterThanEqual(neighbor_coord, ivec2(int(probe_size))))) {
			continue;
		}
		ivec3 neighbor_probe_coord = ivec3(neighbor_coord, int(layer));
		if (texelFetch(probe_object_id, neighbor_probe_coord, 0).r != p_object_id) {
			continue;
		}
		float neighbor_depth = texelFetch(probe_radial, neighbor_probe_coord, 0).r;
		if (neighbor_depth > 0.0) {
			nearest_same_object_depth = min(nearest_same_object_depth, neighbor_depth);
		}
	}
	float expected_radial_depth = -probe_view_position.z;
	float depth_tolerance = max(0.05, expected_radial_depth * 3.0 / float(probe_size));
	if (nearest_same_object_depth < expected_radial_depth - depth_tolerance) {
		return PROBE_RELATION_SAME_OBJECT_IN_FRONT;
	}
	if (nearest_same_object_depth > expected_radial_depth + depth_tolerance) {
		return PROBE_RELATION_SAME_OBJECT_BEHIND;
	}
	return PROBE_RELATION_MATCH;
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

float screen_bayer4_threshold(ivec2 p_screen_position) {
	const float bayer[16] = float[](
			0.0 / 16.0, 8.0 / 16.0, 2.0 / 16.0, 10.0 / 16.0,
			12.0 / 16.0, 4.0 / 16.0, 14.0 / 16.0, 6.0 / 16.0,
			3.0 / 16.0, 11.0 / 16.0, 1.0 / 16.0, 9.0 / 16.0,
			15.0 / 16.0, 7.0 / 16.0, 13.0 / 16.0, 5.0 / 16.0);
	ivec2 cell = p_screen_position & ivec2(3);
	return bayer[cell.y * 4 + cell.x];
}

float transition_dither_threshold(vec3 p_world_position) {
	if (draw_state.probe_masks.w == 0u) {
		return screen_bayer4_threshold(ivec2(gl_FragCoord.xy));
	}
	return world_dither_threshold(p_world_position);
}

bool finite_fragment_vec2(vec2 p_value) {
	return !any(isnan(p_value)) && !any(isinf(p_value));
}

bool finite_fragment_vec3(vec3 p_value) {
	return !any(isnan(p_value)) && !any(isinf(p_value));
}

float srgb_code_to_linear_fragment(float p_srgb) {
	return p_srgb <= 0.04045 ? p_srgb / 12.92 : pow((p_srgb + 0.055) / 1.055, 2.4);
}

void main() {
	if (vertex_valid_flat == 0u || (debug_view_flat != 10u && vertex_color.a <= 0.0)) {
		discard;
	}

	vec2 footprint_position = abs(footprint_uv * 2.0 - 1.0);
	float footprint_value = pow(footprint_position.x, footprint_exponent_flat) + pow(footprint_position.y, footprint_exponent_flat);
	if (footprint_value > 1.0) {
		discard;
	}

	if (debug_view_flat == 10u) {
		ivec2 pixel = ivec2(gl_FragCoord.xy);
		if (pixel.x >= 0 && pixel.x < 256 && pixel.y >= 80 && pixel.y < 84) {
			float source_code = float(pixel.x) / 255.0;
			if (pixel.y == 80) {
				frag_color = vec4(srgb_code_to_linear_fragment(source_code), 0.0, 0.0, 1.0);
			} else if (pixel.y == 81) {
				frag_color = vec4(0.0, srgb_code_to_linear_fragment(source_code), 0.0, 1.0);
			} else if (pixel.y == 82) {
				frag_color = vec4(0.0, 0.0, srgb_code_to_linear_fragment(source_code), 1.0);
			} else {
				frag_color = vec4(0.0, 0.0, 0.0, source_code);
			}
			return;
		}
		frag_color = vertex_color;
		return;
	}

	if (debug_view_flat == 11u) {
		atomicAdd(draw_counters.rasterized_geometry_pixel_count, 1u);
		vec2 duv_dx = dFdx(footprint_uv);
		vec2 duv_dy = dFdy(footprint_uv);
		vec3 dworld_dx = dFdx(world_position);
		vec3 dworld_dy = dFdy(world_position);
		float det_uv = duv_dx.x * duv_dy.y - duv_dy.x * duv_dx.y;
		float det_normalized = abs(det_uv) / max(length(duv_dx) * length(duv_dy), 1e-12);
		bool derivative_finite = finite_fragment_vec2(duv_dx) && finite_fragment_vec2(duv_dy) &&
				finite_fragment_vec3(dworld_dx) && finite_fragment_vec3(dworld_dy) && !isnan(det_uv) && !isinf(det_uv);
		bool measurable = derivative_finite && abs(det_uv) >= 1e-8 && det_normalized >= 1e-3;
		if (!measurable) {
			atomicAdd(draw_counters.jacobian_unmeasurable_pixel_count, 1u);
			if (expected_screen_span_flat.y > 1.5) {
				atomicAdd(draw_counters.unexpected_jacobian_unmeasurable_pixel_count, 1u);
				frag_color = vec4(1.0, 0.0, 1.0, 1.0);
			} else {
				frag_color = vec4(0.05, 0.35, 1.0, 1.0);
			}
			return;
		}

		atomicAdd(draw_counters.jacobian_measurable_pixel_count, 1u);
		vec3 world_du = (dworld_dx * duv_dy.y - dworld_dy * duv_dx.y) / det_uv;
		vec3 world_dv = (-dworld_dx * duv_dy.x + dworld_dy * duv_dx.x) / det_uv;
		vec3 raster_cross = cross(world_du, world_dv);
		float raster_cross_length = length(raster_cross);
		float signed_alignment = raster_cross_length > 1e-10 ? dot(raster_cross / raster_cross_length, base_surface_normal_flat) : -1.0;
		float edge_ratio_u = expected_world_edge_flat > 0.0 ? length(world_du) / expected_world_edge_flat : 0.0;
		float edge_ratio_v = expected_world_edge_flat > 0.0 ? length(world_dv) / expected_world_edge_flat : 0.0;
		float max_edge_ratio = max(edge_ratio_u, edge_ratio_v);
		float min_edge_ratio = min(edge_ratio_u, edge_ratio_v);
		bool outside_expected_bbox = gl_FragCoord.x < expected_screen_bbox_flat.x - 1.5 ||
				gl_FragCoord.y < expected_screen_bbox_flat.y - 1.5 ||
				gl_FragCoord.x > expected_screen_bbox_flat.z + 1.5 ||
				gl_FragCoord.y > expected_screen_bbox_flat.w + 1.5;
		bool structure_failure = !finite_fragment_vec3(world_du) || !finite_fragment_vec3(world_dv) ||
				signed_alignment < 0.95 || max_edge_ratio > 1.01 || min_edge_ratio < 0.99 || outside_expected_bbox;
		if (structure_failure) {
			atomicAdd(draw_counters.ray_structure_failure_count, 1u);
		}
		atomicMax(draw_counters.max_world_extent_ratio_bits, floatBitsToUint(max(max_edge_ratio, 0.0)));
		atomicMax(draw_counters.max_alignment_error_bits, floatBitsToUint(max(1.0 - signed_alignment, 0.0)));
		if (outside_expected_bbox) {
			frag_color = vec4(1.0, 0.0, 1.0, 1.0);
		} else if (signed_alignment < 0.95) {
			frag_color = vec4(1.0, 0.0, 0.0, 1.0);
		} else if (max_edge_ratio > 1.01 || min_edge_ratio < 0.99) {
			frag_color = vec4(1.0, 0.42, 0.0, 1.0);
		} else {
			frag_color = vec4(0.0, 1.0, 0.08, 1.0);
		}
		return;
	}

	float fade = clamp(transition_params_flat.x, 0.0, 1.0);
	float threshold = transition_dither_threshold(world_position);
	uint current_probe_index = uint(round(transition_params_flat.y));
	uint previous_probe_index = uint(round(transition_params_flat.z));
	if (draw_state.probe_masks.z != 0u && transition_params_flat.w > 0.5 && probe_index_flat == previous_probe_index) {
		int fragment_relation = probe_sample_relation(0u, world_position, object_id_flat);
		if (fragment_relation == PROBE_RELATION_DIFFERENT_OBJECT ||
				fragment_relation == PROBE_RELATION_SAME_OBJECT_IN_FRONT ||
				(fragment_relation == PROBE_RELATION_SAME_OBJECT_BEHIND && probe_sample_relation(0u, texel_center_world_position, object_id_flat) < 0)) {
			discard;
		}
	}
	if (transition_params_flat.w > 0.5) {
		if (probe_index_flat == current_probe_index && threshold >= fade) {
			discard;
		}
		if (probe_index_flat == previous_probe_index && threshold < fade) {
			discard;
		}
	}

	if (debug_view_flat == 6u) {
		float center_distance = min(abs(footprint_uv.x - 0.5), abs(footprint_uv.y - 0.5));
		if (center_distance < 0.035) {
			frag_color = vec4(1.0, 0.95, 0.0, 1.0);
		} else if (footprint_value > 0.72) {
			frag_color = vec4(1.0, 0.0, 0.95, 1.0);
		} else {
			frag_color = vec4(0.0, 0.75, 1.0, 1.0);
		}
		return;
	}

	frag_color = vertex_color;
}
