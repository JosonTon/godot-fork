/**************************************************************************/
/*  texel_splat_pipeline_rd.cpp                                           */
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

#include "texel_splat_pipeline_rd.h"

#include "core/config/project_settings.h"
#include "core/error/error_macros.h"
#include "core/io/file_access.h"
#include "core/string/print_string.h"
#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/rendering_server_globals.h"
#include "servers/rendering/storage/utilities.h"

namespace RendererSceneRenderImplementation {

TexelSplatPipelineRD::TexelSplatPipelineRD() = default;

TexelSplatPipelineRD::~TexelSplatPipelineRD() {
	free();
}

bool TexelSplatPipelineRD::initialize() {
	if (initialized) {
		return true;
	}

	_load_project_settings();

	if (!_create_probe_textures()) {
		free();
		return false;
	}

	if (!_create_probe_framebuffers()) {
		free();
		return false;
	}

	if (!_create_process_resources()) {
		free();
		return false;
	}

	if (!_create_draw_resources()) {
		free();
		return false;
	}

	initialized = true;
	return true;
}

void TexelSplatPipelineRD::free() {
	discard_prepared_resolve_and_composite();
	_free_screen_grid_resources(screen_grid);
	_free_draw_resources();
	_free_process_resources();
	_free_probe_framebuffers();
	_free_probe_textures();
	initialized = false;
}

void TexelSplatPipelineRD::sync_project_settings() {
	_load_project_settings();
}

bool TexelSplatPipelineRD::process_probe_data(uint32_t p_active_layer_mask) {
	ERR_FAIL_COND_V(!initialized, false);
	ERR_FAIL_COND_V(process_pipeline.is_null(), false);
	ERR_FAIL_COND_V(process_uniform_set.is_null(), false);

	_load_project_settings();
	if (bool(GLOBAL_GET("rendering/renderer_rd/forward_plus/texel_splatting/debug/force_process_failure"))) {
		return false;
	}

	RenderingDevice *rd = RD::get_singleton();
	ERR_FAIL_NULL_V(rd, false);
	// Draw-health atomics are written after process dispatch. Read the complete
	// previous frame before resetting the shared counter buffer.
	_debug_log_counters(rd);

	CounterData counters;
	DrawIndirectArgs draw_args;
	ERR_FAIL_COND_V(rd->buffer_update(counter_buffer, 0, sizeof(CounterData), &counters) != OK, false);
	ERR_FAIL_COND_V(rd->buffer_update(draw_args_buffer, 0, sizeof(DrawIndirectArgs), &draw_args) != OK, false);

	RENDER_TIMESTAMP("TS Process Begin");
	rd->draw_command_begin_label("Texel Splat Process");

	ProcessPushConstant push_constant;
	push_constant.probe_size = probe_size;
	push_constant.layer_count = PROBE_LAYER_COUNT;
	push_constant.max_visible_refs = texel_capacity;
	push_constant.active_layer_mask = p_active_layer_mask;

	RD::ComputeListID compute_list = rd->compute_list_begin();
	rd->compute_list_bind_compute_pipeline(compute_list, process_pipeline);
	rd->compute_list_bind_uniform_set(compute_list, process_uniform_set, 0);
	rd->compute_list_set_push_constant(compute_list, &push_constant, sizeof(ProcessPushConstant));
	rd->compute_list_dispatch_threads(compute_list, probe_size, probe_size, PROBE_LAYER_COUNT);
	rd->compute_list_add_barrier(compute_list);
	rd->compute_list_end();
	RENDER_TIMESTAMP("TS Process End");

	rd->draw_command_end_label();
	return true;
}

bool TexelSplatPipelineRD::prepare_resolve_and_composite(RID p_framebuffer, const Projection &p_view_projection, float p_camera_far, const Vector<Transform3D> &p_probe_transforms, const Size2i &p_viewport_size, const Vector3 &p_camera_position, float p_grid_step, uint32_t p_eye_face_mask, uint32_t p_current_face_mask, uint32_t p_previous_face_mask, uint32_t p_current_probe_index, uint32_t p_previous_probe_index, float p_transition_fade, bool p_transitioning, const Vector3 &p_directional_light_direction, const Color &p_directional_light_color, bool p_directional_light_enabled) {
	discard_prepared_resolve_and_composite();
	ERR_FAIL_COND_V(!initialized, false);
	ERR_FAIL_COND_V(p_framebuffer.is_null(), false);
	ERR_FAIL_COND_V(resolve_pipeline.is_null(), false);
	ERR_FAIL_COND_V(composite_shader_rd.is_null(), false);
	ERR_FAIL_COND_V(draw_state_buffer.is_null(), false);
	ERR_FAIL_COND_V(p_probe_transforms.size() != PROBE_LAYER_COUNT, false);
	ERR_FAIL_COND_V(p_current_probe_index == 0 || p_current_probe_index >= PROBE_COUNT, false);
	ERR_FAIL_COND_V(p_previous_probe_index == 0 || p_previous_probe_index >= PROBE_COUNT, false);

	_load_project_settings();
	if (!ensure_screen_grid(p_viewport_size)) {
		return false;
	}
	ERR_FAIL_COND_V(screen_grid.resolve_uniform_set.is_null(), false);
	ERR_FAIL_COND_V(screen_grid.composite_uniform_set.is_null(), false);

	RenderingDevice *rd = RD::get_singleton();
	ERR_FAIL_NULL_V(rd, false);
	ERR_FAIL_COND_V(!rd->framebuffer_is_valid(p_framebuffer), false);
	ERR_FAIL_COND_V(!rd->uniform_set_is_valid(screen_grid.resolve_uniform_set), false);
	ERR_FAIL_COND_V(!rd->uniform_set_is_valid(screen_grid.composite_uniform_set), false);
	RID render_pipeline = composite_pipeline.get_render_pipeline(RD::INVALID_ID, rd->framebuffer_get_format(p_framebuffer));
	ERR_FAIL_COND_V(render_pipeline.is_null(), false);

	DrawState draw_state;
	RendererRD::MaterialStorage::store_camera(p_view_projection, draw_state.view_projection);
	RendererRD::MaterialStorage::store_camera(p_view_projection.inverse(), draw_state.inverse_view_projection);
	for (uint32_t i = 0; i < PROBE_LAYER_COUNT; i++) {
		RendererRD::MaterialStorage::store_transform(p_probe_transforms[i], draw_state.probe_transforms[i]);
		RendererRD::MaterialStorage::store_transform(p_probe_transforms[i].affine_inverse(), draw_state.probe_inverse_transforms[i]);
	}
	draw_state.params[0] = float(probe_size);
	draw_state.params[1] = float(p_viewport_size.x);
	draw_state.params[2] = float(p_viewport_size.y);
	draw_state.params[3] = MAX(p_camera_far, 0.001f);
	draw_state.grid_params[0] = float(screen_grid.size.x);
	draw_state.grid_params[1] = float(screen_grid.size.y);
	draw_state.grid_params[2] = owner_boundary_enabled ? 2.0f : float(pixel_scale);
	draw_state.grid_params[3] = MAX(p_grid_step, 0.001f);
	draw_state.debug_params[0] = float(debug_view);
	draw_state.debug_params[1] = float(debug_probe_layer);
	draw_state.debug_params[2] = debug_log_counters ? 1.0f : 0.0f;
	draw_state.debug_params[3] = disocclusion_guard_enabled ? 1.0f : 0.0f;
	const Vector3 light_direction = p_directional_light_direction.normalized();
	draw_state.directional_light_direction[0] = light_direction.x;
	draw_state.directional_light_direction[1] = light_direction.y;
	draw_state.directional_light_direction[2] = light_direction.z;
	draw_state.directional_light_direction[3] = p_directional_light_enabled ? 1.0f : 0.0f;
	draw_state.directional_light_color[0] = p_directional_light_color.r;
	draw_state.directional_light_color[1] = p_directional_light_color.g;
	draw_state.directional_light_color[2] = p_directional_light_color.b;
	draw_state.directional_light_color[3] = 0.15f;
	draw_state.camera_position[0] = p_camera_position.x;
	draw_state.camera_position[1] = p_camera_position.y;
	draw_state.camera_position[2] = p_camera_position.z;
	draw_state.camera_position[3] = owner_boundary_enabled ? 4.0f : 0.0f;
	draw_state.transition_params[0] = CLAMP(p_transition_fade, 0.0f, 1.0f);
	draw_state.transition_params[1] = float(p_current_probe_index);
	draw_state.transition_params[2] = float(p_previous_probe_index);
	draw_state.transition_params[3] = p_transitioning ? 1.0f : 0.0f;
	draw_state.probe_masks[0] = p_eye_face_mask & ((1u << PROBE_FACE_COUNT) - 1u);
	draw_state.probe_masks[1] = p_current_face_mask & ((1u << PROBE_FACE_COUNT) - 1u);
	draw_state.probe_masks[2] = p_previous_face_mask & ((1u << PROBE_FACE_COUNT) - 1u);
	draw_state.probe_masks[3] = transition_dither_mode;
	draw_state.reprojection_params[0] = reprojection_min_tolerance;
	draw_state.reprojection_params[1] = reprojection_max_tolerance;
	draw_state.reprojection_params[2] = reprojection_texel_tolerance_scale;
	draw_state.reprojection_params[3] = reprojection_search_forward_tolerance_scale;
	draw_state.reprojection_control[0] = float(reprojection_scan_steps);
	draw_state.reprojection_control[1] = float(reprojection_bisection_steps);
	draw_state.reprojection_control[2] = reprojection_search_back_tolerance_scale;

	draw_state.reprojection_control[3] = float(reprojection_source_mode);

	ERR_FAIL_COND_V(rd->buffer_update(draw_state_buffer, 0, sizeof(DrawState), &draw_state) != OK, false);
	if (bool(GLOBAL_GET("rendering/renderer_rd/forward_plus/texel_splatting/debug/force_composite_prepare_failure"))) {
		print_line("TexelSplat composite_prepare_forced_failure stage=post_preflight replacement=false");
		return false;
	}

	prepared_composite_framebuffer = p_framebuffer;
	prepared_composite_pipeline = render_pipeline;
	prepared_draw_state = draw_state;
	composite_prepared = true;
	return true;
}

void TexelSplatPipelineRD::execute_prepared_resolve_and_composite() {
	DEV_ASSERT(composite_prepared);
	DEV_ASSERT(prepared_composite_framebuffer.is_valid());
	DEV_ASSERT(prepared_composite_pipeline.is_valid());
	DEV_ASSERT(screen_grid.resolve_uniform_set.is_valid());
	DEV_ASSERT(screen_grid.composite_uniform_set.is_valid());

	RenderingDevice *rd = RD::get_singleton();
	DEV_ASSERT(rd != nullptr);
	RID framebuffer = prepared_composite_framebuffer;
	RID render_pipeline = prepared_composite_pipeline;
	discard_prepared_resolve_and_composite();

	rd->draw_command_begin_label("Resolve Texel Splat Screen Grid");

	_dispatch_resolve(rd);

	rd->draw_command_end_label();
	_debug_dump_screen_grid(rd);

	rd->draw_command_begin_label("Composite Texel Splat Screen Grid");

	RD::DrawListID draw_list = rd->draw_list_begin(framebuffer);
	rd->draw_list_bind_render_pipeline(draw_list, render_pipeline);
	rd->draw_list_bind_uniform_set(draw_list, screen_grid.composite_uniform_set, 0);
	rd->draw_list_draw(draw_list, false, 1u, 3u);
	rd->draw_list_end();

	rd->draw_command_end_label();
}

void TexelSplatPipelineRD::discard_prepared_resolve_and_composite() {
	prepared_composite_framebuffer = RID();
	prepared_composite_pipeline = RID();
	composite_prepared = false;
}

void TexelSplatPipelineRD::_load_project_settings() {
	const uint32_t normalized_probe_size = normalize_probe_size(int32_t(GLOBAL_GET("rendering/renderer_rd/forward_plus/texel_splatting/probe_size")));
	if (!initialized) {
		probe_size = normalized_probe_size;
	}
	splat_expansion_texels = CLAMP(float(GLOBAL_GET("rendering/renderer_rd/forward_plus/texel_splatting/splat_expansion_texels")), 0.0f, 2.0f);
	pixel_scale = uint32_t(CLAMP(int32_t(GLOBAL_GET("rendering/renderer_rd/forward_plus/texel_splatting/pixel_scale")), 1, 8));
	transition_dither_mode = uint32_t(CLAMP(int32_t(GLOBAL_GET("rendering/renderer_rd/forward_plus/texel_splatting/transition_dither_mode")), 0, 1));
	debug_view = uint32_t(CLAMP(int32_t(GLOBAL_GET("rendering/renderer_rd/forward_plus/texel_splatting/debug/view")), 0, int32_t(DEBUG_VIEW_MAX - 1)));
	debug_probe_layer = CLAMP(int32_t(GLOBAL_GET("rendering/renderer_rd/forward_plus/texel_splatting/debug/probe_layer")), -4, int32_t(PROBE_LAYER_COUNT - 1));
	reprojection_source_mode = uint32_t(CLAMP(int32_t(GLOBAL_GET("rendering/renderer_rd/forward_plus/texel_splatting/debug/resolve_source_mode")), 0, 3));
	debug_log_counters = bool(GLOBAL_GET("rendering/renderer_rd/forward_plus/texel_splatting/debug/log_counters"));
	debug_log_counter_interval = MAX(1u, uint32_t(GLOBAL_GET("rendering/renderer_rd/forward_plus/texel_splatting/debug/log_counter_interval_frames")));
	debug_raw_dump_enabled = bool(GLOBAL_GET("rendering/renderer_rd/forward_plus/texel_splatting/debug/raw_dump_enabled"));
	debug_raw_dump_path = String(GLOBAL_GET("rendering/renderer_rd/forward_plus/texel_splatting/debug/raw_dump_path"));
	debug_raw_dump_start_frame = uint64_t(MAX(int64_t(0), int64_t(GLOBAL_GET("rendering/renderer_rd/forward_plus/texel_splatting/debug/raw_dump_start_frame"))));
	debug_raw_dump_frame_count = uint64_t(MAX(int64_t(0), int64_t(GLOBAL_GET("rendering/renderer_rd/forward_plus/texel_splatting/debug/raw_dump_frame_count"))));
	draw_depth_test_enabled = bool(GLOBAL_GET("rendering/renderer_rd/forward_plus/texel_splatting/debug/depth_test_enabled"));
	depth_tie_bias_enabled = bool(GLOBAL_GET("rendering/renderer_rd/forward_plus/texel_splatting/debug/depth_tie_bias_enabled"));
	disocclusion_guard_enabled = bool(GLOBAL_GET("rendering/renderer_rd/forward_plus/texel_splatting/disocclusion_guard_enabled"));
	reprojection_scan_steps = uint32_t(CLAMP(int32_t(GLOBAL_GET("rendering/renderer_rd/forward_plus/texel_splatting/reprojection/scan_steps")), 4, 64));
	reprojection_bisection_steps = uint32_t(CLAMP(int32_t(GLOBAL_GET("rendering/renderer_rd/forward_plus/texel_splatting/reprojection/bisection_steps")), 1, 16));
	reprojection_min_tolerance = MAX(0.0001f, float(GLOBAL_GET("rendering/renderer_rd/forward_plus/texel_splatting/reprojection/min_tolerance")));
	reprojection_max_tolerance = MAX(reprojection_min_tolerance, float(GLOBAL_GET("rendering/renderer_rd/forward_plus/texel_splatting/reprojection/max_tolerance")));
	reprojection_texel_tolerance_scale = MAX(0.25f, float(GLOBAL_GET("rendering/renderer_rd/forward_plus/texel_splatting/reprojection/texel_tolerance_scale")));
	reprojection_search_back_tolerance_scale = MAX(1.0f, float(GLOBAL_GET("rendering/renderer_rd/forward_plus/texel_splatting/reprojection/search_back_tolerance_scale")));
	reprojection_search_forward_tolerance_scale = MAX(0.25f, float(GLOBAL_GET("rendering/renderer_rd/forward_plus/texel_splatting/reprojection/search_forward_tolerance_scale")));
	owner_boundary_enabled = bool(GLOBAL_GET("rendering/renderer_rd/forward_plus/texel_splatting/experimental_owner_boundary_enabled"));
	if (owner_boundary_enabled) {
		pixel_scale = 4;
	}
}

uint32_t TexelSplatPipelineRD::normalize_probe_size(int32_t p_requested_size) {
	const uint32_t requested_probe_size = uint32_t(CLAMP(p_requested_size, 128, 512));
	return CLAMP(((requested_probe_size + 16u) / 32u) * 32u, 128u, 512u);
}

void TexelSplatPipelineRD::_debug_log_counters(RenderingDevice *p_rd) {
	ERR_FAIL_NULL(p_rd);

	debug_frame_index++;
	if (!debug_log_counters || debug_frame_index % debug_log_counter_interval != 0) {
		return;
	}

	Vector<uint8_t> counter_data = p_rd->buffer_get_data(counter_buffer, 0, sizeof(CounterData));
	Vector<uint8_t> draw_args_data = p_rd->buffer_get_data(draw_args_buffer, 0, sizeof(DrawIndirectArgs));
	if (counter_data.size() != sizeof(CounterData) || draw_args_data.size() != sizeof(DrawIndirectArgs)) {
		return;
	}

	CounterData counters;
	DrawIndirectArgs draw_args;
	memcpy(&counters, counter_data.ptr(), sizeof(CounterData));
	memcpy(&draw_args, draw_args_data.ptr(), sizeof(DrawIndirectArgs));
	float max_world_extent_ratio = 0.0f;
	float max_diagonal_extent_ratio = 0.0f;
	float max_alignment_error = 0.0f;
	memcpy(&max_world_extent_ratio, &counters.max_world_extent_ratio_bits, sizeof(float));
	memcpy(&max_diagonal_extent_ratio, &counters.max_diagonal_extent_ratio_bits, sizeof(float));
	memcpy(&max_alignment_error, &counters.max_alignment_error_bits, sizeof(float));

	print_line("TexelSplat counters frame=" + String::num_uint64(debug_frame_index) +
			" debug_probe_layer=" + itos(debug_probe_layer) +
			" visible=" + String::num_uint64(counters.visible_count) +
			" classified=" + String::num_uint64(counters.classified_count) +
			" edge=" + String::num_uint64(counters.edge_count) +
			" cross_face_samples=" + String::num_uint64(counters.cross_face_sample_count) +
			" cross_face_resolved=" + String::num_uint64(counters.cross_face_resolved_count) +
			" cross_face_empty_suppressed=" + String::num_uint64(counters.cross_face_empty_suppressed_count) +
			" cross_face_edges=" + String::num_uint64(counters.cross_face_edge_count) +
			" cross_object_continuous=" + String::num_uint64(counters.cross_object_continuity_count) +
			" invalid_base_normal=" + String::num_uint64(counters.invalid_base_surface_normal_count) +
			" pre_raster_splats=" + String::num_uint64(counters.pre_raster_splat_count) +
			" invalid_or_nonfinite_splats=" + String::num_uint64(counters.invalid_or_nonfinite_splat_count) +
			" degenerate_splats=" + String::num_uint64(counters.degenerate_splat_count) +
			" winding_failures=" + String::num_uint64(counters.winding_failure_count) +
			" extent_failures=" + String::num_uint64(counters.extent_failure_count) +
			" clip_nonfinite=" + String::num_uint64(counters.clip_nonfinite_count) +
			" clip_polygon_overflow=" + String::num_uint64(counters.clip_polygon_overflow_count) +
			" clip_divide_invalid=" + String::num_uint64(counters.clip_divide_invalid_count) +
			" ndc_bbox_invalid=" + String::num_uint64(counters.ndc_bbox_invalid_count) +
			" fully_clipped_splats=" + String::num_uint64(counters.fully_clipped_splat_count) +
			" expected_span_saturated=" + String::num_uint64(counters.expected_span_saturated_count) +
			" expected_grazing_strips=" + String::num_uint64(counters.expected_grazing_strip_count) +
			" rasterized_geometry_pixels=" + String::num_uint64(counters.rasterized_geometry_pixel_count) +
			" jacobian_measurable_pixels=" + String::num_uint64(counters.jacobian_measurable_pixel_count) +
			" jacobian_unmeasurable_pixels=" + String::num_uint64(counters.jacobian_unmeasurable_pixel_count) +
			" unexpected_jacobian_unmeasurable_pixels=" + String::num_uint64(counters.unexpected_jacobian_unmeasurable_pixel_count) +
			" ray_structure_failure=" + String::num_uint64(counters.ray_structure_failure_count) +
			" max_world_extent_ratio=" + String::num(max_world_extent_ratio, 6) +
			" max_diagonal_extent_ratio=" + String::num(max_diagonal_extent_ratio, 6) +
			" min_signed_alignment=" + String::num(1.0f - max_alignment_error, 6) +
			" draw_instances=" + String::num_uint64(draw_args.instance_count) +
			" capacity=" + String::num_uint64(texel_capacity));
}

void TexelSplatPipelineRD::_dispatch_resolve(RenderingDevice *p_rd) {
	ERR_FAIL_NULL(p_rd);
	RD::ComputeListID compute_list = p_rd->compute_list_begin();
	p_rd->compute_list_bind_compute_pipeline(compute_list, resolve_pipeline);
	p_rd->compute_list_bind_uniform_set(compute_list, screen_grid.resolve_uniform_set, 0);
	const Size2i resolve_size = screen_grid.owner_boundary_enabled ? screen_grid.native_size : screen_grid.size;
	p_rd->compute_list_dispatch_threads(compute_list, resolve_size.x, resolve_size.y, 1);
	p_rd->compute_list_add_barrier(compute_list);
	if (screen_grid.owner_boundary_enabled) {
		DEV_ASSERT(owner_boundary_pipeline.is_valid());
		DEV_ASSERT(screen_grid.owner_boundary_uniform_set.is_valid());
		p_rd->compute_list_bind_compute_pipeline(compute_list, owner_boundary_pipeline);
		p_rd->compute_list_bind_uniform_set(compute_list, screen_grid.owner_boundary_uniform_set, 0);
		p_rd->compute_list_dispatch_threads(compute_list, screen_grid.size.x, screen_grid.size.y, 1);
		p_rd->compute_list_add_barrier(compute_list);
	}
	p_rd->compute_list_end();
}

void TexelSplatPipelineRD::_debug_dump_screen_grid(RenderingDevice *p_rd) {
	ERR_FAIL_NULL(p_rd);
	if (!debug_raw_dump_enabled || debug_raw_dump_frame_count == 0 || debug_raw_dump_path.is_empty()) {
		return;
	}
	if (debug_frame_index < debug_raw_dump_start_frame || debug_frame_index - debug_raw_dump_start_frame >= debug_raw_dump_frame_count) {
		return;
	}
	if (!screen_grid.copy_from_enabled) {
		ERR_PRINT_ONCE("TexelSplat raw dump requested without copy-from screen-grid resources.");
		return;
	}
	if (screen_grid.owner_boundary_enabled) {
		ERR_PRINT_ONCE("TexelSplat TSRAW v1 dump is disabled for the rejected owner-boundary archive because the format cannot encode P=4/N=2 ownership metadata.");
		return;
	}

	const uint32_t original_debug_view = uint32_t(CLAMP(int32_t(Math::round(prepared_draw_state.debug_params[0])), 0, int32_t(DEBUG_VIEW_MAX - 1)));
	static const uint32_t raw_views[] = { DEBUG_VIEW_ALBEDO, DEBUG_VIEW_NORMAL, DEBUG_VIEW_SPLAT_ID };
	bool original_grid_available = original_debug_view == raw_views[0];
	bool dump_succeeded = true;
	for (uint32_t raw_view : raw_views) {
		if (!original_grid_available || raw_view != original_debug_view) {
			prepared_draw_state.debug_params[0] = float(raw_view);
			if (p_rd->buffer_update(draw_state_buffer, 0, sizeof(DrawState), &prepared_draw_state) != OK) {
				ERR_PRINT("TexelSplat raw dump could not update DrawState for auxiliary view.");
				dump_succeeded = false;
				break;
			}
			_dispatch_resolve(p_rd);
		}
		if (!_debug_write_screen_grid_dump(p_rd, raw_view)) {
			dump_succeeded = false;
			break;
		}
		original_grid_available = false;
	}

	if (uint32_t(Math::round(prepared_draw_state.debug_params[0])) != original_debug_view) {
		prepared_draw_state.debug_params[0] = float(original_debug_view);
		if (p_rd->buffer_update(draw_state_buffer, 0, sizeof(DrawState), &prepared_draw_state) == OK) {
			_dispatch_resolve(p_rd);
		} else {
			ERR_PRINT("TexelSplat raw dump could not restore DrawState after auxiliary views.");
			dump_succeeded = false;
		}
	}
	if (!dump_succeeded) {
		ERR_PRINT("TexelSplat raw dump frame is incomplete and must be rejected by validation.");
	}
}

bool TexelSplatPipelineRD::_debug_write_screen_grid_dump(RenderingDevice *p_rd, uint32_t p_debug_view) {
	ERR_FAIL_NULL_V(p_rd, false);

	Vector<uint8_t> color_data = p_rd->texture_get_data(screen_grid.color, 0);
	Vector<uint8_t> depth_data = p_rd->texture_get_data(screen_grid.depth, 0);
	Vector<uint8_t> meta_data = p_rd->texture_get_data(screen_grid.meta, 0);
	const uint64_t sample_count = uint64_t(screen_grid.size.x) * uint64_t(screen_grid.size.y);
	if (uint64_t(color_data.size()) != sample_count * 8u || uint64_t(depth_data.size()) != sample_count * 4u || uint64_t(meta_data.size()) != sample_count * 8u) {
		ERR_PRINT("TexelSplat raw dump readback size mismatch.");
		return false;
	}

	const String dump_dir = ProjectSettings::get_singleton()->globalize_path(debug_raw_dump_path);
	const uint32_t dump_source = uint32_t(CLAMP(int32_t(Math::round(prepared_draw_state.reprojection_control[3])), 0, 3));
	const String file_name = vformat("tsraw_frame_%06d_view_%02d_source_%d.bin", debug_frame_index, p_debug_view, dump_source);
	const String file_path = dump_dir.path_join(file_name);
	Error file_error = OK;
	Ref<FileAccess> file = FileAccess::open(file_path, FileAccess::WRITE, &file_error);
	if (file_error != OK || file.is_null()) {
		ERR_PRINT("TexelSplat raw dump could not open '" + file_path + "'.");
		return false;
	}

	static const uint8_t magic[8] = { 'T', 'S', 'R', 'A', 'W', '0', '0', '1' };
	file->store_buffer(magic, sizeof(magic));
	file->store_32(1u);
	file->store_64(debug_frame_index);
	file->store_32(uint32_t(screen_grid.size.x));
	file->store_32(uint32_t(screen_grid.size.y));
	file->store_32(uint32_t(MAX(0.0f, prepared_draw_state.params[1])));
	file->store_32(uint32_t(MAX(0.0f, prepared_draw_state.params[2])));
	file->store_32(uint32_t(MAX(0.0f, prepared_draw_state.params[0])));
	file->store_32(uint32_t(MAX(1.0f, prepared_draw_state.grid_params[2])));
	file->store_32(p_debug_view);
	file->store_32(dump_source);
	file->store_64(sizeof(DrawState));
	file->store_64(color_data.size());
	file->store_64(depth_data.size());
	file->store_64(meta_data.size());
	file->store_buffer(reinterpret_cast<const uint8_t *>(&prepared_draw_state), sizeof(DrawState));
	file->store_buffer(color_data);
	file->store_buffer(depth_data);
	file->store_buffer(meta_data);

	print_line("TexelSplat raw_dump frame=" + String::num_uint64(debug_frame_index) +
			" view=" + itos(p_debug_view) +
			" source=" + itos(dump_source) +
			" grid=" + itos(screen_grid.size.x) + "x" + itos(screen_grid.size.y) +
			" path=" + file_path);
	return true;
}

RID TexelSplatPipelineRD::get_probe_layer_framebuffer(uint32_t p_layer) const {
	ERR_FAIL_INDEX_V(p_layer, PROBE_LAYER_COUNT, RID());
	return probe_layers[p_layer].framebuffer;
}

RD::FramebufferFormatID TexelSplatPipelineRD::get_probe_framebuffer_format() const {
	if (!probe_layers[0].framebuffer.is_valid()) {
		return RD::INVALID_ID;
	}

	return RD::get_singleton()->framebuffer_get_format(probe_layers[0].framebuffer);
}

bool TexelSplatPipelineRD::_create_probe_textures() {
	const uint32_t gbuffer_usage = RD::TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT;
	const uint32_t depth_usage = RD::TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT;
	const uint32_t lit_usage = RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT;

	const RD::DataFormat depth_format = _select_depth_format(depth_usage);
	ERR_FAIL_COND_V_MSG(depth_format == RD::DATA_FORMAT_MAX, false, "Texel splatting requires a depth format that supports depth attachment and sampling usage.");

	struct ProbeTextureSpec {
		ProbeTexture texture;
		RD::DataFormat format;
		uint32_t usage_bits;
		const char *label;
	};

	const ProbeTextureSpec specs[] = {
		{ PROBE_TEXTURE_ALBEDO, RD::DATA_FORMAT_R8G8B8A8_UNORM, gbuffer_usage, "albedo" },
		{ PROBE_TEXTURE_NORMAL, RD::DATA_FORMAT_R8G8B8A8_UNORM, gbuffer_usage, "normal" },
		{ PROBE_TEXTURE_RADIAL, RD::DATA_FORMAT_R32_SFLOAT, gbuffer_usage, "radial depth" },
		{ PROBE_TEXTURE_OBJECT_ID, RD::DATA_FORMAT_R32_UINT, gbuffer_usage, "object id" },
		{ PROBE_TEXTURE_DEPTH, depth_format, depth_usage, "depth" },
		{ PROBE_TEXTURE_LIT, RD::DATA_FORMAT_R8G8B8A8_UNORM, lit_usage, "lit" },
	};

	for (const ProbeTextureSpec &spec : specs) {
		ERR_FAIL_COND_V_MSG(!_is_format_supported(spec.format, spec.usage_bits, spec.label), false, "Texel splatting probe texture format support check failed.");

		RID texture = _create_probe_texture(spec.format, spec.usage_bits, spec.label);
		ERR_FAIL_COND_V_MSG(texture.is_null(), false, "Texel splatting failed to create probe texture array.");

		probe_textures[spec.texture].texture = texture;
		probe_textures[spec.texture].format = spec.format;
		probe_textures[spec.texture].usage_bits = spec.usage_bits;
	}

	return true;
}

bool TexelSplatPipelineRD::_create_probe_framebuffers() {
	for (uint32_t layer = 0; layer < PROBE_LAYER_COUNT; layer++) {
		ProbeLayerData &probe_layer = probe_layers[layer];

		probe_layer.albedo_view = _create_probe_texture_slice(probe_textures[PROBE_TEXTURE_ALBEDO].texture, layer, "albedo");
		probe_layer.normal_view = _create_probe_texture_slice(probe_textures[PROBE_TEXTURE_NORMAL].texture, layer, "normal");
		probe_layer.radial_view = _create_probe_texture_slice(probe_textures[PROBE_TEXTURE_RADIAL].texture, layer, "radial depth");
		probe_layer.object_id_view = _create_probe_texture_slice(probe_textures[PROBE_TEXTURE_OBJECT_ID].texture, layer, "object id");
		probe_layer.depth_view = _create_probe_texture_slice(probe_textures[PROBE_TEXTURE_DEPTH].texture, layer, "depth");

		Vector<RID> attachments;
		attachments.push_back(probe_layer.albedo_view);
		attachments.push_back(probe_layer.normal_view);
		attachments.push_back(probe_layer.radial_view);
		attachments.push_back(probe_layer.object_id_view);
		attachments.push_back(probe_layer.depth_view);

		probe_layer.framebuffer = RD::get_singleton()->framebuffer_create(attachments);
		ERR_FAIL_COND_V_MSG(probe_layer.framebuffer.is_null(), false, "Failed to create texel splatting probe layer framebuffer.");
	}

	return true;
}

bool TexelSplatPipelineRD::_create_process_resources() {
	RenderingDevice *rd = RD::get_singleton();
	ERR_FAIL_NULL_V(rd, false);

	texel_capacity = probe_size * probe_size * PROBE_LAYER_COUNT;
	const uint32_t texel_buffer_size = sizeof(uint32_t) * texel_capacity;

	visible_refs_buffer = rd->storage_buffer_create(texel_buffer_size);
	ERR_FAIL_COND_V_MSG(visible_refs_buffer.is_null(), false, "Failed to create texel splatting visible refs buffer.");

	splat_flags_buffer = rd->storage_buffer_create(texel_buffer_size);
	ERR_FAIL_COND_V_MSG(splat_flags_buffer.is_null(), false, "Failed to create texel splatting flags buffer.");

	CounterData counters;
	Vector<uint8_t> counter_data;
	counter_data.resize(sizeof(CounterData));
	memcpy(counter_data.ptrw(), &counters, sizeof(CounterData));
	counter_buffer = rd->storage_buffer_create(sizeof(CounterData), counter_data);
	ERR_FAIL_COND_V_MSG(counter_buffer.is_null(), false, "Failed to create texel splatting counter buffer.");

	DrawIndirectArgs draw_args;
	Vector<uint8_t> draw_args_data;
	draw_args_data.resize(sizeof(DrawIndirectArgs));
	memcpy(draw_args_data.ptrw(), &draw_args, sizeof(DrawIndirectArgs));
	draw_args_buffer = rd->storage_buffer_create(sizeof(DrawIndirectArgs), draw_args_data, RD::STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT);
	ERR_FAIL_COND_V_MSG(draw_args_buffer.is_null(), false, "Failed to create texel splatting draw args buffer.");

	Vector<String> process_modes;
	process_modes.push_back("");
	process_shader.initialize(process_modes);
	process_shader_version = process_shader.version_create();
	process_shader_rd = process_shader.version_get_shader(process_shader_version, 0);
	ERR_FAIL_COND_V_MSG(process_shader_rd.is_null(), false, "Failed to create texel splatting process shader.");

	process_pipeline = rd->compute_pipeline_create(process_shader_rd);
	ERR_FAIL_COND_V_MSG(process_pipeline.is_null(), false, "Failed to create texel splatting process pipeline.");

	RendererRD::MaterialStorage *material_storage = RendererRD::MaterialStorage::get_singleton();
	ERR_FAIL_NULL_V(material_storage, false);

	RID nearest_sampler = material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	ERR_FAIL_COND_V(nearest_sampler.is_null(), false);

	Vector<RD::Uniform> uniforms;
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, Vector<RID>({ nearest_sampler, probe_textures[PROBE_TEXTURE_ALBEDO].texture })));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, Vector<RID>({ nearest_sampler, probe_textures[PROBE_TEXTURE_NORMAL].texture })));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, Vector<RID>({ nearest_sampler, probe_textures[PROBE_TEXTURE_RADIAL].texture })));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, Vector<RID>({ nearest_sampler, probe_textures[PROBE_TEXTURE_OBJECT_ID].texture })));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 4, visible_refs_buffer));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 5, splat_flags_buffer));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 6, counter_buffer));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 7, draw_args_buffer));

	process_uniform_set = rd->uniform_set_create(uniforms, process_shader_rd, 0);
	ERR_FAIL_COND_V_MSG(process_uniform_set.is_null(), false, "Failed to create texel splatting process uniform set.");

	return true;
}

