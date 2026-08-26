#ifndef SOL_METAL_H
#define SOL_METAL_H

#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

#define SOL_METAL_ABI_VERSION 2u
#define SOL_METAL_DEVICE_NAME_CAPACITY 256u
#define SOL_METAL_ENTRY_POINT_CAPACITY 128u
#define SOL_METAL_ERROR_CAPACITY 512u
#define SOL_METAL_MAX_COLOR_ATTACHMENTS 8u

#if defined(__GNUC__)
#define SOL_METAL_EXPORT __attribute__((visibility("default")))
#else
#define SOL_METAL_EXPORT
#endif

typedef void *SolMetalContextRef;
typedef void *SolMetalShaderTranslationRef;
typedef void *SolMetalBufferRef;
typedef void *SolMetalTextureRef;
typedef void *SolMetalSamplerRef;
typedef void *SolMetalComputePipelineRef;
typedef void *SolMetalRenderPipelineRef;
typedef void *SolMetalVisibilityQueryRef;

typedef enum SolMetalStatus {
    SOL_METAL_STATUS_OK = 0,
    SOL_METAL_STATUS_INVALID_ARGUMENT = 1,
    SOL_METAL_STATUS_INCOMPATIBLE_ABI = 2,
    SOL_METAL_STATUS_NO_DEVICE = 3,
    SOL_METAL_STATUS_UNSUPPORTED = 4,
    SOL_METAL_STATUS_ALLOCATION_FAILED = 5,
    SOL_METAL_STATUS_SHADER_COMPILATION_FAILED = 6,
    SOL_METAL_STATUS_COMMAND_FAILED = 7,
    SOL_METAL_STATUS_DRAWABLE_UNAVAILABLE = 8,
    SOL_METAL_STATUS_VALIDATION_FAILED = 9,
    SOL_METAL_STATUS_INTERNAL_ERROR = 10,
    SOL_METAL_STATUS_INVALID_SPIRV = 11,
    SOL_METAL_STATUS_TRANSLATION_FAILED = 12,
    SOL_METAL_STATUS_OUTPUT_TOO_SMALL = 13,
    SOL_METAL_STATUS_TIMED_OUT = 14,
} SolMetalStatus;

typedef enum SolMetalShaderStage {
    SOL_METAL_SHADER_STAGE_VERTEX = 1,
    SOL_METAL_SHADER_STAGE_TESSELLATION_CONTROL = 2,
    SOL_METAL_SHADER_STAGE_TESSELLATION_EVALUATION = 3,
    SOL_METAL_SHADER_STAGE_GEOMETRY = 4,
    SOL_METAL_SHADER_STAGE_FRAGMENT = 5,
    SOL_METAL_SHADER_STAGE_COMPUTE = 6,
} SolMetalShaderStage;

typedef enum SolMetalBufferStorageMode {
    SOL_METAL_BUFFER_STORAGE_SHARED = 1,
    SOL_METAL_BUFFER_STORAGE_PRIVATE = 2,
} SolMetalBufferStorageMode;

typedef enum SolMetalTexturePixelFormat {
    SOL_METAL_TEXTURE_FORMAT_RGBA8_UNORM = 1,
    SOL_METAL_TEXTURE_FORMAT_BGRA8_UNORM = 2,
    SOL_METAL_TEXTURE_FORMAT_R32_UINT = 3,
    SOL_METAL_TEXTURE_FORMAT_RGBA16_FLOAT = 4,
    SOL_METAL_TEXTURE_FORMAT_DEPTH32_FLOAT = 5,
    SOL_METAL_TEXTURE_FORMAT_DEPTH32_FLOAT_STENCIL8 = 6,
    SOL_METAL_TEXTURE_FORMAT_R8_UNORM = 7,
    SOL_METAL_TEXTURE_FORMAT_RG8_UNORM = 8,
    SOL_METAL_TEXTURE_FORMAT_R16_UNORM = 9,
    SOL_METAL_TEXTURE_FORMAT_RG16_UNORM = 10,
    SOL_METAL_TEXTURE_FORMAT_R16_FLOAT = 11,
    SOL_METAL_TEXTURE_FORMAT_RG16_FLOAT = 12,
    SOL_METAL_TEXTURE_FORMAT_R32_FLOAT = 13,
    SOL_METAL_TEXTURE_FORMAT_RG32_FLOAT = 14,
    SOL_METAL_TEXTURE_FORMAT_RGBA32_FLOAT = 15,
    SOL_METAL_TEXTURE_FORMAT_RGBA8_SRGB = 16,
    SOL_METAL_TEXTURE_FORMAT_BGRA8_SRGB = 17,
    SOL_METAL_TEXTURE_FORMAT_R32_SINT = 18,
    SOL_METAL_TEXTURE_FORMAT_RG16_SNORM = 19,
    SOL_METAL_TEXTURE_FORMAT_R8_UINT = 20,
    SOL_METAL_TEXTURE_FORMAT_RG11B10_FLOAT = 21,
    SOL_METAL_TEXTURE_FORMAT_D24_UNORM_STENCIL8 = 22,
    SOL_METAL_TEXTURE_FORMAT_BC1_RGBA_UNORM = 23,
    SOL_METAL_TEXTURE_FORMAT_BC1_RGBA_SRGB = 24,
    SOL_METAL_TEXTURE_FORMAT_BC2_RGBA_UNORM = 25,
    SOL_METAL_TEXTURE_FORMAT_BC2_RGBA_SRGB = 26,
    SOL_METAL_TEXTURE_FORMAT_BC3_RGBA_UNORM = 27,
    SOL_METAL_TEXTURE_FORMAT_BC3_RGBA_SRGB = 28,
    SOL_METAL_TEXTURE_FORMAT_BC4_R_UNORM = 29,
    SOL_METAL_TEXTURE_FORMAT_BC4_R_SNORM = 30,
    SOL_METAL_TEXTURE_FORMAT_BC5_RG_UNORM = 31,
    SOL_METAL_TEXTURE_FORMAT_BC5_RG_SNORM = 32,
    SOL_METAL_TEXTURE_FORMAT_BC6H_RGB_FLOAT = 33,
    SOL_METAL_TEXTURE_FORMAT_BC6H_RGB_UFLOAT = 34,
    SOL_METAL_TEXTURE_FORMAT_BC7_RGBA_UNORM = 35,
    SOL_METAL_TEXTURE_FORMAT_BC7_RGBA_SRGB = 36,
    SOL_METAL_TEXTURE_FORMAT_RGB10A2_UNORM = 37,
    SOL_METAL_TEXTURE_FORMAT_RGB10A2_UINT = 38,
    SOL_METAL_TEXTURE_FORMAT_RGB9E5_FLOAT = 39,
    SOL_METAL_TEXTURE_FORMAT_BGR10A2_UNORM = 40,
    SOL_METAL_TEXTURE_FORMAT_RGBA32_UINT = 41,
    SOL_METAL_TEXTURE_FORMAT_DEPTH16_UNORM = 42,
    SOL_METAL_TEXTURE_FORMAT_RGBA16_UINT = 43,
    SOL_METAL_TEXTURE_FORMAT_RGBA16_UNORM = 44,
} SolMetalTexturePixelFormat;

typedef enum SolMetalTextureType {
    SOL_METAL_TEXTURE_TYPE_2D = 1,
    SOL_METAL_TEXTURE_TYPE_2D_ARRAY = 2,
    SOL_METAL_TEXTURE_TYPE_3D = 3,
    SOL_METAL_TEXTURE_TYPE_CUBE = 4,
    SOL_METAL_TEXTURE_TYPE_CUBE_ARRAY = 5,
    SOL_METAL_TEXTURE_TYPE_BUFFER = 6,
} SolMetalTextureType;

typedef enum SolMetalTextureUsageFlags {
    SOL_METAL_TEXTURE_USAGE_SAMPLED = 1u << 0,
    SOL_METAL_TEXTURE_USAGE_STORAGE = 1u << 1,
    SOL_METAL_TEXTURE_USAGE_RENDER_TARGET = 1u << 2,
    SOL_METAL_TEXTURE_USAGE_ALL =
        SOL_METAL_TEXTURE_USAGE_SAMPLED |
        SOL_METAL_TEXTURE_USAGE_STORAGE |
        SOL_METAL_TEXTURE_USAGE_RENDER_TARGET,
} SolMetalTextureUsageFlags;

typedef enum SolMetalSamplerFilter {
    SOL_METAL_SAMPLER_FILTER_NEAREST = 1,
    SOL_METAL_SAMPLER_FILTER_LINEAR = 2,
} SolMetalSamplerFilter;

// Presentation orientation flags stored in the presentation descriptor. A
// zero value preserves the original
// full-source, full-drawable presentation contract.
typedef enum SolMetalPresentFlags {
    SOL_METAL_PRESENT_FLIP_X = 1u << 0,
    SOL_METAL_PRESENT_FLIP_Y = 1u << 1,
} SolMetalPresentFlags;

typedef enum SolMetalSamplerMipFilter {
    SOL_METAL_SAMPLER_MIP_FILTER_NOT_MIPMAPPED = 1,
    SOL_METAL_SAMPLER_MIP_FILTER_NEAREST = 2,
    SOL_METAL_SAMPLER_MIP_FILTER_LINEAR = 3,
} SolMetalSamplerMipFilter;

