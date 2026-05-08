# 景深效果优化实现报告

## 1. 概述

本文档记录了 MoerEngine 中景深（Depth of Field, DoF）效果的三项基础优化实现，以及一项性能优化方案的分析与设计。所有修改在独立的 git worktree 中进行，未影响主工作目录。

---

## 2. 环境准备

```bash
# 创建独立 worktree
git worktree add ../MoerEngine-dof-fix lab/lab2-dof-fix

# 复制必要的 submodule 和配置文件
cp MoerEngine.toml ../MoerEngine-dof-fix/
cp -r 3rdparty/entt ../MoerEngine-dof-fix/3rdparty/
cp -r 3rdparty/gtl ../MoerEngine-dof-fix/3rdparty/
```

---

## 3. 已实现的功能

### 3.1 可视化模糊半径（Blur Radius Visualization）

**问题描述**：需要一种直观的方式观察场景中不同像素的模糊强度分布，以便调试焦平面位置和虚化强度参数。

**实现方法**：

1. **C++ 端参数传递**：
   - 在 `DofPipelineBindlessParam` 结构体中添加 `uint b_visualize_blur_radius`
   - 在 `RasterConfig` 中添加 `uint b_visualize_blur_radius = 0`
   - 在 `DofPass::Process()` 中将 UI 配置传递到 Shader
   - 在 `RasterUI.cpp` 中添加 ImGui Checkbox "Visualize Blur Radius"

2. **Shader 端逻辑**：
   ```hlsl
   if (param.b_visualize_blur_radius != 0) {
       float radius_ratio = blur_radius / max_blur_radius;
       color = lerp(float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0), radius_ratio);
   }
   ```

**效果说明**：
- 纯黑色（RGB=0,0,0）：表示模糊半径为 0，即位于焦平面内
- 纯白色（RGB=1,1,1）：表示模糊半径达到最大值（6 像素）
- 中间灰度：线性映射模糊半径的比例

**验证方式**：在编辑器中勾选 "Visualize Blur Radius"，观察场景中焦平面附近呈黑色，远离焦平面的区域逐渐变亮。

---

### 3.2 前后景分离（Foreground/Background Separation）

**问题描述**：原始实现在同一个纹理中混合采样前景和后景像素，导致聚焦在前景时，近景物体的颜色会泄漏到远景中（例如黑色柱子使远景错误变暗），反之亦然。

**根因分析**：
- 原始代码的采样循环不区分采样点的景深类型
- 对一个远景像素进行模糊时，可能采样到近景像素的颜色
- 这与真实光学系统不符（前景和背景独立虚化）

**实现方法**：

在 Shader 的采样循环中增加前后景分离逻辑：

```hlsl
// 获取当前像素的 CoC 符号
float center_coc_sign = sign(coc);

// 对每个采样点，计算其 CoC
float sample_coc = ComputeSampleCoC(sample_uv);

// 根据中心像素的类型过滤采样点
bool should_sample = true;
if (center_coc_sign < 0) {
    // 前景像素：只采样前景或焦平面像素
    should_sample = (sample_coc <= 0);
} else if (center_coc_sign > 0) {
    // 后景像素：只采样后景或焦平面像素
    should_sample = (sample_coc >= 0);
}
// 焦平面像素（center_coc_sign == 0）不进行过滤

if (should_sample) {
    blur_color += sample_color;
    sample_count += 1.0;
}
```

**关键设计决策**：
- 焦平面像素（coc ≈ 0）不做过滤，允许混合所有像素，避免锐利的硬边
- 前景像素过滤掉后景采样点，防止远景亮色泄漏到近景
- 后景像素过滤掉前景采样点，防止近景暗色污染远景

**验证方式**：聚焦在前景物体上，观察远景边缘是否还有错误的颜色泄漏。

---

### 3.3 圆盘采样（Disc Sampling）

**问题描述**：原始实现使用双重 `for` 循环在正方形区域内采样，导致虚化效果出现明显的正方形光斑（Box Artifacts），不符合真实光学系统中圆形透镜的散景（Bokeh）效果。

