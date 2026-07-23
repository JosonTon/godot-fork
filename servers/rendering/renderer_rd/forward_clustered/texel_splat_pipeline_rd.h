/**************************************************************************/
/*  texel_splat_pipeline_rd.h                                             */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#pragma once

#include "core/math/color.h"
#include "core/math/projection.h"
#include "core/math/transform_3d.h"
#include "core/templates/vector.h"
#include "servers/rendering/renderer_rd/pipeline_cache_rd.h"
#include "servers/rendering/renderer_rd/shaders/texel_splat/texel_splat_composite.glsl.gen.h"
#include "servers/rendering/renderer_rd/shaders/texel_splat/texel_splat_owner_boundary.glsl.gen.h"
#include "servers/rendering/renderer_rd/shaders/texel_splat/texel_splat_process.glsl.gen.h"
#include "servers/rendering/renderer_rd/shaders/texel_splat/texel_splat_resolve.glsl.gen.h"
#include "servers/rendering/rendering_device.h"

namespace RendererSceneRenderImplementation {

class TexelSplatPipelineRD {
	static const uint32_t DEFAULT_PROBE_SIZE = 384;
	// Stage 5 reserves persistent eye/current/previous cubemap slots. The frame
	// scheduler decides which of these layers are captured and drawn.
	static const uint32_t PROBE_COUNT = 3;
	static const uint32_t PROBE_FACE_COUNT = 6;
	static const uint32_t PROBE_LAYER_COUNT = PROBE_COUNT * PROBE_FACE_COUNT;

	enum ProbeTexture {
		PROBE_TEXTURE_ALBEDO,
		PROBE_TEXTURE_NORMAL,
		PROBE_TEXTURE_RADIAL,
		PROBE_TEXTURE_OBJECT_ID,
		PROBE_TEXTURE_DEPTH,
		PROBE_TEXTURE_LIT,
		PROBE_TEXTURE_MAX
	};

	struct ProbeTextureData {
		RID texture;
		RD::DataFormat format = RD::DATA_FORMAT_MAX;
		uint32_t usage_bits = 0;
	};

	struct ProbeLayerData {
		RID albedo_view;
		RID normal_view;
		RID radial_view;
		RID object_id_view;
		RID depth_view;
		RID framebuffer;
	};

	struct ProcessPushConstant {
		uint32_t probe_size = 0;
		uint32_t layer_count = 0;
		uint32_t max_visible_refs = 0;
		uint32_t active_layer_mask = 0;
	};

	struct CounterData {
		uint32_t visible_count = 0;
		uint32_t classified_count = 0;
		uint32_t edge_count = 0;
		uint32_t cross_face_sample_count = 0;
		uint32_t cross_face_resolved_count = 0;
		uint32_t cross_face_empty_suppressed_count = 0;
		uint32_t cross_face_edge_count = 0;
		uint32_t cross_object_continuity_count = 0;
		uint32_t invalid_base_surface_normal_count = 0;
		uint32_t pre_raster_splat_count = 0;
		uint32_t invalid_or_nonfinite_splat_count = 0;
		uint32_t degenerate_splat_count = 0;
		uint32_t winding_failure_count = 0;
		uint32_t extent_failure_count = 0;
		uint32_t clip_nonfinite_count = 0;
		uint32_t clip_polygon_overflow_count = 0;
		uint32_t clip_divide_invalid_count = 0;
		uint32_t ndc_bbox_invalid_count = 0;
		uint32_t fully_clipped_splat_count = 0;
		uint32_t expected_span_saturated_count = 0;
		uint32_t expected_grazing_strip_count = 0;
		uint32_t rasterized_geometry_pixel_count = 0;
		uint32_t jacobian_measurable_pixel_count = 0;
		uint32_t jacobian_unmeasurable_pixel_count = 0;
		uint32_t unexpected_jacobian_unmeasurable_pixel_count = 0;
		uint32_t ray_structure_failure_count = 0;
		uint32_t max_world_extent_ratio_bits = 0;
		uint32_t max_diagonal_extent_ratio_bits = 0;
		uint32_t max_alignment_error_bits = 0;
	};

	struct DrawIndirectArgs {
		uint32_t vertex_count = 6;
		uint32_t instance_count = 0;
		uint32_t first_vertex = 0;
		uint32_t first_instance = 0;
	};

