#include "core/common/Bindless.hlsl"
#include "core/common/Common.hlsl"
BINDLESS_BINDINGS(3, 2, 4, 5)
#include "materials/Material.hlsli"
#include "shared/raster/ShaderParameters.h"

[[vk::push_constant]] ConstantBuffer<Moer::DofPipelineBindlessParam> param;

static const int MAX_BLUR_RADIUS = 6;

// 计算 CoC，返回有符号值：正=远景，负=近景，0=焦平面
float ComputeCoc(float depth) {
    float focus_range = max(param.focus_plane_range, 1e-3);
    if (depth <= 1e-4) {
        return 1e10;
    }
    float linearized_depth = param.near_clip * param.far_clip /
        (param.far_clip + (1.0 - depth) * (param.near_clip - param.far_clip));
    float focus_depth  = clamp(param.focus_plane_distance, param.near_clip, param.far_clip);
    float signed_delta = linearized_depth - focus_depth;
    float magnitude    = max(abs(signed_delta) - focus_range, 0.0) / focus_range * param.dof_intensity;
    return sign(signed_delta) * magnitude;
}

// Poisson disk 采样点（归一化到单位圆内）
static const float2 POISSON_DISK[16] = {
    float2(-0.94201624,  -0.39906216),
    float2( 0.94558609,  -0.76890725),
    float2(-0.094184101, -0.92938870),
    float2( 0.34495938,   0.29387760),
    float2(-0.91588581,   0.45771432),
    float2(-0.81544232,  -0.87912464),
    float2(-0.38277543,   0.27676845),
    float2( 0.97484398,   0.75648379),
    float2( 0.44323325,  -0.97511554),
    float2( 0.53742981,  -0.47373420),
    float2(-0.26496911,  -0.41893023),
    float2( 0.79197514,   0.19090188),
    float2(-0.24188840,   0.99706507),
    float2(-0.81409955,   0.91437590),
    float2( 0.19984126,   0.78641367),
    float2( 0.14383161,  -0.14100790),
};

float4 main(float2 uv : TEXCOORD0) : SV_TARGET {
    float3 color = TextureHandle(param.input_color_tex).Sample2D<float4>(uv).rgb;
    float  depth = TextureHandle(param.depth_tex).Sample2D<float>(uv);
    float  coc   = ComputeCoc(depth);

    int blur_radius = min(max((int)round(abs(coc)), 0), MAX_BLUR_RADIUS);

    float3 blur_color = color;
    if (blur_radius > 0) {
        blur_color    = 0.0;
        float weight  = 0.0;

        if (param.b_disk_sampling != 0) {
            // 圆盘采样：使用 Poisson disk 点集，缩放到 blur_radius
            [unroll]
            for (int i = 0; i < 16; ++i) {
                float2 offset      = POISSON_DISK[i] * float(blur_radius) * param.resolution_inv;
                float2 sample_uv   = saturate(uv + offset);
                float  sample_coc  = ComputeCoc(TextureHandle(param.depth_tex).Sample2D<float>(sample_uv));

                // 前后景分离：只采样与当前像素同侧的像素
                bool accept = true;
                if (param.b_separate_fg_bg != 0) {
                    // 远景像素（coc > 0）只接受远景或焦平面采样点
                    // 近景像素（coc < 0）只接受近景或焦平面采样点
                    if (coc > 0.0)
                        accept = (sample_coc >= 0.0);
                    else
                        accept = (sample_coc <= 0.0);
                }

                if (accept) {
                    blur_color += TextureHandle(param.input_color_tex).Sample2D<float4>(sample_uv).rgb;
                    weight     += 1.0;
                }
            }
        } else {
            // 正方形采样（原始实现）
            [loop]
            for (int y = -blur_radius; y <= blur_radius; ++y) {
                [loop]
                for (int x = -blur_radius; x <= blur_radius; ++x) {
                    float2 offset    = float2(x, y) * param.resolution_inv;
                    float2 sample_uv = saturate(uv + offset);
                    float  sample_coc = ComputeCoc(TextureHandle(param.depth_tex).Sample2D<float>(sample_uv));

                    bool accept = true;
                    if (param.b_separate_fg_bg != 0) {
                        if (coc > 0.0)
                            accept = (sample_coc >= 0.0);
                        else
                            accept = (sample_coc <= 0.0);
                    }

                    if (accept) {
                        blur_color += TextureHandle(param.input_color_tex).Sample2D<float4>(sample_uv).rgb;
                        weight     += 1.0;
                    }
                }
            }
        }

        if (weight > 0.0)
            blur_color /= weight;
        else
            blur_color = color; // 无有效采样点时保留原色
    }

    color = blur_color;

    // 可视化模糊半径：黑色=0，白色=最大
    if (param.b_visualize_blur_radius != 0) {
        float t = float(blur_radius) / float(MAX_BLUR_RADIUS);
        return float4(t, t, t, 1.0);
    }

    // 可视化焦平面
    float focus_range = max(param.focus_plane_range, 1e-3);
    if (param.b_visualize_focus_plan != 0) {
        if (abs(coc) > focus_range) {
            if (coc > 0.0)
                color = lerp(color, float3(0.0, 0.0, 1.0), 0.7);
            else
                color = lerp(color, float3(0.0, 1.0, 0.0), 0.7);
        }
    }

    return float4(color, 1.0);
}