bool TexelSplatPipelineRD::_create_draw_resources() {
	RenderingDevice *rd = RD::get_singleton();
	ERR_FAIL_NULL_V(rd, false);

	DrawState draw_state;
	Vector<uint8_t> draw_state_data;
	draw_state_data.resize(sizeof(DrawState));
	memcpy(draw_state_data.ptrw(), &draw_state, sizeof(DrawState));
	draw_state_buffer = rd->storage_buffer_create(sizeof(DrawState), draw_state_data);
	ERR_FAIL_COND_V_MSG(draw_state_buffer.is_null(), false, "Failed to create texel splatting draw state buffer.");

	Vector<String> resolve_modes;
	resolve_modes.push_back("");
	resolve_shader.initialize(resolve_modes);
	resolve_shader_version = resolve_shader.version_create();
	resolve_shader_rd = resolve_shader.version_get_shader(resolve_shader_version, 0);
	ERR_FAIL_COND_V_MSG(resolve_shader_rd.is_null(), false, "Failed to create texel splatting screen-grid resolve shader.");

	resolve_pipeline = rd->compute_pipeline_create(resolve_shader_rd);
	ERR_FAIL_COND_V_MSG(resolve_pipeline.is_null(), false, "Failed to create texel splatting screen-grid resolve pipeline.");

	Vector<String> owner_boundary_modes;
	owner_boundary_modes.push_back("");
	owner_boundary_shader.initialize(owner_boundary_modes);
	owner_boundary_shader_version = owner_boundary_shader.version_create();
	owner_boundary_shader_rd = owner_boundary_shader.version_get_shader(owner_boundary_shader_version, 0);
	ERR_FAIL_COND_V_MSG(owner_boundary_shader_rd.is_null(), false, "Failed to create texel splatting owner-boundary shader.");

	owner_boundary_pipeline = rd->compute_pipeline_create(owner_boundary_shader_rd);
	ERR_FAIL_COND_V_MSG(owner_boundary_pipeline.is_null(), false, "Failed to create texel splatting owner-boundary pipeline.");

	Vector<String> composite_modes;
	composite_modes.push_back("");
	composite_shader.initialize(composite_modes);
	composite_shader_version = composite_shader.version_create();
	composite_shader_rd = composite_shader.version_get_shader(composite_shader_version, 0);
	ERR_FAIL_COND_V_MSG(composite_shader_rd.is_null(), false, "Failed to create texel splatting screen-grid composite shader.");

	RD::PipelineRasterizationState rasterization_state;
	rasterization_state.cull_mode = RD::POLYGON_CULL_DISABLED;

	RD::PipelineDepthStencilState depth_stencil_state;
	depth_stencil_state.enable_depth_test = true;
	depth_stencil_state.enable_depth_write = true;
	depth_stencil_state.depth_compare_operator = RD::COMPARE_OP_GREATER_OR_EQUAL;

	composite_pipeline.setup(
			composite_shader_rd,
			RD::RENDER_PRIMITIVE_TRIANGLES,
			rasterization_state,
			RD::PipelineMultisampleState(),
			depth_stencil_state,
			RD::PipelineColorBlendState::create_disabled(),
			0);

	return true;
}

