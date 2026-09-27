# 可恢复归档后端

独立命令行后端 `rz`，使用 libzstd、BLAKE3 和 Jerasure/GF-Complete。
支持创建分卷、列目录、逐块验证、外置恢复卷修复、完整解压。
GUI 新建使用实验格式 `RZ profile 4` 等大分卷，兼容读取旧版 `profile 1/2/3`。
CLI 指定卷数或 `--profile 4` 使用新布局；不带卷数参数仍默认 profile 3，保留已有脚本行为。
该格式不兼容 RAR、7z 或 PAR2。
macOS GUI 的“新建压缩包 → 可恢复 RZ”已接入此后端，提供创建、浏览、测试、修复和解压。

## 构建和测试

需要 CMake 3.24+、支持 C++20 的编译器和 Python 3.9+（仅测试需要）。
支持 macOS / Linux 的 POSIX 文件 IO；本地验证平台为 Apple Silicon。
全部依赖源码已随仓库保存并固定 SHA-256，配置和构建不会访问网络。
加密使用随包静态编译的 libsodium；构建也需要系统 make（Xcode Command Line Tools 自带）。

```sh
cmake -S recovery -B recovery/build -DCMAKE_BUILD_TYPE=Release
cmake --build recovery/build --parallel 4
ctest --test-dir recovery/build --output-on-failure
recovery/build/rz --help
```

检查器构建（覆盖自有代码和依赖）：

```sh
cmake -S recovery -B recovery/build-sanitize \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo -DRZ_SANITIZE=ON
cmake --build recovery/build-sanitize --parallel 4
UBSAN_OPTIONS=halt_on_error=1 ctest --test-dir recovery/build-sanitize --output-on-failure
```

线程检查器使用独立构建目录，不能与 ASan 同时启用：

```sh
cmake -S recovery -B recovery/build-tsan \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo -DRZ_THREAD_SANITIZE=ON
cmake --build recovery/build-tsan --parallel 4
TSAN_OPTIONS=halt_on_error=1 ctest --test-dir recovery/build-tsan --output-on-failure
```

默认在 ARM64 编译 GF-Complete 的 NEON 后端。可用 `-DRZ_GF_NEON=OFF`
构建标量版本，或通过 `GF_COMPLETE_DISABLE_NEON=1` 在运行时选择标量路径。
两者使用同一磁盘格式，测试会对照独立 GF 算术实现并验证跨后端恢复。

## 密码加密与文件属性（profile 3/4）

- 支持独立密钥文件：`--generate-key-file` 自动创建同目录 `.rzkey`，默认使用双层 AES 加密；
  list/extract 自动匹配同目录密钥，也可 `--key-file FILE` 手动指定。GUI 默认使用该模式，
  缺失时提示选择；需要保密时应将密钥和归档分开存放。详见 [密钥文件](docs/KEY-FILES.md)。

- GUI 可选择“密码”保护，同时加密内容、文件名和保存的属性。密码不进入命令行参数或偏好设置。
- 使用 XChaCha20-Poly1305 独立记录、Argon2id 密码派生、随机归档密钥及公开索引认证。
- 可选“双层加密”：XChaCha20-Poly1305 后增加 AES-256-GCM，主密钥也由两层包装；
  CLI 使用 `--encrypt --password-stdin --encryption dual`。创建和解锁需 AES 硬件支持，
  不支持时明确拒绝；密文修复仍无需密码或 AES。见 [套件 2](docs/ENCRYPTION-SUITE-2.md)。
- 未解锁时可查看公开恢复参数并修复密文；解密、查看目录和完整认证需要密码。
- 默认保存普通权限、时间、ACL、xattr、FinderInfo 和资源叉；可关闭保存或解压时跳过恢复。
- 所有者、特殊权限和受保护的系统属性按明确政策处理，无法还原时报告；内容成功解压不会因属性警告被丢弃。
- 详细字段、恢复政策和安全边界见 [FORMAT-V3](docs/FORMAT-V3.md)。属性单条目限 64 MiB，私有索引限 16 MiB。

## 按数据卷与恢复卷数量创建（profile 4）

- `--data-volumes K --recovery-volumes M`：1 ≤ M ≤ K ≤ 100；`--profile 4` 默认 10+2。
- 恰好 K+M 个卷，所有卷最终文件大小相同；压缩/加密后按 64 KiB 块组成 K+M 条带并补齐尾部。
- 任意 M 卷丢失仍可恢复，前提是其余卷完整。每条带的数据/恢复块损坏数合计不得超过 M。
- 文件属性和私有索引与内容一起受到 RS 保护；公开索引在所有卷首尾及 sidecar 中复制。
  所有可定位公开索引均损坏时仍不能启动修复；独立密钥文件不包含在 RS 保护内。