	struct DrawState {
		float view_projection[16] = {};
		float inverse_view_projection[16] = {};
		float probe_transforms[PROBE_LAYER_COUNT][16] = {};
		float probe_inverse_transforms[PROBE_LAYER_COUNT][16] = {};
		float params[4] = {};
		float grid_params[4] = {};
		float debug_params[4] = {};
		float directional_light_direction[4] = {};
		float directional_light_color[4] = {};
		float camera_position[4] = {};
		float transition_params[4] = {};
		uint32_t probe_masks[4] = {};
		float reprojection_params[4] = {};
		float reprojection_control[4] = {};
	};
	static_assert(sizeof(DrawState) == 2592, "Texel splatting DrawState must match the std430 shader ABI.");

	enum DebugView {
		DEBUG_VIEW_ALBEDO,
		DEBUG_VIEW_EDGE,
		DEBUG_VIEW_CAMERA_DISTANCE,
		DEBUG_VIEW_NORMAL,
		DEBUG_VIEW_OBJECT_ID,
		DEBUG_VIEW_LAYER,
		DEBUG_VIEW_FOOTPRINT,
		DEBUG_VIEW_PROBE_ROLE,
		DEBUG_VIEW_QUAD_NORMAL,
		DEBUG_VIEW_SURFACE_ALIGNMENT_ERROR,
		DEBUG_VIEW_SPLAT_ID,
		DEBUG_VIEW_RASTER_GEOMETRY,
		DEBUG_VIEW_VALIDITY,
		DEBUG_VIEW_PROBE_UV_FACE,
		DEBUG_VIEW_FALLBACK_REASON,
		DEBUG_VIEW_OWNER_BOUNDARY_ROLE,
		DEBUG_VIEW_MAX
	};

	struct ScreenGridResources {
		RID color;
		RID depth;
		RID meta;
		RID native_color;
		RID native_depth;
		RID native_meta;
		RID native_camera_depth;
		RID native_albedo;
		RID native_normal;
		RID resolve_uniform_set;
		RID owner_boundary_uniform_set;
		RID composite_uniform_set;
		Size2i size;
		Size2i native_size;
		bool owner_boundary_enabled = false;
		bool copy_from_enabled = false;
	};

	ProbeTextureData probe_textures[PROBE_TEXTURE_MAX];
	ProbeLayerData probe_layers[PROBE_LAYER_COUNT];
	TexelSplatProcessShaderRD process_shader;
	TexelSplatResolveShaderRD resolve_shader;
	TexelSplatOwnerBoundaryShaderRD owner_boundary_shader;
	TexelSplatCompositeShaderRD composite_shader;
	RID process_shader_version;
	RID resolve_shader_version;
	RID owner_boundary_shader_version;
	RID composite_shader_version;
	RID process_shader_rd;
	RID resolve_shader_rd;
	RID owner_boundary_shader_rd;
	RID composite_shader_rd;
	RID process_pipeline;
	RID resolve_pipeline;
	RID owner_boundary_pipeline;
	PipelineCacheRD composite_pipeline;
	RID process_uniform_set;
	RID visible_refs_buffer;
	RID splat_flags_buffer;
	RID counter_buffer;
	RID draw_args_buffer;
	RID draw_state_buffer;
	ScreenGridResources screen_grid;
	RID prepared_composite_framebuffer;
	RID prepared_composite_pipeline;
	DrawState prepared_draw_state;
	uint32_t probe_size = DEFAULT_PROBE_SIZE;
	uint32_t texel_capacity = 0;
	uint32_t pixel_scale = 4;
	float splat_expansion_texels = 0.5f;
	uint32_t transition_dither_mode = 0;
	uint32_t debug_view = DEBUG_VIEW_ALBEDO;
	int32_t debug_probe_layer = -1;
	uint32_t reprojection_source_mode = 0;
	bool debug_log_counters = false;
	uint32_t debug_log_counter_interval = 60;
	uint64_t debug_frame_index = 0;
	bool debug_raw_dump_enabled = false;
	String debug_raw_dump_path;
	uint64_t debug_raw_dump_start_frame = 0;
	uint64_t debug_raw_dump_frame_count = 0;
	bool draw_depth_test_enabled = false;
	bool disocclusion_guard_enabled = true;
	bool depth_tie_bias_enabled = true;
	uint32_t reprojection_scan_steps = 12;
	uint32_t reprojection_bisection_steps = 8;
	float reprojection_min_tolerance = 0.0025f;
	float reprojection_max_tolerance = 0.25f;
	float reprojection_texel_tolerance_scale = 1.5f;
	float reprojection_search_back_tolerance_scale = 4.0f;
	float reprojection_search_forward_tolerance_scale = 1.0f;
	bool owner_boundary_enabled = false;
	bool initialized = false;
	bool composite_prepared = false;

