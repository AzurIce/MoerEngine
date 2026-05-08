#include "core/common/Bindless.hlsl"
#include "core/common/Common.hlsl"
BINDLESS_BINDINGS(3, 2, 4, 5)
#include "materials/Material.hlsli"
#include "shared/raster/ShaderParameters.h"

[[vk::push_constant]] ConstantBuffer<Moer::DofPipelineBindlessParam> param;

float4 main(float2 uv : TEXCOORD0) : SV_TARGET {
    // uv 即 屏幕坐标，值域为[0, 1]，表示了不同的像素
    float3 color = TextureHandle(param.input_color_tex).Sample2D<float4 >(uv).rgb;
    // 深 度： 值 域 为 [0, 1]， 近 处 为0， 无 限 远 处 为1
    // - 另 外， MoerEngine 使 用 了 Reverse-Z技 术。 如 果 你 接 触 过 其 他 渲 染 器， 你 会 发 现 此 处0和1的 对 应 关 系
    // 跟 通 常 渲 染 器 不 同
    float depth = TextureHandle(param.depth_tex).Sample2D<float>(uv);
    float coc = 0.0f;
    float focus_range = max(param.focus_plane_range , 1e-3);
    if (depth <= 1e-4) {
    // 如 果 当 前 像 素 是 天 空 （无 限 远）
    coc = 1e10; // 一 个 非 常 大 的 值， 表 示 完 全 虚 化
    } else {
    // 正 常 情 况
    // 线 性 化 深 度： 值 域 为 [near_clip, far_clip]， 单 位 为 世 界 坐 标 距 离
    float linearized_depth = param.near_clip * param.far_clip / (param.far_clip + (1.0 -
    depth) * (param.near_clip - param.far_clip));
    // 焦 平 面 距 离
    float focus_depth = clamp(param.focus_plane_distance , param.near_clip, param.far_clip);
    // 距 离 差 值
    float signed_delta = linearized_depth - focus_depth;
    float coc_magnitude = max(abs(signed_delta) - focus_range , 0.0) / focus_range * param.
    dof_intensity;
    // 焦 平 面 附 近 coc = 0， 远 景 coc > 0， 近 景 coc < 0
    coc = sign(signed_delta) * coc_magnitude;
    }
    // 根 据 coc 计 算 模 糊 半 径， 最 大 为6像 素
    int blur_radius = min(max((int)round(abs(coc)), 0), 6);
    // 根 据 coc 虚 化 像 素
    float3 blur_color = color;
    if (blur_radius > 0) {
    blur_color = 0.0;
    float sample_count = 0.0;
    // 模 糊， 本 质 上 就 是 获 取 周 围 像 素 的 颜 色， 然 后 求 平 均 值 （卷 积）
    // 下 面 的 代 码 就 是 在 以 当 前 像 素 为 中 心， 半 径 为 blur_radius 的 范 围 内， 采 样 颜 色 并 求 平 均 值
    [loop]
    for (int y = -blur_radius; y <= blur_radius; ++y) {
    [loop]
    for (int x = -blur_radius; x <= blur_radius; ++x) {
    float2 offset = float2(x, y) * param.resolution_inv;
    blur_color += TextureHandle(param.input_color_tex).Sample2D<float4>(saturate(uv +
    offset)).rgb;
    sample_count += 1.0;
    }
    }
    blur_color /= sample_count;
    }
    color = blur_color;
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