bool TexelSplatPipelineRD::ensure_screen_grid(const Size2i &p_viewport_size) {
	ERR_FAIL_COND_V(!initialized, false);
	ERR_FAIL_COND_V(p_viewport_size.x <= 0 || p_viewport_size.y <= 0, false);

	_load_project_settings();

	const Size2i requested_grid_size = owner_boundary_enabled ?
			Size2i(((p_viewport_size.x + 3) / 4) * 2, ((p_viewport_size.y + 3) / 4) * 2) :
			Size2i((p_viewport_size.x + int(pixel_scale) - 1) / int(pixel_scale), (p_viewport_size.y + int(pixel_scale) - 1) / int(pixel_scale));
	const bool copy_from_requested = debug_raw_dump_enabled && debug_raw_dump_frame_count > 0 && !debug_raw_dump_path.is_empty();
	if (screen_grid.color.is_valid() && screen_grid.depth.is_valid() && screen_grid.meta.is_valid() &&
			screen_grid.native_camera_depth.is_valid() && screen_grid.native_albedo.is_valid() && screen_grid.native_normal.is_valid() &&
			screen_grid.resolve_uniform_set.is_valid() && screen_grid.composite_uniform_set.is_valid() &&
			(!owner_boundary_enabled || (screen_grid.native_color.is_valid() && screen_grid.native_depth.is_valid() && screen_grid.native_meta.is_valid() && screen_grid.owner_boundary_uniform_set.is_valid())) &&
			screen_grid.size == requested_grid_size && screen_grid.native_size == p_viewport_size &&
			screen_grid.owner_boundary_enabled == owner_boundary_enabled && screen_grid.copy_from_enabled == copy_from_requested) {
		return true;
	}

	ScreenGridResources new_resources;
	if (!_create_screen_grid_resources(requested_grid_size, p_viewport_size, owner_boundary_enabled, new_resources)) {
		_free_screen_grid_resources(new_resources);
		return false;
	}

	_free_screen_grid_resources(screen_grid);
	screen_grid = new_resources;
	return true;
}

