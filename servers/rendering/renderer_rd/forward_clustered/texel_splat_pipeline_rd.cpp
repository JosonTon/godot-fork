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

#include "core/error/error_macros.h"
#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"

namespace RendererSceneRenderImplementation {

TexelSplatPipelineRD::TexelSplatPipelineRD() = default;

TexelSplatPipelineRD::~TexelSplatPipelineRD() {
	free();
}

bool TexelSplatPipelineRD::initialize() {
	if (initialized) {
		return true;
	}

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
	_free_draw_resources();
	_free_process_resources();
	_free_probe_framebuffers();
	_free_probe_textures();
	initialized = false;
}

void TexelSplatPipelineRD::process_probe_data() {
	ERR_FAIL_COND(!initialized);
	ERR_FAIL_COND(process_pipeline.is_null());
	ERR_FAIL_COND(process_uniform_set.is_null());

	RenderingDevice *rd = RD::get_singleton();
	ERR_FAIL_NULL(rd);

	CounterData counters;
	DrawIndirectArgs draw_args;
	ERR_FAIL_COND(rd->buffer_update(counter_buffer, 0, sizeof(CounterData), &counters) != OK);
	ERR_FAIL_COND(rd->buffer_update(draw_args_buffer, 0, sizeof(DrawIndirectArgs), &draw_args) != OK);

	rd->draw_command_begin_label("Texel Splat Process");

	ProcessPushConstant push_constant;
	push_constant.probe_size = PROBE_SIZE;
	push_constant.layer_count = PROBE_LAYER_COUNT;
	push_constant.max_visible_refs = texel_capacity;

	RD::ComputeListID compute_list = rd->compute_list_begin();
	rd->compute_list_bind_compute_pipeline(compute_list, process_pipeline);
	rd->compute_list_bind_uniform_set(compute_list, process_uniform_set, 0);
	rd->compute_list_set_push_constant(compute_list, &push_constant, sizeof(ProcessPushConstant));
	rd->compute_list_dispatch_threads(compute_list, PROBE_SIZE, PROBE_SIZE, PROBE_LAYER_COUNT);
	rd->compute_list_add_barrier(compute_list);
	rd->compute_list_end();

	rd->draw_command_end_label();
}

void TexelSplatPipelineRD::draw_splats(RID p_framebuffer, const Projection &p_view_projection, const Vector<Transform3D> &p_probe_transforms, const Size2i &p_viewport_size) {
	ERR_FAIL_COND(!initialized);
	ERR_FAIL_COND(p_framebuffer.is_null());
	ERR_FAIL_COND(draw_uniform_set.is_null());
	ERR_FAIL_COND(draw_args_buffer.is_null());
	ERR_FAIL_COND(p_probe_transforms.size() != PROBE_LAYER_COUNT);

	RenderingDevice *rd = RD::get_singleton();
	ERR_FAIL_NULL(rd);

	DrawState draw_state;
	RendererRD::MaterialStorage::store_camera(p_view_projection, draw_state.view_projection);
	for (uint32_t i = 0; i < PROBE_LAYER_COUNT; i++) {
		RendererRD::MaterialStorage::store_transform(p_probe_transforms[i], draw_state.probe_transforms[i]);
	}
	draw_state.params[0] = float(PROBE_SIZE);
	draw_state.params[1] = 2.0f;
	draw_state.params[2] = float(p_viewport_size.x);
	draw_state.params[3] = float(p_viewport_size.y);

	ERR_FAIL_COND(rd->buffer_update(draw_state_buffer, 0, sizeof(DrawState), &draw_state) != OK);

	rd->draw_command_begin_label("Draw Texel Splats");

	RD::DrawListID draw_list = rd->draw_list_begin(p_framebuffer);
	RID pipeline = draw_pipeline.get_render_pipeline(RD::INVALID_ID, rd->framebuffer_get_format(p_framebuffer));
	rd->draw_list_bind_render_pipeline(draw_list, pipeline);
	rd->draw_list_bind_uniform_set(draw_list, draw_uniform_set, 0);
	rd->draw_list_draw_indirect(draw_list, false, draw_args_buffer);
	rd->draw_list_end();

	rd->draw_command_end_label();
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

	texel_capacity = PROBE_SIZE * PROBE_SIZE * PROBE_LAYER_COUNT;
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

	Vector<String> draw_modes;
	draw_modes.push_back("");
	draw_shader.initialize(draw_modes);
	draw_shader_version = draw_shader.version_create();
	draw_shader_rd = draw_shader.version_get_shader(draw_shader_version, 0);
	ERR_FAIL_COND_V_MSG(draw_shader_rd.is_null(), false, "Failed to create texel splatting draw shader.");

	RD::PipelineRasterizationState rasterization_state;
	rasterization_state.cull_mode = RD::POLYGON_CULL_DISABLED;

	draw_pipeline.setup(
			draw_shader_rd,
			RD::RENDER_PRIMITIVE_TRIANGLES,
			rasterization_state,
			RD::PipelineMultisampleState(),
			RD::PipelineDepthStencilState(),
			RD::PipelineColorBlendState::create_blend(),
			0);

	RendererRD::MaterialStorage *material_storage = RendererRD::MaterialStorage::get_singleton();
	ERR_FAIL_NULL_V(material_storage, false);

	RID nearest_sampler = material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	ERR_FAIL_COND_V(nearest_sampler.is_null(), false);

	Vector<RD::Uniform> uniforms;
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, Vector<RID>({ nearest_sampler, probe_textures[PROBE_TEXTURE_ALBEDO].texture })));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, Vector<RID>({ nearest_sampler, probe_textures[PROBE_TEXTURE_RADIAL].texture })));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 2, visible_refs_buffer));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 3, splat_flags_buffer));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 4, draw_state_buffer));

	draw_uniform_set = rd->uniform_set_create(uniforms, draw_shader_rd, 0);
	ERR_FAIL_COND_V_MSG(draw_uniform_set.is_null(), false, "Failed to create texel splatting draw uniform set.");

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

RID TexelSplatPipelineRD::_create_probe_texture(RD::DataFormat p_format, uint32_t p_usage_bits, const char *p_label) const {
	RD::TextureFormat texture_format;
	texture_format.format = p_format;
	texture_format.width = PROBE_SIZE;
	texture_format.height = PROBE_SIZE;
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

	if (draw_uniform_set.is_valid() && rd->uniform_set_is_valid(draw_uniform_set)) {
		rd->free_rid(draw_uniform_set);
	}
	draw_uniform_set = RID();

	draw_pipeline.clear();

	if (draw_state_buffer.is_valid()) {
		rd->free_rid(draw_state_buffer);
		draw_state_buffer = RID();
	}

	if (draw_shader_version.is_valid()) {
		draw_shader.version_free(draw_shader_version);
		draw_shader_version = RID();
	}
	draw_shader_rd = RID();
}

} // namespace RendererSceneRenderImplementation