typedef enum SolMetalSamplerAddressMode {
    SOL_METAL_SAMPLER_ADDRESS_CLAMP_TO_EDGE = 1,
    SOL_METAL_SAMPLER_ADDRESS_REPEAT = 2,
    SOL_METAL_SAMPLER_ADDRESS_MIRROR_REPEAT = 3,
    SOL_METAL_SAMPLER_ADDRESS_CLAMP_TO_ZERO = 4,
    SOL_METAL_SAMPLER_ADDRESS_CLAMP_TO_BORDER = 5,
} SolMetalSamplerAddressMode;

typedef enum SolMetalSamplerBorderColor {
    SOL_METAL_SAMPLER_BORDER_TRANSPARENT_BLACK = 0,
    SOL_METAL_SAMPLER_BORDER_OPAQUE_BLACK = 1,
    SOL_METAL_SAMPLER_BORDER_OPAQUE_WHITE = 2,
} SolMetalSamplerBorderColor;

typedef enum SolMetalColorWriteMaskFlags {
    SOL_METAL_COLOR_WRITE_RED = 1u << 0,
    SOL_METAL_COLOR_WRITE_GREEN = 1u << 1,
    SOL_METAL_COLOR_WRITE_BLUE = 1u << 2,
    SOL_METAL_COLOR_WRITE_ALPHA = 1u << 3,
    SOL_METAL_COLOR_WRITE_ALL =
        SOL_METAL_COLOR_WRITE_RED |
        SOL_METAL_COLOR_WRITE_GREEN |
        SOL_METAL_COLOR_WRITE_BLUE |
        SOL_METAL_COLOR_WRITE_ALPHA,
} SolMetalColorWriteMaskFlags;

// Optional behavior carried in the clear descriptors. A zero flags value
// retains the original full-surface,
// floating-point clear contract for existing callers.
typedef enum SolMetalTextureClearFlags {
    SOL_METAL_TEXTURE_CLEAR_REGION = 1u << 0,
    SOL_METAL_TEXTURE_CLEAR_RAW_COLOR_BITS = 1u << 1,
} SolMetalTextureClearFlags;

typedef enum SolMetalPrimitiveType {
    SOL_METAL_PRIMITIVE_POINT = 1,
    SOL_METAL_PRIMITIVE_LINE = 2,
    SOL_METAL_PRIMITIVE_LINE_STRIP = 3,
    SOL_METAL_PRIMITIVE_TRIANGLE = 4,
    SOL_METAL_PRIMITIVE_TRIANGLE_STRIP = 5,
} SolMetalPrimitiveType;

// Metal render pipelines specialize the broad primitive topology class even
// though the exact point/line/strip/triangle type remains draw-time state.
typedef enum SolMetalPrimitiveTopologyClass {
    SOL_METAL_PRIMITIVE_TOPOLOGY_UNSPECIFIED = 0,
    SOL_METAL_PRIMITIVE_TOPOLOGY_POINT = 1,
    SOL_METAL_PRIMITIVE_TOPOLOGY_LINE = 2,
    SOL_METAL_PRIMITIVE_TOPOLOGY_TRIANGLE = 3,
} SolMetalPrimitiveTopologyClass;

typedef enum SolMetalFrontFaceWinding {
    SOL_METAL_WINDING_CLOCKWISE = 1,
    SOL_METAL_WINDING_COUNTER_CLOCKWISE = 2,
} SolMetalFrontFaceWinding;

typedef enum SolMetalCullMode {
    SOL_METAL_CULL_NONE = 1,
    SOL_METAL_CULL_FRONT = 2,
    SOL_METAL_CULL_BACK = 3,
    SOL_METAL_CULL_FRONT_AND_BACK = 4,
} SolMetalCullMode;

typedef enum SolMetalTriangleFillMode {
    SOL_METAL_TRIANGLE_FILL = 1,
    SOL_METAL_TRIANGLE_LINES = 2,
} SolMetalTriangleFillMode;

typedef enum SolMetalDepthClipMode {
    SOL_METAL_DEPTH_CLIP = 1,
    SOL_METAL_DEPTH_CLAMP = 2,
} SolMetalDepthClipMode;

typedef enum SolMetalRenderLoadAction {
    SOL_METAL_RENDER_LOAD_DONT_CARE = 1,
    SOL_METAL_RENDER_LOAD = 2,
    SOL_METAL_RENDER_LOAD_CLEAR = 3,
} SolMetalRenderLoadAction;

typedef enum SolMetalRenderStoreAction {
    SOL_METAL_RENDER_STORE_DONT_CARE = 1,
    SOL_METAL_RENDER_STORE = 2,
} SolMetalRenderStoreAction;

typedef enum SolMetalVertexFormat {
    SOL_METAL_VERTEX_FORMAT_FLOAT = 1,
    SOL_METAL_VERTEX_FORMAT_FLOAT2 = 2,
    SOL_METAL_VERTEX_FORMAT_FLOAT3 = 3,
    SOL_METAL_VERTEX_FORMAT_FLOAT4 = 4,
    SOL_METAL_VERTEX_FORMAT_HALF2 = 5,
    SOL_METAL_VERTEX_FORMAT_HALF4 = 6,
    SOL_METAL_VERTEX_FORMAT_UCHAR4_NORMALIZED = 7,
    SOL_METAL_VERTEX_FORMAT_CHAR4_NORMALIZED = 8,
    SOL_METAL_VERTEX_FORMAT_USHORT2_NORMALIZED = 9,
    SOL_METAL_VERTEX_FORMAT_USHORT4_NORMALIZED = 10,
    SOL_METAL_VERTEX_FORMAT_UINT = 11,
    SOL_METAL_VERTEX_FORMAT_UINT2 = 12,
    SOL_METAL_VERTEX_FORMAT_UINT4 = 13,
    SOL_METAL_VERTEX_FORMAT_INT1010102_NORMALIZED = 14,
    SOL_METAL_VERTEX_FORMAT_UINT1010102_NORMALIZED = 15,
    SOL_METAL_VERTEX_FORMAT_UCHAR2_NORMALIZED = 16,
    SOL_METAL_VERTEX_FORMAT_CHAR2_NORMALIZED = 17,
    SOL_METAL_VERTEX_FORMAT_UCHAR3_NORMALIZED = 18,
    SOL_METAL_VERTEX_FORMAT_CHAR3_NORMALIZED = 19,
    SOL_METAL_VERTEX_FORMAT_UCHAR2 = 20,
    SOL_METAL_VERTEX_FORMAT_UCHAR3 = 21,
    SOL_METAL_VERTEX_FORMAT_UCHAR4 = 22,
    SOL_METAL_VERTEX_FORMAT_CHAR2 = 23,
    SOL_METAL_VERTEX_FORMAT_CHAR3 = 24,
    SOL_METAL_VERTEX_FORMAT_CHAR4 = 25,
    SOL_METAL_VERTEX_FORMAT_USHORT2 = 26,
    SOL_METAL_VERTEX_FORMAT_USHORT3 = 27,
    SOL_METAL_VERTEX_FORMAT_USHORT4 = 28,
    SOL_METAL_VERTEX_FORMAT_SHORT2 = 29,
    SOL_METAL_VERTEX_FORMAT_SHORT3 = 30,
    SOL_METAL_VERTEX_FORMAT_SHORT4 = 31,
    SOL_METAL_VERTEX_FORMAT_SHORT2_NORMALIZED = 32,
    SOL_METAL_VERTEX_FORMAT_SHORT3_NORMALIZED = 33,
    SOL_METAL_VERTEX_FORMAT_SHORT4_NORMALIZED = 34,
    SOL_METAL_VERTEX_FORMAT_HALF3 = 35,
    SOL_METAL_VERTEX_FORMAT_INT = 36,
    SOL_METAL_VERTEX_FORMAT_INT2 = 37,
    SOL_METAL_VERTEX_FORMAT_INT3 = 38,
    SOL_METAL_VERTEX_FORMAT_INT4 = 39,
    SOL_METAL_VERTEX_FORMAT_UINT3 = 40,
    SOL_METAL_VERTEX_FORMAT_UCHAR = 41,
    SOL_METAL_VERTEX_FORMAT_CHAR = 42,
    SOL_METAL_VERTEX_FORMAT_UCHAR_NORMALIZED = 43,
    SOL_METAL_VERTEX_FORMAT_CHAR_NORMALIZED = 44,
    SOL_METAL_VERTEX_FORMAT_USHORT = 45,
    SOL_METAL_VERTEX_FORMAT_SHORT = 46,
    SOL_METAL_VERTEX_FORMAT_USHORT_NORMALIZED = 47,
    SOL_METAL_VERTEX_FORMAT_SHORT_NORMALIZED = 48,
    SOL_METAL_VERTEX_FORMAT_HALF = 49,
    SOL_METAL_VERTEX_FORMAT_FLOAT_RG11B10 = 50,
    SOL_METAL_VERTEX_FORMAT_FLOAT_RGB9E5 = 51,
    SOL_METAL_VERTEX_FORMAT_USHORT3_NORMALIZED = 52,
} SolMetalVertexFormat;

typedef enum SolMetalVertexStepFunction {
    SOL_METAL_VERTEX_STEP_PER_VERTEX = 1,
    SOL_METAL_VERTEX_STEP_PER_INSTANCE = 2,
    SOL_METAL_VERTEX_STEP_CONSTANT = 3,
} SolMetalVertexStepFunction;