**实现方法**：

使用极坐标将正方形采样转换为圆盘采样：

```hlsl
// 伪随机数生成器
float Random(float2 seed) {
    return frac(sin(dot(seed, float2(12.9898, 78.233))) * 43758.5453);
}

[loop]
for (int i = 0; i < (blur_radius * blur_radius); ++i) {
    // 在圆盘内均匀采样
    float r = sqrt(Random(uv + float2(i * 0.371, i * 0.237)));
    float theta = Random(uv + float2(i * 0.613, i * 0.791)) * 2.0 * 3.14159265;
    float2 disk_offset = float2(r * cos(theta), r * sin(theta)) * blur_radius;
    
    float2 offset = disk_offset * param.resolution_inv;
    float2 sample_uv = saturate(uv + offset);
    // ... 采样逻辑
}
```

**数学原理**：
- 均匀分布在圆盘内的点满足：$r \sim \sqrt{U[0,1]}$，$\theta \sim U[0, 2\pi]$
- 取平方根确保点在面积上均匀分布（而非半径上均匀分布）
- 使用基于 UV 坐标的确定性伪随机，保证每帧结果稳定（无 temporal flickering）

**效果说明**：
- 消除了正方形光斑，取而代之的是更自然的圆形散景
- 高光点（bright specular highlights）呈现圆形光斑，更符合物理直觉

**验证方式**：观察高光区域的虚化形状，应呈现圆形而非正方形。

---

## 4. 性能优化分析与设计方案

### 4.1 当前性能瓶颈分析

当前 DoF 实现的计算复杂度为：

$$\text{Total Samples} = W \times H \times (2r + 1)^2$$

其中：
- $W, H$ 为屏幕分辨率（如 1920×1080）
- $r$ 为模糊半径（最大 6）

对于 1080p 分辨率、最大模糊半径的情况：
- 每帧总采样数：$1920 \times 1080 \times 13 \times 13 \approx 3.5 \times 10^8$ 次
- 每次采样涉及：纹理读取（颜色+深度）、深度线性化、CoC 计算、条件分支
- 性能开销极高，在强度拉高时帧率显著下降

**瓶颈定位**：
1. **显存带宽**：大量纹理采样（颜色和深度各一次）
2. **ALU 计算**：每个采样点都重复进行深度线性化和 CoC 计算
3. **分支发散**：`[loop]` 导致的动态循环次数引起 warp 内线程发散

---

### 4.2 优化方案一：Poisson Disk 采样 + 双线性过滤

**原理**：
- 传统均匀采样在低频区域存在冗余，Poisson Disk 采样确保采样点之间的距离不小于某个阈值，在视觉上更均匀
- 配合硬件双线性过滤（bilinear filtering），每次纹理采样实际上获取了 2×2 像素块的加权平均

**实现方案**：

```hlsl
// 预定义 Poisson Disk 采样核（例如 16 个样本）
static const float2 PoissonDisk[16] = {
    float2(-0.94201624, -0.39906216),
    float2(0.94558609, -0.76890725),
    // ... 其余 14 个点
};

[unroll]
for (int i = 0; i < 16; ++i) {
    float2 offset = PoissonDisk[i] * blur_radius * param.resolution_inv;
    // 使用硬件双线性过滤，无需手动取 2x2 平均
    float3 sample_color = TextureHandle(param.input_color_tex)
        .Sample2D<float4>(uv + offset).rgb;
}
```

**预期收益**：
- 采样数从 $(2r+1)^2$ 降至固定 16 次
- 在 1080p、r=6 时，采样数从 169 降至 16，**减少 90.5%**
- 配合双线性过滤，视觉上与密集采样接近

**局限**：
- 对于非常大的 blur radius，固定 16 个样本可能产生明显的采样 pattern
- 需要动态调整样本数或引入抖动（jitter）

---

