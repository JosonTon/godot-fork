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
	mat4 probe_transforms[18];
	vec4 params;
	vec4 debug_params;
}
draw_state;

layout(location = 0) out vec4 vertex_color;

const vec2 QUAD[6] = vec2[](
	vec2(-0.5, -0.5),
	vec2(0.5, -0.5),
	vec2(-0.5, 0.5),
	vec2(-0.5, 0.5),
	vec2(0.5, -0.5),
	vec2(0.5, 0.5)
);

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

	vec2 uv = (vec2(x, y) + vec2(0.5)) / float(probe_size);
	float half_texel = 0.5 / float(probe_size);
	float expansion = max(draw_state.params.y, 0.0) / float(probe_size);
	float half_splat = half_texel + expansion;
	vec2 corner_uv = uv + QUAD[gl_VertexIndex] * 2.0 * half_splat;
	vec2 corner_face_xy = corner_uv * 2.0 - 1.0;
	vec3 raw_dir = vec3(corner_face_xy.x, -corner_face_xy.y, -1.0);
	float max_comp = max(abs(raw_dir.x), max(abs(raw_dir.y), abs(raw_dir.z)));
	vec3 probe_view_pos = raw_dir * (radial_depth / max(max_comp, 0.00001));
	vec4 world_pos = draw_state.probe_transforms[layer] * vec4(probe_view_pos, 1.0);
	gl_Position = draw_state.view_projection * world_pos;

	uint flags = splat_flags.data[texel_ref];
	int selected_layer = int(round(draw_state.debug_params.y));
	if (selected_layer >= 0 && int(layer) != selected_layer) {
		vertex_color = vec4(0.0);
		return;
	}

	uint debug_view = uint(draw_state.debug_params.x);
	bool edge = (flags & 2u) != 0u;
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
		color = encoded_normal;
	} else if (debug_view == 4u) {
		color = hash_color(object_id);
	} else if (debug_view == 5u) {
		color = hash_color(layer + 1u);
	}

	vertex_color = vec4(color, min(max(albedo.a, 0.35), 1.0));
}

#[fragment]

#version 450

#VERSION_DEFINES

layout(location = 0) in vec4 vertex_color;
layout(location = 0) out vec4 frag_color;

void main() {
	if (vertex_color.a <= 0.0) {
		discard;
	}
	frag_color = vertex_color;
}
