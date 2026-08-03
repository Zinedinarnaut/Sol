#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct MetalUniforms {
    float time;
    float focusIntensity;
    float scrollOffset;
    float transition;
    float2 resolution;
    float2 focusPoint;
    float hasBackground;
    float performance;
};

vertex VertexOut vertex_main(uint vertexID [[vertex_id]]) {
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };

    float2 uvs[3] = {
        float2(0.0, 0.0),
        float2(2.0, 0.0),
        float2(0.0, 2.0)
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = uvs[vertexID];
    return out;
}

float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 34.23);
    return fract(p.x * p.y);
}

float2 coverUV(float2 uv, float2 texSize, float2 screenSize) {
    float texAspect = texSize.x / max(texSize.y, 1.0);
    float screenAspect = screenSize.x / max(screenSize.y, 1.0);
    float2 outUV = uv;

    if (texAspect > screenAspect) {
        float scale = screenAspect / texAspect;
        outUV.x = (uv.x - 0.5) * scale + 0.5;
    } else {
        float scale = texAspect / screenAspect;
        outUV.y = (uv.y - 0.5) * scale + 0.5;
    }

    return outUV;
}

float2 containUV(float2 uv, float2 texSize, float2 screenSize) {
    float texAspect = texSize.x / max(texSize.y, 1.0);
    float screenAspect = screenSize.x / max(screenSize.y, 1.0);
    float2 outUV = uv;

    if (texAspect > screenAspect) {
        float scale = texAspect / screenAspect;
        outUV.y = (uv.y - 0.5) * scale + 0.5;
    } else {
        float scale = screenAspect / texAspect;
        outUV.x = (uv.x - 0.5) * scale + 0.5;
    }

    return outUV;
}

float4 sampleBlurUV(texture2d<float> tex, sampler s, float2 uv, float2 motion, float performance) {
    float2 texSize = float2(tex.get_width(), tex.get_height());
    float2 texel = 1.0 / max(texSize, float2(1.0));
    float blurScale = mix(0.55, 1.0, performance);
    float2 o = texel * (1.4 * blurScale);

    float2 base = uv + motion;
    float4 color = tex.sample(s, base) * 0.4;
    color += tex.sample(s, base + float2(o.x, 0.0)) * 0.15;
    color += tex.sample(s, base - float2(o.x, 0.0)) * 0.15;
    color += tex.sample(s, base + float2(0.0, o.y)) * 0.15;
    color += tex.sample(s, base - float2(0.0, o.y)) * 0.15;
    return color;
}

float4 sampleBlurCover(texture2d<float> tex, sampler s, float2 uv, float2 screenSize, float2 motion, float performance) {
    float2 texSize = float2(tex.get_width(), tex.get_height());
    float2 coord = coverUV(uv, texSize, screenSize);
    return sampleBlurUV(tex, s, coord, motion, performance);
}

float containMask(float2 uv) {
    float2 dist = min(uv, 1.0 - uv);
    float edge = 0.05;
    return smoothstep(0.0, edge, min(dist.x, dist.y));
}

float4 sampleBlurContain(texture2d<float> tex, sampler s, float2 uv, float2 screenSize, float2 motion, float performance, float4 fallback) {
    float2 texSize = float2(tex.get_width(), tex.get_height());
    float2 coord = containUV(uv, texSize, screenSize);
    float mask = containMask(coord);
    float4 contain = sampleBlurUV(tex, s, coord, motion, performance);
    return mix(fallback, contain, mask);
}

fragment float4 fragment_main(
    VertexOut in [[stage_in]],
    constant MetalUniforms &u [[buffer(0)]],
    texture2d<float> currentTexture [[texture(0)]],
    texture2d<float> previousTexture [[texture(1)]]
) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    float2 uv = in.uv * 0.5;
    float2 centered = uv - 0.5;
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    centered.x *= aspect;

    float scroll = u.scrollOffset * 0.00018;
    float2 drift = float2(sin(u.time * 0.06), cos(u.time * 0.05)) * 0.01 * u.performance;
    float2 motion = float2(scroll, 0.0) + drift;

    float4 baseColor;
    if (u.hasBackground > 0.5) {
        float4 prevCover = sampleBlurCover(previousTexture, s, uv, u.resolution, motion, u.performance);
        float4 currCover = sampleBlurCover(currentTexture, s, uv, u.resolution, motion, u.performance);
        float4 prevContain = sampleBlurContain(previousTexture, s, uv, u.resolution, motion * 0.6, u.performance, prevCover);
        float4 currContain = sampleBlurContain(currentTexture, s, uv, u.resolution, motion * 0.6, u.performance, currCover);
        baseColor = mix(prevContain, currContain, u.transition);
    } else {
        float gradient = 0.12 + 0.06 * sin(u.time * 0.08 + uv.y * 3.2);
        float noise = hash21(uv * float2(120.0, 80.0) + float2(u.time * 0.15, scroll * 40.0));
        float softNoise = mix(noise, hash21(uv * float2(40.0, 22.0) + u.time * 0.05), 0.6);
        float value = 0.08 + gradient + softNoise * 0.04;
        baseColor = float4(value, value, value, 1.0);
    }

    float luma = dot(baseColor.rgb, float3(0.2126, 0.7152, 0.0722));
    baseColor.rgb = mix(baseColor.rgb, float3(luma), 0.42);
    baseColor.rgb *= 0.45;

    float vignette = smoothstep(1.0, 0.2, length(centered));
    baseColor.rgb *= vignette;

    float2 focusDelta = uv - u.focusPoint;
    focusDelta.x *= aspect;
    float glow = exp(-dot(focusDelta, focusDelta) * 7.5);
    glow *= u.focusIntensity * 0.35;

    float3 glowColor = float3(0.12, 0.12, 0.12) * u.performance;
    baseColor.rgb += glow * glowColor;

    return float4(clamp(baseColor.rgb, 0.0, 1.0), 1.0);
}
