# Lab 2 景深（DOF）优化报告

## 5. 可视化模糊半径

### 实现方案

在 `DofPipelineBindlessParam` 中新增 `b_visualize_blur_radius` 字段（`uint`），通过 UI 复选框控制。

Shader 中，在完成模糊计算后，若该标志位为非零，则直接将模糊半径归一化到 `[0, 1]` 并输出为灰度值：

```hlsl
if (param.b_visualize_blur_radius != 0) {
    float t = float(blur_radius) / float(MAX_BLUR_RADIUS);
    return float4(t, t, t, 1.0);
}
```

- `blur_radius == 0`（焦平面内）→ 纯黑
- `blur_radius == MAX_BLUR_RADIUS`（最大虚化）→ 纯白

### 实现细节

| 文件 | 修改内容 |
|------|----------|
| `ShaderParameters.h` | 新增 `b_visualize_blur_radius` 字段 |
| `RasterConfig.h` | 新增 `b_visualize_blur_radius = 0` |
| `RasterUI.cpp` | 新增 "Visualize Blur Radius" 复选框 |
| `DofPass.h` | 传递 `ui_config.b_visualize_blur_radius` |
| `Dof.hlsl` | 在输出前判断并返回灰度值 |

### 验证

启用后，画面呈现灰度图：焦平面附近为黑色，远离焦平面的区域逐渐变白，与 CoC 大小完全对应。

---

## 6. 前后景分离

### 问题分析

原始实现在对某像素进行模糊时，直接从整张颜色纹理中采样周围像素，不区分采样点属于近景还是远景。当聚焦在远景时，近景像素（颜色较深或较亮）会被采样进远景的模糊核，导致颜色"泄漏"——远景边缘出现不自然的亮斑或暗斑。

### 实现方案

在采样循环中，对每个采样点额外读取其深度并计算 CoC，根据符号判断其所属区域：

```hlsl
float sample_coc = ComputeCoc(TextureHandle(param.depth_tex).Sample2D<float>(sample_uv));

bool accept = true;
if (param.b_separate_fg_bg != 0) {
    if (coc > 0.0)       // 当前像素属于远景
        accept = (sample_coc >= 0.0);  // 只接受远景/焦平面采样点
    else                 // 当前像素属于近景
        accept = (sample_coc <= 0.0);  // 只接受近景/焦平面采样点
}
```

若过滤后无有效采样点（`weight == 0`），则保留原始颜色，避免出现黑块。

### 实现细节

| 文件 | 修改内容 |
|------|----------|
| `ShaderParameters.h` | 新增 `b_separate_fg_bg` 字段 |
| `RasterConfig.h` | 新增 `b_separate_fg_bg = 1`（默认开启） |
| `RasterUI.cpp` | 新增 "Separate Foreground/Background" 复选框 |
| `DofPass.h` | 传递 `ui_config.b_separate_fg_bg` |
| `Dof.hlsl` | 采样循环内按 CoC 符号过滤采样点 |

### 代价

每个采样点需要额外一次深度纹理采样（用于计算 `sample_coc`）。在圆盘采样模式下为 16 次额外采样，在正方形模式下为 `(2r+1)²` 次。

### 验证

开启前后景分离后，聚焦远景时，近景柱子的颜色不再扩散到远景中；远景边缘的亮斑消失，景深过渡更自然。

---

## 7. 圆盘采样

### 问题分析

原始实现使用双重 `for` 循环遍历正方形区域内的所有像素，导致虚化光斑呈现明显的正方形轮廓，与真实光学系统（圆形光圈）不符。

### 实现方案

使用预定义的 **Poisson Disk** 采样点集（16 个点，均匀分布在单位圆内），将其缩放到 `blur_radius` 像素半径后进行采样：

```hlsl
static const float2 POISSON_DISK[16] = { /* 16 个均匀分布在单位圆内的点 */ };

[unroll]
for (int i = 0; i < 16; ++i) {
    float2 offset    = POISSON_DISK[i] * float(blur_radius) * param.resolution_inv;
    float2 sample_uv = saturate(uv + offset);
    // ...
}
```

Poisson Disk 的特性保证采样点在圆盘内均匀分布，避免了正方形 Pattern，同时固定 16 次采样也比正方形的 `(2*6+1)² = 169` 次采样少得多。

UI 中提供 "Disk Sampling" 复选框，可切换回正方形采样以对比效果。

### 实现细节

| 文件 | 修改内容 |
|------|----------|
| `ShaderParameters.h` | 新增 `b_disk_sampling` 字段 |
| `RasterConfig.h` | 新增 `b_disk_sampling = 1`（默认开启） |
| `RasterUI.cpp` | 新增 "Disk Sampling" 复选框 |
| `DofPass.h` | 传递 `ui_config.b_disk_sampling` |
| `Dof.hlsl` | 新增 Poisson Disk 采样分支 |

### 验证

开启圆盘采样后，虚化光斑由正方形变为圆形，画面中不再出现正方形 Pattern，虚化效果更接近真实镜头的焦外成像（Bokeh）。

---

## 8. 性能优化分析与设计（调查报告）

### 当前性能瓶颈

以 1080p 分辨率、最大模糊半径 6 为例：