- 每卷大小自动计算，不能同时指定卷大小上限、恢复比例或恢复容量。总内容和索引限制保持不变。
- 恢复池根据 K+M、条带数、CPU 和 256 MiB 缓冲预算限制 worker；auto 按每 1 MiB 编码工作量
  至多分配一个 worker，单条带只启动一个。分卷封装独立按卷数/工作量调度，最多 4 路并行 IO，
  不超过显式 `--threads N`。取消或失败先停止并等待 worker，再清理暂存目录。
- `list --json` 增加 `volumeSizeBytes`、`toleratedVolumeLosses`；旧字段 `volumeLimitBytes` 为 0（未设上限）。
  `RZTIMING1` 增加 `volume_write_workers`。详见 [FORMAT-V4](docs/FORMAT-V4.md)。

```sh
recovery/build/rz create input archive.rz --data-volumes 10 --recovery-volumes 2 --threads auto
recovery/build/rz create-selected archive.rz --data-volumes 4 --recovery-volumes 2 -- file folder
```

## 旧版按大小与恢复载荷创建（CLI profile 2/3）

- CLI 可指定每卷大小上限（1 MiB–16 GiB）。GUI 创建入口已改为卷数模式。
- 恢复载荷可按 **1%–100%** 输入，最多两位小数，或直接指定恢复数据容量。
- 百分比按补齐后的压缩数据计算。指定容量按 64 KiB 向上取整，至少为每个编码组提供一块，最多为数据载荷的 100%；不满足时提示本次归档的有效范围。
- 数据块与物理分卷分离。改变分卷大小不会改变编码组及恢复载荷预算。
- 小归档的实际比例可能因取整增加；GUI 归档详情和 `list --json` 都会显示实际载荷。
- 每组恢复能力分别计算，不能把百分比当作任意损坏分布或整卷丢失的保证。
- 新格式详细布局见 [FORMAT-V2](docs/FORMAT-V2.md)。旧版归档仍可验证、修复和解压。

```sh
recovery/build/rz create /path/to/input /path/to/archive.rz --volume-size 1.5MiB --recovery-percent 7.5
recovery/build/rz create /path/to/input /path/to/archive.rz --volume-size 1.25GiB --recovery-bytes 500MiB
```

## 多线程压缩

所有 profile 的创建命令默认使用 `--threads auto`，GUI 创建也自动启用。
可用 `--threads 1` 限制每个阶段为单个 worker，或用 `--threads N` 请求 1–64 个 worker。
profile 2/3/4 分别并行内容压缩和恢复码生成，两个线程池按阶段运行，不叠加使用。
实际数量受 CPU 数量（auto 模式）、任务数量及每阶段 256 MiB 的缓冲/上下文预算限制。
压缩 worker 按在途数据量启动。
小文件队列不足一个 4 MiB 帧的工作量时只启动一个 worker，避免按文件数量创建过多线程。
该预算不含索引、文件属性、线程栈和分配器开销，不是整个进程的 RSS 上限。

```sh
recovery/build/rz create /path/to/input /path/to/archive.rz --threads 4
```

每个 worker 复用独立 Zstd 上下文，按原有 4 MiB 独立帧、级别 3 压缩。
在途窗口最多为实际 worker 上限的两倍，排队、执行中及等待按序提交的结果一起计数。
文件摘要按原始字节顺序计算，记录偏移、加密、索引和临时流写入统一按原顺序提交。
不改变帧边界、压缩参数或磁盘格式；普通/双重加密均支持。加密创建时明文缓冲仅在内存中暂存，
成功、异常和取消都会清零任务中的原始数据及未加密压缩结果，worker 退出后才清理暂存目录。

恢复阶段按编码组并行读取临时流、生成 RS 恢复块及计算块摘要。每个 worker 独享 GF-Complete
上下文，所有上下文在启动线程前完成初始化；不调用含全局可变状态的 Jerasure 编码接口。
一组最多 100 个数据块和 100 个恢复块，块缓冲最多 12.5 MiB；队列把执行中和已完成未提交的组
一起计入预算，并按组号顺序写入分卷。线程数也受实际编码组数量限制，小归档不会启动空闲 worker。
保留现有 Cauchy 矩阵、GF(256)/0x11d、块摘要域和物理布局，旧版解码器可读取和修复新归档。