bool TexelSplatPipelineRD::_create_screen_grid_resources(const Size2i &p_grid_size, const Size2i &p_viewport_size, bool p_owner_boundary_enabled, ScreenGridResources &r_resources) {
	RenderingDevice *rd = RD::get_singleton();
	ERR_FAIL_NULL_V(rd, false);
	ERR_FAIL_COND_V(resolve_shader_rd.is_null(), false);
	ERR_FAIL_COND_V(owner_boundary_shader_rd.is_null(), false);
	ERR_FAIL_COND_V(composite_shader_rd.is_null(), false);
	ERR_FAIL_COND_V(draw_state_buffer.is_null(), false);
	ERR_FAIL_COND_V(splat_flags_buffer.is_null(), false);

	const bool copy_from_requested = debug_raw_dump_enabled && debug_raw_dump_frame_count > 0 && !debug_raw_dump_path.is_empty();
	const uint32_t usage_bits = RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT | (copy_from_requested ? RD::TEXTURE_USAGE_CAN_COPY_FROM_BIT : 0u);
	ERR_FAIL_COND_V_MSG(!_is_format_supported(RD::DATA_FORMAT_R16G16B16A16_SFLOAT, usage_bits, "screen-grid color"), false, "Texel splatting screen-grid color texture format support check failed.");
	ERR_FAIL_COND_V_MSG(!_is_format_supported(RD::DATA_FORMAT_R32_SFLOAT, usage_bits, "screen-grid depth"), false, "Texel splatting screen-grid depth texture format support check failed.");
	ERR_FAIL_COND_V_MSG(!_is_format_supported(RD::DATA_FORMAT_R32G32_UINT, usage_bits, "screen-grid meta"), false, "Texel splatting screen-grid meta texture format support check failed.");

	r_resources.color = _create_screen_grid_texture(RD::DATA_FORMAT_R16G16B16A16_SFLOAT, p_grid_size, usage_bits, "color");
	ERR_FAIL_COND_V(r_resources.color.is_null(), false);
	r_resources.depth = _create_screen_grid_texture(RD::DATA_FORMAT_R32_SFLOAT, p_grid_size, usage_bits, "depth");
	ERR_FAIL_COND_V(r_resources.depth.is_null(), false);
	r_resources.meta = _create_screen_grid_texture(RD::DATA_FORMAT_R32G32_UINT, p_grid_size, usage_bits, "meta");
	ERR_FAIL_COND_V(r_resources.meta.is_null(), false);
	r_resources.size = p_grid_size;
	r_resources.native_size = p_viewport_size;
	r_resources.owner_boundary_enabled = p_owner_boundary_enabled;
	r_resources.copy_from_enabled = copy_from_requested;

	const Size2i resolve_target_size = p_owner_boundary_enabled ? p_viewport_size : p_grid_size;
	if (p_owner_boundary_enabled) {
		r_resources.native_color = _create_screen_grid_texture(RD::DATA_FORMAT_R16G16B16A16_SFLOAT, resolve_target_size, RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT, "owner-boundary native color");
		ERR_FAIL_COND_V(r_resources.native_color.is_null(), false);
		r_resources.native_depth = _create_screen_grid_texture(RD::DATA_FORMAT_R32_SFLOAT, resolve_target_size, RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT, "owner-boundary native depth");
		ERR_FAIL_COND_V(r_resources.native_depth.is_null(), false);
		r_resources.native_meta = _create_screen_grid_texture(RD::DATA_FORMAT_R32G32_UINT, resolve_target_size, RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT, "owner-boundary native meta");
		ERR_FAIL_COND_V(r_resources.native_meta.is_null(), false);
	}
	r_resources.native_camera_depth = _create_screen_grid_texture(RD::DATA_FORMAT_R32_SFLOAT, resolve_target_size, RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT, "owner-boundary camera depth");
	ERR_FAIL_COND_V(r_resources.native_camera_depth.is_null(), false);
	r_resources.native_albedo = _create_screen_grid_texture(RD::DATA_FORMAT_R16G16B16A16_SFLOAT, resolve_target_size, RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT, "owner-boundary albedo");
	ERR_FAIL_COND_V(r_resources.native_albedo.is_null(), false);
	r_resources.native_normal = _create_screen_grid_texture(RD::DATA_FORMAT_R16G16B16A16_SFLOAT, resolve_target_size, RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT, "owner-boundary normal");
	ERR_FAIL_COND_V(r_resources.native_normal.is_null(), false);

	RendererRD::MaterialStorage *material_storage = RendererRD::MaterialStorage::get_singleton();
	ERR_FAIL_NULL_V(material_storage, false);

	RID nearest_sampler = material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	ERR_FAIL_COND_V(nearest_sampler.is_null(), false);

	Vector<RD::Uniform> resolve_uniforms;
	resolve_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, Vector<RID>({ nearest_sampler, probe_textures[PROBE_TEXTURE_ALBEDO].texture })));
	resolve_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, Vector<RID>({ nearest_sampler, probe_textures[PROBE_TEXTURE_NORMAL].texture })));
	resolve_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, Vector<RID>({ nearest_sampler, probe_textures[PROBE_TEXTURE_RADIAL].texture })));
	resolve_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, Vector<RID>({ nearest_sampler, probe_textures[PROBE_TEXTURE_OBJECT_ID].texture })));
	resolve_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 4, splat_flags_buffer));
	resolve_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 5, draw_state_buffer));
	resolve_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 6, p_owner_boundary_enabled ? r_resources.native_color : r_resources.color));
	resolve_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 7, p_owner_boundary_enabled ? r_resources.native_depth : r_resources.depth));
	resolve_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 8, p_owner_boundary_enabled ? r_resources.native_meta : r_resources.meta));
	resolve_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 9, r_resources.native_camera_depth));
	resolve_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 10, r_resources.native_albedo));
	resolve_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 11, r_resources.native_normal));

	r_resources.resolve_uniform_set = rd->uniform_set_create(resolve_uniforms, resolve_shader_rd, 0);
	ERR_FAIL_COND_V_MSG(r_resources.resolve_uniform_set.is_null(), false, "Failed to create texel splatting screen-grid resolve uniform set.");

	if (p_owner_boundary_enabled) {
		Vector<RD::Uniform> owner_boundary_uniforms;
		owner_boundary_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, Vector<RID>({ nearest_sampler, r_resources.native_color })));
		owner_boundary_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, Vector<RID>({ nearest_sampler, r_resources.native_depth })));
		owner_boundary_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, Vector<RID>({ nearest_sampler, r_resources.native_meta })));
		owner_boundary_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, Vector<RID>({ nearest_sampler, r_resources.native_camera_depth })));
		owner_boundary_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 4, Vector<RID>({ nearest_sampler, r_resources.native_albedo })));
		owner_boundary_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 5, Vector<RID>({ nearest_sampler, r_resources.native_normal })));
		owner_boundary_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 6, draw_state_buffer));
		owner_boundary_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 7, r_resources.color));
		owner_boundary_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 8, r_resources.depth));
		owner_boundary_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 9, r_resources.meta));
		r_resources.owner_boundary_uniform_set = rd->uniform_set_create(owner_boundary_uniforms, owner_boundary_shader_rd, 0);
		ERR_FAIL_COND_V_MSG(r_resources.owner_boundary_uniform_set.is_null(), false, "Failed to create texel splatting owner-boundary uniform set.");
	}

	Vector<RD::Uniform> composite_uniforms;
	composite_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, Vector<RID>({ nearest_sampler, r_resources.color })));
	composite_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, Vector<RID>({ nearest_sampler, r_resources.depth })));
	composite_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, Vector<RID>({ nearest_sampler, r_resources.meta })));
	composite_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 3, draw_state_buffer));

	r_resources.composite_uniform_set = rd->uniform_set_create(composite_uniforms, composite_shader_rd, 0);
	ERR_FAIL_COND_V_MSG(r_resources.composite_uniform_set.is_null(), false, "Failed to create texel splatting screen-grid composite uniform set.");

	return true;
}