### 4.3 优化方案二：半分辨率（Half-Resolution）渲染

**原理**：
- 景深是低频效果，对高频细节不敏感
- 先降采样到半分辨率（或 1/4 分辨率），进行 DoF 计算，再上采样回全分辨率

**实现方案**：

1. **新增降采样 Pass**：
   - 输入：全分辨率颜色和深度
   - 输出：半分辨率颜色和深度（540×960）
   - 使用双线性过滤降采样颜色，最近邻降采样深度（避免深度混合错误）

2. **DoF Pass 改为处理半分辨率**：
   - 直接在半分辨率纹理上执行 DoF 计算
   - 像素数减少为 1/4，计算量等比例减少

3. **新增上采样 Pass**：
   - 使用双线性或更高级的上采样（如 FSR 的 EASU）将结果放大回全分辨率
   - 可在上采样时引入深度权重，避免边缘模糊

**管线修改**：
```
FullRes Color/Depth → [Downsample] → HalfRes Color/Depth
                                               ↓
FullRes Color ← [Upsample] ← [DoF Pass] ← HalfRes Color
```

**预期收益**：
- 像素数减少 75%，总计算量减少 75%
- 显存带宽同步降低（半分辨率纹理更小）
- 在 1080p 下，从 ~3.5 亿次采样降至 ~8800 万次

**局限**：
- 上采样可能引入轻微的边缘模糊
- 需要额外的两个 Pass（降采样+上采样），增加管线复杂度

---

### 4.4 优化方案三：CoC 预计算纹理

**原理**：
- 当前实现中，每个采样点都重复计算深度线性化和 CoC
- 实际上，CoC 只与像素位置和深度有关，可以预先计算并缓存

**实现方案**：

1. **新增 CoC Pass**（全分辨率或半分辨率）：
   ```hlsl
   // 输入：深度纹理 + 相机参数
   // 输出：CoC 纹理（R8_UNORM 或 R16_FLOAT，单通道）
   float CoC = ComputeCoC(depth, camera_params);
   return saturate(abs(CoC) / max_coc); // 归一化到 [0,1]
   ```

2. **DoF Pass 直接采样 CoC 纹理**：
   ```hlsl
   float coc = TextureHandle(param.coc_tex).Sample2D<float>(uv);
   int blur_radius = int(coc * max_blur_radius);
   ```

3. **采样循环中复用 CoC**：
   - 对于前后景分离，采样点的 CoC 也从预计算纹理读取
   - 避免每个采样点重复进行深度线性化

**预期收益**：
- 每个采样点节省：1 次深度纹理采样 + 深度线性化（除法+乘法）+ CoC 计算
- 对于 16 个采样点，每个像素节省约 16 次复杂 ALU 运算
- 整体 ALU 压力降低约 40-50%

**额外收益**：
- CoC 纹理可用于其他后处理效果（如动态模糊）
- 可在 CoC Pass 中同时计算最大模糊半径，用于 Tile-based 优化

---

### 4.5 优化方案四：Tile-Based 优化

**原理**：
- 将屏幕划分为固定大小的 Tile（如 8×8 或 16×16 像素）
- 每个 Tile 预先计算该区域的最大 CoC，决定该 Tile 需要的采样半径
- 对于最大 CoC 为 0 的 Tile，直接跳过 DoF 计算（复制原图）

**实现方案**：

1. **Tile CoC 计算 Pass**（Compute Shader）：
   ```hlsl
   [numthreads(16, 16, 1)]
   void main(uint2 id : SV_DispatchThreadID, uint2 gid : SV_GroupID) {
       float max_coc = 0;
       for (int y = 0; y < 16; ++y) {
           for (int x = 0; x < 16; ++x) {
               float coc = LoadCoC(gid * 16 + int2(x, y));
               max_coc = max(max_coc, abs(coc));
           }
       }
       TileMaxCoC[gid] = max_coc;
   }
   ```