属性捕获/压缩、加密提交、分卷写入、封装和复验仍串行；profile 1 的恢复码生成以及所有 profile
的修复仍使用串行 Jerasure。普通异常或取消会停止派发任务，并在编码行边界停止其他 worker。
实际加速取决于这些阶段占比及磁盘吞吐，不承诺随核心数线性提升。

### 阶段统计与性能对照

profile 2/3/4 使用 `--progress` 时，成功创建后还会向 stderr 输出一行 `RZTIMING1\t{...}` JSON。
原有 `RZPROGRESS1` 字段和压缩速度语义保持不变，旧 GUI 会忽略新统计行。统计不包含路径、密码或内容。

- `packing_us`：内容压缩阶段及此前的属性处理/密钥准备、私有索引和布局计算；
  `compression_us` 是其中内容读取、摘要、压缩和提交的耗时。
- `recovery_wall_us`：恢复阶段实际耗时，包含上下文初始化、组任务和载荷写入。
- `read_work_us`、`rs_work_us`、`hash_work_us`：各 worker 的读取/分配、RS 运算、块摘要耗时之和；
  它们与写入可以重叠，不可相加当成实际耗时或 CPU 使用时间。
- `payload_write_us`：按序写入临时分卷载荷；`index_us`：最终索引认证/序列化；
  `volume_write_us`：最终分卷封装与同步；`verify_us`：存储复验；`publish_us`：原子发布；`total_us`：创建总耗时。
- `recovery_workers`、`recovery_peak_jobs`、`recovery_estimated_bytes`：恢复线程数、最多在途组数和预算估计。

可复现的本地对照脚本（128 MiB 日志/随机数据，1%/20%/100% 恢复比例，三次取中位数）：

```sh
python3 recovery/benchmarks/parallel_recovery.py recovery/build/rz --output /tmp/rz-benchmark.json
# 可选 --reference /path/to/previous/rz，对照上一版完整创建耗时。
```

## 使用

以一个目录作为输入；输出目录必须尚不存在，且不能位于输入目录内部。
输出的父目录需要已存在。

```sh
# 每个数据卷或恢复卷的实际文件大小不超过 64 MiB。
recovery/build/rz create /path/to/input /path/to/archive --volume-size 64MiB
recovery/build/rz list /path/to/archive
recovery/build/rz verify /path/to/archive

# 修复结果写到新的完整卷集，原卷保持原样。
recovery/build/rz repair /path/to/archive /path/to/repaired
recovery/build/rz extract /path/to/repaired /path/to/extracted

# GUI 使用的多选输入模式，保留相对于共同上级目录的路径，不复制源文件。
recovery/build/rz create-selected /path/to/archive.rz --volume-size 64MiB -- /path/to/file /path/to/folder
# 版本化 JSON 清单用于前端集成。
recovery/build/rz list /path/to/archive.rz --json
```

`--volume-size` 接受整数字节数、`MiB`、`GiB`，范围 1 MiB–16 GiB，支持最多三位小数。
卷尺寸包含头部和两份索引；扣除元数据后计算可用载荷，保证实际文件不超限。
`manifest.rzm` 是单独的索引副本，不是数据卷，不受此参数限制。

profile 2 卷集包含 `d000000.rzv` 等数据卷、`p000000.rzr` 等恢复卷和 `manifest.rzm`。卷数由实际载荷与上限计算。

旧版 profile 1 卷集示例：

```text
archive/
  manifest.rzm
  g000000.d00.rzv ... g000000.d09.rzv  # 第 0 组的十个数据卷
  g000000.p00.rzr ... g000000.p01.rzr  # 第 0 组的两个恢复卷
  g000001.d00.rzv ...                 # 超出一组时继续分组
```

请保留规范卷名，并将同一卷集的可用文件放在同一个目录。`list` 只验证和读取元数据；
`verify` 校验所有存储块和索引副本；`extract` 另外验证每个解压文件的完整 BLAKE3。
缺少恢复卷但所有数据块完好时可以直接解压。数据块损坏时应先运行 `repair`。

| `verify` 退出码 | 含义 |
|---|---|
| 0 | 所有卷、块和元数据副本完整 |
| 2 | 存在坏块或元数据副本缺损，仍可修复 |
| 3 | 至少一个编码组超过其恢复预算，无法完整修复 |
| 4 | 密码缺失或错误 |
| 5 | 文件内容已解压，部分属性未恢复（解压命令） |
| 1 | 参数、IO、格式错误、卷集冲突，或所有索引副本均不可用 |

除上述状态外，其他错误返回 1；错误原因输出到 stderr。
`verify` 未提供密码时仅校验存储数据，不能据此声称加密认证通过。

