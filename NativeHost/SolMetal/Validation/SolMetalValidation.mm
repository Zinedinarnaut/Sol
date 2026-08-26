#import "SolMetal.h"

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <mach/mach.h>
#include <mach/task_info.h>

#include <cerrno>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <thread>
#include <vector>

#include "SolMetalAddSpirv.inc"

namespace {

struct Options {
    uint32_t contexts = 8;
    uint32_t iterations = 1;
    uint32_t flags = SOL_METAL_VALIDATION_ALL;
    uint64_t maxGrowthBytes = 384ull * 1024ull * 1024ull;
    uint32_t sharedContextThreads = 0;
    bool present = false;
    bool requireDirectMutationBatching = false;
    bool json = false;
};

static void PrintUsage(const char *executable) {
    std::fprintf(
        stderr,
        "Usage: %s [--contexts N] [--iterations N] [--max-growth-mib N] "
        "[--shared-context-threads N] [--render-only] "
        "[--render-pipeline-api-only] [--require-direct-mutation-batching] "
        "[--present] [--json]\n",
        executable);
}

static bool ParseUInt32(const char *value, uint32_t *output) {
    if (value == nullptr || output == nullptr || value[0] == '\0') {
        return false;
    }
    errno = 0;
    char *end = nullptr;
    const unsigned long long parsed = std::strtoull(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || parsed == 0 ||
        parsed > std::numeric_limits<uint32_t>::max()) {
        return false;
    }
    *output = static_cast<uint32_t>(parsed);
    return true;
}

static bool ParseOptions(int argc, const char *argv[], Options *options) {
    if (options == nullptr) {
        return false;
    }

    for (int index = 1; index < argc; ++index) {
        const char *argument = argv[index];
        if (std::strcmp(argument, "--present") == 0) {
            options->present = true;
        } else if (std::strcmp(argument, "--render-only") == 0) {
            options->flags = SOL_METAL_VALIDATION_RENDER;
        } else if (std::strcmp(argument, "--render-pipeline-api-only") == 0) {
            options->flags = SOL_METAL_VALIDATION_RENDER_PIPELINE_API;
        } else if (std::strcmp(
                       argument,
                       "--require-direct-mutation-batching") == 0) {
            options->requireDirectMutationBatching = true;
        } else if (std::strcmp(argument, "--json") == 0) {
            options->json = true;
        } else if (std::strcmp(argument, "--contexts") == 0 ||
                   std::strcmp(argument, "--iterations") == 0 ||
                   std::strcmp(argument, "--max-growth-mib") == 0 ||
                   std::strcmp(argument, "--shared-context-threads") == 0) {
            if (index + 1 >= argc) {
                return false;
            }
            uint32_t parsed = 0;
            if (!ParseUInt32(argv[++index], &parsed)) {
                return false;
            }
            if (std::strcmp(argument, "--contexts") == 0) {
                options->contexts = parsed;
            } else if (std::strcmp(argument, "--iterations") == 0) {
                options->iterations = parsed;
            } else if (std::strcmp(argument, "--shared-context-threads") == 0) {
                options->sharedContextThreads = parsed;
            } else {
                options->maxGrowthBytes =
                    static_cast<uint64_t>(parsed) * 1024ull * 1024ull;
            }
        } else if (std::strcmp(argument, "--help") == 0 ||
                   std::strcmp(argument, "-h") == 0) {
            PrintUsage(argv[0]);
            std::exit(0);
        } else {
            return false;
        }
    }
    return true;
}

static uint64_t PhysicalFootprint() {
    task_vm_info_data_t info = {};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    const kern_return_t result = task_info(
        mach_task_self(),
        TASK_VM_INFO,
        reinterpret_cast<task_info_t>(&info),
        &count);
    return result == KERN_SUCCESS ? info.phys_footprint : 0;
}

static bool ValidateFaultGuards() {
    SolMetalCapabilities capabilities = {};
    capabilities.struct_size = 1;
    if (sol_metal_query_capabilities(nullptr) !=
            SOL_METAL_STATUS_INVALID_ARGUMENT ||
        sol_metal_query_capabilities(&capabilities) !=
            SOL_METAL_STATUS_INCOMPATIBLE_ABI ||
        sol_metal_context_create(nullptr) !=
            SOL_METAL_STATUS_INVALID_ARGUMENT) {
        return false;
    }

    SolMetalContextRef context = nullptr;
    if (sol_metal_context_create(&context) != SOL_METAL_STATUS_OK ||
        context == nullptr) {
        return false;
    }

    SolMetalValidationReport undersizedReport = {};
    undersizedReport.struct_size = 1;
    SolMetalValidationReport validReport = {};
    validReport.struct_size = sizeof(validReport);
    SolMetalCapabilities undersizedCapabilities = {};
    undersizedCapabilities.struct_size = 1;
    uint32_t invalidSpirv[5] = {};
    SolMetalSpirvTranslationOptions translationOptions = {};
    translationOptions.struct_size = sizeof(translationOptions);
    translationOptions.abi_version = SOL_METAL_ABI_VERSION;
    translationOptions.stage = SOL_METAL_SHADER_STAGE_COMPUTE;
    SolMetalSpirvTranslationOptions undersizedTranslationOptions =
        translationOptions;
    undersizedTranslationOptions.struct_size = 1;
    SolMetalSpirvTranslationReport translationReport = {};
    translationReport.struct_size = sizeof(translationReport);
    SolMetalSpirvTranslationReport undersizedTranslationReport = {};
    undersizedTranslationReport.struct_size = 1;
    SolMetalShaderTranslationRef translation = nullptr;
    uint64_t requiredSize = 0;
    SolMetalBufferDescriptor bufferDescriptor = {};
    bufferDescriptor.struct_size = sizeof(bufferDescriptor);
    bufferDescriptor.abi_version = SOL_METAL_ABI_VERSION;
    bufferDescriptor.size = 256;
    bufferDescriptor.storage_mode = SOL_METAL_BUFFER_STORAGE_SHARED;
    SolMetalBufferDescriptor undersizedBufferDescriptor = bufferDescriptor;
    undersizedBufferDescriptor.struct_size = 1;
    SolMetalBufferRef buffer = nullptr;
    SolMetalTextureDescriptor textureDescriptor = {};
    textureDescriptor.struct_size = sizeof(textureDescriptor);
    textureDescriptor.abi_version = SOL_METAL_ABI_VERSION;
    textureDescriptor.width = 8;
    textureDescriptor.height = 8;
    textureDescriptor.pixel_format = SOL_METAL_TEXTURE_FORMAT_RGBA8_UNORM;
    textureDescriptor.storage_mode = SOL_METAL_BUFFER_STORAGE_PRIVATE;
    textureDescriptor.usage = SOL_METAL_TEXTURE_USAGE_SAMPLED;
    SolMetalTextureDescriptor undersizedTextureDescriptor = textureDescriptor;
    undersizedTextureDescriptor.struct_size = 1;
    SolMetalTextureRef texture = nullptr;
    SolMetalPresentTextureDescriptor presentTextureDescriptor = {};
    presentTextureDescriptor.struct_size = sizeof(presentTextureDescriptor);
    presentTextureDescriptor.abi_version = SOL_METAL_ABI_VERSION;
    presentTextureDescriptor.pixel_width = 64;
    presentTextureDescriptor.pixel_height = 64;
    presentTextureDescriptor.filter = SOL_METAL_SAMPLER_FILTER_LINEAR;
    SolMetalPresentTextureDescriptor undersizedPresentTextureDescriptor =
        presentTextureDescriptor;
    undersizedPresentTextureDescriptor.struct_size = 1;
    SolMetalSamplerDescriptor samplerDescriptor = {};
    samplerDescriptor.struct_size = sizeof(samplerDescriptor);
    samplerDescriptor.abi_version = SOL_METAL_ABI_VERSION;
    samplerDescriptor.min_filter = SOL_METAL_SAMPLER_FILTER_NEAREST;
    samplerDescriptor.mag_filter = SOL_METAL_SAMPLER_FILTER_NEAREST;
    samplerDescriptor.mip_filter =
        SOL_METAL_SAMPLER_MIP_FILTER_NOT_MIPMAPPED;
    samplerDescriptor.address_u = SOL_METAL_SAMPLER_ADDRESS_CLAMP_TO_EDGE;
    samplerDescriptor.address_v = SOL_METAL_SAMPLER_ADDRESS_CLAMP_TO_EDGE;
    samplerDescriptor.address_w = SOL_METAL_SAMPLER_ADDRESS_CLAMP_TO_EDGE;
    samplerDescriptor.max_anisotropy = 1;
    SolMetalSamplerDescriptor undersizedSamplerDescriptor = samplerDescriptor;
    undersizedSamplerDescriptor.struct_size = 1;
    SolMetalSamplerRef sampler = nullptr;
    SolMetalComputePipelineRef computePipeline = nullptr;
    SolMetalComputePipelineInfo pipelineInfo = {};
    pipelineInfo.struct_size = sizeof(pipelineInfo);
    SolMetalComputePipelineInfo undersizedPipelineInfo = {};
    undersizedPipelineInfo.struct_size = 1;
    SolMetalComputeDispatchDescriptor dispatchDescriptor = {};
    dispatchDescriptor.struct_size = sizeof(dispatchDescriptor);
    dispatchDescriptor.abi_version = SOL_METAL_ABI_VERSION;
    dispatchDescriptor.thread_count_x = 1;
    dispatchDescriptor.thread_count_y = 1;
    dispatchDescriptor.thread_count_z = 1;
    dispatchDescriptor.threadgroup_size_x = 1;
    dispatchDescriptor.threadgroup_size_y = 1;
    dispatchDescriptor.threadgroup_size_z = 1;
    SolMetalRenderPipelineDescriptor renderPipelineDescriptor = {};
    renderPipelineDescriptor.struct_size = sizeof(renderPipelineDescriptor);
    renderPipelineDescriptor.abi_version = SOL_METAL_ABI_VERSION;
    SolMetalRenderPipelineDescriptor undersizedRenderPipelineDescriptor = {};
    undersizedRenderPipelineDescriptor.struct_size = 1;
    SolMetalRenderPipelineAdvancedDescriptor
        undersizedAdvancedRenderPipelineDescriptor = {};
    undersizedAdvancedRenderPipelineDescriptor.struct_size = 1;
    SolMetalRenderPipelineRef renderPipeline = nullptr;
    SolMetalRenderDrawDescriptor renderDrawDescriptor = {};
    renderDrawDescriptor.struct_size = sizeof(renderDrawDescriptor);
    renderDrawDescriptor.abi_version = SOL_METAL_ABI_VERSION;
    SolMetalRasterizerState rasterizerState = {};
    rasterizerState.struct_size = sizeof(rasterizerState);
    rasterizerState.abi_version = SOL_METAL_ABI_VERSION;
    rasterizerState.front_face = SOL_METAL_WINDING_CLOCKWISE;
    rasterizerState.cull_mode = SOL_METAL_CULL_NONE;
    rasterizerState.triangle_fill_mode = SOL_METAL_TRIANGLE_FILL;
    rasterizerState.depth_clip_mode = SOL_METAL_DEPTH_CLIP;
    SolMetalVertexBufferLayout vertexLayout = {};
    vertexLayout.buffer_index = 0;
    vertexLayout.stride = 16;
    vertexLayout.step_function = SOL_METAL_VERTEX_STEP_PER_VERTEX;
    vertexLayout.step_rate = 1;
    SolMetalVertexAttribute vertexAttribute = {};
    vertexAttribute.location = 0;
    vertexAttribute.buffer_index = 0;
    vertexAttribute.format = SOL_METAL_VERTEX_FORMAT_FLOAT4;
    SolMetalRenderStageBindings stageBindings = {};
    stageBindings.struct_size = sizeof(stageBindings);
    stageBindings.abi_version = SOL_METAL_ABI_VERSION;
    SolMetalRenderIndexBinding indexBinding = {};
    indexBinding.struct_size = sizeof(indexBinding);
    indexBinding.abi_version = SOL_METAL_ABI_VERSION;
    indexBinding.index_type = SOL_METAL_INDEX_UINT16;
    const bool passed =
        sol_metal_context_query_capabilities(context, nullptr) ==
            SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_query_capabilities(context, &undersizedCapabilities) ==
            SOL_METAL_STATUS_INCOMPATIBLE_ABI &&
        sol_metal_context_run_validation(
            context,
            SOL_METAL_VALIDATION_ALL,
            1,
            nullptr) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_run_validation(
            context,
            SOL_METAL_VALIDATION_ALL,
            1,
            &undersizedReport) == SOL_METAL_STATUS_INCOMPATIBLE_ABI &&
        sol_metal_context_run_validation(
            context,
            0,
            1,
            &validReport) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_run_validation(
            context,
            SOL_METAL_VALIDATION_ALL << 1,
            1,
            &validReport) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_run_validation(
            context,
            SOL_METAL_VALIDATION_ALL,
            0,
            &validReport) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_translate_spirv(
            context,
            invalidSpirv,
            5,
            &translationOptions,
            &undersizedTranslationReport,
            &translation) == SOL_METAL_STATUS_INCOMPATIBLE_ABI &&
        translation == nullptr &&
        sol_metal_context_translate_spirv(
            context,
            invalidSpirv,
            5,
            &undersizedTranslationOptions,
            &translationReport,
            &translation) == SOL_METAL_STATUS_INCOMPATIBLE_ABI &&
        translation == nullptr &&
        sol_metal_context_translate_spirv(
            context,
            invalidSpirv,
            5,
            &translationOptions,
            &translationReport,
            nullptr) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_shader_translation_copy_msl(
            nullptr,
            nullptr,
            0,
            &requiredSize) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_shader_translation_copy_msl(
            nullptr,
            nullptr,
            0,
            nullptr) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_buffer_create(
            nullptr,
            &bufferDescriptor,
            &buffer) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        buffer == nullptr &&
        sol_metal_context_buffer_create(
            context,
            nullptr,
            &buffer) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        buffer == nullptr &&
        sol_metal_context_buffer_create(
            context,
            &bufferDescriptor,
            nullptr) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_buffer_create(
            context,
            &undersizedBufferDescriptor,
            &buffer) == SOL_METAL_STATUS_INCOMPATIBLE_ABI &&
        buffer == nullptr &&
        sol_metal_context_buffer_create(
            context,
            &bufferDescriptor,
            &buffer) == SOL_METAL_STATUS_OK &&
        buffer != nullptr &&
        sol_metal_context_buffer_upload(
            nullptr,
            buffer,
            0,
            &requiredSize,
            sizeof(requiredSize)) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_buffer_upload(
            context,
            nullptr,
            0,
            &requiredSize,
            sizeof(requiredSize)) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_buffer_download(
            context,
            buffer,
            255,
            &requiredSize,
            sizeof(requiredSize)) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_buffer_copy(
            context,
            buffer,
            0,
            nullptr,
            0,
            1) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_texture_create_2d(
            nullptr,
            &textureDescriptor,
            &texture) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        texture == nullptr &&
        sol_metal_context_texture_create_2d(
            context,
            &undersizedTextureDescriptor,
            &texture) == SOL_METAL_STATUS_INCOMPATIBLE_ABI &&
        texture == nullptr &&
        sol_metal_context_texture_create_2d(
            context,
            &textureDescriptor,
            &texture) == SOL_METAL_STATUS_OK &&
        texture != nullptr &&
        sol_metal_context_texture_upload_2d(
            context,
            texture,
            nullptr,
            32,
            256) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_texture_download_2d(
            nullptr,
            texture,
            &requiredSize,
            32,
            256) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_texture_copy_2d(
            context,
            texture,
            nullptr) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_sampler_create(
            nullptr,
            &samplerDescriptor,
            &sampler) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sampler == nullptr &&
        sol_metal_context_sampler_create(
            context,
            &undersizedSamplerDescriptor,
            &sampler) == SOL_METAL_STATUS_INCOMPATIBLE_ABI &&
        sampler == nullptr &&
        sol_metal_context_sampler_create(
            context,
            &samplerDescriptor,
            &sampler) == SOL_METAL_STATUS_OK &&
        sampler != nullptr &&
        sol_metal_context_compute_pipeline_create(
            context,
            nullptr,
            &computePipeline) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        computePipeline == nullptr &&
        sol_metal_context_compute_pipeline_create(
            context,
            nullptr,
            nullptr) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_compute_pipeline_query_info(
            nullptr,
            &pipelineInfo) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_compute_pipeline_query_info(
            nullptr,
            &undersizedPipelineInfo) == SOL_METAL_STATUS_INCOMPATIBLE_ABI &&
        sol_metal_context_compute_dispatch(
            context,
            nullptr,
            &dispatchDescriptor) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_render_pipeline_create(
            context,
            nullptr,
            &renderPipeline) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        renderPipeline == nullptr &&
        sol_metal_context_render_pipeline_create(
            context,
            &undersizedRenderPipelineDescriptor,
            &renderPipeline) == SOL_METAL_STATUS_INCOMPATIBLE_ABI &&
        renderPipeline == nullptr &&
        sol_metal_context_render_pipeline_create(
            context,
            &renderPipelineDescriptor,
            nullptr) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_render_pipeline_create_with_vertex_layout(
            context,
            nullptr,
            &vertexLayout,
            1,
            &vertexAttribute,
            1,
            &renderPipeline) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        renderPipeline == nullptr &&
        sol_metal_context_render_pipeline_create_with_vertex_layout(
            context,
            &undersizedRenderPipelineDescriptor,
            &vertexLayout,
            1,
            &vertexAttribute,
            1,
            &renderPipeline) == SOL_METAL_STATUS_INCOMPATIBLE_ABI &&
        renderPipeline == nullptr &&
        sol_metal_context_render_pipeline_create_with_vertex_layout(
            context,
            &renderPipelineDescriptor,
            &vertexLayout,
            1,
            &vertexAttribute,
            1,
            nullptr) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_render_pipeline_create_advanced(
            context,
            &undersizedAdvancedRenderPipelineDescriptor,
            &vertexLayout,
            1,
            &vertexAttribute,
            1,
            &renderPipeline) == SOL_METAL_STATUS_INCOMPATIBLE_ABI &&
        renderPipeline == nullptr &&
        sol_metal_context_render_draw(
            context,
            nullptr,
            &renderDrawDescriptor) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_render_draw_bound(
            context,
            nullptr,
            &renderDrawDescriptor,
            &stageBindings,
            &stageBindings) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_render_draw_indexed_bound(
            context,
            nullptr,
            &renderDrawDescriptor,
            nullptr,
            &stageBindings,
            &stageBindings) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_render_draw_advanced(
            context,
            nullptr,
            &renderDrawDescriptor,
            nullptr,
            &stageBindings,
            &stageBindings,
            nullptr) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_render_draw_rasterized(
            context,
            nullptr,
            &renderDrawDescriptor,
            nullptr,
            &stageBindings,
            &stageBindings,
            nullptr,
            &rasterizerState) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_render_draw_rasterized(
            context,
            nullptr,
            &renderDrawDescriptor,
            nullptr,
            &stageBindings,
            &stageBindings,
            nullptr,
            nullptr) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_render_draw_indexed_bound(
            context,
            nullptr,
            &renderDrawDescriptor,
            &indexBinding,
            &stageBindings,
            &stageBindings) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_present_clear(
            context,
            nullptr,
            64,
            64,
            0,
            0,
            0,
            1) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_present_texture(
            context,
            nullptr,
            &undersizedPresentTextureDescriptor) ==
                SOL_METAL_STATUS_INCOMPATIBLE_ABI &&
        sol_metal_context_present_texture(
            context,
            nullptr,
            &presentTextureDescriptor) ==
                SOL_METAL_STATUS_INVALID_ARGUMENT;
    sol_metal_context_destroy(context);
    sol_metal_context_destroy(nullptr);
    sol_metal_shader_translation_destroy(nullptr);
    sol_metal_buffer_destroy(buffer);
    sol_metal_buffer_destroy(nullptr);
    sol_metal_texture_destroy(texture);
    sol_metal_texture_destroy(nullptr);
    sol_metal_sampler_destroy(sampler);
    sol_metal_sampler_destroy(nullptr);
    sol_metal_compute_pipeline_destroy(computePipeline);
    sol_metal_compute_pipeline_destroy(nullptr);
    sol_metal_render_pipeline_destroy(renderPipeline);
    sol_metal_render_pipeline_destroy(nullptr);
    return passed;
}

static bool ValidateContextIsolation() {
    SolMetalContextRef firstContext = nullptr;
    SolMetalContextRef secondContext = nullptr;
    SolMetalBufferRef sourceBuffer = nullptr;
    SolMetalBufferRef destinationBuffer = nullptr;
    SolMetalTextureRef texture = nullptr;
    SolMetalBufferDescriptor bufferDescriptor = {};
    SolMetalTextureDescriptor textureDescriptor = {};
    std::array<uint8_t, 256> bytes = {};
    constexpr uint32_t firstUnsupportedQuadCount =
        static_cast<uint32_t>((64ull * 1024ull * 1024ull) /
            (6ull * sizeof(uint32_t)) + 1ull);
    bool passed = false;

    if (sol_metal_context_create(&firstContext) != SOL_METAL_STATUS_OK ||
        sol_metal_context_create(&secondContext) != SOL_METAL_STATUS_OK) {
        goto cleanup;
    }

    bufferDescriptor.struct_size = sizeof(bufferDescriptor);
    bufferDescriptor.abi_version = SOL_METAL_ABI_VERSION;
    bufferDescriptor.size = 256;
    bufferDescriptor.storage_mode = SOL_METAL_BUFFER_STORAGE_SHARED;
    if (sol_metal_context_buffer_create(
            firstContext,
            &bufferDescriptor,
            &sourceBuffer) != SOL_METAL_STATUS_OK ||
        sol_metal_context_buffer_create(
            firstContext,
            &bufferDescriptor,
            &destinationBuffer) != SOL_METAL_STATUS_OK) {
        goto cleanup;
    }

    textureDescriptor.struct_size = sizeof(textureDescriptor);
    textureDescriptor.abi_version = SOL_METAL_ABI_VERSION;
    textureDescriptor.width = 8;
    textureDescriptor.height = 8;
    textureDescriptor.pixel_format = SOL_METAL_TEXTURE_FORMAT_RGBA8_UNORM;
    textureDescriptor.storage_mode = SOL_METAL_BUFFER_STORAGE_PRIVATE;
    textureDescriptor.usage = SOL_METAL_TEXTURE_USAGE_SAMPLED;
    if (sol_metal_context_texture_create_2d(
            firstContext,
            &textureDescriptor,
            &texture) != SOL_METAL_STATUS_OK) {
        goto cleanup;
    }

    passed =
        sol_metal_context_buffer_upload(
            secondContext,
            sourceBuffer,
            0,
            bytes.data(),
            bytes.size()) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_texture_upload_2d(
            secondContext,
            texture,
            bytes.data(),
            8 * 4,
            bytes.size()) == SOL_METAL_STATUS_INVALID_ARGUMENT &&
        sol_metal_context_buffer_expand_quad_indices(
            firstContext,
            sourceBuffer,
            0,
            SOL_METAL_INDEX_UINT8,
            firstUnsupportedQuadCount,
            destinationBuffer,
            0) == SOL_METAL_STATUS_UNSUPPORTED;

cleanup:
    sol_metal_texture_destroy(texture);
    sol_metal_buffer_destroy(destinationBuffer);
    sol_metal_buffer_destroy(sourceBuffer);
    sol_metal_context_destroy(secondContext);
    sol_metal_context_destroy(firstContext);
    return passed;
}

static SolMetalStatus ValidatePresentation(
    SolMetalContextRef context,
    NSString **errorMessage) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    [NSApp finishLaunching];

