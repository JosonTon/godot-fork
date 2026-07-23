#[vertex]

#version 450

#VERSION_DEFINES

void main() {
	vec2 position = vec2((gl_VertexIndex == 1) ? 3.0 : -1.0, (gl_VertexIndex == 2) ? 3.0 : -1.0);
	gl_Position = vec4(position, 0.0, 1.0);
}

#[fragment]

#version 450

#VERSION_DEFINES

layout(set = 0, binding = 0) uniform sampler2D grid_color;
layout(set = 0, binding = 1) uniform sampler2D grid_depth;
layout(set = 0, binding = 2) uniform usampler2D grid_meta;

layout(set = 0, binding = 3, std430) restrict readonly buffer DrawState {
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

layout(location = 0) out vec4 frag_color;

const uint META_VALID = 1u;

void main() {
	ivec2 pixel = ivec2(gl_FragCoord.xy);
	ivec2 cell;
	if (draw_state.camera_position.w > 0.5) {
		const int owner_pixel_scale = 4;
		const int owner_subdivisions = 2;
		ivec2 viewport_size = ivec2(draw_state.params.yz);
		ivec2 coarse = pixel / owner_pixel_scale;
		ivec2 origin = coarse * owner_pixel_scale;
		ivec2 extent = max(min(ivec2(owner_pixel_scale), viewport_size - origin), ivec2(1));
		ivec2 local = pixel - origin;
		ivec2 subcell = min((local * owner_subdivisions) / extent, ivec2(owner_subdivisions - 1));
		cell = coarse * owner_subdivisions + subcell;
	} else {
		int pixel_scale = max(int(round(draw_state.grid_params.z)), 1);
		cell = pixel / pixel_scale;
	}
	ivec2 grid_size = ivec2(draw_state.grid_params.xy);
	if (any(lessThan(cell, ivec2(0))) || any(greaterThanEqual(cell, grid_size))) {
		discard;
	}

	uint meta = texelFetch(grid_meta, cell, 0).r;
	if ((meta & META_VALID) == 0u) {
		discard;
	}

	float depth = texelFetch(grid_depth, cell, 0).r;
	if (depth < 0.0 || depth > 1.0 || isnan(depth) || isinf(depth)) {
		discard;
	}

	vec4 color = texelFetch(grid_color, cell, 0);
	if (color.a <= 0.0) {
		discard;
	}

	frag_color = color;
	gl_FragDepth = depth;
}