## 旧版 profile 1 的配置及恢复保证

- 每文件独立切成最多 4 MiB 的 Zstd frame，压缩级别 3；空文件不生成 frame。
- 压缩流顺序映射到各数据卷，按 64 KiB 存储块计算 BLAKE3 和纠删码。
- 每个编码组固定 10 个数据卷、2 个外置恢复卷，GF(256)，多项式 `0x11d`。
- 每条带取各卷相同块号，使用固定系统 Cauchy 矩阵。先哈希判坏，再按 erasure 解码。
- 每条带最多修复两个不可用块，数据块和校验块合计计算。其余块及必要元数据必须有效。
- 在这些条件下，每组任意两个整卷缺失都可重建。各组额度互不通用。
- 恢复之后逐块复验，并重新读取完整输出卷集验证，成功才发布结果。

20% 指相对于**补齐后的数据载荷**的 RS 校验开销，不代表任意分布的 20% 字节损坏可修复。
末组零填充、每卷至少一个条带、重复索引还会增加空间：即使空归档也会有 12 个卷。
每个数据卷与恢复卷首尾都保存完整索引；丢失 sidecar、首卷或部分卷头不会成为单点故障。
若所有索引副本都丢失，目前不能从压缩数据扫描重建文件树。

## 首版边界

- 保存相对 UTF-8 路径、目录、普通文件、内容及可选属性。保留空目录和空文件。
  拒绝符号链接、设备、FIFO 和危险路径；硬链接作为独立文件保存，稀疏布局不保留。
- 不支持数字签名、内嵌恢复记录、追加恢复卷、增量更新、单文件提取或重命名卷自动发现。
  BLAKE3 存储校验不代替密码认证；加密使用独立 AEAD 和 keyed BLAKE3 索引认证。
- 上限：原始内容与属性合计 64 GiB、100,000 个条目；公开/私有索引各限 16 MiB。profile 2/3 每种物理卷最多 65,536 个，profile 4 最多 100+100 个等大卷；profile 1 另限 4,096 个编码组。
  实际先到达哪项就受哪项限制。重复完整索引会限制大规模扩展，小卷装不下索引时会提示增大卷尺寸。
- 源目录在创建过程中应保持不变；首版没有文件系统快照语义。
- 临时空间包含压缩流、数据载荷和恢复载荷，再加分卷写入重叠与索引开销（profile 4 最多同时封装 4 卷）；恢复载荷越大，占用越多。
  内存按 frame / 条带处理，不加载整个归档；索引目前驻留内存。
- 写入先进入同一父目录下的私有 `.rz-stage-*`，文件和目录同步后以禁止覆盖的 rename 发布。
  普通失败和 SIGINT/SIGTERM 会清理；SIGKILL、断电可能留下未提交临时目录。
  尚未进行真实断电与介质故障实验。
- 单次创建的内容压缩和 profile 2/3/4 恢复码生成分别使用有界线程池；
  旧版编码与修复中的 Jerasure 全局状态仍只允许串行调用。

## 验证与实现入口

- [可配置格式 profile 2](docs/FORMAT-V2.md)
- [等大 K+M 分卷 profile 4](docs/FORMAT-V4.md)
- [加密与元数据 profile 3](docs/FORMAT-V3.md)
- [旧版格式 profile 1](docs/FORMAT.md)
- [本地验证记录](docs/VALIDATION.md)
- [依赖来源、校验值和许可证](vendor/PROVENANCE.md)
- `src/codec.*`：独立 frame、BLAKE3、RS 后端
- `src/compression_pool.*`：有界帧任务、每线程 Zstd 上下文、按序结果及失败/取消收束
- `src/recovery_pool.*`：独立 GF 上下文、有界编码组、并行读取/编码/块摘要及按序提交
- `src/creation_timing.hpp`：独立于原 GUI 进度协议的阶段耗时统计
- `src/configurable_*`：profile 2/3/4 参数、布局、校验和恢复
- `src/inputs.*`：两版共用的输入规划和独立 frame 压缩
- `src/format.*`：有界二进制序列化、严格路径和几何验证
- `src/archive.*`：创建、分卷、验证、修复、解压
- `src/io.*`：短 IO、取消、独占创建和原子发布
- `tests/`：编码黄金向量、元数据畸形输入、黑盒故障注入

自有代码沿用仓库根目录 LGPL-3.0 许可证。第三方代码保留各自许可证；
分发可执行文件时须一并提供相关声明和满足 LGPL 的对应源码要求。