bool TexelSplatPipelineRD::_is_format_supported(RD::DataFormat p_format, uint32_t p_usage_bits, const char *p_label) const {
	const bool supported = RD::get_singleton()->texture_is_format_supported_for_usage(p_format, p_usage_bits);
	ERR_FAIL_COND_V_MSG(!supported, false, "Texel splatting probe texture '" + String(p_label) + "' requires unsupported RD texture usage bits.");
	return true;
}

RD::DataFormat TexelSplatPipelineRD::_select_depth_format(uint32_t p_usage_bits) const {
	if (RD::get_singleton()->texture_is_format_supported_for_usage(RD::DATA_FORMAT_D32_SFLOAT, p_usage_bits)) {
		return RD::DATA_FORMAT_D32_SFLOAT;
	}
	if (RD::get_singleton()->texture_is_format_supported_for_usage(RD::DATA_FORMAT_X8_D24_UNORM_PACK32, p_usage_bits)) {
		return RD::DATA_FORMAT_X8_D24_UNORM_PACK32;
	}

	return RD::DATA_FORMAT_MAX;
}

RID TexelSplatPipelineRD::_create_screen_grid_texture(RD::DataFormat p_format, const Size2i &p_size, uint32_t p_usage_bits, const char *p_label) const {
	RD::TextureFormat texture_format;
	texture_format.format = p_format;
	texture_format.width = p_size.x;
	texture_format.height = p_size.y;
	texture_format.texture_type = RD::TEXTURE_TYPE_2D;
	texture_format.usage_bits = p_usage_bits;

	RID texture = RD::get_singleton()->texture_create(texture_format, RD::TextureView());
	ERR_FAIL_COND_V_MSG(texture.is_null(), RID(), "Failed to create texel splatting screen-grid texture '" + String(p_label) + "'.");
	return texture;
}