2. **DoF Pass 读取 Tile 数据**：
   ```hlsl
   uint2 tile_id = uint2(uv * resolution) / 16;
   float tile_max_coc = TileMaxCoC[tile_id];
   if (tile_max_coc < 0.5) {
       // 整个 Tile 几乎都在焦平面内，直接输出原图
       return original_color;
   }
   ```

**预期收益**：
- 对于大部分场景，焦平面覆盖的区域超过 50%，这些 Tile 可直接跳过
- 整体计算量减少 30-60%（取决于场景内容）
- 可与其他优化叠加（如半分辨率 + Tile-based）

**局限**：
- 需要 Compute Shader 支持
- Tile 边缘可能出现轻微的不连续（需要 overlap 处理）

---

### 4.6 综合优化管线设计

推荐将上述方案组合使用，设计如下管线：

```
Pass 1: CoC Generation (全分辨率)
   输入：Depth Texture, Camera Params
   输出：CoC Texture (R8_UNORM)
   
Pass 2: Tile Max CoC (Compute Shader)
   输入：CoC Texture
   输出：TileMaxCoC Buffer
   
Pass 3: Downsample (全分辨率 → 半分辨率)
   输入：Color Texture, CoC Texture
   输出：HalfRes Color, HalfRes CoC
   
Pass 4: DoF Blur (半分辨率)
   输入：HalfRes Color, HalfRes CoC, TileMaxCoC
   输出：HalfRes DoF Result
   优化：
   - 使用 Poisson Disk 采样（固定 16 样本）
   - 直接读取 CoC 纹理（无需重复计算）
   - Tile 级别 Early-out（跳过清晰区域）
   
Pass 5: Upsample (半分辨率 → 全分辨率)
   输入：FullRes Color, HalfRes DoF Result, FullRes CoC
   输出：Final DoF Result
   方法：基于 CoC 权重的深度感知上采样
```

**预期综合收益**：

| 优化项 | 单独收益 | 叠加收益 |
|--------|---------|---------|
| Poisson Disk (16 spp) | -90% 采样数 | 基础 |
| 半分辨率 | -75% 像素数 | -97.5% 总采样 |
| CoC 预计算 | -40% ALU | 减少重复计算 |
| Tile-based | -30~60% Tile 跳过 | 视场景而定 |

**保守估计**：综合优化后，DoF Pass 的计算量可降低 **95% 以上**，从 ~3.5 亿次采样降至 ~1000 万次以下。

---

## 5. 实现验证与测试建议

### 5.1 功能验证

1. **可视化模糊半径**：
   - 勾选 "Visualize Blur Radius"
   - 观察焦平面附近为黑色，远离区域逐渐变白
   - 调整 Focus Plane Distance，观察黑白边界随焦平面移动

2. **前后景分离**：
   - 将焦点对准前景物体
   - 观察远景边缘，确认无颜色泄漏
   - 对比原始实现（可临时注释分离逻辑）

3. **圆盘采样**：
   - 观察高光区域的散景形状
   - 确认无正方形光斑
   - 调整 DoF Intensity 到最大，观察大光圈效果

### 5.2 性能测量

**注意**：禁止使用 CPU 端 `std::chrono` 测量 DoF Pass 耗时。GPU 操作为异步执行，CPU 计时只反映提交开销。

**推荐方法**：
1. **帧率对比**：
   - 记录优化前后的平均帧率（使用引擎内置统计）
   - 在相同场景、相同相机位置下测试

2. **GPU Profiler**（推荐）：
   - 使用 NSight Graphics 或 RenderDoc 截帧
   - 查看 DoF Pass 的 GPU 耗时（以微秒为单位）
   - 分析顶点/片段着色器的指令数和寄存器压力

3. **理论分析**：
   - 计算优化前后的采样数差异
   - 估算显存带宽节省（纹理读取次数 × 纹理大小）

---

## 6. 代码修改清单

### 6.1 C++ 端修改

