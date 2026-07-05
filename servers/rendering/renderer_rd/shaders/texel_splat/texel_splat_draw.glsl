#[vertex]

#version 450

#VERSION_DEFINES

layout(set = 0, binding = 0) uniform sampler2DArray probe_albedo;
layout(set = 0, binding = 1) uniform sampler2DArray probe_radial;

layout(set = 0, binding = 2, std430) restrict readonly buffer VisibleRefs {
	uint data[];
}
visible_refs;

layout(set = 0, binding = 3, std430) restrict readonly buffer SplatFlags {
	uint data[];
}
splat_flags;

layout(set = 0, binding = 4, std430) restrict readonly buffer DrawState {
	mat4 view_projection;
	mat4 probe_transforms[18];
	vec4 params;
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

void main() {
	uint probe_size = uint(draw_state.params.x);
	uint texel_ref = visible_refs.data[gl_InstanceIndex];
	uint layer = texel_ref / (probe_size * probe_size);
	uint layer_texel = texel_ref - layer * probe_size * probe_size;
	uint y = layer_texel / probe_size;
	uint x = layer_texel - y * probe_size;

	ivec3 probe_coord = ivec3(int(x), int(y), int(layer));
	vec4 albedo = texelFetch(probe_albedo, probe_coord, 0);
	float radial_depth = texelFetch(probe_radial, probe_coord, 0).r;

	vec2 uv = (vec2(x, y) + vec2(0.5)) / float(probe_size);
	vec2 face_xy = uv * 2.0 - 1.0;
	vec3 probe_view_pos = vec3(face_xy.x * radial_depth, -face_xy.y * radial_depth, -radial_depth);
	vec4 world_pos = draw_state.probe_transforms[layer] * vec4(probe_view_pos, 1.0);
	vec4 clip_pos = draw_state.view_projection * world_pos;

	vec2 viewport_size = max(draw_state.params.zw, vec2(1.0));
	vec2 ndc_pixel = QUAD[gl_VertexIndex] * draw_state.params.y * 2.0 / viewport_size;
	clip_pos.xy += ndc_pixel * clip_pos.w;
	gl_Position = clip_pos;

	uint flags = splat_flags.data[texel_ref];
	vec3 edge_tint = ((flags & 2u) != 0u) ? vec3(1.0, 0.55, 0.25) : vec3(1.0);
	vertex_color = vec4(albedo.rgb * edge_tint, min(max(albedo.a, 0.35), 1.0));
}

#[fragment]

#version 450

#VERSION_DEFINES

layout(location = 0) in vec4 vertex_color;
layout(location = 0) out vec4 frag_color;

void main() {
	frag_color = vertex_color;
}