RID TexelSplatPipelineRD::_create_probe_texture(RD::DataFormat p_format, uint32_t p_usage_bits, const char *p_label) const {
	RD::TextureFormat texture_format;
	texture_format.format = p_format;
	texture_format.width = probe_size;
	texture_format.height = probe_size;
	texture_format.array_layers = PROBE_LAYER_COUNT;
	texture_format.texture_type = RD::TEXTURE_TYPE_2D_ARRAY;
	texture_format.usage_bits = p_usage_bits;

	RID texture = RD::get_singleton()->texture_create(texture_format, RD::TextureView());
	ERR_FAIL_COND_V_MSG(texture.is_null(), RID(), "Failed to create texel splatting probe texture array '" + String(p_label) + "'.");
	return texture;
}

RID TexelSplatPipelineRD::_create_probe_texture_slice(RID p_texture, uint32_t p_layer, const char *p_label) const {
	RID texture_slice = RD::get_singleton()->texture_create_shared_from_slice(RD::TextureView(), p_texture, p_layer, 0);
	ERR_FAIL_COND_V_MSG(texture_slice.is_null(), RID(), "Failed to create texel splatting probe texture slice '" + String(p_label) + "'.");
	return texture_slice;
}

void TexelSplatPipelineRD::_free_probe_textures() {
	for (uint32_t i = 0; i < PROBE_TEXTURE_MAX; i++) {
		ProbeTextureData &texture = probe_textures[i];
		if (texture.texture.is_valid()) {
			RD::get_singleton()->free_rid(texture.texture);
			texture.texture = RID();
		}
		texture.format = RD::DATA_FORMAT_MAX;
		texture.usage_bits = 0;
	}
}

