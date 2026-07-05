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

bool is_edge_texel(ivec3 p_coord, uint p_object_id, vec3 p_normal) {
	bool edge = false;

	if (uint(p_coord.x + 1) < params.probe_size) {
		ivec3 neighbor_coord = p_coord + ivec3(1, 0, 0);
		uint neighbor_object_id = texelFetch(probe_object_id, neighbor_coord, 0).r;
		vec3 neighbor_normal = normalize(texelFetch(probe_normal, neighbor_coord, 0).xyz * 2.0 - 1.0);
		edge = edge || neighbor_object_id != p_object_id || dot(p_normal, neighbor_normal) < 0.85;
	}

	if (uint(p_coord.y + 1) < params.probe_size) {
		ivec3 neighbor_coord = p_coord + ivec3(0, 1, 0);
		uint neighbor_object_id = texelFetch(probe_object_id, neighbor_coord, 0).r;
		vec3 neighbor_normal = normalize(texelFetch(probe_normal, neighbor_coord, 0).xyz * 2.0 - 1.0);
		edge = edge || neighbor_object_id != p_object_id || dot(p_normal, neighbor_normal) < 0.85;
	}

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