    const NSRect frame = NSMakeRect(-10'000, -10'000, 160, 90);
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:frame
        styleMask:NSWindowStyleMaskBorderless
        backing:NSBackingStoreBuffered
        defer:NO];
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 160, 90)];
    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = MTLCreateSystemDefaultDevice();
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    layer.drawableSize = CGSizeMake(320, 180);
    layer.maximumDrawableCount = 3;
    layer.allowsNextDrawableTimeout = YES;
    view.wantsLayer = YES;
    view.layer = layer;
    window.contentView = view;
    [window orderBack:nil];
    [window displayIfNeeded];

    id<MTLDevice> originalDevice = layer.device;
    const MTLPixelFormat originalPixelFormat = layer.pixelFormat;
    const BOOL originalFramebufferOnly = layer.framebufferOnly;
    const CGSize originalDrawableSize = layer.drawableSize;
    const BOOL originalAllowsNextDrawableTimeout = layer.allowsNextDrawableTimeout;

    SolMetalStatus status = sol_metal_context_present_clear(
        context,
        (__bridge void *)layer,
        320,
        180,
        0.02,
        0.04,
        0.08,
        1.0);

    SolMetalTextureRef sourceTexture = nullptr;
    if (status == SOL_METAL_STATUS_OK) {
        SolMetalTextureDescriptor textureDescriptor = {};
        textureDescriptor.struct_size = sizeof(textureDescriptor);
        textureDescriptor.abi_version = SOL_METAL_ABI_VERSION;
        textureDescriptor.width = 160;
        textureDescriptor.height = 90;
        textureDescriptor.pixel_format = SOL_METAL_TEXTURE_FORMAT_BGRA8_UNORM;
        textureDescriptor.storage_mode = SOL_METAL_BUFFER_STORAGE_PRIVATE;
        textureDescriptor.usage = SOL_METAL_TEXTURE_USAGE_SAMPLED;
        status = sol_metal_context_texture_create_2d(
            context,
            &textureDescriptor,
            &sourceTexture);
    }

    if (status == SOL_METAL_STATUS_OK) {
        SolMetalTextureDescriptor arrayDescriptor = {};
        arrayDescriptor.struct_size = sizeof(arrayDescriptor);
        arrayDescriptor.abi_version = SOL_METAL_ABI_VERSION;
        arrayDescriptor.width = 160;
        arrayDescriptor.height = 90;
        arrayDescriptor.texture_type = SOL_METAL_TEXTURE_TYPE_2D_ARRAY;
        arrayDescriptor.depth_or_array_length = 2;
        arrayDescriptor.pixel_format = SOL_METAL_TEXTURE_FORMAT_BGRA8_UNORM;
        arrayDescriptor.storage_mode = SOL_METAL_BUFFER_STORAGE_PRIVATE;
        arrayDescriptor.usage = SOL_METAL_TEXTURE_USAGE_SAMPLED;
        SolMetalTextureRef arrayTexture = nullptr;
        status = sol_metal_context_texture_create_2d(
            context,
            &arrayDescriptor,
            &arrayTexture);
        if (status == SOL_METAL_STATUS_OK) {
            SolMetalPresentTextureDescriptor invalidPresent = {};
            invalidPresent.struct_size = sizeof(invalidPresent);
            invalidPresent.abi_version = SOL_METAL_ABI_VERSION;
            invalidPresent.source_texture = arrayTexture;
            invalidPresent.pixel_width = 320;
            invalidPresent.pixel_height = 180;
            invalidPresent.filter = SOL_METAL_SAMPLER_FILTER_NEAREST;
            const SolMetalStatus guardStatus =
                sol_metal_context_present_texture(
                    context,
                    (__bridge void *)layer,
                    &invalidPresent);
            if (guardStatus != SOL_METAL_STATUS_INVALID_ARGUMENT) {
                status = SOL_METAL_STATUS_VALIDATION_FAILED;
                if (errorMessage != nullptr) {
                    *errorMessage =
                        @"Presentation accepted a non-2D source texture";
                }
            }
        }
        sol_metal_texture_destroy(arrayTexture);
    }

    if (status == SOL_METAL_STATUS_OK) {
        SolMetalContextRef foreignContext = nullptr;
        status = sol_metal_context_create(&foreignContext);
        if (status == SOL_METAL_STATUS_OK) {
            SolMetalPresentTextureDescriptor invalidPresent = {};
            invalidPresent.struct_size = sizeof(invalidPresent);
            invalidPresent.abi_version = SOL_METAL_ABI_VERSION;
            invalidPresent.source_texture = sourceTexture;
            invalidPresent.pixel_width = 320;
            invalidPresent.pixel_height = 180;
            invalidPresent.filter = SOL_METAL_SAMPLER_FILTER_NEAREST;
            const SolMetalStatus guardStatus =
                sol_metal_context_present_texture(
                    foreignContext,
                    (__bridge void *)layer,
                    &invalidPresent);
            if (guardStatus != SOL_METAL_STATUS_INVALID_ARGUMENT) {
                status = SOL_METAL_STATUS_VALIDATION_FAILED;
                if (errorMessage != nullptr) {
                    *errorMessage =
                        @"Presentation accepted a texture owned by another context";
                }
            }
        }
        sol_metal_context_destroy(foreignContext);
    }

    if (status == SOL_METAL_STATUS_OK) {
        constexpr uint32_t sourceWidth = 160;
        constexpr uint32_t sourceHeight = 90;
        constexpr uint32_t bytesPerPixel = 4;
        std::vector<uint8_t> pixels(
            sourceWidth * sourceHeight * bytesPerPixel);
        for (uint32_t y = 0; y < sourceHeight; ++y) {
            for (uint32_t x = 0; x < sourceWidth; ++x) {
                const size_t offset =
                    (static_cast<size_t>(y) * sourceWidth + x) *
                    bytesPerPixel;
                pixels[offset + 0] = static_cast<uint8_t>(
                    24 + (x * 96) / (sourceWidth - 1));
                pixels[offset + 1] = static_cast<uint8_t>(
                    28 + (y * 112) / (sourceHeight - 1));
                pixels[offset + 2] = static_cast<uint8_t>(
                    48 + ((x + y) * 144) /
                        (sourceWidth + sourceHeight - 2));
                pixels[offset + 3] = 255;
            }
        }
        status = sol_metal_context_texture_upload_2d(
            context,
            sourceTexture,
            pixels.data(),
            sourceWidth * bytesPerPixel,
            pixels.size());
    }

    if (status == SOL_METAL_STATUS_OK) {
        SolMetalPresentTextureDescriptor presentDescriptor = {};
        presentDescriptor.struct_size = sizeof(presentDescriptor);
        presentDescriptor.abi_version = SOL_METAL_ABI_VERSION;
        presentDescriptor.source_texture = sourceTexture;
        presentDescriptor.pixel_width = 320;
        presentDescriptor.pixel_height = 180;

        // Submit more frames than the layer can keep drawable-backed at once.
        // This exercises bounded asynchronous presentation rather than only
        // proving that one command buffer can be encoded.
        constexpr uint32_t presentationFrameCount = 8;
        for (uint32_t frameIndex = 0;
             frameIndex < presentationFrameCount;
             ++frameIndex) {
            presentDescriptor.filter = frameIndex % 2 == 0
                ? SOL_METAL_SAMPLER_FILTER_NEAREST
                : SOL_METAL_SAMPLER_FILTER_LINEAR;
            if (presentDescriptor.filter ==
                SOL_METAL_SAMPLER_FILTER_LINEAR) {
                // The managed app uses live sizing because AppKit may settle
                // a resize between surface measurement and presentation.
                presentDescriptor.pixel_width = 0;
                presentDescriptor.pixel_height = 0;
            } else {
                presentDescriptor.pixel_width = 320;
                presentDescriptor.pixel_height = 180;
            }
            status = sol_metal_context_present_texture(
                context,
                (__bridge void *)layer,
                &presentDescriptor);
            if (status != SOL_METAL_STATUS_OK) {
                break;
            }
        }

        if (status == SOL_METAL_STATUS_OK) {
            presentDescriptor.pixel_width = 319;
            presentDescriptor.pixel_height = 180;
            const SolMetalStatus guardStatus =
                sol_metal_context_present_texture(
                    context,
                    (__bridge void *)layer,
                    &presentDescriptor);
            if (guardStatus != SOL_METAL_STATUS_INVALID_ARGUMENT) {
                status = SOL_METAL_STATUS_VALIDATION_FAILED;
            }
        }
        if (status == SOL_METAL_STATUS_OK) {
            status = sol_metal_context_wait_idle(
                context,
                5'000'000'000ull);
        }
    }
    sol_metal_texture_destroy(sourceTexture);

    if (status == SOL_METAL_STATUS_OK &&
        (layer.device != originalDevice ||
         layer.pixelFormat != originalPixelFormat ||
         layer.framebufferOnly != originalFramebufferOnly ||
         !CGSizeEqualToSize(layer.drawableSize, originalDrawableSize) ||
         layer.allowsNextDrawableTimeout != originalAllowsNextDrawableTimeout)) {
        if (errorMessage != nullptr) {
            *errorMessage = [NSString stringWithFormat:
                @"CAMetalLayer ownership changed (device=%d format=%d framebuffer=%d size=%d %.1fx%.1f->%.1fx%.1f timeout=%d)",
                layer.device != originalDevice,
                layer.pixelFormat != originalPixelFormat,
                layer.framebufferOnly != originalFramebufferOnly,
                !CGSizeEqualToSize(layer.drawableSize, originalDrawableSize),
                originalDrawableSize.width,
                originalDrawableSize.height,
                layer.drawableSize.width,
                layer.drawableSize.height,
                layer.allowsNextDrawableTimeout != originalAllowsNextDrawableTimeout];
        }
        status = SOL_METAL_STATUS_VALIDATION_FAILED;
    }

    view.layer = nil;
    [window orderOut:nil];
    [window close];
    return status;
}