void TexelSplatPipelineRD::_free_probe_framebuffers() {
	for (uint32_t i = 0; i < PROBE_LAYER_COUNT; i++) {
		ProbeLayerData &probe_layer = probe_layers[i];

		if (probe_layer.framebuffer.is_valid()) {
			RD::get_singleton()->free_rid(probe_layer.framebuffer);
			probe_layer.framebuffer = RID();
		}
		if (probe_layer.albedo_view.is_valid()) {
			RD::get_singleton()->free_rid(probe_layer.albedo_view);
			probe_layer.albedo_view = RID();
		}
		if (probe_layer.normal_view.is_valid()) {
			RD::get_singleton()->free_rid(probe_layer.normal_view);
			probe_layer.normal_view = RID();
		}
		if (probe_layer.radial_view.is_valid()) {
			RD::get_singleton()->free_rid(probe_layer.radial_view);
			probe_layer.radial_view = RID();
		}
		if (probe_layer.object_id_view.is_valid()) {
			RD::get_singleton()->free_rid(probe_layer.object_id_view);
			probe_layer.object_id_view = RID();
		}
		if (probe_layer.depth_view.is_valid()) {
			RD::get_singleton()->free_rid(probe_layer.depth_view);
			probe_layer.depth_view = RID();
		}
	}
}