typedef enum SolMetalIndexType {
    SOL_METAL_INDEX_UINT16 = 1,
    SOL_METAL_INDEX_UINT32 = 2,
    // Metal has no native 8-bit index type. SolMetal expands these indices to
    // UInt16 on the GPU before encoding the draw.
    SOL_METAL_INDEX_UINT8 = 3,
} SolMetalIndexType;

typedef enum SolMetalCompareFunction {
    SOL_METAL_COMPARE_NEVER = 1,
    SOL_METAL_COMPARE_LESS = 2,
    SOL_METAL_COMPARE_EQUAL = 3,
    SOL_METAL_COMPARE_LESS_EQUAL = 4,
    SOL_METAL_COMPARE_GREATER = 5,
    SOL_METAL_COMPARE_NOT_EQUAL = 6,
    SOL_METAL_COMPARE_GREATER_EQUAL = 7,
    SOL_METAL_COMPARE_ALWAYS = 8,
} SolMetalCompareFunction;

typedef enum SolMetalStencilOperation {
    SOL_METAL_STENCIL_KEEP = 1,
    SOL_METAL_STENCIL_ZERO = 2,
    SOL_METAL_STENCIL_REPLACE = 3,
    SOL_METAL_STENCIL_INCREMENT_CLAMP = 4,
    SOL_METAL_STENCIL_DECREMENT_CLAMP = 5,
    SOL_METAL_STENCIL_INVERT = 6,
    SOL_METAL_STENCIL_INCREMENT_WRAP = 7,
    SOL_METAL_STENCIL_DECREMENT_WRAP = 8,
} SolMetalStencilOperation;

typedef enum SolMetalBlendOperation {
    SOL_METAL_BLEND_ADD = 1,
    SOL_METAL_BLEND_SUBTRACT = 2,
    SOL_METAL_BLEND_REVERSE_SUBTRACT = 3,
    SOL_METAL_BLEND_MIN = 4,
    SOL_METAL_BLEND_MAX = 5,
} SolMetalBlendOperation;

typedef enum SolMetalBlendFactor {
    SOL_METAL_BLEND_ZERO = 1,
    SOL_METAL_BLEND_ONE = 2,
    SOL_METAL_BLEND_SOURCE_COLOR = 3,
    SOL_METAL_BLEND_ONE_MINUS_SOURCE_COLOR = 4,
    SOL_METAL_BLEND_SOURCE_ALPHA = 5,
    SOL_METAL_BLEND_ONE_MINUS_SOURCE_ALPHA = 6,
    SOL_METAL_BLEND_DESTINATION_COLOR = 7,
    SOL_METAL_BLEND_ONE_MINUS_DESTINATION_COLOR = 8,
    SOL_METAL_BLEND_DESTINATION_ALPHA = 9,
    SOL_METAL_BLEND_ONE_MINUS_DESTINATION_ALPHA = 10,
    SOL_METAL_BLEND_SOURCE_ALPHA_SATURATED = 11,
    SOL_METAL_BLEND_SOURCE1_COLOR = 12,
    SOL_METAL_BLEND_ONE_MINUS_SOURCE1_COLOR = 13,
    SOL_METAL_BLEND_SOURCE1_ALPHA = 14,
    SOL_METAL_BLEND_ONE_MINUS_SOURCE1_ALPHA = 15,
    SOL_METAL_BLEND_BLEND_COLOR = 16,
    SOL_METAL_BLEND_ONE_MINUS_BLEND_COLOR = 17,
    SOL_METAL_BLEND_BLEND_ALPHA = 18,
    SOL_METAL_BLEND_ONE_MINUS_BLEND_ALPHA = 19,
} SolMetalBlendFactor;

typedef enum SolMetalValidationFlags {
    SOL_METAL_VALIDATION_DEVICE = 1u << 0,
    SOL_METAL_VALIDATION_BUFFER_COPY = 1u << 1,
    SOL_METAL_VALIDATION_TEXTURE_COPY = 1u << 2,
    SOL_METAL_VALIDATION_COMPUTE = 1u << 3,
    SOL_METAL_VALIDATION_RENDER = 1u << 4,
    SOL_METAL_VALIDATION_FAULT_RECOVERY = 1u << 5,
    SOL_METAL_VALIDATION_SHADER_CACHE = 1u << 6,
    SOL_METAL_VALIDATION_SPIRV_TRANSLATION = 1u << 7,
    SOL_METAL_VALIDATION_BUFFER_API = 1u << 8,
    SOL_METAL_VALIDATION_TEXTURE_API = 1u << 9,
    SOL_METAL_VALIDATION_COMPUTE_PIPELINE_API = 1u << 10,
    SOL_METAL_VALIDATION_RENDER_PIPELINE_API = 1u << 11,
    SOL_METAL_VALIDATION_RENDER_BINDING_API = 1u << 12,
    SOL_METAL_VALIDATION_RENDER_STATE_API = 1u << 13,
    SOL_METAL_VALIDATION_TIMELINE_API = 1u << 14,
    SOL_METAL_VALIDATION_ALL =
        SOL_METAL_VALIDATION_DEVICE |
        SOL_METAL_VALIDATION_BUFFER_COPY |
        SOL_METAL_VALIDATION_TEXTURE_COPY |
        SOL_METAL_VALIDATION_COMPUTE |
        SOL_METAL_VALIDATION_RENDER |
        SOL_METAL_VALIDATION_FAULT_RECOVERY |
        SOL_METAL_VALIDATION_SHADER_CACHE |
        SOL_METAL_VALIDATION_SPIRV_TRANSLATION |
        SOL_METAL_VALIDATION_BUFFER_API |
        SOL_METAL_VALIDATION_TEXTURE_API |
        SOL_METAL_VALIDATION_COMPUTE_PIPELINE_API |
        SOL_METAL_VALIDATION_RENDER_PIPELINE_API |
        SOL_METAL_VALIDATION_RENDER_BINDING_API |
        SOL_METAL_VALIDATION_RENDER_STATE_API |
        SOL_METAL_VALIDATION_TIMELINE_API,
} SolMetalValidationFlags;

typedef struct SolMetalBufferDescriptor {
    uint32_t struct_size;
    uint32_t abi_version;
    uint64_t size;
    SolMetalBufferStorageMode storage_mode;
    uint32_t reserved[11];
} SolMetalBufferDescriptor;

typedef enum SolMetalTextureSwizzle {
    SOL_METAL_TEXTURE_SWIZZLE_ZERO = 0,
    SOL_METAL_TEXTURE_SWIZZLE_ONE = 1,
    SOL_METAL_TEXTURE_SWIZZLE_RED = 2,
    SOL_METAL_TEXTURE_SWIZZLE_GREEN = 3,
    SOL_METAL_TEXTURE_SWIZZLE_BLUE = 4,
    SOL_METAL_TEXTURE_SWIZZLE_ALPHA = 5,
} SolMetalTextureSwizzle;

typedef struct SolMetalTextureDescriptor {
    uint32_t struct_size;
    uint32_t abi_version;
    uint32_t width;
    uint32_t height;
    SolMetalTexturePixelFormat pixel_format;
    SolMetalBufferStorageMode storage_mode;
    uint32_t usage;
    SolMetalTextureType texture_type;
    uint32_t depth_or_array_length;
    uint32_t mipmap_level_count;
    uint32_t sample_count;
    SolMetalTextureSwizzle swizzle_r;
    SolMetalTextureSwizzle swizzle_g;
    SolMetalTextureSwizzle swizzle_b;
    SolMetalTextureSwizzle swizzle_a;
    uint32_t reserved[1];
} SolMetalTextureDescriptor;

typedef struct SolMetalTextureViewDescriptor {
    uint32_t struct_size;
    uint32_t abi_version;
    SolMetalTexturePixelFormat pixel_format;
    SolMetalTextureSwizzle swizzle_r;
    SolMetalTextureSwizzle swizzle_g;
    SolMetalTextureSwizzle swizzle_b;
    SolMetalTextureSwizzle swizzle_a;
    uint32_t first_level;
    uint32_t level_count;
    uint32_t first_slice;
    uint32_t slice_count;
    SolMetalTextureType texture_type;
    uint32_t reserved[7];
} SolMetalTextureViewDescriptor;

// Describes a 2D texture copy with explicit source and destination regions.
// Coordinates use half-open bounds. The initial native path supports nearest
// D24S8 scaling, including SolMetal's D24-to-D32Float/S8 host conversion.
typedef struct SolMetalTextureBlitDescriptor {
    uint32_t struct_size;
    uint32_t abi_version;
    int32_t source_x1;
    int32_t source_y1;
    int32_t source_x2;
    int32_t source_y2;
    int32_t destination_x1;
    int32_t destination_y1;
    int32_t destination_x2;
    int32_t destination_y2;
    uint32_t linear_filter;
    uint32_t source_slice;
    uint32_t source_level;
    uint32_t destination_slice;
    uint32_t destination_level;
    uint32_t reserved[3];
} SolMetalTextureBlitDescriptor;

// Describes an unscaled copy between one source and destination subresource.
// Levels and slices are relative to the supplied texture or texture view.
typedef struct SolMetalTextureCopyDescriptor {
    uint32_t struct_size;
    uint32_t abi_version;
    uint32_t source_slice;
    uint32_t destination_slice;
    uint32_t source_level;
    uint32_t destination_level;
    uint32_t width;
    uint32_t height;
    uint32_t reserved[8];
} SolMetalTextureCopyDescriptor;

