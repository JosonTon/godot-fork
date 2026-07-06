#[compute]

#version 450

#VERSION_DEFINES

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2DArray probe_albedo;
layout(set = 0, binding = 1) uniform sampler2DArray probe_normal;
layout(set = 0, binding = 2) uniform sampler2DArray probe_radial;
layout(set = 0, binding = 3) uniform usampler2DArray probe_object_id;

layout(set = 0, binding = 4, std430) restrict buffer VisibleRefs {
	uint data[];
}
visible_refs;

layout(set = 0, binding = 5, std430) restrict buffer SplatFlags {
	uint data[];
}
splat_flags;

layout(set = 0, binding = 6, std430) restrict buffer Counters {
	uint visible_count;
	uint classified_count;
	uint edge_count;
	uint pad;
}
counters;

layout(set = 0, binding = 7, std430) restrict buffer DrawArgs {
	uint vertex_count;
	uint instance_count;
	uint first_vertex;
	uint first_instance;
}
draw_args;

layout(push_constant, std430) uniform Params {
	uint probe_size;
	uint layer_count;
	uint max_visible_refs;
	uint pad;
}
params;

uint get_texel_index(uvec3 p_coord) {
	return (p_coord.z * params.probe_size + p_coord.y) * params.probe_size + p_coord.x;
}

vec3 face_normal(uint p_face) {
	if (p_face == 0u) {
		return vec3(1.0, 0.0, 0.0);
	} else if (p_face == 1u) {
		return vec3(-1.0, 0.0, 0.0);
	} else if (p_face == 2u) {
		return vec3(0.0, 1.0, 0.0);
	} else if (p_face == 3u) {
		return vec3(0.0, -1.0, 0.0);
	} else if (p_face == 4u) {
		return vec3(0.0, 0.0, 1.0);
	}
	return vec3(0.0, 0.0, -1.0);
}

vec3 face_up(uint p_face) {
	if (p_face == 2u) {
		return vec3(0.0, 0.0, 1.0);
	} else if (p_face == 3u) {
		return vec3(0.0, 0.0, -1.0);
	}
	return vec3(0.0, -1.0, 0.0);
}

vec3 face_right(uint p_face) {
	vec3 normal = face_normal(p_face);
	vec3 up = face_up(p_face);
	return normalize(cross(up, -normal));
}

vec3 face_direction(uint p_face, vec2 p_face_xy) {
	vec3 normal = face_normal(p_face);
	vec3 up = face_up(p_face);
	vec3 right = face_right(p_face);
	return normalize(normal + right * p_face_xy.x - up * p_face_xy.y);
}

uint direction_face(vec3 p_direction) {
	vec3 ad = abs(p_direction);
	if (ad.x >= ad.y && ad.x >= ad.z) {
		return p_direction.x >= 0.0 ? 0u : 1u;
	} else if (ad.y >= ad.x && ad.y >= ad.z) {
		return p_direction.y >= 0.0 ? 2u : 3u;
	}
	return p_direction.z >= 0.0 ? 4u : 5u;
}

vec2 direction_face_xy(vec3 p_direction, uint p_face) {
	vec3 normal = face_normal(p_face);
	vec3 up = face_up(p_face);
	vec3 right = face_right(p_face);
	float denom = max(dot(p_direction, normal), 0.00001);
	return vec2(dot(p_direction, right) / denom, -dot(p_direction, up) / denom);
}

ivec3 resolve_neighbor_coord(ivec3 p_coord, ivec2 p_offset) {
	ivec2 neighbor_xy = p_coord.xy + p_offset;
	if (neighbor_xy.x >= 0 && neighbor_xy.y >= 0 && uint(neighbor_xy.x) < params.probe_size && uint(neighbor_xy.y) < params.probe_size) {
		return ivec3(neighbor_xy, p_coord.z);
	}

	uint probe = uint(p_coord.z) / 6u;
	uint current_face = uint(p_coord.z) - probe * 6u;
	vec2 uv = (vec2(neighbor_xy) + vec2(0.5)) / float(params.probe_size);
	vec2 current_face_xy = uv * 2.0 - 1.0;
	vec3 direction = face_direction(current_face, current_face_xy);
	uint neighbor_face = direction_face(direction);
	vec2 neighbor_face_xy = direction_face_xy(direction, neighbor_face);
	vec2 neighbor_uv = neighbor_face_xy * 0.5 + 0.5;
	ivec2 resolved_xy = ivec2(clamp(floor(neighbor_uv * float(params.probe_size)), vec2(0.0), vec2(float(params.probe_size - 1u))));
	uint resolved_layer = probe * 6u + neighbor_face;
	return ivec3(resolved_xy, int(resolved_layer));
}

bool is_edge_texel(ivec3 p_coord, uint p_object_id, vec3 p_normal) {
	bool edge = false;

	ivec3 neighbor_coord = resolve_neighbor_coord(p_coord, ivec2(1, 0));
	uint neighbor_object_id = texelFetch(probe_object_id, neighbor_coord, 0).r;
	vec3 neighbor_normal = normalize(texelFetch(probe_normal, neighbor_coord, 0).xyz * 2.0 - 1.0);
	edge = edge || neighbor_object_id != p_object_id || dot(p_normal, neighbor_normal) < 0.85;

	neighbor_coord = resolve_neighbor_coord(p_coord, ivec2(0, 1));
	neighbor_object_id = texelFetch(probe_object_id, neighbor_coord, 0).r;
	neighbor_normal = normalize(texelFetch(probe_normal, neighbor_coord, 0).xyz * 2.0 - 1.0);
	edge = edge || neighbor_object_id != p_object_id || dot(p_normal, neighbor_normal) < 0.85;

	return edge;
}

void main() {
	uvec3 coord = gl_GlobalInvocationID;
	if (coord.x >= params.probe_size || coord.y >= params.probe_size || coord.z >= params.layer_count) {
		return;
	}

	ivec3 icoord = ivec3(coord);
	uint texel_index = get_texel_index(coord);
	uint object_id = texelFetch(probe_object_id, icoord, 0).r;
	vec4 albedo = texelFetch(probe_albedo, icoord, 0);
	float radial_depth = texelFetch(probe_radial, icoord, 0).r;

	bool visible = object_id != 0u && radial_depth > 0.0 && albedo.a > 0.0;
	uint flags = visible ? 1u : 0u;

	if (visible) {
		vec3 normal = normalize(texelFetch(probe_normal, icoord, 0).xyz * 2.0 - 1.0);
		bool edge = is_edge_texel(icoord, object_id, normal);
		flags |= edge ? 2u : 0u;

		uint compact_index = atomicAdd(draw_args.instance_count, 1u);
		if (compact_index < params.max_visible_refs) {
			visible_refs.data[compact_index] = texel_index;
		}

		atomicAdd(counters.visible_count, 1u);
		atomicAdd(counters.classified_count, 1u);
		if (edge) {
			atomicAdd(counters.edge_count, 1u);
		}
	}

	splat_flags.data[texel_index] = flags;
}
