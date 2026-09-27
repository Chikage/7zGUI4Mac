# RZ profile 2：可配置恢复载荷

新写入器默认使用 profile 2；profile 1 的读取、验证、修复、解压仍保持兼容。
所有整数为无符号小端。Zstd frame、文件索引条目、路径检查及文件 BLAKE3 规则沿用
[profile 1](FORMAT.md)。本格式仍为实验格式。

## 载荷与编码组

压缩流切成 64 KiB 数据块，仅最后一个块补零。空压缩流仍使用一个全零块。
`D = max(1, ceil(stream_size / 65536))`，编码组数量 `G = ceil(D / 100)`。
每组最多 100 个数据块，最后一组使用实际块数，不强制补满 100 个。

恢复配置两种模式互斥：

- 百分比：以整数 basis points 表示百分数的百分之一，允许 100..10000，即 1%..100%。
  `R = ceil(D * requested_value / 10000)`。
- 指定恢复字节：`R = ceil(requested_bytes / 65536)`。
  要求 `G <= R <= D`，不足时报告最小字节数，超过时报告最大字节数。

先为每组分配一个恢复块，再按 `k_i - 1` 的比例分配剩下的 `R-G` 个。
用累计整数除法保证总和恰好为 R：

```text
W = D-G
C_i = sum(j<=i, k_j-1)
m_i = 1 + floor(C_i*(R-G)/W) - floor(C_(i-1)*(R-G)/W)
```

当 W=0 时各组 m=1。每组 `1 <= m_i <= k_i <= 100`。
恢复载荷是 `R*65536`，数据载荷是 `D*65536`；比例不包含索引和卷头等额外开销。
取整可能使实际比例高于输入值，尤其是很小的归档。

## 稳定的 RS 数学定义

采用系统 Cauchy RS，GF(256)，多项式 `0x11d`，标准逐字节映射。
数据列编号 c=0..k-1，恢复行编号 r=0..m-1：

```text
A[r,c] = inverse_GF256((128+r) XOR c)
P[r][byte] = XOR(c=0..k-1, multiply_GF256(A[r,c], D[c][byte]))
```

数据域元素 0..99 与恢复行域元素 128..255 分离。
改变 m 不改变已有行系数。当前写入器仍要求 m<=k，不提供创建后追加功能；
稳定行编号为以后扩展预留数学基础，不能据此直接修改现有索引。

块摘要：

```text
BLAKE3(ASCII("rz-block-v2") || UUID[16] || LE32(group_id) || LE32(shard_id) || payload[65536])
```

组内 shard_id 0..k-1 为数据，k..k+m-1 为恢复数据。计算覆盖零填充。
恢复条件是每组不可用块总数（数据加恢复块）不超过该组 m；其他组的余量不能借用。

## 编码块与物理分卷解耦

每卷大小上限 V 为 1 MiB..16 GiB，可以是任意字节上限。
设最终索引长度为 L，则每卷最多容纳
`C = floor((V - 240 - 2*L)/65536)` 块，C 必须至少为 1。

数据卷数量 `DV=ceil(D/C)`，恢复卷数量 `PV=ceil(R/C)`。
每种卷最多 65536 个。全局数据块号 b，或全局恢复块号 b，分别按以下方式定位：

```text
volume_id = b % volume_count
slot       = b / volume_count
offset     = 120 + L + slot*65536
```

数据块按逻辑流顺序编号。恢复块先按编码组排序，再按组内恢复行排序。
这种交错布局将同组块分散到可用物理卷中，缓解整卷丢失的集中损坏。
实际卷大小可能小于上限。每卷载荷块数最多相差 1。
一个卷丢失会在多个编码组中形成擦除；不能仅凭全局恢复比例承诺可恢复多少个卷。

卷名：`d000000.rzv`、`d000001.rzv` …；恢复卷名：`p000000.rzr` …。
文件打开缓存最多 16 个句柄，不随卷数无界增长。

## 卷头与索引

每个卷仍是 `Header[120] | Manifest[L] | Payload | Manifest[L] | Footer[120]`。
头部偏移沿用 profile 1，差异如下：

| 偏移 | 类型 | profile 2 内容 |
|---|---|---|
| 0 | 8 bytes | `RZVOL002` / `RZEND002` |
| 8 | u32 | 2 |
| 12 | u32 | 0=data、1=recovery |
| 16 | 16 bytes | UUID |
| 32 | u32 | 同类型物理卷编号 |
| 36 | u32 | 保留，必须为 0 |
| 40 | u64 | Manifest 长度 |
| 48 | u64 | 该卷载荷长度 |
| 56 | 32 bytes | BLAKE3(Manifest) |
| 88 | 32 bytes | BLAKE3(前 88 字节) |

Manifest 字段依次为：

```text
magic[8] = "RZIDX002"
uuid[16]
profile:u32 = 2
block_size:u32 = 65536
frame_size:u32 = 4194304
requested_mode:u32                 # 0=百分比、1=恢复字节
requested_value:u64                # basis points 或字节
volume_size_limit:u64
blocks_per_volume:u32
stream_size:u64
data_blocks:u64
recovery_blocks:u64
group_count:u32
repeat group_count:
    k:u32
    m:u32
    hashes[k+m][32]
entries                            # 与 profile 1 的 entry_count 及条目格式相同
```

读者重新计算块数、恢复预算、各组 k/m、分卷容量并核对，拒绝矛盾参数。
校验顺序、首尾及 sidecar 索引副本、独占输出和修复后复验沿用 profile 1。
不同版本/归档的有效元数据冲突会失败；不会静默混用。

## CLI 与 GUI 契约

```sh
rz create input archive.rz --volume-size 1.5MiB --recovery-percent 7.5
rz create-selected archive.rz --volume-size 1.25GiB --recovery-bytes 500MiB -- file folder
rz create input legacy.rz --profile 1
rz list archive.rz --json
```

CLI 大小输入接受 B、KiB、MiB、GiB（最多三位小数，转字节向下取整）；
百分比最多两位小数。GUI 将自由输入量精确换算成整数后传参。

JSON 外层 `version` 保持 1，新增可选 `recovery` 对象，包含 profile、dataBytes、payloadBytes、
volumeLimitBytes、dataVolumes、recoveryVolumes、requestedMode、requestedValue。
profile 1 不提供该对象；GUI 明确显示旧版固定配置。