	void _load_project_settings();
	bool _create_probe_textures();
	bool _create_probe_framebuffers();
	bool _create_process_resources();
	bool _create_draw_resources();
	bool _create_screen_grid_resources(const Size2i &p_grid_size, const Size2i &p_viewport_size, bool p_owner_boundary_enabled, ScreenGridResources &r_resources);
	void _dispatch_resolve(RenderingDevice *p_rd);
	void _debug_log_counters(RenderingDevice *p_rd);
	void _debug_dump_screen_grid(RenderingDevice *p_rd);
	bool _debug_write_screen_grid_dump(RenderingDevice *p_rd, uint32_t p_debug_view);
	bool _is_format_supported(RD::DataFormat p_format, uint32_t p_usage_bits, const char *p_label) const;
	RD::DataFormat _select_depth_format(uint32_t p_usage_bits) const;
	RID _create_screen_grid_texture(RD::DataFormat p_format, const Size2i &p_size, uint32_t p_usage_bits, const char *p_label) const;
	RID _create_probe_texture(RD::DataFormat p_format, uint32_t p_usage_bits, const char *p_label) const;
	RID _create_probe_texture_slice(RID p_texture, uint32_t p_layer, const char *p_label) const;
	void _free_probe_textures();
	void _free_probe_framebuffers();
	void _free_process_resources();
	void _free_draw_resources();
	void _free_screen_grid_resources(ScreenGridResources &r_resources);

public:
	static uint32_t normalize_probe_size(int32_t p_requested_size);
	static uint32_t get_static_probe_count() { return PROBE_COUNT; }
	static uint32_t get_static_probe_face_count() { return PROBE_FACE_COUNT; }
	static uint32_t get_static_probe_layer_count() { return PROBE_LAYER_COUNT; }
	bool initialize();
	void free();
	void sync_project_settings();
	bool process_probe_data(uint32_t p_active_layer_mask);
	bool ensure_screen_grid(const Size2i &p_viewport_size);
	bool prepare_resolve_and_composite(RID p_framebuffer, const Projection &p_view_projection, float p_camera_far, const Vector<Transform3D> &p_probe_transforms, const Size2i &p_viewport_size, const Vector3 &p_camera_position, float p_grid_step, uint32_t p_eye_face_mask, uint32_t p_current_face_mask, uint32_t p_previous_face_mask, uint32_t p_current_probe_index, uint32_t p_previous_probe_index, float p_transition_fade, bool p_transitioning, const Vector3 &p_directional_light_direction, const Color &p_directional_light_color, bool p_directional_light_enabled);
	void execute_prepared_resolve_and_composite();
	void discard_prepared_resolve_and_composite();
	bool is_initialized() const { return initialized; }
	uint32_t get_probe_size() const { return probe_size; }
	uint32_t get_pixel_scale() const { return pixel_scale; }
	uint32_t get_probe_count() const { return PROBE_COUNT; }
	uint32_t get_probe_face_count() const { return PROBE_FACE_COUNT; }
	uint32_t get_probe_layer_count() const { return PROBE_LAYER_COUNT; }
	uint32_t get_texel_capacity() const { return texel_capacity; }
	bool is_draw_depth_test_enabled() const { return draw_depth_test_enabled; }
	RID get_visible_refs_buffer() const { return visible_refs_buffer; }
	RID get_splat_flags_buffer() const { return splat_flags_buffer; }
	RID get_draw_args_buffer() const { return draw_args_buffer; }
	RID get_probe_layer_framebuffer(uint32_t p_layer) const;
	RD::FramebufferFormatID get_probe_framebuffer_format() const;

	TexelSplatPipelineRD();
	~TexelSplatPipelineRD();
};

} // namespace RendererSceneRenderImplementation
