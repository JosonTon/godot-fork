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

	initialized = true;
	return true;
}

void TexelSplatPipelineRD::free() {
	_free_probe_textures();
	initialized = false;
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

} // namespace RendererSceneRenderImplementation
