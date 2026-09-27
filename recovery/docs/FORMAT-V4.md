# RZ profile 4：等大 K+M 分卷

沿用 profile 3 的压缩记录、可选加密（含双层套件和独立密钥文件）、文件属性、私有索引、
BLAKE3 块校验和多份公开索引。profile 1/2/3 的读写保持兼容。此格式仍为实验格式。

## 布局和恢复保证

输入参数是数据卷数 K、恢复卷数 M，1 ≤ M ≤ K ≤ 100。块大小 B=65536。
S 为压缩、按需加密后的逻辑流长度，包含属性记录、文件内容和私有索引，不含公开索引。

```
T = max(1, ceil(S / (K * B)))
data_blocks = T * K
recovery_blocks = T * M
blocks_per_volume = T
```

每条带固定 K 个数据块和 M 个恢复块，最后一个条带的数据部分补零，真实长度由 S 保留。
全局数据块 b 写入数据卷 b%K 的槽 b/K；全局恢复块 r 写入恢复卷 r%M 的槽 r/M。
因此每个卷在每个条带恰好占一个块，所有卷载荷均为 T*B 字节。
RS 使用 profile 2 的系统 Cauchy GF(256)/0x11d 矩阵与稳定恢复行号，
块摘要继续使用 rz-block-v2 域，以条带号作为 group_id、组内列作为 shard_id。

每条带不可用块总数（数据和恢复块）≤M 时可恢复。因此任意 M 个物理卷缺失可恢复，
前提是其余卷和至少一份可定位公开索引完整。额外局部坏块与缺卷共同消耗预算；
其他条带的空闲预算不可借用，不承诺任意位置损坏 M/K 比例仍可恢复。

公开索引、卷头、卷尾等长，所以所有数据卷和恢复卷最终文件大小完全相同：
`2*120 + 2*L + T*65536`。manifest.rzm 和可选 .rzkey 是独立文件，不计入 K+M。
不再限制用户选择每卷大小；总内容上限和公开/私有索引 16 MiB 上限沿用旧版。
恢复比例 M/K 基于补齐后的数据载荷，不包含重复索引、卷头和尾部填充相对于原始流的额外开销。

## 二进制索引

全部整数小端。卷头/尾 magic 为 RZVOL004/RZEND004，版本为 4，其他字段和 120 字节长度沿用 profile 3。

```
magic[8] = RZIDX004
uuid[16]
profile:u32 = 4
block_size:u32 = 65536
frame_size:u32 = 4194304
requested_mode:u32 = 2
requested_value:u64 = 0
volume_size_limit:u64 = 0
data_volumes:u32 = K
recovery_volumes:u32 = M
blocks_per_volume:u32 = T
stream_size:u64 = S
data_blocks:u64 = T*K
recovery_blocks:u64 = T*M
group_count:u32 = T
repeat T:
    k:u32 = K
    m:u32 = M
    hashes[K+M][32]
security fields and private-index frame mapping  # 完整沿用 FORMAT-V3
```

K/M/T 在偏移 56/60/64，S/data_blocks/recovery_blocks 在 68/76/84，组数在 92，组表从 96 开始。
解析器从 K/M/S 重新推导 T、块数、每卷载荷与分组，并检查所有冗余字段一致。
拒绝旧版 profile 搭配 requested_mode=2、越界卷数、非零旧版预算参数、截断哈希及矛盾几何。
加密时公开索引 MAC 覆盖新增参数及全部条带哈希，沿用现有密钥包装和记录认证定义。

## 调度与 CLI

`--data-volumes K --recovery-volumes M` 必须一起提供，并选择 profile 4；不能混用旧 profile、
`--volume-size`、`--recovery-percent` 或 `--recovery-bytes`。`--profile 4` 不带卷数时默认 10+2。
不带卷数的新建 CLI 仍默认 profile 3，GUI 总是显式传递两项卷数。

压缩池按文件帧和在途字节数调度。恢复池按条带并行，每个 worker 独占 GF 上下文；
上下文在启动线程前串行初始化。worker 数受请求值（auto 为 CPU 并发数）、64 上限、T、
K+M 对应的块缓冲和 256 MiB 预算限制；auto 进一步按每 1 MiB 编码工作量至多分配一个 worker。
在途任务最多为两倍 worker 数且不超过 T，完成任务仍计入预算，提交者按条带序号顺序写出。

分卷封装阶段按 K+M、请求线程数、编码载荷工作量选择 1–4 个 worker。每个任务独占一个输出卷，
只同时打开源载荷和目标卷，复制缓冲为 64 KiB。异常停止派发，并等待 worker 退出后清理暂存目录。
各阶段依次执行，完整卷集复验成功后才发布。内存预算不包含索引、文件属性、线程栈和分配器。

list JSON 保留 version=1，recovery 中 profile=4、requestedMode=2、requestedValue=0、volumeLimitBytes=0，
并提供 volumeSizeBytes（含全部封装的精确每卷大小）与 toleratedVolumeLosses=M。
RZTIMING1 保留原统计，增加 volume_write_workers。