// Clears one or more renderable color slices at mip zero. Layer indices are
// relative to the supplied texture or view. When REGION is set, the rectangle
// is expressed in target pixels and only that area is changed. RAW_COLOR_BITS
// makes the four bit-pattern fields authoritative; this preserves integer
// attachment clears and non-normal floating-point values exactly. These fields
// are part of ABI v2; zeroed descriptors request a full-surface clear using
// the double components.
typedef struct SolMetalTextureClearColorDescriptor {
    uint32_t struct_size;
    uint32_t abi_version;
    uint32_t first_slice;
    uint32_t slice_count;
    uint32_t component_mask;
    uint32_t flags;
    double clear_red;
    double clear_green;
    double clear_blue;
    double clear_alpha;
    uint32_t clear_x;
    uint32_t clear_y;
    uint32_t clear_width;
    uint32_t clear_height;
    uint32_t clear_red_bits;
    uint32_t clear_green_bits;
    uint32_t clear_blue_bits;
    uint32_t clear_alpha_bits;
} SolMetalTextureClearColorDescriptor;

// Clears one or more renderable depth/stencil slices at mip zero. A zero mask
// preserves that aspect. REGION enables a pixel rectangle. Partial stencil
// masks use the shader-based clear path while full-surface, full-mask clears
// retain Metal's fast render-pass load action.
typedef struct SolMetalTextureClearDepthStencilDescriptor {
    uint32_t struct_size;
    uint32_t abi_version;
    uint32_t first_slice;
    uint32_t slice_count;
    uint32_t depth_mask;
    uint32_t stencil_mask;
    double clear_depth;
    uint32_t clear_stencil;
    uint32_t flags;
    uint32_t clear_x;
    uint32_t clear_y;
    uint32_t clear_width;
    uint32_t clear_height;
    uint32_t reserved[4];
} SolMetalTextureClearDepthStencilDescriptor;

// Describes an asynchronous presentation from a SolMetal-owned texture into a
// caller-owned CAMetalLayer. The source rectangle uses top-left, right/bottom
// exclusive pixel coordinates. A zero left/right pair selects the full source
// width; a zero top/bottom pair independently selects the full source height.
// A zero aspect ratio pair stretches to the drawable; otherwise the image is
// aspect-fitted and uncovered pixels are cleared to opaque black. Set both
// pixel dimensions to zero when the layer is live-resizing and SolMetal should
// use the acquired drawable's current dimensions. If either is nonzero, both
// must exactly match the layer's configured drawable size.
typedef struct SolMetalPresentTextureDescriptor {
    uint32_t struct_size;
    uint32_t abi_version;
    SolMetalTextureRef source_texture;
    uint32_t pixel_width;
    uint32_t pixel_height;
    SolMetalSamplerFilter filter;
    int32_t source_left;
    int32_t source_top;
    int32_t source_right;
    int32_t source_bottom;
    float aspect_ratio_x;
    float aspect_ratio_y;
    uint32_t flags;
    uint32_t reserved[2];
} SolMetalPresentTextureDescriptor;

typedef struct SolMetalSamplerDescriptor {
    uint32_t struct_size;
    uint32_t abi_version;
    SolMetalSamplerFilter min_filter;
    SolMetalSamplerFilter mag_filter;
    SolMetalSamplerMipFilter mip_filter;
    SolMetalSamplerAddressMode address_u;
    SolMetalSamplerAddressMode address_v;
    SolMetalSamplerAddressMode address_w;
    uint32_t max_anisotropy;
    float lod_min_clamp;
    float lod_max_clamp;
    SolMetalSamplerBorderColor border_color;
    uint32_t compare_enabled;
    SolMetalCompareFunction compare_function;
    float lod_bias;
    uint32_t reserved0;
    uint32_t reserved[4];
} SolMetalSamplerDescriptor;

typedef struct SolMetalBufferBinding {
    uint32_t index;
    // Zero is a discrete Metal slot. Otherwise this is the argument-buffer
    // Metal buffer slot plus one and index is the member [[id]].
    uint32_t argument_buffer;
    SolMetalBufferRef buffer;
    uint64_t offset;
} SolMetalBufferBinding;

typedef struct SolMetalTextureBinding {
    uint32_t index;
    uint32_t argument_buffer;
    SolMetalTextureRef texture;
} SolMetalTextureBinding;

typedef struct SolMetalSamplerBinding {
    uint32_t index;
    uint32_t argument_buffer;
    SolMetalSamplerRef sampler;
} SolMetalSamplerBinding;

typedef struct SolMetalComputeDispatchDescriptor {
    uint32_t struct_size;
    uint32_t abi_version;
    uint32_t thread_count_x;
    uint32_t thread_count_y;
    uint32_t thread_count_z;
    uint32_t threadgroup_size_x;
    uint32_t threadgroup_size_y;
    uint32_t threadgroup_size_z;
    uint32_t buffer_binding_count;
    uint32_t texture_binding_count;
    uint32_t sampler_binding_count;
    uint32_t reserved0;
    const SolMetalBufferBinding *buffer_bindings;
    const SolMetalTextureBinding *texture_bindings;
    const SolMetalSamplerBinding *sampler_bindings;
    uint32_t reserved[8];
} SolMetalComputeDispatchDescriptor;

typedef struct SolMetalComputePipelineInfo {
    uint32_t struct_size;
    uint32_t abi_version;
    uint32_t thread_execution_width;
    uint32_t max_total_threads_per_threadgroup;
    uint64_t static_threadgroup_memory_length;
    uint32_t reserved[8];
} SolMetalComputePipelineInfo;

typedef struct SolMetalRenderPipelineDescriptor {
    uint32_t struct_size;
    uint32_t abi_version;
    SolMetalShaderTranslationRef vertex_translation;
    SolMetalShaderTranslationRef fragment_translation;
    SolMetalTexturePixelFormat color_format;
    uint32_t color_write_mask;
    uint32_t alpha_to_coverage_enabled;
    uint32_t alpha_to_coverage_dither_enabled;
    uint32_t alpha_to_one_enabled;
    SolMetalPrimitiveTopologyClass input_primitive_topology;
    uint32_t reserved[6];
} SolMetalRenderPipelineDescriptor;

typedef struct SolMetalRenderDrawDescriptor {
    uint32_t struct_size;
    uint32_t abi_version;
    SolMetalTextureRef color_target;
    SolMetalPrimitiveType primitive_type;
    SolMetalRenderLoadAction load_action;
    SolMetalRenderStoreAction store_action;
    uint32_t vertex_start;
    uint32_t vertex_count;
    uint32_t instance_count;
    uint32_t base_instance;
    double clear_red;
    double clear_green;
    double clear_blue;
    double clear_alpha;
    double viewport_x;
    double viewport_y;
    double viewport_width;
    double viewport_height;
    double viewport_near_z;
    double viewport_far_z;
    uint32_t scissor_x;
    uint32_t scissor_y;
    uint32_t scissor_width;
    uint32_t scissor_height;
    // Metal color attachment index used by both the pipeline and render pass.
    // Values 0...7 are valid. Keeping this explicit prevents a guest output at
    // location N from being silently redirected to attachment zero.
    uint32_t color_attachment_index;
    float blend_red;
    float blend_green;
    float blend_blue;
    float blend_alpha;
    uint32_t reserved[3];
} SolMetalRenderDrawDescriptor;

typedef struct SolMetalVertexBufferLayout {
    uint32_t buffer_index;
    uint32_t stride;
    SolMetalVertexStepFunction step_function;
    uint32_t step_rate;
    uint32_t reserved[4];
} SolMetalVertexBufferLayout;

typedef struct SolMetalVertexAttribute {
    uint32_t location;
    uint32_t buffer_index;
    SolMetalVertexFormat format;
    uint32_t offset;
    uint32_t reserved[4];
} SolMetalVertexAttribute;

typedef struct SolMetalRenderStageBindings {
    uint32_t struct_size;
    uint32_t abi_version;
    uint32_t buffer_binding_count;
    uint32_t texture_binding_count;
    uint32_t sampler_binding_count;
    uint32_t reserved0;
    const SolMetalBufferBinding *buffer_bindings;
    const SolMetalTextureBinding *texture_bindings;
    const SolMetalSamplerBinding *sampler_bindings;
    uint32_t reserved[8];
} SolMetalRenderStageBindings;

typedef struct SolMetalRenderIndexBinding {
    uint32_t struct_size;
    uint32_t abi_version;
    SolMetalBufferRef buffer;
    uint64_t offset;
    SolMetalIndexType index_type;
    int32_t base_vertex;
    uint32_t base_instance;
    uint32_t reserved[8];
} SolMetalRenderIndexBinding;

// Points at one Vulkan-compatible indirect command in a Metal buffer. The
// command is MTLDrawPrimitivesIndirectArguments when index_binding is null and
// MTLDrawIndexedPrimitivesIndirectArguments otherwise. Both layouts match the
// corresponding Vulkan command byte-for-byte, so GPU-written arguments do not
// need a CPU readback or conversion pass.
typedef struct SolMetalRenderIndirectBinding {
    uint32_t struct_size;
    uint32_t abi_version;
    SolMetalBufferRef buffer;
    uint64_t offset;
    uint64_t size;
    uint32_t reserved[6];
} SolMetalRenderIndirectBinding;