| 文件 | 修改内容 |
|------|---------|
| `source/runtime/render/shaderheaders/shared/raster/post_process/ShaderParameters.h` | `DofPipelineBindlessParam` 添加 `uint b_visualize_blur_radius` |
| `source/runtime/render/renderer/raster/RasterConfig.h` | `RasterConfig` 添加 `uint b_visualize_blur_radius = 0` |
| `source/runtime/render/renderer/raster/DofPass.h` | `Process()` 中传递 `b_visualize_blur_radius` 参数 |
| `source/editor/raster_ui/RasterUI.cpp` | DoF UI 面板添加 "Visualize Blur Radius" Checkbox |

### 6.2 Shader 端修改

| 文件 | 修改内容 |
|------|---------|
| `shaders/pipelines/postprocess/color/Dof.hlsl` | 实现可视化模糊半径、前后景分离、圆盘采样 |

---

## 7. 总结

本次优化实现了景深效果的三项基础改进：

1. **可视化模糊半径**：通过颜色映射直观展示模糊强度分布，便于调试
2. **前后景分离**：基于 CoC 符号过滤采样点，消除颜色泄漏，效果更物理正确
3. **圆盘采样**：使用极坐标均匀采样替代正方形采样，消除 Box Artifacts，散景更自然

性能方面，分析了四种可行的优化方案，推荐组合使用 **Poisson Disk 采样 + 半分辨率渲染 + CoC 预计算 + Tile-based Early-out**，预计可将 DoF 计算量降低 95% 以上。

---

## 附录：关键代码片段

### A.1 圆盘采样 + 前后景分离（完整 Shader 核心逻辑）

```hlsl
float4 main(float2 uv : TEXCOORD0) : SV_TARGET {
    float3 color = TextureHandle(param.input_color_tex).Sample2D<float4>(uv).rgb;
    float depth = TextureHandle(param.depth_tex).Sample2D<float>(uv);
    
    // 计算 CoC
    float coc = ComputeCoC(depth, param);
    int blur_radius = min(max((int)round(abs(coc)), 0), 6);
    float max_blur_radius = 6.0;
    
    float3 blur_color = color;
    if (blur_radius > 0) {
        blur_color = 0.0;
        float sample_count = 0.0;
        float center_coc_sign = sign(coc);
        
        [loop]
        for (int i = 0; i < (blur_radius * blur_radius); ++i) {
            // 圆盘采样
            float r = sqrt(Random(uv + float2(i * 0.371, i * 0.237)));
            float theta = Random(uv + float2(i * 0.613, i * 0.791)) * 2.0 * PI;
            float2 disk_offset = float2(r * cos(theta), r * sin(theta)) * blur_radius;
            float2 sample_uv = saturate(uv + disk_offset * param.resolution_inv);
            
            // 采样颜色和深度
            float3 sample_color = TextureHandle(param.input_color_tex).Sample2D<float4>(sample_uv).rgb;
            float sample_depth = TextureHandle(param.depth_tex).Sample2D<float>(sample_uv);
            float sample_coc = ComputeCoC(sample_depth, param);
            
            // 前后景分离
            bool should_sample = true;
            if (center_coc_sign < 0) should_sample = (sample_coc <= 0);
            else if (center_coc_sign > 0) should_sample = (sample_coc >= 0);
            
            if (should_sample) {
                blur_color += sample_color;
                sample_count += 1.0;
            }
        }
        
        blur_color = sample_count > 0 ? blur_color / sample_count : color;
    }
    color = blur_color;
    
    // 可视化
    if (param.b_visualize_blur_radius != 0) {
        color = lerp(float3(0,0,0), float3(1,1,1), blur_radius / max_blur_radius);
    }
    
    return float4(color, 1.0);
}
```

### A.2 Random 函数

```hlsl
float Random(float2 seed) {
    return frac(sin(dot(seed, float2(12.9898, 78.233))) * 43758.5453);
}
```

---

*报告完成日期：2026-05-08*
*工作分支：lab/lab2-dof-fix*
*Worktree：../MoerEngine-dof-fix*