static bool RunOneContext(
    const Options &options,
    bool validatePresentation,
    uint64_t *expectedSignature,
    uint64_t *testsRun,
    uint64_t *testsPassed,
    uint64_t *commandBuffers,
    uint64_t *bytesVerified,
    uint64_t *gpuNanoseconds,
    NSString **errorMessage) {
    SolMetalContextRef context = nullptr;
    SolMetalStatus status = sol_metal_context_create(&context);
    if (status != SOL_METAL_STATUS_OK || context == nullptr) {
        *errorMessage = [NSString stringWithFormat:
            @"Context creation failed: %s",
            sol_metal_status_string(status)];
        return false;
    }

    if (options.requireDirectMutationBatching) {
        SolMetalRuntimeBatchReport batchReport = {};
        batchReport.struct_size = sizeof(batchReport);
        status = sol_metal_context_runtime_batch_query(
            context,
            &batchReport);
        if (status != SOL_METAL_STATUS_OK ||
            batchReport.direct_mutation_batching_enabled != 1) {
            *errorMessage = [NSString stringWithFormat:
                @"Direct mutation batching was required but runtime telemetry reported enabled=%u (%s)",
                batchReport.direct_mutation_batching_enabled,
                sol_metal_status_string(status)];
            sol_metal_context_destroy(context);
            return false;
        }
    }

    SolMetalValidationReport report = {};
    report.struct_size = sizeof(report);
    status = sol_metal_context_run_validation(
        context,
        options.flags,
        options.iterations,
        &report);
    bool passed = status == SOL_METAL_STATUS_OK &&
        report.abi_version == SOL_METAL_ABI_VERSION &&
        report.completed_flags == options.flags &&
        report.iterations_completed == options.iterations &&
        report.tests_run == report.tests_passed;
    if (passed && (options.flags & SOL_METAL_VALIDATION_SHADER_CACHE) != 0) {
        passed = report.shader_cache_hits >= options.iterations &&
            report.shader_cache_misses >= 1 &&
            report.binary_archives_created == options.iterations;
        if (!passed) {
            *errorMessage = @"Shader cache/archive counters violated their validation contract";
        }
    }

    if (passed && *expectedSignature == 0) {
        *expectedSignature = report.output_signature;
    } else if (passed && report.output_signature != *expectedSignature) {
        passed = false;
        *errorMessage = @"Validation output signature changed between contexts";
    }

    if (passed && validatePresentation) {
        status = ValidatePresentation(context, errorMessage);
        passed = status == SOL_METAL_STATUS_OK;
    }

    *testsRun += report.tests_run;
    *testsPassed += report.tests_passed;
    *commandBuffers += report.command_buffers_completed;
    *bytesVerified += report.bytes_verified;
    *gpuNanoseconds += report.gpu_time_nanoseconds;

    if (!passed && *errorMessage == nil) {
        if (report.last_error[0] != '\0') {
            *errorMessage = [NSString stringWithUTF8String:report.last_error];
        } else {
            *errorMessage = [NSString stringWithFormat:
                @"Validation failed: %s",
                sol_metal_status_string(status)];
        }
    }

    sol_metal_context_destroy(context);
    return passed;
}