// Supplies the GPU-written draw count for a bounded indirect command stream.
// SolMetal clamps the count to max_draw_count and consumes commands separated
// by stride bytes. The count itself remains GPU-resident; the native backend
// never maps or reads it on the CPU.
typedef struct SolMetalRenderIndirectCountBinding {
    uint32_t struct_size;
    uint32_t abi_version;
    SolMetalBufferRef buffer;
    uint64_t offset;
    uint64_t size;
    uint32_t max_draw_count;
    uint32_t stride;
    uint32_t reserved[6];
} SolMetalRenderIndirectCountBinding;

typedef struct SolMetalBlendDescriptor {
    uint32_t enabled;
    SolMetalBlendOperation rgb_operation;
    SolMetalBlendOperation alpha_operation;
    SolMetalBlendFactor source_rgb_factor;
    SolMetalBlendFactor destination_rgb_factor;
    SolMetalBlendFactor source_alpha_factor;
    SolMetalBlendFactor destination_alpha_factor;
    uint32_t reserved[5];
} SolMetalBlendDescriptor;

typedef struct SolMetalStencilFaceDescriptor {
    SolMetalCompareFunction compare_function;
    SolMetalStencilOperation stencil_failure_operation;
    SolMetalStencilOperation depth_failure_operation;
    SolMetalStencilOperation depth_stencil_pass_operation;
    uint32_t read_mask;
    uint32_t write_mask;
    uint32_t reserved[4];
} SolMetalStencilFaceDescriptor;

typedef struct SolMetalDepthStencilDescriptor {
    SolMetalCompareFunction depth_compare_function;
    uint32_t depth_write_enabled;
    uint32_t stencil_enabled;
    uint32_t reserved0;
    SolMetalStencilFaceDescriptor front_face;
    SolMetalStencilFaceDescriptor back_face;
    uint32_t reserved[8];
} SolMetalDepthStencilDescriptor;

typedef struct SolMetalRenderPipelineAdvancedDescriptor {
    uint32_t struct_size;
    uint32_t abi_version;
    SolMetalShaderTranslationRef vertex_translation;
    SolMetalShaderTranslationRef fragment_translation;
    SolMetalTexturePixelFormat color_format;
    uint32_t color_write_mask;
    SolMetalTexturePixelFormat depth_stencil_format;
    // Metal supports eight color attachments. This controlled descriptor still
    // binds one color texture, but it may preserve any guest attachment slot.
    uint32_t color_attachment_index;
    SolMetalBlendDescriptor color_blend;
    SolMetalDepthStencilDescriptor depth_stencil;
    uint32_t alpha_to_coverage_enabled;
    uint32_t alpha_to_coverage_dither_enabled;
    uint32_t alpha_to_one_enabled;
    SolMetalPrimitiveTopologyClass input_primitive_topology;
    uint32_t reserved[4];
} SolMetalRenderPipelineAdvancedDescriptor;

typedef struct SolMetalRenderColorAttachmentDescriptor {
    uint32_t attachment_index;
    SolMetalTexturePixelFormat pixel_format;
    uint32_t color_write_mask;
    uint32_t reserved0;
    SolMetalBlendDescriptor blend;
    uint32_t reserved[4];
} SolMetalRenderColorAttachmentDescriptor;

// Describes every live guest color output without compacting attachment slots.
// The attachment array is borrowed for pipeline creation and copied internally.
typedef struct SolMetalRenderPipelineMrtDescriptor {
    uint32_t struct_size;
    uint32_t abi_version;
    SolMetalShaderTranslationRef vertex_translation;
    SolMetalShaderTranslationRef fragment_translation;
    uint32_t color_attachment_count;
    SolMetalTexturePixelFormat depth_stencil_format;
    const SolMetalRenderColorAttachmentDescriptor *color_attachments;
    SolMetalDepthStencilDescriptor depth_stencil;
    uint32_t alpha_to_coverage_enabled;
    uint32_t alpha_to_coverage_dither_enabled;
    uint32_t alpha_to_one_enabled;
    SolMetalPrimitiveTopologyClass input_primitive_topology;
    uint32_t reserved[4];
} SolMetalRenderPipelineMrtDescriptor;

typedef struct SolMetalRenderColorTargetBinding {
    uint32_t attachment_index;
    SolMetalRenderLoadAction load_action;
    SolMetalRenderStoreAction store_action;
    uint32_t reserved0;
    SolMetalTextureRef texture;
    double clear_red;
    double clear_green;
    double clear_blue;
    double clear_alpha;
    uint32_t reserved[4];
} SolMetalRenderColorTargetBinding;

typedef struct SolMetalRenderPassState {
    uint32_t struct_size;
    uint32_t abi_version;
    SolMetalTextureRef depth_stencil_target;
    SolMetalRenderLoadAction depth_load_action;
    SolMetalRenderStoreAction depth_store_action;
    SolMetalRenderLoadAction stencil_load_action;
    SolMetalRenderStoreAction stencil_store_action;
    double clear_depth;
    uint32_t clear_stencil;
    uint32_t stencil_reference_front;
    uint32_t stencil_reference_back;
    uint32_t reserved[8];
} SolMetalRenderPassState;

typedef struct SolMetalRasterizerState {
    uint32_t struct_size;
    uint32_t abi_version;
    SolMetalFrontFaceWinding front_face;
    SolMetalCullMode cull_mode;
    SolMetalTriangleFillMode triangle_fill_mode;
    SolMetalDepthClipMode depth_clip_mode;
    float depth_bias;
    float depth_bias_slope_scale;
    float depth_bias_clamp;
    uint32_t reserved0;
    uint32_t reserved[8];
} SolMetalRasterizerState;

typedef struct SolMetalSpirvResourceBinding {
    uint32_t descriptor_set;
    uint32_t binding;
    uint32_t msl_buffer;
    uint32_t msl_texture;
    uint32_t msl_sampler;
    uint32_t resource_array_size;
    uint32_t reserved[2];
} SolMetalSpirvResourceBinding;

typedef struct SolMetalSpirvTranslationOptions {
    uint32_t struct_size;
    uint32_t abi_version;
    SolMetalShaderStage stage;
    uint32_t msl_version;
    uint32_t enable_argument_buffers;
    uint32_t flip_vertex_y;
    uint32_t resource_binding_count;
    // Descriptor-set bitmask. Enabled sets use Metal argument buffers; all
    // other sets remain discrete. The current ABI maps one enabled set to
    // Metal buffer slot 30.
    uint32_t argument_buffer_set_mask;
    const SolMetalSpirvResourceBinding *resource_bindings;
    // Keep SPIRV-Cross's point-size builtin for point pipelines. Non-point
    // topology variants set this flag so Metal never sees [[point_size]].
    uint32_t disable_point_size_builtin;
    uint32_t reserved[7];
    char entry_point[SOL_METAL_ENTRY_POINT_CAPACITY];
} SolMetalSpirvTranslationOptions;

typedef struct SolMetalSpirvTranslationReport {
    uint32_t struct_size;
    uint32_t abi_version;
    SolMetalShaderStage stage;
    uint32_t msl_version;
    uint64_t spirv_bytes;
    uint64_t msl_source_bytes;
    uint32_t entry_point_count;
    uint32_t uniform_buffer_count;
    uint32_t storage_buffer_count;
    uint32_t sampled_image_count;
    uint32_t separate_image_count;
    uint32_t storage_image_count;
    uint32_t separate_sampler_count;
    uint32_t push_constant_buffer_count;
    uint32_t stage_input_count;
    uint32_t stage_output_count;
    uint32_t remapped_binding_count;
    uint32_t argument_buffers_enabled;
    uint32_t metal_library_compiled;
    uint32_t metal_function_created;
    // Structural SPIRV-Cross reflection, independent of whether the Metal
    // point-size semantic was disabled for this translation variant.
    uint32_t writes_point_size;
    uint32_t reserved[7];
    char entry_point[SOL_METAL_ENTRY_POINT_CAPACITY];
    char last_error[SOL_METAL_ERROR_CAPACITY];
} SolMetalSpirvTranslationReport;

typedef struct SolMetalCapabilities {
    uint32_t struct_size;
    uint32_t abi_version;
    uint64_t registry_id;
    uint64_t max_buffer_length;
    uint64_t recommended_max_working_set_size;
    uint32_t max_threads_per_threadgroup;
    uint32_t apple_gpu_family;
    uint32_t argument_buffer_tier;
    uint32_t has_unified_memory;
    uint32_t is_low_power;
    uint32_t is_removable;
    uint32_t is_headless;
    uint32_t supports_bc_texture_compression;
    uint32_t supports_ray_tracing;
    uint32_t supports_binary_archives;
    // Vertex-stage [[render_target_array_index]] plus layered render-pass
    // encoding is exposed only on the Apple GPU families validated by SolMetal.
    uint32_t supports_layered_vertex_output;
    uint32_t reserved[7];
    char device_name[SOL_METAL_DEVICE_NAME_CAPACITY];
} SolMetalCapabilities;

typedef struct SolMetalValidationReport {
    uint32_t struct_size;
    uint32_t abi_version;
    uint32_t requested_flags;
    uint32_t completed_flags;
    uint32_t iterations_requested;
    uint32_t iterations_completed;
    uint32_t tests_run;
    uint32_t tests_passed;
    uint64_t command_buffers_completed;
    uint64_t bytes_verified;
    uint64_t output_signature;
    uint64_t gpu_time_nanoseconds;
    SolMetalStatus last_status;
    uint32_t shader_cache_hits;
    uint32_t shader_cache_misses;
    uint32_t binary_archives_created;
    uint32_t reserved[4];
    char last_error[SOL_METAL_ERROR_CAPACITY];
} SolMetalValidationReport;