void TexelSplatPipelineRD::_free_process_resources() {
	RenderingDevice *rd = RD::get_singleton();
	ERR_FAIL_NULL(rd);

	if (process_uniform_set.is_valid() && rd->uniform_set_is_valid(process_uniform_set)) {
		rd->free_rid(process_uniform_set);
	}
	process_uniform_set = RID();

	if (process_pipeline.is_valid()) {
		rd->free_rid(process_pipeline);
		process_pipeline = RID();
	}

	if (visible_refs_buffer.is_valid()) {
		rd->free_rid(visible_refs_buffer);
		visible_refs_buffer = RID();
	}
	if (splat_flags_buffer.is_valid()) {
		rd->free_rid(splat_flags_buffer);
		splat_flags_buffer = RID();
	}
	if (counter_buffer.is_valid()) {
		rd->free_rid(counter_buffer);
		counter_buffer = RID();
	}
	if (draw_args_buffer.is_valid()) {
		rd->free_rid(draw_args_buffer);
		draw_args_buffer = RID();
	}

	if (process_shader_version.is_valid()) {
		process_shader.version_free(process_shader_version);
		process_shader_version = RID();
	}
	process_shader_rd = RID();
	texel_capacity = 0;
}

void TexelSplatPipelineRD::_free_draw_resources() {
	RenderingDevice *rd = RD::get_singleton();
	ERR_FAIL_NULL(rd);

	_free_screen_grid_resources(screen_grid);

	composite_pipeline.clear();

	if (resolve_pipeline.is_valid()) {
		rd->free_rid(resolve_pipeline);
		resolve_pipeline = RID();
	}
	if (owner_boundary_pipeline.is_valid()) {
		rd->free_rid(owner_boundary_pipeline);
		owner_boundary_pipeline = RID();
	}

	if (draw_state_buffer.is_valid()) {
		rd->free_rid(draw_state_buffer);
		draw_state_buffer = RID();
	}

	if (resolve_shader_version.is_valid()) {
		resolve_shader.version_free(resolve_shader_version);
		resolve_shader_version = RID();
	}
	resolve_shader_rd = RID();

	if (owner_boundary_shader_version.is_valid()) {
		owner_boundary_shader.version_free(owner_boundary_shader_version);
		owner_boundary_shader_version = RID();
	}
	owner_boundary_shader_rd = RID();

	if (composite_shader_version.is_valid()) {
		composite_shader.version_free(composite_shader_version);
		composite_shader_version = RID();
	}
	composite_shader_rd = RID();
}

void TexelSplatPipelineRD::_free_screen_grid_resources(ScreenGridResources &r_resources) {
	RenderingDevice *rd = RD::get_singleton();
	ERR_FAIL_NULL(rd);

	if (r_resources.resolve_uniform_set.is_valid() && rd->uniform_set_is_valid(r_resources.resolve_uniform_set)) {
		rd->free_rid(r_resources.resolve_uniform_set);
	}
	r_resources.resolve_uniform_set = RID();

	if (r_resources.owner_boundary_uniform_set.is_valid() && rd->uniform_set_is_valid(r_resources.owner_boundary_uniform_set)) {
		rd->free_rid(r_resources.owner_boundary_uniform_set);
	}
	r_resources.owner_boundary_uniform_set = RID();

	if (r_resources.composite_uniform_set.is_valid() && rd->uniform_set_is_valid(r_resources.composite_uniform_set)) {
		rd->free_rid(r_resources.composite_uniform_set);
	}
	r_resources.composite_uniform_set = RID();

	if (r_resources.color.is_valid()) {
		rd->free_rid(r_resources.color);
		r_resources.color = RID();
	}
	if (r_resources.depth.is_valid()) {
		rd->free_rid(r_resources.depth);
		r_resources.depth = RID();
	}
	if (r_resources.meta.is_valid()) {
		rd->free_rid(r_resources.meta);
		r_resources.meta = RID();
	}
	if (r_resources.native_color.is_valid()) {
		rd->free_rid(r_resources.native_color);
		r_resources.native_color = RID();
	}
	if (r_resources.native_depth.is_valid()) {
		rd->free_rid(r_resources.native_depth);
		r_resources.native_depth = RID();
	}
	if (r_resources.native_meta.is_valid()) {
		rd->free_rid(r_resources.native_meta);
		r_resources.native_meta = RID();
	}
	if (r_resources.native_camera_depth.is_valid()) {
		rd->free_rid(r_resources.native_camera_depth);
		r_resources.native_camera_depth = RID();
	}
	if (r_resources.native_albedo.is_valid()) {
		rd->free_rid(r_resources.native_albedo);
		r_resources.native_albedo = RID();
	}
	if (r_resources.native_normal.is_valid()) {
		rd->free_rid(r_resources.native_normal);
		r_resources.native_normal = RID();
	}
	r_resources.size = Size2i();
	r_resources.native_size = Size2i();
	r_resources.owner_boundary_enabled = false;
	r_resources.copy_from_enabled = false;
}

} // namespace RendererSceneRenderImplementation
