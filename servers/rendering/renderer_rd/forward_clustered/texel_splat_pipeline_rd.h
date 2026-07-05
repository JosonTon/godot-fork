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

#include "servers/rendering/rendering_device.h"

namespace RendererSceneRenderImplementation {

class TexelSplatPipelineRD {
	static const uint32_t PROBE_SIZE = 384;
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

	ProbeTextureData probe_textures[PROBE_TEXTURE_MAX];
	ProbeLayerData probe_layers[PROBE_LAYER_COUNT];
	bool initialized = false;

	bool _create_probe_textures();
	bool _create_probe_framebuffers();
	bool _is_format_supported(RD::DataFormat p_format, uint32_t p_usage_bits, const char *p_label) const;
	RD::DataFormat _select_depth_format(uint32_t p_usage_bits) const;
	RID _create_probe_texture(RD::DataFormat p_format, uint32_t p_usage_bits, const char *p_label) const;
	RID _create_probe_texture_slice(RID p_texture, uint32_t p_layer, const char *p_label) const;
	void _free_probe_textures();
	void _free_probe_framebuffers();

public:
	bool initialize();
	void free();
	bool is_initialized() const { return initialized; }
	uint32_t get_probe_size() const { return PROBE_SIZE; }
	uint32_t get_probe_layer_count() const { return PROBE_LAYER_COUNT; }
	RID get_probe_layer_framebuffer(uint32_t p_layer) const;
	RD::FramebufferFormatID get_probe_framebuffer_format() const;

	TexelSplatPipelineRD();
	~TexelSplatPipelineRD();
};

} // namespace RendererSceneRenderImplementation