// Reports the ordered command-queue timeline used by the managed GAL bridge.
// Every submitted value completes after all command buffers committed before
// it on SolMetal's primary queue. A failed command still retires its value so
// callers never deadlock; last_status and first_failed_value carry the error.
typedef struct SolMetalTimelineReport {
    uint32_t struct_size;
    uint32_t abi_version;
    uint64_t latest_submitted_value;
    uint64_t latest_completed_value;
    uint64_t first_failed_value;
    SolMetalStatus last_status;
    // Number of Metal render passes opened for the batched draws, saturated
    // to 32 bits. Comparing this with batched_draw_count exposes encoder reuse.
    uint32_t draw_render_pass_count;
    // Runtime draw-batch telemetry. These counters are monotonic for the
    // lifetime of the context; pending_draw_count is an instantaneous value.
    uint64_t batched_draw_count;
    uint64_t draw_command_buffer_count;
    uint64_t draw_boundary_flush_count;
    uint32_t maximum_draw_batch_size;
    uint32_t pending_draw_count;
} SolMetalTimelineReport;

// Reasons why a pending draw command buffer was committed. The fixed indices
// keep telemetry consumers independent from Timeline v1's stable layout.
#define SOL_METAL_RUNTIME_BATCH_FLUSH_REASON_COUNT 8u
typedef enum SolMetalRuntimeBatchFlushReason {
    SOL_METAL_RUNTIME_BATCH_FLUSH_DRAW_LIMIT = 0,
    SOL_METAL_RUNTIME_BATCH_FLUSH_ORDERED_SUBMISSION = 1,
    SOL_METAL_RUNTIME_BATCH_FLUSH_SYNCHRONOUS_SUBMISSION = 2,
    SOL_METAL_RUNTIME_BATCH_FLUSH_TIMELINE = 3,
    SOL_METAL_RUNTIME_BATCH_FLUSH_CONTEXT_DESTROY = 4,
    SOL_METAL_RUNTIME_BATCH_FLUSH_MUTATION_ENCODER_LIMIT = 5,
    SOL_METAL_RUNTIME_BATCH_FLUSH_MUTATION_TRANSIENT_LIMIT = 6,
    SOL_METAL_RUNTIME_BATCH_FLUSH_RESERVED_7 = 7,
} SolMetalRuntimeBatchFlushReason;

// Optional, versioned runtime batching telemetry. This is intentionally a
// separate API so adding counters never changes SolMetalTimelineReport v1.
typedef struct SolMetalRuntimeBatchReport {
    uint32_t struct_size;
    uint32_t abi_version;
    uint32_t direct_mutation_batching_enabled;
    uint32_t mutation_encoder_limit;
    uint64_t mutation_transient_byte_limit;
    uint64_t batched_draw_count;
    uint64_t draw_command_buffer_count;
    uint64_t draw_render_pass_count;
    uint64_t borrowed_mutation_count;
    uint64_t borrowed_mutation_encoder_count;
    uint64_t borrowed_mutation_transient_bytes;
    uint64_t standalone_mutation_count;
    uint64_t discarded_pending_command_buffer_count;
    uint64_t discarded_pending_draw_count;
    uint32_t maximum_draw_batch_size;
    uint32_t maximum_mutation_count;
    uint32_t maximum_mutation_encoder_count;
    uint32_t pending_draw_count;
    uint32_t pending_mutation_count;
    uint32_t pending_mutation_encoder_count;
    uint64_t maximum_mutation_transient_bytes;
    uint64_t pending_mutation_transient_bytes;
    uint64_t flush_reason_counts[
        SOL_METAL_RUNTIME_BATCH_FLUSH_REASON_COUNT];
    uint64_t reserved[8];
} SolMetalRuntimeBatchReport;

SOL_METAL_EXPORT uint32_t sol_metal_abi_version(void);
SOL_METAL_EXPORT const char *sol_metal_status_string(SolMetalStatus status);

SOL_METAL_EXPORT SolMetalStatus sol_metal_query_capabilities(
    SolMetalCapabilities *capabilities);

SOL_METAL_EXPORT SolMetalStatus sol_metal_context_create(
    SolMetalContextRef *out_context);

SOL_METAL_EXPORT void sol_metal_context_destroy(
    SolMetalContextRef context);

// Copies the most recent detailed error recorded by this context. The output
// is always NUL-terminated when capacity is nonzero.
SOL_METAL_EXPORT SolMetalStatus sol_metal_context_copy_last_error(
    SolMetalContextRef context,
    char *destination,
    uint64_t capacity);

SOL_METAL_EXPORT SolMetalStatus sol_metal_context_query_capabilities(
    SolMetalContextRef context,
    SolMetalCapabilities *capabilities);

SOL_METAL_EXPORT SolMetalStatus sol_metal_context_run_validation(
    SolMetalContextRef context,
    uint32_t flags,
    uint32_t iterations,
    SolMetalValidationReport *report);

// Translates a caller-owned SPIR-V word stream to MSL, then asks the active
// Metal device to compile the generated entry point. The input and binding
// arrays are borrowed only for this call. On success, the returned translation
// owns an immutable MSL copy until explicitly destroyed.
SOL_METAL_EXPORT SolMetalStatus sol_metal_context_translate_spirv(
    SolMetalContextRef context,
    const uint32_t *spirv_words,
    uint64_t word_count,
    const SolMetalSpirvTranslationOptions *options,
    SolMetalSpirvTranslationReport *report,
    SolMetalShaderTranslationRef *out_translation);

SOL_METAL_EXPORT void sol_metal_shader_translation_destroy(
    SolMetalShaderTranslationRef translation);

// When destination is null or too small, required_size still receives the
// UTF-8 byte count including the trailing null terminator.
SOL_METAL_EXPORT SolMetalStatus sol_metal_shader_translation_copy_msl(
    SolMetalShaderTranslationRef translation,
    char *destination,
    uint64_t destination_size,
    uint64_t *required_size);

SOL_METAL_EXPORT SolMetalStatus sol_metal_context_buffer_create(
    SolMetalContextRef context,
    const SolMetalBufferDescriptor *descriptor,
    SolMetalBufferRef *out_buffer);

SOL_METAL_EXPORT void sol_metal_buffer_destroy(
    SolMetalBufferRef buffer);

SOL_METAL_EXPORT SolMetalStatus sol_metal_context_buffer_upload(
    SolMetalContextRef context,
    SolMetalBufferRef buffer,
    uint64_t destination_offset,
    const void *source,
    uint64_t size);

SOL_METAL_EXPORT SolMetalStatus sol_metal_context_buffer_download(
    SolMetalContextRef context,
    SolMetalBufferRef buffer,
    uint64_t source_offset,
    void *destination,
    uint64_t size);

SOL_METAL_EXPORT SolMetalStatus sol_metal_context_buffer_copy(
    SolMetalContextRef context,
    SolMetalBufferRef source,
    uint64_t source_offset,
    SolMetalBufferRef destination,
    uint64_t destination_offset,
    uint64_t size);

// Writes a repeated 32-bit value across a four-byte-aligned buffer range.
// Shared buffers are filled directly; private buffers use a cached Metal
// compute pipeline so the clear remains on the GPU.
SOL_METAL_EXPORT SolMetalStatus sol_metal_context_buffer_fill_u32(
    SolMetalContextRef context,
    SolMetalBufferRef buffer,
    uint64_t destination_offset,
    uint64_t size,
    uint32_t value);

// Expands four guest quad indices into the six UInt32 indices Metal needs for
// two triangles. The conversion is encoded on the GPU and, when direct
// mutation batching is enabled, is retained ahead of the following draw in
// the same ordered command stream. Source and destination ranges must not
// alias. Indirect argument conversion is deliberately outside this API.
SOL_METAL_EXPORT SolMetalStatus sol_metal_context_buffer_expand_quad_indices(
    SolMetalContextRef context,
    SolMetalBufferRef source,
    uint64_t source_offset,
    SolMetalIndexType source_index_type,
    uint32_t quad_count,
    SolMetalBufferRef destination,
    uint64_t destination_offset);

SOL_METAL_EXPORT SolMetalStatus sol_metal_context_texture_create_2d(
    SolMetalContextRef context,
    const SolMetalTextureDescriptor *descriptor,
    SolMetalTextureRef *out_texture);

// Creates a Metal texture-buffer view over an existing SolMetal buffer. The
// descriptor supplies the texel format, width, swizzle, and shader usage; its
// type must be SOL_METAL_TEXTURE_TYPE_BUFFER.
SOL_METAL_EXPORT SolMetalStatus sol_metal_context_texture_create_buffer_view(
    SolMetalContextRef context,
    SolMetalBufferRef buffer,
    uint64_t buffer_offset,
    uint64_t buffer_size,
    const SolMetalTextureDescriptor *descriptor,
    SolMetalTextureRef *out_texture);

SOL_METAL_EXPORT void sol_metal_texture_destroy(
    SolMetalTextureRef texture);

SOL_METAL_EXPORT SolMetalStatus sol_metal_context_texture_create_view_2d(
    SolMetalContextRef context,
    SolMetalTextureRef source,
    const SolMetalTextureViewDescriptor *descriptor,
    SolMetalTextureRef *out_texture);

