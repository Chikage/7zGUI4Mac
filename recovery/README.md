# 可恢复归档后端

命令行工具 `rz` 和 macOS 应用仅支持 **RZ 第 5 版（profile 5）**。创建归档默认使用 10 个数据卷和 2 个恢复卷，也可以显式传入 `--profile 5`。已有第 1 至第 4 版归档请用对应的旧版工具处理。

从 `rz 0.8.0` 起，默认输出为单个 `.rz` 容器文件，内含原有 profile 5 索引、数据卷及恢复卷。
新版本继续读取旧版目录归档；旧版本工具不能直接读取新容器。容器布局见 [单文件封装](docs/CONTAINER-V1.md)。

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

## 创建和使用

```sh
recovery/build/rz create input archive.rz
recovery/build/rz create-selected selected.rz --data-volumes 4 --recovery-volumes 2 -- file folder
recovery/build/rz list archive.rz --json
recovery/build/rz verify archive.rz
recovery/build/rz repair archive.rz repaired.rz
recovery/build/rz extract repaired.rz extracted
```

`--data-volumes K` 和 `--recovery-volumes M` 成对使用，要求 `1 ≤ M ≤ K ≤ 100`。输出文件必须位于输入目录之外，父目录须已存在。容器内的数据卷和恢复卷使用相同的物理大小，由压缩后的内容和索引共同决定。

容器将 `manifest.rzm`、`d000000.rzv` 等数据卷和 `p000000.rzr` 等恢复卷连续存储，首尾各有一份带校验的容器头。读取按偏移直接访问，无需先展开容器。只要容器布局可读取、其余卷完整且至少一份启动元数据可读取，损坏任意 M 个内部卷均可修复；整个容器文件丢失无法自行恢复。修复写入新的容器文件，发布前会重新打开并验证。

旧版目录仍可直接列出、验证、解压和修复。用 `rz repair 旧目录 新文件.rz` 可将其重建为新容器。需要独立分卷时，创建或修复命令可加 `--directory`：

```sh
rz create input legacy.rz --directory
rz repair archive.rz loose-volumes --directory
```

此模式生成目录，分卷必须保留原文件名并放在同一目录；可供旧版 profile 5 工具读取。

## 加密与文件属性

- 支持独立密钥文件：`--generate-key-file` 自动创建同目录 `.rzkey`，默认使用双层 AES 加密；
  list/extract 自动匹配同目录密钥，也可 `--key-file FILE` 手动指定。GUI 默认使用该模式，
  缺失时提示选择；需要保密时应将密钥和归档分开存放。详见 [密钥文件](docs/KEY-FILES.md)。

- GUI 可选择“密码”保护，同时加密内容、文件名和保存的属性。密码不进入命令行参数或偏好设置。
- 使用 XChaCha20-Poly1305 独立记录、Argon2id 密码派生、随机归档密钥及公开索引认证。
- 可选“双层加密”：XChaCha20-Poly1305 后增加 AES-256-GCM，主密钥也由两层包装；
  CLI 使用 `--encrypt --password-stdin --encryption dual`。创建和解锁需 AES 硬件支持，
  不支持时明确拒绝；密文修复仍无需密码或 AES。见 [套件 2](docs/ENCRYPTION-SUITE-2.md)。
- 未解锁时可查看公开恢复参数并修复密文；解密、查看目录和完整认证需要密码或匹配的密钥文件。
- 默认保存普通权限、时间、ACL、xattr、FinderInfo 和资源叉；可关闭保存或解压时跳过恢复。
- 所有者、特殊权限和受保护的系统属性按明确政策处理，无法还原时报告；内容成功解压不会因属性警告被丢弃。

## 容量与资源

- 原始内容和属性合计最多 1 TiB。每个归档最多 100,000 个条目，每条目属性最多 64 MiB，私有目录索引最多 16 MiB。
- 内容按最多 4 MiB 的独立 Zstd 帧压缩。数据和索引分别按 64 KiB 块进行 Reed–Solomon 编码。启动元数据最多 8 KiB，根表和分页摘要由恢复卷保护。小文件集也需要至少一个数据条带和一个索引条带。
- 仅保存普通文件和目录，包括空文件和空目录。硬链接按独立文件保存，源目录在创建期间应保持稳定。
- 创建默认使用 `--threads auto`，也可指定 1–64 个线程。压缩和恢复编码各使用 256 MiB 的有界工作池，最终分卷封装及完整存储扫描最多使用 4 路并行 IO。
- 暂存空间包含压缩流、分页摘要和分卷。容器组装以 1 MiB 缓冲逐卷复制，复制完成即删除该暂存卷，避免长期保留两套完整副本。发布前同步文件与目录，普通失败或取消会清理暂存目录。

## 退出码

| 退出码 | 含义 |
|---:|---|
| 0 | 操作成功 |
| 1 | 参数、格式、IO 或认证错误，卷集冲突，或修复失败 |
| 2 | 完整性验证发现可修复的损坏 |
| 3 | 完整性验证发现至少一个条带超出恢复预算 |
| 4 | 需要正确密码 |
| 5 | 解压内容已发布，部分属性未恢复 |
| 6 | 需要匹配的密钥文件 |

加密归档执行 `verify` 时，提供密码或 `--key-file` / `--auto-key-file` 可同时认证内容。无凭据时只执行存储校验。

## 进度与性能统计

创建时使用 `--progress` 可在 stderr 读取 `RZPROGRESS1` 进度及 `RZTIMING1` 阶段耗时。比较线程数和分卷配置可运行：

```sh
python3 recovery/benchmarks/parallel_recovery.py recovery/build/rz --output /tmp/rz-benchmark.json
```

`rz verify SET --progress` 与 `rz extract SET OUTPUT --json --progress` 支持读取进度。
进度写入 stderr，stdout 继续只包含原有结果（包括提取属性警告的 JSON）。默认不输出进度。
每条记录为制表符分隔的
`RZREADPROGRESS1 phase processed_bytes total_bytes completed_files total_files elapsed_ms`。
阶段为 `preparing`、`storage`、`checking`、`extracting`、`attributes`、`publishing`、`completed`。
`storage` 统计已检查的卷载荷块（包括分页索引记录），文件计数为 0；
`checking` / `extracting` 统计原始文件字节及非目录文件数，包括空文件。
每个可计量阶段重新计时和计数；属性恢复与发布阶段保留内容统计，不提供耗时百分比。
创建归档时启用 `--progress`，创建后的完整性校验也使用上述 `storage` / `checking`
记录报告实际处理量；创建流程仍以 `RZPROGRESS1 completed` 表示整个归档成功保存。
只在成功完成（或内容成功、属性有警告）时发送 `completed`；失败或取消不发送。
记录不含文件路径或凭据；多线程校验的更新串行化并按 200 ms 限流，阶段边界与首次处理即时发送。

## 实现文档

- [单文件容器布局](docs/CONTAINER-V1.md)
- [第 5 版磁盘布局](docs/FORMAT-V5.md)
- [算法与格式规范](docs/RZ-SPEC.md)
- [依赖来源、校验值和许可证](vendor/PROVENANCE.md)
- [本地验证记录](docs/VALIDATION.md)

自有代码沿用仓库根目录 LGPL-3.0 许可证。第三方代码保留各自许可证。
