#[vertex]

#version 450

#VERSION_DEFINES

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
	mat4 probe_transforms[6];
	vec4 params;
	vec4 debug_params;
	vec4 directional_light_direction;
	vec4 directional_light_color;
	vec4 camera_position;
}
draw_state;

layout(location = 0) out vec4 vertex_color;
layout(location = 1) out vec2 footprint_uv;
layout(location = 2) flat out uint debug_view_flat;

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

vec3 decode_probe_normal(vec3 encoded_normal) {
	return normalize(encoded_normal * 2.0 - 1.0);
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

void main() {
	uint probe_size = uint(draw_state.params.x);
	uint texel_ref = visible_refs.data[gl_InstanceIndex];
	uint layer = texel_ref / (probe_size * probe_size);
	uint layer_texel = texel_ref - layer * probe_size * probe_size;
	uint y = layer_texel / probe_size;
	uint x = layer_texel - y * probe_size;

	ivec3 probe_coord = ivec3(int(x), int(y), int(layer));
	vec4 albedo = texelFetch(probe_albedo, probe_coord, 0);
	vec3 encoded_normal = texelFetch(probe_normal, probe_coord, 0).xyz;
	float radial_depth = texelFetch(probe_radial, probe_coord, 0).r;
	uint object_id = texelFetch(probe_object_id, probe_coord, 0).r;
	uint flags = splat_flags.data[texel_ref];

	vec2 uv = (vec2(x, y) + vec2(0.5)) / float(probe_size);
	float half_texel = 0.5 / float(probe_size);
	float expansion = max(draw_state.params.y, 0.0) / float(probe_size);
	vec4 center_world_pos = probe_world_position(layer, uv, radial_depth);
	vec3 face_normal = normalize(mat3(draw_state.probe_transforms[layer]) * vec3(0.0, 0.0, -1.0));
	vec3 view_dir = normalize(center_world_pos.xyz - draw_state.camera_position.xyz);
	float cos_theta = max(abs(dot(view_dir, face_normal)), 0.14);
	float tan_theta = sqrt(max(1.0 - cos_theta * cos_theta, 0.0)) / cos_theta;
	float half_edge = half_texel * 1.15 + 0.0005 * tan_theta;
	float half_fill = max(half_texel + expansion, half_edge);
	float half_left = (flags & FLAG_CONT_LEFT) != 0u ? half_edge : half_fill;
	float half_right = (flags & FLAG_CONT_RIGHT) != 0u ? half_edge : half_fill;
	float half_bottom = (flags & FLAG_CONT_BOTTOM) != 0u ? half_edge : half_fill;
	float half_top = (flags & FLAG_CONT_TOP) != 0u ? half_edge : half_fill;
	vec2 quad_corner = QUAD[gl_VertexIndex] * 2.0;
	vec2 corner_uv = uv + vec2(quad_corner.x < 0.0 ? -half_left : half_right, quad_corner.y < 0.0 ? -half_bottom : half_top);
	vec4 world_pos = probe_world_position(layer, corner_uv, radial_depth);
	gl_Position = draw_state.view_projection * world_pos;
	uint h = ((layer * probe_size * probe_size + y * probe_size + x) * 2654435761u) >> 24u;
	gl_Position.z += float(h) * 1e-9 * gl_Position.w;
	gl_Position.z = min(gl_Position.z, gl_Position.w);

	uint debug_view = uint(draw_state.debug_params.x);
	footprint_uv = QUAD[gl_VertexIndex] + vec2(0.5);
	debug_view_flat = debug_view;

	int selected_layer = int(round(draw_state.debug_params.y));
	if (selected_layer >= 0 && int(layer) != selected_layer) {
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
		color = decode_probe_normal(encoded_normal) * 0.5 + 0.5;
	} else if (debug_view == 4u) {
		color = hash_color(object_id);
	} else if (debug_view == 5u) {
		color = hash_color(layer + 1u);
	} else if (debug_view == 6u) {
		vertex_color = vec4(0.0, 0.75, 1.0, 1.0);
		return;
	}

	if (debug_view == 0u && draw_state.directional_light_direction.w > 0.5) {
		vec3 world_normal = decode_probe_normal(encoded_normal);
		vec3 light_direction = normalize(draw_state.directional_light_direction.xyz);
		float diffuse = max(dot(world_normal, light_direction), 0.0);
		vec3 lighting = vec3(draw_state.directional_light_color.a) + draw_state.directional_light_color.rgb * diffuse;
		color = clamp(color * lighting, vec3(0.0), vec3(1.0));
	}

	vertex_color = vec4(color, min(max(albedo.a, 0.35), 1.0));
}

#[fragment]

#version 450

#VERSION_DEFINES

layout(location = 0) in vec4 vertex_color;
layout(location = 1) in vec2 footprint_uv;
layout(location = 2) flat in uint debug_view_flat;
layout(location = 0) out vec4 frag_color;

void main() {
	if (vertex_color.a <= 0.0) {
		discard;
	}

	if (debug_view_flat == 6u) {
		float border_distance = min(min(footprint_uv.x, 1.0 - footprint_uv.x), min(footprint_uv.y, 1.0 - footprint_uv.y));
		float center_distance = min(abs(footprint_uv.x - 0.5), abs(footprint_uv.y - 0.5));
		if (center_distance < 0.035) {
			frag_color = vec4(1.0, 0.95, 0.0, 1.0);
		} else if (border_distance < 0.08) {
			frag_color = vec4(1.0, 0.0, 0.95, 1.0);
		} else {
			frag_color = vec4(0.0, 0.75, 1.0, 1.0);
		}
		return;
	}

	frag_color = vertex_color;
}