// Transfers the complete single-level texture. The caller buffer must contain
// bytes_per_row * height bytes; only each row's pixel bytes are read or written,
// so caller-owned row padding is preserved on download.
SOL_METAL_EXPORT SolMetalStatus sol_metal_context_texture_upload_2d(
    SolMetalContextRef context,
    SolMetalTextureRef texture,
    const void *source,
    uint64_t source_bytes_per_row,
    uint64_t source_size);

SOL_METAL_EXPORT SolMetalStatus sol_metal_context_texture_download_2d(
    SolMetalContextRef context,
    SolMetalTextureRef texture,
    void *destination,
    uint64_t destination_bytes_per_row,
    uint64_t destination_size);

// Optional ABI-v1 diagnostic extension. This deliberately does not broaden
// the public texture download contract above: it accepts only a single-level,
// single-sample 2D DEPTH32_FLOAT texture and exists for bounded renderer probes.
// Caller row padding is preserved exactly as with the public download path.
SOL_METAL_EXPORT SolMetalStatus
sol_metal_context_texture_probe_download_depth32_2d(
    SolMetalContextRef context,
    SolMetalTextureRef texture,
    void *destination,
    uint64_t destination_bytes_per_row,
    uint64_t destination_size);

// Downloads one depth/stencil subresource using the guest-visible byte
// layout declared by the SolMetal texture format. D16_UNORM returns one
// 16-bit code per texel, D32_FLOAT returns one float per texel,
// D24_UNORM_STENCIL8 returns packed depth:24/stencil:8 words, and
// D32_FLOAT_STENCIL8 returns a float followed by a 32-bit stencil word. The
// selected mip and slice are bounds checked and caller row padding is
// preserved. Multisample, 3D, buffer, and non-depth textures fail closed.
SOL_METAL_EXPORT SolMetalStatus
sol_metal_context_texture_download_depth_stencil_subresource_2d(
    SolMetalContextRef context,
    SolMetalTextureRef texture,
    uint32_t source_slice,
    uint32_t source_level,
    void *destination,
    uint64_t destination_bytes_per_row,
    uint64_t destination_size);

// Copies one texture slice and mip into an existing GPU buffer. Metal's
// texture-row alignment is handled inside SolMetal; caller row padding is left
// untouched and the copy remains asynchronous on the context command queue.
SOL_METAL_EXPORT SolMetalStatus sol_metal_context_texture_copy_to_buffer(
    SolMetalContextRef context,
    SolMetalTextureRef texture,
    uint32_t source_slice,
    uint32_t source_level,
    SolMetalBufferRef destination,
    uint64_t destination_offset,
    uint64_t destination_size,
    uint64_t destination_bytes_per_row);

SOL_METAL_EXPORT SolMetalStatus sol_metal_context_texture_copy_2d(
    SolMetalContextRef context,
    SolMetalTextureRef source,
    SolMetalTextureRef destination);

SOL_METAL_EXPORT SolMetalStatus sol_metal_context_texture_copy_subresource_2d(
    SolMetalContextRef context,
    SolMetalTextureRef source,
    SolMetalTextureRef destination,
    const SolMetalTextureCopyDescriptor *descriptor);

// Converts one R32_FLOAT color subresource into one DEPTH32_FLOAT
// subresource without staging through CPU memory. The selected mip and slice
// may belong to a 2D, array, cube, or cube-array texture. Both resources must
// be single-sample and the requested top-left extent must fit both selected
// subresources. 3D, buffer, multisample, scaled, and other format pairs fail
// closed.
SOL_METAL_EXPORT SolMetalStatus
sol_metal_context_texture_copy_r32float_to_depth32_subresource_2d(
    SolMetalContextRef context,
    SolMetalTextureRef source,
    SolMetalTextureRef destination,
    const SolMetalTextureCopyDescriptor *descriptor);

SOL_METAL_EXPORT SolMetalStatus sol_metal_context_texture_clear_color(
    SolMetalContextRef context,
    SolMetalTextureRef texture,
    const SolMetalTextureClearColorDescriptor *descriptor);

SOL_METAL_EXPORT SolMetalStatus sol_metal_context_texture_clear_depth_stencil(
    SolMetalContextRef context,
    SolMetalTextureRef texture,
    const SolMetalTextureClearDepthStencilDescriptor *descriptor);

SOL_METAL_EXPORT SolMetalStatus sol_metal_context_texture_blit_2d(
    SolMetalContextRef context,
    SolMetalTextureRef source,
    SolMetalTextureRef destination,
    const SolMetalTextureBlitDescriptor *descriptor);

SOL_METAL_EXPORT SolMetalStatus sol_metal_context_sampler_create(
    SolMetalContextRef context,
    const SolMetalSamplerDescriptor *descriptor,
    SolMetalSamplerRef *out_sampler);

SOL_METAL_EXPORT void sol_metal_sampler_destroy(
    SolMetalSamplerRef sampler);

// Creates a compute pipeline from a retained compute-stage translation. The
// resulting pipeline owns everything it needs and may outlive the translation.
SOL_METAL_EXPORT SolMetalStatus sol_metal_context_compute_pipeline_create(
    SolMetalContextRef context,
    SolMetalShaderTranslationRef translation,
    SolMetalComputePipelineRef *out_pipeline);

SOL_METAL_EXPORT void sol_metal_compute_pipeline_destroy(
    SolMetalComputePipelineRef pipeline);

SOL_METAL_EXPORT SolMetalStatus sol_metal_compute_pipeline_query_info(
    SolMetalComputePipelineRef pipeline,
    SolMetalComputePipelineInfo *info);

// Dispatches one synchronous compute command. Binding arrays are borrowed for
// this call; resources and the pipeline remain caller-owned. Buffer offsets
// are byte offsets. Duplicate binding indices are rejected.
SOL_METAL_EXPORT SolMetalStatus sol_metal_context_compute_dispatch(
    SolMetalContextRef context,
    SolMetalComputePipelineRef pipeline,
    const SolMetalComputeDispatchDescriptor *descriptor);

SOL_METAL_EXPORT SolMetalStatus sol_metal_context_render_pipeline_create(
    SolMetalContextRef context,
    const SolMetalRenderPipelineDescriptor *descriptor,
    SolMetalRenderPipelineRef *out_pipeline);

// Creates a render pipeline with explicit Metal vertex fetch layouts. Buffer
// and attribute arrays are borrowed for this call and copied into the pipeline.
SOL_METAL_EXPORT SolMetalStatus
sol_metal_context_render_pipeline_create_with_vertex_layout(
    SolMetalContextRef context,
    const SolMetalRenderPipelineDescriptor *descriptor,
    const SolMetalVertexBufferLayout *buffer_layouts,
    uint32_t buffer_layout_count,
    const SolMetalVertexAttribute *attributes,
    uint32_t attribute_count,
    SolMetalRenderPipelineRef *out_pipeline);

// Creates a one-color render pipeline with explicit blend and depth/stencil
// state. A zero depth_stencil_format disables depth and stencil attachments.
SOL_METAL_EXPORT SolMetalStatus
sol_metal_context_render_pipeline_create_advanced(
    SolMetalContextRef context,
    const SolMetalRenderPipelineAdvancedDescriptor *descriptor,
    const SolMetalVertexBufferLayout *buffer_layouts,
    uint32_t buffer_layout_count,
    const SolMetalVertexAttribute *attributes,
    uint32_t attribute_count,
    SolMetalRenderPipelineRef *out_pipeline);

// Creates a render pipeline with one to eight color attachments. Sparse guest
// attachment indices are preserved, and duplicate indices are rejected.
SOL_METAL_EXPORT SolMetalStatus
sol_metal_context_render_pipeline_create_mrt(
    SolMetalContextRef context,
    const SolMetalRenderPipelineMrtDescriptor *descriptor,
    const SolMetalVertexBufferLayout *buffer_layouts,
    uint32_t buffer_layout_count,
    const SolMetalVertexAttribute *attributes,
    uint32_t attribute_count,
    SolMetalRenderPipelineRef *out_pipeline);

SOL_METAL_EXPORT void sol_metal_render_pipeline_destroy(
    SolMetalRenderPipelineRef pipeline);

// Encodes one synchronous draw into a caller-owned 2D render-target texture.
// This initial pass has one color attachment and no depth/stencil attachment.
SOL_METAL_EXPORT SolMetalStatus sol_metal_context_render_draw(
    SolMetalContextRef context,
    SolMetalRenderPipelineRef pipeline,
    const SolMetalRenderDrawDescriptor *descriptor);

SOL_METAL_EXPORT SolMetalStatus sol_metal_context_render_draw_bound(
    SolMetalContextRef context,
    SolMetalRenderPipelineRef pipeline,
    const SolMetalRenderDrawDescriptor *descriptor,
    const SolMetalRenderStageBindings *vertex_bindings,
    const SolMetalRenderStageBindings *fragment_bindings);

// For indexed draws, descriptor.vertex_start is the first index and
// descriptor.vertex_count is the index count. index_binding.offset is a byte
// offset to the start of the index allocation.
SOL_METAL_EXPORT SolMetalStatus sol_metal_context_render_draw_indexed_bound(
    SolMetalContextRef context,
    SolMetalRenderPipelineRef pipeline,
    const SolMetalRenderDrawDescriptor *descriptor,
    const SolMetalRenderIndexBinding *index_binding,
    const SolMetalRenderStageBindings *vertex_bindings,
    const SolMetalRenderStageBindings *fragment_bindings);