static bool ValidateSharedContextThreads(
    uint32_t threadCount,
    NSString **errorMessage) {
    if (threadCount == 0) {
        return true;
    }

    SolMetalContextRef context = nullptr;
    SolMetalStatus createStatus = sol_metal_context_create(&context);
    if (createStatus != SOL_METAL_STATUS_OK || context == nullptr) {
        *errorMessage = @"Shared-context stress could not create a SolMetal context";
        return false;
    }

    if (sol_metal_add_spirv_len % sizeof(uint32_t) != 0) {
        sol_metal_context_destroy(context);
        *errorMessage = @"Concurrent translation fixture has an invalid size";
        return false;
    }
    std::vector<uint32_t> translationWords(
        sol_metal_add_spirv_len / sizeof(uint32_t));
    std::memcpy(
        translationWords.data(),
        sol_metal_add_spirv,
        sol_metal_add_spirv_len);

    struct TranslationThreadResult {
        SolMetalStatus status = SOL_METAL_STATUS_INTERNAL_ERROR;
        SolMetalSpirvTranslationReport report = {};
        bool resourcesPassed = false;
    };
    std::vector<TranslationThreadResult> translationResults(threadCount);
    std::vector<std::thread> translationThreads;
    translationThreads.reserve(threadCount);
    try {
        for (uint32_t index = 0; index < threadCount; ++index) {
            translationThreads.emplace_back(
                [context, index, &translationWords, &translationResults]() {
                    @autoreleasepool {
                        TranslationThreadResult &result =
                            translationResults[index];
                        SolMetalSpirvResourceBinding binding = {};
                        binding.descriptor_set = 0;
                        binding.binding = 0;
                        binding.msl_buffer = 0;
                        SolMetalSpirvTranslationOptions translationOptions = {};
                        translationOptions.struct_size =
                            sizeof(translationOptions);
                        translationOptions.abi_version = SOL_METAL_ABI_VERSION;
                        translationOptions.stage =
                            SOL_METAL_SHADER_STAGE_COMPUTE;
                        translationOptions.resource_binding_count = 1;
                        translationOptions.resource_bindings = &binding;

                        constexpr uint32_t TranslationIterations = 8;
                        SolMetalComputePipelineRef computePipeline = nullptr;
                        for (uint32_t iteration = 0;
                             iteration < TranslationIterations;
                             ++iteration) {
                            result.report = {};
                            result.report.struct_size = sizeof(result.report);
                            SolMetalShaderTranslationRef translation = nullptr;
                            result.status = sol_metal_context_translate_spirv(
                                context,
                                translationWords.data(),
                                translationWords.size(),
                                &translationOptions,
                                &result.report,
                                &translation);
                            if (result.status != SOL_METAL_STATUS_OK ||
                                translation == nullptr) {
                                sol_metal_shader_translation_destroy(translation);
                                return;
                            }

                            uint64_t requiredSize = 0;
                            result.status = sol_metal_shader_translation_copy_msl(
                                translation,
                                nullptr,
                                0,
                                &requiredSize);
                            if (result.status != SOL_METAL_STATUS_OUTPUT_TOO_SMALL ||
                                requiredSize == 0) {
                                sol_metal_shader_translation_destroy(translation);
                                return;
                            }
                            std::vector<char> source(requiredSize);
                            result.status = sol_metal_shader_translation_copy_msl(
                                translation,
                                source.data(),
                                source.size(),
                                &requiredSize);
                            if (result.status == SOL_METAL_STATUS_OK &&
                                iteration + 1 == TranslationIterations) {
                                result.status =
                                    sol_metal_context_compute_pipeline_create(
                                        context,
                                        translation,
                                        &computePipeline);
                            }
                            sol_metal_shader_translation_destroy(translation);
                            if (result.status != SOL_METAL_STATUS_OK ||
                                result.report.metal_function_created != 1) {
                                sol_metal_compute_pipeline_destroy(computePipeline);
                                return;
                            }
                        }

                        std::vector<uint32_t> bufferInput(1'024);
                        std::vector<uint32_t> bufferOutput(1'024);
                        std::vector<uint32_t> bufferExpected(1'024);
                        for (size_t value = 0; value < bufferInput.size(); ++value) {
                            bufferInput[value] = static_cast<uint32_t>(
                                value * 31u + index * 17u);
                            bufferExpected[value] = bufferInput[value] + 7u;
                        }
                        SolMetalBufferDescriptor bufferDescriptor = {};
                        bufferDescriptor.struct_size = sizeof(bufferDescriptor);
                        bufferDescriptor.abi_version = SOL_METAL_ABI_VERSION;
                        bufferDescriptor.size =
                            bufferInput.size() * sizeof(uint32_t);
                        bufferDescriptor.storage_mode =
                            SOL_METAL_BUFFER_STORAGE_PRIVATE;
                        SolMetalBufferRef buffer = nullptr;
                        result.status = sol_metal_context_buffer_create(
                            context,
                            &bufferDescriptor,
                            &buffer);
                        if (result.status == SOL_METAL_STATUS_OK) {
                            result.status = sol_metal_context_buffer_upload(
                                context,
                                buffer,
                                0,
                                bufferInput.data(),
                                bufferDescriptor.size);
                        }
                        if (result.status == SOL_METAL_STATUS_OK) {
                            SolMetalBufferBinding bufferBinding = {};
                            bufferBinding.index = 0;
                            bufferBinding.buffer = buffer;
                            SolMetalComputeDispatchDescriptor dispatch = {};
                            dispatch.struct_size = sizeof(dispatch);
                            dispatch.abi_version = SOL_METAL_ABI_VERSION;
                            dispatch.thread_count_x = bufferInput.size();
                            dispatch.thread_count_y = 1;
                            dispatch.thread_count_z = 1;
                            dispatch.threadgroup_size_x = 64;
                            dispatch.threadgroup_size_y = 1;
                            dispatch.threadgroup_size_z = 1;
                            dispatch.buffer_binding_count = 1;
                            dispatch.buffer_bindings = &bufferBinding;
                            result.status = sol_metal_context_compute_dispatch(
                                context,
                                computePipeline,
                                &dispatch);
                        }
                        if (result.status == SOL_METAL_STATUS_OK) {
                            result.status = sol_metal_context_buffer_download(
                                context,
                                buffer,
                                0,
                                bufferOutput.data(),
                                bufferDescriptor.size);
                        }
                        sol_metal_buffer_destroy(buffer);
                        sol_metal_compute_pipeline_destroy(computePipeline);
                        if (result.status != SOL_METAL_STATUS_OK ||
                            bufferExpected != bufferOutput) {
                            return;
                        }

                        std::vector<uint8_t> textureInput(8 * 8 * 4);
                        std::vector<uint8_t> textureOutput(8 * 8 * 4);
                        for (size_t byte = 0; byte < textureInput.size(); ++byte) {
                            textureInput[byte] = static_cast<uint8_t>(
                                (byte * 13u + index * 29u) & 0xffu);
                        }
                        SolMetalTextureDescriptor textureDescriptor = {};
                        textureDescriptor.struct_size = sizeof(textureDescriptor);
                        textureDescriptor.abi_version = SOL_METAL_ABI_VERSION;
                        textureDescriptor.width = 8;
                        textureDescriptor.height = 8;
                        textureDescriptor.pixel_format =
                            SOL_METAL_TEXTURE_FORMAT_RGBA8_UNORM;
                        textureDescriptor.storage_mode =
                            SOL_METAL_BUFFER_STORAGE_PRIVATE;
                        textureDescriptor.usage =
                            SOL_METAL_TEXTURE_USAGE_SAMPLED;
                        SolMetalTextureRef texture = nullptr;
                        result.status = sol_metal_context_texture_create_2d(
                            context,
                            &textureDescriptor,
                            &texture);
                        if (result.status == SOL_METAL_STATUS_OK) {
                            result.status = sol_metal_context_texture_upload_2d(
                                context,
                                texture,
                                textureInput.data(),
                                8 * 4,
                                textureInput.size());
                        }
                        if (result.status == SOL_METAL_STATUS_OK) {
                            result.status = sol_metal_context_texture_download_2d(
                                context,
                                texture,
                                textureOutput.data(),
                                8 * 4,
                                textureOutput.size());
                        }
                        sol_metal_texture_destroy(texture);
                        result.resourcesPassed =
                            result.status == SOL_METAL_STATUS_OK &&
                            textureInput == textureOutput;
                    }
                });
        }
    } catch (const std::exception &exception) {
        for (std::thread &thread : translationThreads) {
            if (thread.joinable()) {
                thread.join();
            }
        }
        sol_metal_context_destroy(context);
        *errorMessage = [NSString stringWithFormat:
            @"Could not create concurrent translation threads: %s",
            exception.what()];
        return false;
    }
    for (std::thread &thread : translationThreads) {
        thread.join();
    }
    for (uint32_t index = 0; index < threadCount; ++index) {
        const TranslationThreadResult &result = translationResults[index];
        if (result.status != SOL_METAL_STATUS_OK ||
            result.report.metal_function_created != 1 ||
            result.report.storage_buffer_count != 1 ||
            !result.resourcesPassed) {
            *errorMessage = [NSString stringWithFormat:
                @"Concurrent translation worker %u failed: %s (%s)",
                index,
                sol_metal_status_string(result.status),
                result.report.last_error];
            sol_metal_context_destroy(context);
            return false;
        }
    }

    struct ThreadResult {
        SolMetalStatus status = SOL_METAL_STATUS_INTERNAL_ERROR;
        SolMetalValidationReport report = {};
    };
    std::vector<ThreadResult> results(threadCount);
    std::vector<std::thread> threads;
    threads.reserve(threadCount);

    try {
        for (uint32_t index = 0; index < threadCount; ++index) {
            threads.emplace_back([context, index, &results]() {
                @autoreleasepool {
                    ThreadResult &result = results[index];
                    result.report.struct_size = sizeof(result.report);
                    result.status = sol_metal_context_run_validation(
                        context,
                        SOL_METAL_VALIDATION_ALL,
                        1,
                        &result.report);
                }
            });
        }
    } catch (const std::exception &exception) {
        for (std::thread &thread : threads) {
            if (thread.joinable()) {
                thread.join();
            }
        }
        sol_metal_context_destroy(context);
        *errorMessage = [NSString stringWithFormat:
            @"Could not create shared-context validation threads: %s",
            exception.what()];
        return false;
    }

    for (std::thread &thread : threads) {
        thread.join();
    }

    uint64_t expectedSignature = 0;
    bool passed = true;
    for (uint32_t index = 0; index < threadCount; ++index) {
        const ThreadResult &result = results[index];
        if (result.status != SOL_METAL_STATUS_OK ||
            result.report.tests_run != result.report.tests_passed ||
            result.report.completed_flags != SOL_METAL_VALIDATION_ALL) {
            *errorMessage = [NSString stringWithFormat:
                @"Shared-context worker %u failed: %s",
                index,
                sol_metal_status_string(result.status)];
            passed = false;
            break;
        }
        if (expectedSignature == 0) {
            expectedSignature = result.report.output_signature;
        } else if (result.report.output_signature != expectedSignature) {
            *errorMessage = [NSString stringWithFormat:
                @"Shared-context worker %u produced a different GPU signature",
                index];
            passed = false;
            break;
        }
    }

    sol_metal_context_destroy(context);
    return passed;
}

}  // namespace

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        Options options;
        if (!ParseOptions(argc, argv, &options)) {
            PrintUsage(argv[0]);
            return 2;
        }

        if (sol_metal_abi_version() != SOL_METAL_ABI_VERSION ||
            !ValidateFaultGuards() || !ValidateContextIsolation()) {
            std::fprintf(stderr, "SolMetal ABI fault guards failed.\n");
            return 3;
        }

        SolMetalCapabilities capabilities = {};
        capabilities.struct_size = sizeof(capabilities);
        SolMetalStatus status = sol_metal_query_capabilities(&capabilities);
        if (status != SOL_METAL_STATUS_OK ||
            capabilities.abi_version != SOL_METAL_ABI_VERSION) {
            std::fprintf(
                stderr,
                "SolMetal capability query failed: %s\n",
                sol_metal_status_string(status));
            return 4;
        }

        NSString *threadFailure = nil;
        if (!ValidateSharedContextThreads(
                options.sharedContextThreads,
                &threadFailure)) {
            std::fprintf(
                stderr,
                "SolMetal shared-context stress failed: %s\n",
                threadFailure.UTF8String ?: "unknown failure");
            return 5;
        }

        // Warm all compiler/driver caches before measuring repeated context
        // lifetime. Otherwise one-time Metal shader compilation is mistaken
        // for a per-context leak.
        Options warmup = options;
        warmup.contexts = 1;
        warmup.iterations = 1;
        uint64_t warmupSignature = 0;
        uint64_t warmupTests = 0;
        uint64_t warmupPassed = 0;
        uint64_t warmupBuffers = 0;
        uint64_t warmupBytes = 0;
        uint64_t warmupGPU = 0;
        NSString *warmupError = nil;
        if (!RunOneContext(
                warmup,
                options.present,
                &warmupSignature,
                &warmupTests,
                &warmupPassed,
                &warmupBuffers,
                &warmupBytes,
                &warmupGPU,
                &warmupError)) {
            std::fprintf(
                stderr,
                "SolMetal warmup failed: %s\n",
                warmupError.UTF8String ?: "unknown failure");
            return 5;
        }

        const uint64_t footprintBefore = PhysicalFootprint();
        uint64_t expectedSignature = 0;
        uint64_t testsRun = 0;
        uint64_t testsPassed = 0;
        uint64_t commandBuffers = 0;
        uint64_t bytesVerified = 0;
        uint64_t gpuNanoseconds = 0;
        NSString *failure = nil;

        for (uint32_t contextIndex = 0;
             contextIndex < options.contexts;
             ++contextIndex) {
            @autoreleasepool {
                if (!RunOneContext(
                        options,
                        options.present && contextIndex == 0,
                        &expectedSignature,
                        &testsRun,
                        &testsPassed,
                        &commandBuffers,
                        &bytesVerified,
                        &gpuNanoseconds,
                        &failure)) {
                    break;
                }
            }
        }

        const uint64_t footprintAfter = PhysicalFootprint();
        const uint64_t footprintGrowth = footprintAfter > footprintBefore
            ? footprintAfter - footprintBefore
            : 0;
        if (failure == nil && footprintBefore != 0 &&
            footprintGrowth > options.maxGrowthBytes) {
            failure = [NSString stringWithFormat:
                @"Repeated contexts grew physical footprint by %.1f MiB (limit %.1f MiB)",
                double(footprintGrowth) / (1024.0 * 1024.0),
                double(options.maxGrowthBytes) / (1024.0 * 1024.0)];
        }

        NSDictionary *summary = @{
            @"abiVersion": @(SOL_METAL_ABI_VERSION),
            @"device": [NSString stringWithUTF8String:capabilities.device_name],
            @"appleGPUFamily": @(capabilities.apple_gpu_family),
            @"argumentBufferTier": @(capabilities.argument_buffer_tier),
            @"unifiedMemory": @(capabilities.has_unified_memory != 0),
            @"contexts": @(options.contexts),
            @"iterationsPerContext": @(options.iterations),
            @"testsRun": @(testsRun),
            @"testsPassed": @(testsPassed),
            @"commandBuffers": @(commandBuffers),
            @"bytesVerified": @(bytesVerified),
            @"gpuMilliseconds": @(double(gpuNanoseconds) / 1'000'000.0),
            @"outputSignature": [NSString stringWithFormat:@"%016llx", expectedSignature],
            @"footprintBeforeBytes": @(footprintBefore),
            @"footprintAfterBytes": @(footprintAfter),
            @"footprintGrowthBytes": @(footprintGrowth),
            @"presentationTested": @(options.present),
            @"directMutationBatchingRequired": @(
                options.requireDirectMutationBatching),
            @"sharedContextThreads": @(options.sharedContextThreads),
            @"passed": @(failure == nil),
            @"failure": failure ?: [NSNull null],
        };

        if (options.json) {
            NSError *jsonError = nil;
            NSData *data = [NSJSONSerialization
                dataWithJSONObject:summary
                options:NSJSONWritingSortedKeys
                error:&jsonError];
            if (data == nil) {
                std::fprintf(stderr, "%s\n", jsonError.localizedDescription.UTF8String);
                return 6;
            }
            std::fwrite(data.bytes, 1, data.length, stdout);
            std::fputc('\n', stdout);
        } else {
            std::printf(
                "SolMetal ABI v%u on %s (Apple GPU family %u)\n"
                "  contexts: %u x %u iterations\n"
                "  tests: %llu/%llu\n"
                "  command buffers: %llu\n"
                "  verified: %.2f MiB\n"
                "  GPU time: %.3f ms\n"
                "  signature: %016llx\n"
                "  footprint growth: %.2f MiB\n"
                "  shared-context threads: %u\n"
                "  CAMetalLayer presentation: %s\n",
                SOL_METAL_ABI_VERSION,
                capabilities.device_name,
                capabilities.apple_gpu_family,
                options.contexts,
                options.iterations,
                static_cast<unsigned long long>(testsPassed),
                static_cast<unsigned long long>(testsRun),
                static_cast<unsigned long long>(commandBuffers),
                double(bytesVerified) / (1024.0 * 1024.0),
                double(gpuNanoseconds) / 1'000'000.0,
                static_cast<unsigned long long>(expectedSignature),
                double(footprintGrowth) / (1024.0 * 1024.0),
                options.sharedContextThreads,
                options.present ? "passed" : "not requested");
            if (failure != nil) {
                std::fprintf(stderr, "SolMetal validation failed: %s\n", failure.UTF8String);
            }
        }

        return failure == nil ? 0 : 7;
    }
}