- **正方形采样**：`1920 × 1080 × (2×6+1)² ≈ 3.2 亿次`纹理采样/帧
- **圆盘采样（本实现）**：`1920 × 1080 × 16 ≈ 3300 万次`纹理采样/帧，约为正方形的 1/10

即便如此，在模糊半径较大时，帧率仍会显著下降，主要原因是：

1. 每个像素独立计算 CoC（重复的数学运算）
2. 每个采样点额外读取深度纹理（前后景分离带来的开销）
3. 纹理采样本身的显存带宽压力

### 优化方案分析

#### 方案一：Poisson Disk + 双线性插值（已部分实现）

**原理**：使用稀疏的 Poisson Disk 采样点代替密铺采样，并利用 GPU 硬件双线性插值在采样点之间插值，以较少的采样次数获得接近的模糊质量。

**实现复杂度**：低。本报告已实现 Poisson Disk 采样（16 点），若进一步启用双线性插值（`SampleLevel` 而非 `Sample2D`），可在不增加采样数的情况下提升质量。

**预期收益**：相比正方形采样，采样次数从 `O(r²)` 降至 `O(1)`（固定 16 次），在 `r=6` 时约有 **10× 加速**。

**缺点**：固定 16 个采样点在模糊半径很大时可能出现欠采样噪点。

---

#### 方案二：半分辨率优化

**原理**：将输入图像下采样到半分辨率（960×540），在半分辨率下执行景深模糊，再上采样回全分辨率。

**实现复杂度**：中。需要新增两个 Pass：
1. **Downsample Pass**：将全分辨率颜色+深度缩小到 1/2
2. **DOF Pass**：在半分辨率上执行（现有逻辑基本不变）
3. **Upsample Pass**：双线性或深度引导上采样回全分辨率

**预期收益**：像素数量减少 75%，理论上 DOF Pass 耗时降低约 **4×**。上采样 Pass 本身开销极小。

**缺点**：半分辨率处理会损失细节，在焦平面边缘可能出现轻微的锯齿或模糊边界。景深虚化本身对细节依赖较弱，因此这种近似在视觉上通常可接受。这是工业界最常用的后处理优化手段之一（UE4/UE5 均采用此方案）。

---

#### 方案三：CoC 预计算（CoC Pre-pass）

**原理**：在独立的 Compute Pass 中，预先为每个像素计算 CoC 和 `blur_radius`，存入一张 R16F 纹理。DOF Pass 采样时直接读取该纹理，避免重复的深度线性化和 CoC 计算。

**实现复杂度**：中。需要：
1. 新增 `CocPrepass`（Compute Shader）
2. 新增 `coc_tex` 纹理资源
3. DOF Pass 读取 `coc_tex` 而非重新计算

**预期收益**：减少 DOF Pass 中每个采样点的数学运算量。在前后景分离开启时，每个采样点需要读取邻居的 CoC，预计算可将这部分开销从"计算+采样深度"降为"仅采样 CoC 纹理"，节省约 **20-40%** 的 ALU 开销。

**缺点**：增加一次全屏 Pass 的开销和一张额外纹理的显存占用（1080p R16F ≈ 4MB）。在模糊半径较小时，收益不明显。

---

#### 方案四：Tile-based 优化

**原理**：将屏幕划分为 8×8 或 16×16 的 Tile，对每个 Tile 计算最大 CoC，用于 Early-out（若 Tile 内最大 CoC 为 0，则跳过模糊）或动态调整采样数。

**实现复杂度**：高。需要：
1. Compute Pass 计算每个 Tile 的最大 CoC（Reduction）
2. DOF Pass 读取 Tile 数据决定是否跳过或降低采样数

**预期收益**：对于焦平面附近的大片区域（CoC ≈ 0），可完全跳过模糊计算，节省大量 GPU 时间。在焦平面覆盖大部分画面的场景下，收益显著（可达 **2-5×**）；在全画面虚化时收益有限。

**缺点**：实现复杂，需要修改渲染管线结构；Tile 边界处可能出现突变（需要额外的平滑处理）。

---

### 推荐优先级

| 优先级 | 方案 | 实现成本 | 预期收益 | 适用场景 |
|--------|------|----------|----------|----------|
| 1 | 半分辨率优化 | 中 | 4× | 所有场景 |
| 2 | Poisson Disk + 双线性 | 低 | 10×（vs 正方形） | 已实现基础版 |
| 3 | CoC 预计算 | 中 | 20-40% ALU | 前后景分离开启时 |
| 4 | Tile-based | 高 | 2-5× | 焦平面覆盖面积大时 |

**最优组合**：半分辨率 + Poisson Disk（16点）+ CoC 预计算，可在保持视觉质量的前提下，将 DOF Pass 总开销降低至原始正方形实现的 **1/30 ~ 1/40**。

### 测量建议

由于现代图形 API 为异步操作，C++ 端的 `std::chrono` 计时只能反映 CPU 提交耗时，无法准确测量 GPU 实际执行时间。推荐使用：

- **NVIDIA NSight Graphics**：精确测量每个 Pass 的 GPU 耗时
- **RenderDoc**：查看 GPU 时间戳
- **帧率对比**：粗略评估，适合快速验证优化方向
