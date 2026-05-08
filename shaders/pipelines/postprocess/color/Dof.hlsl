#include "core/common/Bindless.hlsl"
#include "core/common/Common.hlsl"
BINDLESS_BINDINGS(3, 2, 4, 5)
#include "materials/Material.hlsli"
#include "shared/raster/ShaderParameters.h"

[[vk::push_constant]] ConstantBuffer<Moer::DofPipelineBindlessParam> param;

// 伪 随 机 数 生 成 器
float Random(float2 seed) {
    return frac(sin(dot(seed, float2(12.9898, 78.233))) * 43758.5453);
}

float4 main(float2 uv : TEXCOORD0) : SV_TARGET {
    // uv 即 屏 幕 坐 标 ， 值 域 为 [0, 1]
    float3 color = TextureHandle(param.input_color_tex).Sample2D<float4>(uv).rgb;
    // 深 度 ： 值 域 为 [0, 1]， 近 处 为 0， 无 限 远 处 为 1
    // - 另 外 ， MoerEngine 使 用 了 Reverse-Z技 术 。
    float depth = TextureHandle(param.depth_tex).Sample2D<float>(uv);
    float coc = 0.0f;
    float focus_range = max(param.focus_plane_range, 1e-3);
    if (depth <= 1e-4) {
        // 如 果 当 前 像 素 是 天 空 （ 无 限 远 ）
        coc = 1e10; // 一 个 非 常 大 的 值 ， 表 示 完 全 虚 化
    } else {
        // 正 常 情 况
        // 线 性 化 深 度 ： 值 域 为 [near_clip, far_clip]， 单 位 为 世 界 坐 标 距 离
        float linearized_depth = param.near_clip * param.far_clip / (param.far_clip + (1.0 - depth) * (param.near_clip - param.far_clip));
        // 焦 平 面 距 离
        float focus_depth = clamp(param.focus_plane_distance, param.near_clip, param.far_clip);
        // 距 离 差 值
        float signed_delta = linearized_depth - focus_depth;
        float coc_magnitude = max(abs(signed_delta) - focus_range, 0.0) / focus_range * param.dof_intensity;
        // 焦 平 面 附 近 coc = 0， 远 景 coc > 0， 近 景 coc < 0
        coc = sign(signed_delta) * coc_magnitude;
    }
    // 根 据 coc 计 算 模 糊 半 径 ， 最 大 为 6 像 素
    int blur_radius = min(max((int)round(abs(coc)), 0), 6);
    float max_blur_radius = 6.0;

    // 根 据 coc 虚 化 像 素
    float3 blur_color = color;
    if (blur_radius > 0) {
        blur_color = 0.0;
        float sample_count = 0.0;

        // 获 取 当 前 像 素 的 CoC 符 号 ， 用 于 前 后 景 分 离
        float center_coc_sign = sign(coc);

        // 在 圆 盘 区 域 内 采 样
        [loop]
        for (int i = 0; i < (blur_radius * blur_radius); ++i) {
            // 使 用 极 坐 标 进 行 圆 盘 采 样
            float r = sqrt(Random(uv + float2(i * 0.371, i * 0.237)));
            float theta = Random(uv + float2(i * 0.613, i * 0.791)) * 2.0 * 3.14159265;
            float2 disk_offset = float2(r * cos(theta), r * sin(theta)) * blur_radius;

            float2 offset = disk_offset * param.resolution_inv;
            float2 sample_uv = saturate(uv + offset);

            // 采 样 颜 色 和 深 度
            float3 sample_color = TextureHandle(param.input_color_tex).Sample2D<float4>(sample_uv).rgb;
            float sample_depth = TextureHandle(param.depth_tex).Sample2D<float>(sample_uv);

            // 计 算 采 样 点 的 CoC
            float sample_coc = 0.0;
            if (sample_depth <= 1e-4) {
                sample_coc = 1e10;
            } else {
                float sample_linear_depth = param.near_clip * param.far_clip / (param.far_clip + (1.0 - sample_depth) * (param.near_clip - param.far_clip));
                float sample_focus_depth = clamp(param.focus_plane_distance, param.near_clip, param.far_clip);
                float sample_signed_delta = sample_linear_depth - sample_focus_depth;
                float sample_coc_magnitude = max(abs(sample_signed_delta) - focus_range, 0.0) / focus_range * param.dof_intensity;
                sample_coc = sign(sample_signed_delta) * sample_coc_magnitude;
            }

            // 前 后 景 分 离 ： 只 采 样 同 类 型 像 素
            // 中 心 像 素 在 焦 平 面 附 近 (coc = 0)， 则 不 进 行 分 离 ， 直 接 采 样
            // 中 心 像 素 为 前 景 (coc < 0)， 只 采 样 前 景 像 素 (sample_coc <= 0)
            // 中 心 像 素 为 后 景 (coc > 0)， 只 采 样 后 景 像 素 (sample_coc >= 0)
            bool should_sample = true;
            if (center_coc_sign < 0) {
                // 前 景 ： 只 采 样 前 景 或 焦 平 面
                should_sample = (sample_coc <= 0);
            } else if (center_coc_sign > 0) {
                // 后 景 ： 只 采 样 后 景 或 焦 平 面
                should_sample = (sample_coc >= 0);
            }

            if (should_sample) {
                blur_color += sample_color;
                sample_count += 1.0;
            }
        }

        if (sample_count > 0) {
            blur_color /= sample_count;
        } else {
            blur_color = color;
        }
    }
    color = blur_color;

    // 可 视 化 模 糊 半 径
    if (param.b_visualize_blur_radius != 0) {
        float radius_ratio = blur_radius / max_blur_radius;
        color = lerp(float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0), radius_ratio);
    }

    // 可 视 化 焦 平 面
    if (param.b_visualize_focus_plan != 0) {
        if (abs(coc) <= focus_range) {
            color = color; // do nothing
        } else if (coc > 0.0) {
            color = lerp(color, float3(0.0, 0.0, 1.0), 0.7);
        } else {
            color = lerp(color, float3(0.0, 1.0, 0.0), 0.7);
        }
    }
    return float4(color, 1.0);
}
