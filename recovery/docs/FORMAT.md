# RZ v1，profile 1

本文件定义实验性第一阶段格式。对外稳定承诺前应完成独立实现互操作审查。
所有整数均为无符号小端；UUID 是随机 16 字节；摘要是完整 32 字节 BLAKE3。
禁止把 C/C++ 结构体内存布局直接写入文件。未知 magic / profile 必须拒绝。

## 压缩及编码

目录条目按相对 UTF-8 路径的字节序排序。普通文件依次按 4 MiB 原始数据切分，
末 frame 可以更短；空文件不产生 frame。每个 frame 是单独的标准 Zstd frame，
不使用共享字典，包含明确的原始大小。压缩级别 3 是当前写入器策略，不是读取限制。
各 frame 字节依次连接成为长度 `stream_size` 的逻辑压缩流。

每组包含 10 个数据 shard、2 个 parity shard。一个 shard 对应一个卷，
其载荷长度均为 `stripes * 65536`。组内逻辑数据依次填入 d00、d01 … d09，
末尾不足补零。组的 `valid` 是未补齐的压缩流长度，组之间顺序衔接。
每组 `stripes = max(1, ceil(valid / (10 * 65536)))`。空压缩流使用一个全零条带组。

对每个块号独立编码，有限域 GF(2^8)，定义多项式 `x^8+x^4+x^3+x^2+1` (`0x11d`)。
系统生成矩阵上半为 10×10 单位矩阵，下半为 2×10 Cauchy 矩阵：

```text
A[r,c] = inverse_GF256(r XOR (2+c))
r = 0,1; c = 0..9
P[r][byte] = XOR(c=0..9, multiply_GF256(A[r,c], D[c][byte]))
```

域元素就是单字节，不使用 ALTMAP 或依赖内存对齐的磁盘表示。
profile 1 不允许改变 k、m、矩阵或追加新的校验行。

每块摘要按以下字节串计算，包括整个 65536 字节载荷及零填充：

```text
BLAKE3(ASCII("rz-block-v1") || UUID[16] ||
       LE32(group_id) || LE32(shard_id) || LE32(stripe_id) || payload[65536])
```

data shard ID 为 0..9，parity 为 10..11。文件最终摘要为普通 BLAKE3(原始文件内容)。
目录和空文件摘要均为 BLAKE3(空串)。

## 卷文件

```text
Header[120] | Manifest[L] | Payload[P] | Manifest[L] | Footer[120]
```

Header 和 Footer 字段相同，magic 不同。相同块号在不同卷中的物理偏移相同。
载荷起点为 `120+L`，第二份索引起点为 `120+L+P`。

| 偏移 | 长度 | 含义 |
|---|---|---|
| 0 | 8 | Header `RZVOL001` / Footer `RZEND001` |
| 8 | 4 | 版本，固定 1 |
| 12 | 4 | 0=data，1=parity |
| 16 | 16 | 归档 UUID |
| 32 | 4 | group ID，从 0 开始 |
| 36 | 4 | shard ID，0..11 |
| 40 | 8 | L，完整 manifest 字节数 |
| 48 | 8 | P，载荷字节数 |
| 56 | 32 | BLAKE3(Manifest) |
| 88 | 32 | BLAKE3(该头部前 88 字节) |

数据卷命名 `gNNNNNN.dSS.rzv`，恢复卷命名 `gNNNNNN.pSS.rzr`。
文件名中的 parity 序号 00/01 对应 shard ID 10/11。第一阶段要求规范文件名。
卷头、文件名、索引身份冲突必须报错，不能以多数投票静默选择另一个归档。

额外的 `manifest.rzm` 保存 `Manifest || BLAKE3(Manifest)`。
每卷都携带完整索引，所以该 sidecar 可丢失；它的缺失仍算完整性降级。

## Manifest

字段顺序：

```text
magic[8] = "RZIDX001"
uuid[16]
profile:u32 = 1
block_size:u32 = 65536
frame_size:u32 = 4194304
k:u32 = 10
m:u32 = 2
stream_size:u64
group_count:u32
repeat group_count:
    stripes:u32
    valid:u64
    hashes[12 * stripes][32]       # shard-major，然后 stripe 号
entry_count:u32
repeat entry_count:
    kind:u32                      # 0=file，1=directory
    path_length:u32
    path[path_length]             # 无 NUL 的相对 UTF-8 路径
    original_size:u64
    original_digest[32]
    frame_count:u32
    repeat frame_count:
        stream_offset:u64
        compressed_size:u32
        original_size:u32
```

解析器必须验证所有长度、计数、总和及 frame 的连续映射，不能接受尾随字节。
文件 frame 的总原始大小必须等于文件大小；所有组有效长度、所有 frame 压缩长度
都必须等于 `stream_size`。要求路径唯一且排序，父目录必须先出现，禁止文件充当父目录。
路径不能含绝对前缀、空组件、`.`、`..`、反斜杠、冒号、ASCII 控制字符或非法 UTF-8。

## 修复顺序

1. 在 sidecar、各卷头尾可定位的索引副本中寻找一份通过 BLAKE3 和结构检查的索引。
2. 检查所有可读卷头的身份、索引摘要和几何参数，无冲突才能继续。
3. 根据索引与规范文件名定位各载荷。即使某卷头尾都损坏，只要其他索引副本有效，仍可校验它的载荷。
4. 哈希不符、缺卷或读取不足均按整个 64 KiB 块不可用处理。截断不改变其他块的位置。
5. 逐条带统计数据和 parity 的不可用块，总数超过 2 时完整修复失败。
6. Jerasure 按 erasure 列表重建，逐块与索引摘要核对，再写到新的完整卷集。
7. 输出卷集全部重新读取校验通过后，同步并发布。任何失败不发布部分成功结果。

哈希不能证明来源真实性。插入/删除字节造成后续载荷错位时，首版按错位后的块损坏处理，
不执行滚动哈希重同步。所有索引副本失效时不能恢复，即使 RS 载荷还有足够冗余。