// Uses the pipeline's immutable depth/stencil state. index_binding may be null
// for a non-indexed draw. A pipeline created without a depth/stencil format
// requires render_pass_state to be null.
SOL_METAL_EXPORT SolMetalStatus sol_metal_context_render_draw_advanced(
    SolMetalContextRef context,
    SolMetalRenderPipelineRef pipeline,
    const SolMetalRenderDrawDescriptor *descriptor,
    const SolMetalRenderIndexBinding *index_binding,
    const SolMetalRenderStageBindings *vertex_bindings,
    const SolMetalRenderStageBindings *fragment_bindings,
    const SolMetalRenderPassState *render_pass_state);

// Encodes the advanced draw with explicit dynamic rasterizer state. The
// rasterizer descriptor is borrowed for this call and never retained.
SOL_METAL_EXPORT SolMetalStatus sol_metal_context_render_draw_rasterized(
    SolMetalContextRef context,
    SolMetalRenderPipelineRef pipeline,
    const SolMetalRenderDrawDescriptor *descriptor,
    const SolMetalRenderIndexBinding *index_binding,
    const SolMetalRenderStageBindings *vertex_bindings,
    const SolMetalRenderStageBindings *fragment_bindings,
    const SolMetalRenderPassState *render_pass_state,
    const SolMetalRasterizerState *rasterizer_state);

// MRT counterpart to render_draw_rasterized. descriptor color fields are
// ignored; color_targets contains the complete live attachment set.
SOL_METAL_EXPORT SolMetalStatus
sol_metal_context_render_draw_mrt_rasterized(
    SolMetalContextRef context,
    SolMetalRenderPipelineRef pipeline,
    const SolMetalRenderDrawDescriptor *descriptor,
    const SolMetalRenderColorTargetBinding *color_targets,
    uint32_t color_target_count,
    const SolMetalRenderIndexBinding *index_binding,
    const SolMetalRenderStageBindings *vertex_bindings,
    const SolMetalRenderStageBindings *fragment_bindings,
    const SolMetalRenderPassState *render_pass_state,
    const SolMetalRasterizerState *rasterizer_state);

// GPU-driven counterpart to render_draw_mrt_rasterized. Exactly one command
// is read from indirect_binding. UInt8 guest index buffers are expanded to a
// transient UInt16 stream on the GPU before Metal consumes the command.
SOL_METAL_EXPORT SolMetalStatus
sol_metal_context_render_draw_mrt_rasterized_indirect(
    SolMetalContextRef context,
    SolMetalRenderPipelineRef pipeline,
    const SolMetalRenderDrawDescriptor *descriptor,
    const SolMetalRenderColorTargetBinding *color_targets,
    uint32_t color_target_count,
    const SolMetalRenderIndirectBinding *indirect_binding,
    const SolMetalRenderIndexBinding *index_binding,
    const SolMetalRenderStageBindings *vertex_bindings,
    const SolMetalRenderStageBindings *fragment_bindings,
    const SolMetalRenderPassState *render_pass_state,
    const SolMetalRasterizerState *rasterizer_state);

// Count-buffer counterpart to the single-command indirect entry point. A
// Metal compute prepass clamps the GPU-written count and packs active commands
// into a private command stream before the bounded draws are encoded. This
// preserves Vulkan/GAL count semantics without a CPU readback or queue stall.
SOL_METAL_EXPORT SolMetalStatus
sol_metal_context_render_draw_mrt_rasterized_indirect_count(
    SolMetalContextRef context,
    SolMetalRenderPipelineRef pipeline,
    const SolMetalRenderDrawDescriptor *descriptor,
    const SolMetalRenderColorTargetBinding *color_targets,
    uint32_t color_target_count,
    const SolMetalRenderIndirectBinding *indirect_binding,
    const SolMetalRenderIndirectCountBinding *count_binding,
    const SolMetalRenderIndexBinding *index_binding,
    const SolMetalRenderStageBindings *vertex_bindings,
    const SolMetalRenderStageBindings *fragment_bindings,
    const SolMetalRenderPassState *render_pass_state,
    const SolMetalRasterizerState *rasterizer_state);

// Diagnostic counterpart to render_draw_mrt_rasterized. The draw is completed
// before returning and out_visible_samples receives Metal's visibility-query
// count after clipping, culling, depth, and stencil testing. This is intended
// for validation and frame probes; normal rendering should use the asynchronous
// entry point above.
SOL_METAL_EXPORT SolMetalStatus
sol_metal_context_render_draw_mrt_rasterized_visibility(
    SolMetalContextRef context,
    SolMetalRenderPipelineRef pipeline,
    const SolMetalRenderDrawDescriptor *descriptor,
    const SolMetalRenderColorTargetBinding *color_targets,
    uint32_t color_target_count,
    const SolMetalRenderIndexBinding *index_binding,
    const SolMetalRenderStageBindings *vertex_bindings,
    const SolMetalRenderStageBindings *fragment_bindings,
    const SolMetalRenderPassState *render_pass_state,
    const SolMetalRasterizerState *rasterizer_state,
    uint64_t *out_visible_samples);

// Creates an asynchronous visibility-query batch. Draws encoded against the
// batch write independent Metal visibility slots without waiting for the GPU.
// The caller must order resolution after those draws (normally with SolMetal's
// timeline API), then destroy the batch when its result is no longer needed.
SOL_METAL_EXPORT SolMetalStatus sol_metal_context_visibility_query_create(
    SolMetalContextRef context,
    SolMetalVisibilityQueryRef *out_query);

SOL_METAL_EXPORT void sol_metal_visibility_query_destroy(
    SolMetalVisibilityQueryRef query);

SOL_METAL_EXPORT SolMetalStatus sol_metal_context_visibility_query_resolve(
    SolMetalContextRef context,
    SolMetalVisibilityQueryRef query,
    uint64_t *out_visible_samples);

// Asynchronous MRT draw counterpart used by the GAL sample-counter path. The
// query batch is borrowed for this call and must belong to the same context.
SOL_METAL_EXPORT SolMetalStatus
sol_metal_context_render_draw_mrt_rasterized_query(
    SolMetalContextRef context,
    SolMetalRenderPipelineRef pipeline,
    const SolMetalRenderDrawDescriptor *descriptor,
    const SolMetalRenderColorTargetBinding *color_targets,
    uint32_t color_target_count,
    const SolMetalRenderIndexBinding *index_binding,
    const SolMetalRenderStageBindings *vertex_bindings,
    const SolMetalRenderStageBindings *fragment_bindings,
    const SolMetalRenderPassState *render_pass_state,
    const SolMetalRasterizerState *rasterizer_state,
    SolMetalVisibilityQueryRef query);

// Ends the current render encoder so subsequent reads observe preceding
// shader, attachment, and storage writes. The command buffer remains open;
// this is an ordering boundary, not a CPU wait or queue submission.
SOL_METAL_EXPORT SolMetalStatus sol_metal_context_memory_barrier(
    SolMetalContextRef context);

// Commits an ordered, non-blocking marker to the primary Metal queue. The
// returned value can be associated with a GAL sync ID and waited later.
SOL_METAL_EXPORT SolMetalStatus sol_metal_context_timeline_submit(
    SolMetalContextRef context,
    uint64_t *out_value);

SOL_METAL_EXPORT SolMetalStatus sol_metal_context_timeline_query(
    SolMetalContextRef context,
    SolMetalTimelineReport *report);

SOL_METAL_EXPORT SolMetalStatus sol_metal_context_runtime_batch_query(
    SolMetalContextRef context,
    SolMetalRuntimeBatchReport *report);

// timeout_nanoseconds == UINT64_MAX waits without a deadline. Zero performs a
// non-blocking poll. A value greater than the latest submission is invalid.
SOL_METAL_EXPORT SolMetalStatus sol_metal_context_timeline_wait(
    SolMetalContextRef context,
    uint64_t value,
    uint64_t timeout_nanoseconds);

// Commits an ordered marker after all work already submitted to the context,
// waits for it, then reports any asynchronous Metal command failure observed
// through that point.
SOL_METAL_EXPORT SolMetalStatus sol_metal_context_wait_idle(
    SolMetalContextRef context,
    uint64_t timeout_nanoseconds);

// Presents a clear-only frame into a caller-owned CAMetalLayer. The layer is
// borrowed while the frame is encoded and must already be configured for the
// context device, BGRA8Unorm, and the given drawable size. Submission is
// asynchronous; wait_idle observes completion and any delayed Metal error.
// SolMetal does not alter the layer's configuration.
SOL_METAL_EXPORT SolMetalStatus sol_metal_context_present_clear(
    SolMetalContextRef context,
    void *ca_metal_layer,
    uint32_t pixel_width,
    uint32_t pixel_height,
    double red,
    double green,
    double blue,
    double alpha);

// Presents a sampled SolMetal texture into a caller-owned CAMetalLayer. The
// source texture and layer are borrowed while the frame is encoded. Metal
// retains the encoded resources until the asynchronous submission completes;
// wait_idle observes completion and any delayed Metal error. The texture must
// belong to context, include SAMPLED usage, and use an RGBA8/BGRA8 unorm or
// sRGB format. The layer must already use the context device and BGRA8Unorm.
// Nonzero descriptor dimensions must match the configured drawable size.
// SolMetal does not change layer ownership or configuration.
SOL_METAL_EXPORT SolMetalStatus sol_metal_context_present_texture(
    SolMetalContextRef context,
    void *ca_metal_layer,
    const SolMetalPresentTextureDescriptor *descriptor);

#if defined(__cplusplus)
}
#endif

#endif
