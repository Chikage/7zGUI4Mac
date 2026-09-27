# RZ 算法、磁盘格式与兼容性维护规范

本文记录 **2026-09-27 工作区实现**的 RZ 格式，供实现读取器、定位损坏、优化性能及后续版本迭代参考。最新容器为 **profile 5**。本文完整定义其分页摘要索引、受恢复码保护的索引区、冗余启动元数据及 1 TiB 内容上限，并保留 profile 1–4 的字节布局与兼容性约束。Profile 5 的磁盘定义从 [第 6.6 节](#66-profile-5-几何与物理布局) 开始，专项说明另见 [FORMAT-V5.md](FORMAT-V5.md)。

本文不是某个上游 `.rz` 格式的说明：本项目 RZ 是自定义可恢复归档，不能当作 RAR、7z、PAR2 或其他同扩展名格式读取。当前仍标记为实验格式。

**维护约定：已有编号对应的字节语义必须保留。新读取器继续读取已有合法归档；新功能不得在原编号下悄悄改写算法。** 第 12–13 节是后续变更的审查及验证要求；文档本身不会自动阻止不兼容代码合入，现有测试与尚待补齐的保障在第 13 节分别列明。

## 目录

1. [版本与实现基线](#1-版本与实现基线)
2. [术语、编码约定与处理流水线](#2-术语编码约定与处理流水线)
3. [输入规划与压缩算法](#3-输入规划与压缩算法)
4. [校验、纠删码及恢复保证](#4-校验纠删码及恢复保证)
5. [加密、密钥派生与密钥文件](#5-加密密钥派生与密钥文件)
6. [profile 4 与 profile 5 分卷和索引](#6-profile-4-与-profile-5-分卷和索引)（[Profile 5 入口](#66-profile-5-几何与物理布局)）
7. [私有索引、条目与文件属性](#7-私有索引条目与文件属性)
8. [读取、验证、修复和解压](#8-读取验证修复和解压)
9. [版本差异与旧版兼容规则](#9-版本差异与旧版兼容规则)
10. [并行处理、资源限制与发布](#10-并行处理资源限制与发布)
11. [CLI 与前端协议](#11-cli-与前端协议)
12. [版本迭代规则](#12-版本迭代规则)
13. [兼容性验证与发布检查表](#13-兼容性验证与发布检查表)
14. [实现导航与文档维护](#14-实现导航与文档维护)

## 1. 版本与实现基线

### 1.1 不同层的版本必须分开理解

| 层 | 当前值 | 作用 |
|---|---|---|
| CLI 展示版本 | `rz 0.7.0`，见 `main.cpp::usage` | 程序发布标识，不参与文件解析 |
| CMake 工程版本 | `0.7.0` | 与 CLI 同步；不能单凭程序版本判断归档格式 |
| 容器 / 编码 profile | 最新 `5`，支持 `1/2/3/4/5` | 决定公开索引、卷头、编码几何与映射 |
| 加密套件 `crypto_suite` | `1` 或 `2` | 仅加密归档存储此字段；JSON 的 `0` 表示未加密 |
| 私有索引 | `RZPRI003` | profile 3、4、5 共用；profile 升级不意味着所有 magic 同步升级 |
| 属性记录 | `RZMET001` | 与容器版本独立 |
| 外置密钥文件 | `RZKEY001` | 与加密套件独立 |
| JSON / 能力查询 / 统计 | `version=1` | 与磁盘 profile 无关 |
| 进度与统计前缀 | `RZPROGRESS1`、`RZTIMING1` | stderr 中供 GUI 解析的独立协议 |

基线来自当前源文件，包含尚未提交的工作区代码；不能仅凭仓库已有 Git HEAD 重建此基线。归档版本必须由 magic、profile 和功能字段共同识别，不能依据扩展名、GUI 版本或 CMake 版本猜测。

### 1.2 当前创建默认值

| 创建方式 | 容器与保护策略 |
|---|---|
| CLI 不带卷数参数、不显式指定 profile | profile 3；64 MiB 卷大小上限；20% 恢复载荷；保存属性；默认不加密 |
| CLI `--profile 4` | profile 4；默认 `K=10, M=2`；保存属性；默认不加密 |
| CLI 同时指定 K/M，未显式指定 profile | 选择 profile 4；与 `--profile 5` 同用时选择 profile 5 |
| CLI 密码加密，未指定套件 | suite 1，`standard` |
| CLI `--generate-key-file`，未指定套件 | suite 2，`dual` |
| CLI `--profile 5` | profile 5；默认 10+2；分页索引；内容上限 1 TiB |
| macOS GUI 新建 RZ | 显式传入 profile 5 和 K/M，默认 10+2；默认自动生成密钥文件及双层加密，可改选 |

“最新支持 profile 5”不等于“无参数 CLI 默认写 profile 5”。保留 CLI 的 profile 3 默认是已有脚本的兼容契约。

### 1.3 固定依赖

| 组件 | 基线版本 / revision | 用途 |
|---|---|---|
| Zstd | 1.5.7 | 独立帧压缩 |
| BLAKE3 | 1.8.2 | 内容、存储块与结构摘要；加密索引 MAC |
| libsodium | 1.0.22 | Argon2id、BLAKE2b KDF、XChaCha20-Poly1305、AES-GCM、随机数和秘密内存 |
| Jerasure | `de1739cc8483696506829b52e7fda4f6bb195e6a` | 串行恢复、profile 1 编码 |
| GF-Complete | `a6862d10c9db467148f20eef2c6445ac9afd94d8` | GF(256) 运算及独立并行编码上下文 |

源码归档及 SHA-256 见 [依赖来源](../vendor/PROVENANCE.md)；CMake 从本地归档构建。Zstd 内部多线程关闭，多核压缩由本项目按独立帧调度。更换依赖版本不能自动视为格式兼容，仍须执行第 13 节的互操作验证。

## 2. 术语、编码约定与处理流水线

### 2.1 字节约定

- `u32/u64` 分别是 4/8 字节**无符号小端整数**；`LE32/LE64` 表示同样的序列化。时间的秒字段例外地按二补码有符号值解释，见第 7 节。
- `X[n]` 是恰好 n 个原始字节；`||` 是字节连接；文本长度按字节计算。
- 所有 magic 均为 8 个 ASCII 字节，不带结尾 NUL。本文列出的哈希域和 AAD 文本同样不带 NUL。
- UUID 是 16 个随机字节，不是文本 UUID；摘要为完整 32 字节，磁盘上不是十六进制字符串。
- 不直接序列化 C++ 结构体，不能依赖 ABI、对齐或宿主字节序。
- MiB=`2^20` 字节、GiB=`2^30` 字节。取整必须使用整数运算；向上除法可写为 `a/b + (a%b != 0)`，避免 `a+b-1` 溢出。

### 2.2 逻辑记录、存储块与物理卷

| 名称 | 大小 / 含义 |
|---|---|
| frame / 内容记录 | 最多 4 MiB 原始字节的独立压缩帧；加密时包含 nonce、密文和 tag |
| block / shard | 固定 64 KiB 存储块，是哈希判坏及 RS 擦除的最小单位 |
| profile 5 块记录 | 固定 65568 字节：64 KiB 载荷及 32 字节局部摘要；不是上面的可变长内容记录 |
| volume | 一个物理 `.rzv` 或 `.rzr` 文件，包含索引或启动副本、载荷及头尾 |

记录可以跨块、跨卷、跨条带。读取记录必须先恢复逻辑流顺序，不能直接对一个物理数据卷运行 Zstd 解压。

### 2.3 profile 3/4 的创建顺序

```text
扫描输入、相对路径排序
  ├─ 按条目顺序捕获属性 → 属性序列化 → 切帧 → Zstd → 可选 AEAD
  ├─ 按条目顺序读取文件 → 内容切帧   → Zstd → 可选 AEAD
  └─ 序列化私有索引               → 切帧 → Zstd → 可选 AEAD
                  ↓ 顺序连接
逻辑存储流 S = [全部属性记录][全部内容记录][私有索引记录]
                  ↓ 切成 64 KiB 数据块，尾部补零
按条带生成 RS 恢复块 → 计算存储摘要 → 按序直接写最终暂存卷载荷
                  ↓
生成公开索引 → 加密时计算公开索引 MAC → 普通 BLAKE3 摘要
                  ↓
回填卷首尾索引和头尾 → 写 sidecar → 完整复验 → 发布
```

RS 作用于**最终存储字节**：加密时包括密文、nonce 和认证标签。填充零在记录加密之后添加。profile 3/4 的公开索引和卷头尾不进入 RS；私有索引和属性记录进入 RS。

### 2.4 profile 5 的创建顺序

```text
属性记录 + 内容记录 + 私有目录记录 → 压缩/可选加密逻辑流
    ↓ 64 KiB 分块、K+M 编码
内容块及恢复块 → 直接写暂存卷，每块附局部摘要
    ↓ 按条带顺序汇集所有内容区摘要
64 KiB 摘要叶页 → 各叶页 BLAKE3 → 根表
    ↓ 叶页 + 根表作为独立索引流，按相同 K+M 编码
索引数据块及恢复块 → 追加到各暂存卷，每块附独立域的局部摘要
    ↓ 计算每卷整个索引区摘要
bootstrap（根摘要、索引卷摘要、几何、密钥槽）→ 可选 MAC
    ↓ 回填各卷首尾 bootstrap/头尾，写 sidecar
重新打开产物、完整复验 → 同步 → 禁止覆盖地发布
```

摘要叶页和根表进入 RS；bootstrap 和卷头尾通过复制冗余保护。块记录末尾的 32 字节局部摘要不作为 RS 载荷，RS 仍只编码每块的 64 KiB。

## 3. 输入规划与压缩算法

### 3.1 路径与条目

仅接受目录、普通文件，保存空目录和空文件；符号链接、设备、FIFO 等拒绝。硬链接按独立文件归档，不保存稀疏布局。

`create` 保存输入目录内的条目，不把输入根目录本身当成条目；`create-selected` 基于共同上级目录生成相对路径，去重重复选择和已被选中父目录覆盖的子项，并补入必要父目录。

条目按相对 UTF-8 路径字节序严格递增。路径长 1–4096 字节，不能包含绝对路径、空组件、`.`、`..`、反斜杠、冒号、ASCII 控制字符、DEL 或非法 UTF-8。父目录必须已存在于先前条目，普通文件不能充当父目录。不做 Unicode 规范化或大小写折叠；目标文件系统出现名称碰撞时不能合并或覆盖。

### 3.2 分帧与 Zstd

设文件原始长度为 `Q`，`F=4,194,304`：

```text
frame_count = ceil(Q / F)         # Q=0 时为 0
plain_i = min(F, Q - i*F)
compressed_i = Zstd.compress(original_i, level=3)
```

每帧为独立标准 Zstd frame，不共享字典，不跨文件建立 solid 压缩状态。每个非末帧原始长度必须恰好为 F；空文件没有零长度 frame。文件 BLAKE3 按**完整原始内容顺序**增量计算，不能改为连接各帧摘要。

属性字节串、私有索引也按 F 切帧。内容帧可并行压缩，属性和私有索引当前串行压缩。压缩级别 3 是当前写入策略；读取器并不检查压缩级别。

### 3.3 记录长度与严格解码

索引中的每个 `Frame` 为 16 字节：

```text
offset:u64       # 相对于逻辑存储流起点；不是卷内文件偏移
stored:u32       # 完整记录长度；加密时包含所有 nonce 和 tag
plain:u32        # 解压后的原始长度
```

当前一般映射检查要求 `0 < plain <= F`、`0 < stored <= F+floor(F/100)`，后者为 **4,236,247** 字节。加密记录还须满足套件开销和 AEAD 检查。

解密后 / 未加密时，`decompress_frame` 同时要求：

1. 原始长度在 `1..F`，压缩输入不超过 `ZSTD_compressBound(F)`。
2. `ZSTD_findFrameCompressedSize(bytes) == bytes.size()`，记录必须恰好是一个帧，不能拼接额外帧或尾随字节。
3. `ZSTD_getFrameContentSize(bytes) == plain`，原始大小必须明确且与索引一致。
4. 解压成功且返回字节数等于 `plain`。

当前 profile 没有可替换的压缩算法 ID。将 Zstd 换成其他算法、引入外部字典或改变独立帧语义，需要新的格式契约。只调整 Zstd 级别也必须确认结果仍满足旧读取器的帧和长度限制。

## 4. 校验、纠删码及恢复保证

### 4.1 BLAKE3 校验层次

| 对象 | 摘要输入 / 作用 |
|---|---|
| 原始文件 | `BLAKE3(全部原始文件内容)`；目录、空文件使用空串摘要 |
| 属性 | `BLAKE3(RZMET001 完整原始字节串)`，摘要保存在私有索引 |
| 数据块、恢复块 | 下述带域及身份的块摘要，覆盖整个 64 KiB，包括零填充 |
| 公开索引 | `BLAKE3(完整公开索引字节串)`，含最终 public_mac |
| 卷头 / 卷尾 | `BLAKE3(该头 / 尾前 88 字节)` |
| 密钥文件 | `BLAKE3(前 56 字节)` |
| profile 5 摘要叶页 / 根表 | 各自完整字节的 BLAKE3；根表保存叶页摘要，bootstrap 保存根摘要 |
| profile 5 索引块 | 独立域、UUID、索引条带号、列号和 64 KiB 载荷 |
| profile 5 索引卷整体 | 同一卷索引区全部 `payload || local_digest` 的连续 BLAKE3 |
| 加密公开索引 / bootstrap MAC | keyed BLAKE3，见第 5 节；与普通摘要不能混用 |

profile 2/3/4 的存储块，以及 profile 5 **内容区**的数据块和恢复块，摘要固定为：

```text
BLAKE3(
    ASCII("rz-block-v2") || UUID[16]
    || LE32(group_id) || LE32(shard_id)
    || block[65536]
)
```

profile 4 和 profile 5 内容区中，`group_id` 就是从 0 起的条带号 `t`，数据 `shard_id=0..K-1`，恢复 `shard_id=K..K+M-1`。这里**没有额外 stripe_id**，也不能另改域名。profile 5 索引区使用独立的 `rz5-index-block` 域，定义见第 6.8 节。

普通 BLAKE3 用于发现损坏及定位擦除，不能证明来源真实性。攻击者能重新计算未加密归档的摘要。加密归档通过密钥包装、公开索引 MAC 和记录 AEAD 获得认证；无凭据修复只能提供存储一致性。

### 4.2 profile 4/5 的系统 Cauchy Reed–Solomon

固定域为 `GF(2^8)`，不可约多项式为：

```text
x^8 + x^4 + x^3 + x^2 + 1  =  0x11d
```

每个磁盘字节直接表示一个域元素。域加法为 XOR，域乘法为二进制多项式乘法后模 `0x11d` 约减。移位乘法实现中最高位溢出时 XOR `0x1d`；非零元素逆元可用 `x^254` 或等价域算法计算。不能替换成 AES 常见的 `0x11b`。

参数 `1 <= M <= K <= 100`。系统生成矩阵为 `[I_K; A]`，其中：

```text
A[r,c] = inverse_GF256((128+r) XOR c)
         r = 0..M-1，c = 0..K-1

P[t,r][j] = XOR(c=0..K-1,
                  multiply_GF256(A[r,c], D[t,c][j]))
         j = 0..65535
```

数据列域元素 `0..99` 与恢复行域元素 `128..227` 在当前允许范围内不相交，分母非零。底层编码器可构造更多行，但容器当前仍强制 `M<=K<=100`。增减 M 不改变已有恢复行的系数；不能把恢复行重排成其他“等价 RS”矩阵。

恢复时从存活 shard 对应的生成矩阵行中取 K 行，求逆并恢复数据，进而重建恢复块。实际由 Jerasure 擦除解码完成。`jerasure_matrix_decode` 的 `row_k_ones` 必须为 **0**：此 Cauchy 矩阵首个恢复行并非全 1，不能使用该快捷假设。

### 4.3 从损坏检测到擦除恢复

对每个条带的 K+M 个块，读取不足、缺卷或摘要不匹配均视为整块不可用；一个字节损坏也消耗一个块的额度。设条带 t 的不可用块数为 `e_t`：

```text
所有条带 e_t <= M  →  在有效公开索引和其他块完整的前提下可重建
任一条带 e_t > M   →  当前修复器拒绝完整修复
```

系统先哈希判坏，再把已知位置传给 erasure 解码器；不进行未知错误位置的盲纠错，也不尝试滚动重同步插入 / 删除的字节。

profile 4 每卷每条带恰好一个块，因此**任意 M 个整卷丢失可恢复**，条件是其余卷完整且至少一份公开索引仍可定位、可校验。额外局部损坏与缺卷共同消耗同一条带的 M 额度，不能借用其他条带的剩余额度。

profile 5 在内容区与索引区分别应用相同 K+M 几何；任意 M 整卷丢失的保证要求剩余卷完整且至少一份 bootstrap 可定位、可校验。索引区先恢复，再恢复内容区，具体认证与擦除判断见第 6.9–6.10 节。

例如 10+2 缺少两个数据卷后，第三卷任一条带再坏一块，就有该条带三块不可用；“20% 恢复载荷”不能保证恢复这种损坏。仅缺恢复卷且所有数据块完整时，可以直接解压；完整修复仍按上述总擦除数判断。

## 5. 加密、密钥派生与密钥文件

### 5.1 保护范围与记录身份

| `kind` | 记录 |
|---|---|
| 1 | 文件内容 |
| 2 | 文件 / 目录属性 |
| 3 | 私有索引，含文件名、目录结构、原始摘要及记录映射 |

未加密时记录为裸 Zstd frame；“私有索引”这个名称本身不表示保密。启用加密后同时保护上述三类记录，不存在只加密内容却公开文件名的当前模式。

公开信息仍包括 UUID、卷数、块哈希、逻辑流大小、私有索引原始大小及帧映射、套件、KDF 参数、盐和加密 / 属性标志。双层加密不隐藏这些结构信息，也不提供数字签名或防回滚。

### 5.2 凭据到包装根密钥

**密码模式：**

```text
KEK = Argon2id13(password_bytes, salt[16], output=32,
                t=3, m=65536 KiB, p=1)
```

使用 `crypto_pwhash_ALG_ARGON2ID13`，`opslimit=3`、`memlimit=67,108,864` 字节，不能改用可随库版本变化的默认算法编号。读取器在运行 KDF 前检查固定成本值，不接受任意成本参数。

CLI 从 stdin 读取一行至 LF 或 EOF，非空且最多 1024 字节；拒绝 ASCII `<32` 和 DEL，所以 CRLF 的 CR 也不会被静默剥除。按原始字节使用密码，不做 Unicode 规范化；CLI 的该函数不额外验证 UTF-8 编码合法性。GUI 输入是 UTF-8。密码不得写进 argv、偏好设置或日志。

**独立密钥文件模式：**随机生成 32 字节高熵 `secret`，不使用密码或 Argon2id：

```text
KEK = BLAKE2b-256(
    key = secret[32],
    message = ASCII("rz-keyfile-kek-v1") || UUID[16] || salt[16]
)
```

此时成本字段严格为 0。两种凭据来源不能互换；密钥文件 UUID 必须与归档匹配。两种模式的盐均为每归档新生成的随机 16 字节。

### 5.3 suite 1：XChaCha20-Poly1305-IETF

每次新建归档生成独立随机 32 字节主密钥 `Mx`，再由 KEK 包装它。子密钥定义为 libsodium 的 BLAKE2b KDF：

```text
subkey[id] = crypto_kdf_blake2b_derive_from_key(
    output=32, subkey_id=id, context="RZ3KEYS!", master=Mx)

id=1 内容；id=2 属性；id=3 私有索引；id=4 公开索引 MAC
```

context 是精确 8 字节。不能用普通 `BLAKE2b(master || id)` 替代此 KDF 接口的定义。

主密钥包装使用随机 24 字节 nonce，输出 `wrapped_master_key[48] = ciphertext[32] || tag[16]`。nonce 单独存入公开密钥槽。包装 AAD 为：

```text
ASCII("rz3-keyslot") || UUID[16] || LE32(1)
|| LE64(opslimit) || LE64(memlimit) || salt[16]
|| [ASCII("rz-keyfile-v1")，仅密钥文件模式追加]
```

记录使用与 kind 对应的子密钥，nonce 为独立随机 24 字节：

```text
record = nonce[24] || ciphertext[compressed_length] || tag[16]
stored = compressed_length + 40

AAD = ASCII("rz3-record") || UUID[16] || LE32(kind)
      || LE64(stream_offset) || LE32(original_size)
```

suite 1 的记录 AAD **不附加 suite 或 layer 字段**，不能为了与 suite 2 统一而修改旧布局。

### 5.4 suite 2：XChaCha 后再 AES-256-GCM

每次创建随机生成 64 字节主密钥材料，分为 `Mx[32] || Ma[32]`：

| 用途 | 派生定义 |
|---|---|
| 内层记录密钥 | `KDF(Mx, context="RZ3DUAL!", id=kind)` |
| 外层记录根密钥 | `KDF(Ma, context="RZ3AES2!", id=kind)` |
| 每记录 AES 密钥 | `KDF(外层记录根密钥, context="RZ3REC2!", id=stream_offset)` |
| 包装内层密钥 `Kx` | `KDF(KEK, context="RZ3WRAP!", id=1)` |
| 包装外层密钥 `Ka` | `KDF(KEK, context="RZ3WRAP!", id=2)` |
| 公开索引 MAC 密钥 | `BLAKE2b-256(key=Mx||Ma, message=ASCII("rz3-dual-manifest-key"))` |

表中 KDF 均为上述 libsodium KDF，输出 32 字节。两层使用同一份用户凭据派生的 KEK，但各层用途密钥不同。

**主密钥包装：**

```text
inner = XChaCha_AEAD(Kx, random_nonce[24], plaintext=Mx||Ma, aad_layer_1)
        # 64 字节明文 + 16 字节 tag = 80 字节
wrapped = AES256GCM_AEAD(Ka, random_nonce[12], plaintext=inner, aad_layer_2)
          # 80 + 16 = 96 字节
```

两个包装 nonce 独立存入公开密钥槽，不能把任何一份明文主密钥留在公开索引。每层包装 AAD 为：

```text
ASCII("rz3-keyslot") || UUID[16] || LE32(2)
|| LE64(opslimit) || LE64(memlimit) || salt[16] || LE32(layer)
|| [ASCII("rz-keyfile-v1")，仅密钥文件模式追加]
```

`layer=1` 为内层，`layer=2` 为外层；密钥文件后缀在 layer **之后**。

**记录加密：**

```text
inner = random_xchacha_nonce[24] || XChaCha_ciphertext || XChaCha_tag[16]
aes_nonce = LE32(kind) || LE64(stream_offset)          # 12 字节
record = aes_nonce || AES_ciphertext(inner) || AES_tag[16]
stored = compressed_length + 68

AAD_layer = ASCII("rz3-record") || UUID[16] || LE32(kind)
            || LE64(stream_offset) || LE32(original_size)
            || LE32(2) || LE32(layer)
```

外层同时加密内层 nonce、密文和 tag。每记录派生独立 AES 密钥，该密钥仅用于这一条记录；包装 AES 密钥也只包装一次。记录原始数据上限为 4 MiB，压缩及内层开销另计。

写入器要求 suite 2 记录范围向前推进，下一记录 offset 不小于上一记录末尾，拒绝重叠 / 重用位置。归档解锁得到的 `ArchiveKeys` 只读，不能用于 seal。读取时先检查 AES nonce 与 kind/offset 完全一致，认证外层，再认证内层，最后解压。不得先向最终输出发布未经认证的明文。

创建和解锁 suite 2 要求 libsodium AES-GCM 硬件能力检测通过；不支持时拒绝，不能降级成 suite 1。读取公开摘要、存储校验和密文修复不要求 AES 或凭据。双层不增加弱密码的熵，也不能替代密钥备份；此自定义组合尚无独立密码协议审计。

### 5.5 公开索引认证的精确顺序

profile 3/4 的规范化输入为完整公开索引：

```text
canonical = serialize(public_manifest with public_mac = 32 zero bytes)
public_mac = keyed_BLAKE3(mac_key,
                         ASCII("rz3-public-index") || canonical)
final_manifest = serialize(public_manifest with public_mac filled)
manifest_digest = BLAKE3(final_manifest)
```

profile 3/4 的 MAC 直接覆盖几何、全部块摘要、私有索引位置、功能标志及密钥槽。

profile 5 保留相同的 MAC 算法、密钥派生和 `rz3-public-index` 域，但规范化输入改为第 6.7 节的**整个 bootstrap**，仅将其中 `public_mac[32]` 置零。输入包含根表摘要及末尾所有索引卷整体摘要；内容块摘要通过根表和叶页间接绑定。必须使用 `serialize_bootstrap`，不能用旧公开索引的序列化器代替。

读取时解开主密钥后先重算并常量时间比较对应版本的 MAC，通过后才加载私有索引。profile 5 复用既有 suite 1/2 的记录 AAD、nonce、密钥包装和 KDF 参数；只在明确的 profile 5 创建路径放宽记录偏移上限至 `1 TiB+floor(1 TiB/100)`，旧路径保持 64 GiB 基准。

规范化由当前 profile 的固定字段序列定义，不存在任意顺序字段或可忽略扩展字节。序列化顺序、字段宽度、默认值或尾随数据处理的改变，都会影响认证。

### 5.6 外置 `.rzkey` 格式及发现

固定 88 字节：

| 偏移 | 长度 | 内容 |
|---:|---:|---|
| 0 | 8 | `RZKEY001` |
| 8 | 16 | 归档 UUID |
| 24 | 32 | 随机 secret |
| 56 | 32 | `BLAKE3(前 56 字节)` |

创建 `name.rz` 时在同目录生成 `name.rzkey`；实现为替换输出路径扩展名。以 `0600` 权限写入，仅以 `O_NOFOLLOW` 打开普通文件，长度、magic、摘要及 UUID 均须检查，随后仍须通过包装认证和索引 MAC。

自动查找先试同名文件，再遍历同目录 `.rzkey` 候选，扩展名不区分 ASCII 大小写；最多遍历 65,536 个目录项、512 个其他候选。身份由 UUID 与认证确定，不由文件名确定。改名和修复保留 UUID，原密钥可以继续使用。

`list`、`extract` 默认尝试自动密钥文件；`verify` 默认只检查存储，需 `--auto-key-file` 或 `--key-file` 才请求密钥文件认证。无匹配密钥时 list 可以返回锁定摘要，要求认证的操作失败返回 6。自动搜索上限可通过显式选择文件绕过。

密钥文件不进入 K+M 卷集，也不受 RS 保护；`repair` 不复制或生成密钥。归档和密钥一起泄露即可解密，全部恢复卷完好也不能弥补密钥丢失。

## 6. profile 4 与 profile 5 分卷和索引

第 6.1–6.5 节保留 profile 4 的完整公开索引格式，第 6.6–6.11 节定义 profile 5 的分页格式。两者共享第 4 节的 RS 数学定义；各节局部符号不能跨格式套用。

### 6.1 逻辑块、条带与物理位置

令 `B=65,536`，`S` 为全部记录连接后的实际字节数，含属性、内容、私有索引和加密开销，不含公开索引：

```text
T = max(1, ceil(S / (K*B)))
data_blocks = T*K
recovery_blocks = T*M
blocks_per_volume = T
P = T*B                                  # 每卷载荷字节数
```

逻辑数据流末尾补零至 `T*K*B`。`D[t,c]` 对应逻辑流的 `[(t*K+c)*B, (t*K+c+1)*B)`；超过 S 的字节为零。恢复块 `P[t,r]` 按第 4 节计算。

设公开索引长度为 L：

```text
全局数据块 b：  volume_id=b%K，slot=floor(b/K)
全局恢复块 q：  volume_id=q%M，slot=floor(q/M)
块的物理偏移：  120 + L + slot*B
```

数据卷为 `d000000.rzv` 至 `d(K-1).rzv`，恢复卷为 `p000000.rzr` 至 `p(M-1).rzr`，编号十进制、至少六位补零。所有卷中的第 t 个槽组成同一条带。

```text
               d000000    d000001    ... d(K-1)     p000000 ... p(M-1)
slot 0         D[0,0]     D[0,1]        D[0,K-1]    P[0,0]     P[0,M-1]
slot 1         D[1,0]     D[1,1]        D[1,K-1]    P[1,0]     P[1,M-1]
...
slot T-1       D[T-1,0]   D[T-1,1]      D[T-1,K-1]  P[T-1,0]   P[T-1,M-1]
```

### 6.2 卷封装

```text
Header[120] | PublicManifest[L] | Payload[P] | PublicManifest[L] | Footer[120]
```

头和尾的字段相同，magic 不同：

| 偏移 | 类型 / 长度 | profile 4 字段 |
|---:|---|---|
| 0 | 8 bytes | 头 `RZVOL004` / 尾 `RZEND004` |
| 8 | u32 | 4 |
| 12 | u32 | 0=数据卷，1=恢复卷 |
| 16 | 16 bytes | UUID |
| 32 | u32 | 同类型物理卷编号，从 0 开始 |
| 36 | u32 | 保留，必须为 0 |
| 40 | u64 | L，公开索引字节数 |
| 48 | u64 | P，该卷载荷字节数 |
| 56 | 32 bytes | BLAKE3(完整公开索引) |
| 88 | 32 bytes | BLAKE3(本头 / 尾前 88 字节) |

第二份索引起点为 `120+L+P`，Footer 起点为 `120+2L+P`。每个数据卷和恢复卷大小严格相同：

```text
V = 240 + 2*L + T*65536
```

`manifest.rzm` 为 `PublicManifest[L] || BLAKE3(PublicManifest)[32]`，大小 L+32。sidecar 与可选 `.rzkey` 不计入 K+M；`.rz` 在当前 CLI 中是包含卷集的**目录**，并不是把所有卷连接起来的单个文件。

### 6.3 公开索引固定前缀

| 偏移 | 类型 / 长度 | 值 |
|---:|---|---|
| 0 | 8 bytes | `RZIDX004` |
| 8 | 16 bytes | UUID |
| 24 | u32 | profile=4 |
| 28 | u32 | block_size=65536 |
| 32 | u32 | frame_size=4194304 |
| 36 | u32 | requested_mode=2，按卷数 |
| 40 | u64 | requested_value=0 |
| 48 | u64 | volume_size_limit=0，表示不设旧版卷大小上限 |
| 56 | u32 | K，数据卷数 |
| 60 | u32 | M，恢复卷数 |
| 64 | u32 | blocks_per_volume=T |
| 68 | u64 | stream_size=S |
| 76 | u64 | data_blocks=T*K |
| 84 | u64 | recovery_blocks=T*M |
| 92 | u32 | group_count=T |
| 96 | 变长 | 条带组表 |

组表按 t 递增，每组：

```text
k:u32 = K
m:u32 = M
hashes[K+M][32]            # 先 K 个数据列，再 M 个恢复行
```

读取器重新从 S/K/M 推导 T、块数及卷大小，逐组检查 k/m 一致，拒绝任何互相矛盾的冗余字段，不能选择其中一个值“尽量读取”。

### 6.4 安全尾部与私有索引映射

组表之后从 `96 + T*(8+32*(K+M))` 开始：

```text
security_flags:u32
private_index_original_size:u64
private_index_frame_count:u32 = n
repeat n:
    offset:u64
    stored:u32
    plain:u32

if security_flags & 1:
    crypto_suite:u32                      # 1 或 2
    password_opslimit:u64                 # 密码=3；密钥文件=0
    password_memlimit:u64                 # 密码=67108864；密钥文件=0
    salt[16]
    wrap_nonce[24]
    if crypto_suite == 2:
        aes_wrap_nonce[12]
        wrapped_master_keys[96]
    else:
        wrapped_master_key[48]
    public_mac[32]
```

`security_flags` 位语义：bit0（1）加密；bit1（2）保存属性；bit2（4）独立密钥文件。其他位当前必须为零；bit2 设置时必须同时设置 bit0。关闭加密时不写 crypto_suite、成本、盐、包装或 MAC 字段。

私有索引原始长度在 `1..16 MiB`，`n=ceil(original_size/F)`，所以 n 为 1–4。帧位置连续，最后一帧末尾必须等于 S，非末帧 plain=F，plain 总和等于声明的私有索引原始长度。整个公开索引不得有尾随字节。

由字段可直接推导其精确长度：

```text
E = 0（不加密），140（suite 1），200（suite 2）
L = 96 + T*(8 + 32*(K+M)) + 16 + 16*n + E
```

E 只指 `if encrypted` 中的密钥槽尾部，不含其前面的 flags、长度和映射。当前 profile 4 没有公开文件条目，L 与文件数的关系通过私有索引及流大小间接体现。

### 6.5 空间例子与容量边界

假设 S=700,000 字节、K=4、M=2、未加密且私有索引只有一帧：

```text
T = ceil(700000 / 262144) = 3
数据载荷 = 12*65536 = 786432 字节
恢复载荷 =  6*65536 = 393216 字节
尾部补零 = 786432-700000 = 86432 字节
L = 96 + 3*(8+32*6) + 16 + 16 = 728 字节
每卷 V = 240+2*728+3*65536 = 198304 字节
```

恢复载荷比例为 `M/K=50%`，相对于补齐后的数据载荷；相对于所有编码载荷则为 `M/(K+M)`。它们都不是相对于原始文件总大小的压缩率，也不包含索引重复开销。

公开索引最多 16 MiB；必须同时满足上述 L 公式。代码还先检查 `(data_blocks+recovery_blocks)*32 <=16 MiB`，但这个初筛不含组头和安全尾部，最终仍以完整序列化长度为准。名义 64 GiB 原始数据上限不代表所有 64 GiB 输入都可创建：不可压缩输入可能先触及块哈希表 / 索引限制。

空目录输入也生成私有索引记录，S 不必为零；最小条带数仍为 1，默认 10+2 仍有 12 个卷。profile 4 的卷大小自动推导，不能再指定 `--volume-size`、恢复百分比或恢复字节数。

### 6.6 profile 5 几何与物理布局

profile 5 只支持等大卷数模式：`1<=M<=K<=100`，保持 `d000000.rzv` / `p000000.rzr` 卷名及 `manifest.rzm` sidecar。原始内容与属性合计最多 **1 TiB**（`2^40=1099511627776` 字节）；路径、条目与私有目录限制见第 7、10 节。

本节定义 `B=65536`、`R=B+32=65568`、`S` 为压缩/加密后的逻辑内容流长度、`b` 为 bootstrap 长度：

```text
0 < S <= 1099511627776 + floor(1099511627776/100)
D = ceil(S / (K*B))                    # 内容区条带数，每数据卷 D 块
P = ceil(D*(K+M)*32 / B)                # 摘要叶页数
root_size = 44 + 32*P
I = ceil((P*B + root_size) / (K*B))      # 索引区条带数
```

空输入仍有私有目录记录，所以 S/D/P/I 均非零。所有乘加与类型转换须在 S/K/M 上限验证后执行，再核对所有冗余几何字段；不可按归档给出的 P/I 直接分配数组。D 必须能用 u32 表示，根表不得超过 1 MiB。

各卷的物理布局为：

```text
卷头[120] | bootstrap[b] | 内容区块记录[D*R] | 索引区块记录[I*R] | bootstrap[b] | 卷尾[120]
每卷大小 V = 240 + 2*b + (D+I)*R
```

每个块记录为 `payload[65536] || local_digest[32]`。列 c=0..K-1 为数据卷，列 K+r 对应恢复卷 r。内容逻辑块 q 与索引逻辑块 q 分别映射为：

```text
column = q % K
stripe = floor(q / K)
内容区块载荷卷内偏移 = 120 + b + stripe*R
索引区块载荷卷内偏移 = 120 + b + (D+stripe)*R
局部摘要偏移         = 对应块载荷偏移 + B
尾部 bootstrap 偏移 = 120 + b + (D+I)*R
卷尾偏移             = 120 + 2*b + (D+I)*R
```

内容区末尾补零至 D*K*B；索引逻辑流末尾补零至 I*K*B。每类条带分别生成 M 个恢复块；不得把 32 字节局部摘要放入 RS 载荷，或把内容区与索引区混为一条逻辑流。

### 6.7 profile 5 卷头与 bootstrap 字段

卷头和卷尾均为 120 字节：

| 偏移 | 类型 / 长度 | 字段 |
|---:|---|---|
| 0 | [8] | 卷头 `RZVOL005`，卷尾 `RZEND005` |
| 8 | u32 | profile=5 |
| 12 | u32 | parity：数据卷0、恢复卷1 |
| 16 | [16] | UUID |
| 32 | u32 | 本类卷号，数据卷 `<K`，恢复卷 `<M` |
| 36 | u32 | 保留，必须为0 |
| 40 | u64 | bootstrap 长度 b，不超过8192 |
| 48 | u64 | 物理载荷长度 `(D+I)*65568` |
| 56 | [32] | 最终 bootstrap 的普通 BLAKE3，包含已填充 MAC |
| 88 | [32] | 该卷头/尾前88字节的 BLAKE3 |

卷头和卷尾各自计算摘要，不能把卷头摘要直接复制为卷尾摘要。`manifest.rzm = bootstrap || BLAKE3(bootstrap)`，没有另一个封装头。

bootstrap 的固定前缀如下：

| 偏移 | 类型 / 长度 | 字段 |
|---:|---|---|
| 0 | [8] | `RZIDX005` |
| 8 | [16] | UUID |
| 24 | u32 | profile=5 |
| 28 | u32 | B=65536 |
| 32 | u32 | F=4194304 |
| 36 | u32 | K |
| 40 | u32 | M |
| 44 | u64 | 逻辑内容流长度 S |
| 52 | u64 | D，内容区条带数 |
| 60 | u64 | I，索引区条带数 |
| 68 | u32 | P，摘要叶页数 |
| 72 | u64 | root_size |
| 80 | [32] | 完整根表的 BLAKE3 |
| 112 | u32 | security_flags，与第6.4节相同 |
| 116 | u64 | 私有目录原始长度，1..16 MiB |
| 124 | u32 | 私有目录帧数 n=ceil(original_size/F)，1..4 |
| 128 | 16*n | 每帧依次写入 offset:u64、stored:u32、plain:u32 |

随后写入以下尾部，顺序不可调整：

```text
if security_flags & 1:
    crypto_suite:u32
    password_opslimit:u64
    password_memlimit:u64
    salt[16]
    wrap_nonce[24]
    if crypto_suite == 2:
        aes_wrap_nonce[12]
        wrapped_master_keys[96]
    else:
        wrapped_master_key[48]
    public_mac[32]
index_volume_hash_count:u32 = K+M
index_volume_hashes[K+M][32]           # 先 K 个数据卷，再 M 个恢复卷
```

密钥槽、flags 及私有目录帧连续性约束与第 5、6.4 节相同。私有目录最后一帧末尾必须等于 S；不能忽略尾随字节。尾部的 `index_volume_hashes` 无论是否加密都存在，且计数必须恰好等于 K+M。

```text
E = 0（不加密），140（suite 1），200（suite 2）
b = 132 + 16*n + E + 32*(K+M) <= 8192
```

b 不随内容块总数线性增长；与 profile 4 不同，bootstrap 不内嵌每条带的全部摘要。每卷首尾及 sidecar 复制相同 bootstrap，共 `2*(K+M)+1` 个副本，但仍至少需要一份可定位的有效副本才能开始恢复。

### 6.8 profile 5 摘要叶页、根表及局部摘要

内容区的数据块和恢复块摘要沿用第 4.1 节的 `rz-block-v2` 域，`group_id=stripe`、`shard_id=column`。每个条带按列0..K+M-1连接摘要，再按条带号递增连接：

```text
H = hash[0,0] || ... || hash[0,K+M-1] || hash[1,0] || ...
len(H) = D*(K+M)*32
leaf[p] = H[p*B : (p+1)*B]           # 最后一页不足 B 时补零
leaf_digest[p] = BLAKE3(leaf[p])      # 覆盖补零后的完整 B 字节
```

一页容纳2048个完整摘要，摘要不会跨页。根表的精确结构为：

```text
magic[8] = "RZROOT05"
UUID[16]
K:u32
M:u32
D:u64
P:u32
leaf_digest[P][32]
```

根表长度为44+32*P，UUID/K/M/D/P 必须与 bootstrap 一致。根表摘要覆盖上述全部字节，不包含随后用于 RS 的尾部补零。

索引逻辑流为 `leaf[0] || ... || leaf[P-1] || root`，根表起点为 P*B。它按第 6.6 节映射至索引区，使用相同 K/M、Cauchy 系数和 `0x11d`；索引条带号从0重新开始。索引块局部摘要为：

```text
BLAKE3(
    ASCII("rz5-index-block") || UUID[16]
    || LE32(index_stripe) || LE32(column)
    || payload[65536]
)
```

内容区与索引区局部摘要不可互换。局部摘要用于定位普通擦除；单独验证局部摘要不能证明归档没有被主动改写。

### 6.9 profile 5 索引卷摘要与认证链

对每个物理卷 s，按索引条带号递增，计算包含局部摘要的整体摘要：

```text
index_volume_hash[s] = BLAKE3(
    index_payload[0,s] || index_local_digest[0,s]
    || ...
    || index_payload[I-1,s] || index_local_digest[I-1,s]
)
```

它不包含卷头、bootstrap 或内容区，覆盖索引数据块、恢复块和尾部填充。结果写入 bootstrap。加密时，MAC 输入为第 6.7 节的**全部 bootstrap 字节**，仅将 public_mac 置零，保留包括索引卷摘要在内的其他字段。

读取内容的校验链为：bootstrap MAC（加密时）→ 根表摘要 → 叶页摘要 → 内容块预期摘要 → 记录 AEAD（加密时）→ 原始文件摘要。完整存储验证还必须核对每卷索引区整体摘要。

不能只根据索引块局部摘要判定完整验证成功：攻击者可一起改写载荷和局部摘要。索引卷整体摘要将这种改写与已认证的 bootstrap 绑定，也覆盖未直接列入叶页表的索引恢复块。

所需 MAC、AEAD 和索引校验必须通过后才发布相应结果。无凭据验证和修复仍只提供存储一致性；未加密归档的普通 BLAKE3 都可被攻击者重算，不提供数字签名或可信来源认证。

### 6.10 profile 5 索引恢复与失败边界

完整验证和修复按以下次序处理：

1. 校验 bootstrap 字段、几何及卷身份；加密操作在有凭据时先验证其 MAC。
2. 按索引条带检查局部摘要和数据列尾部补零，统计不可用记录；任一条带超过 M 则拒绝完整修复。
3. 有普通擦除时，先在内存重建索引条带，并重新计算各卷索引区整体摘要。
4. 整体摘要仍不匹配的索引列作为可疑列，纳入各索引条带擦除集合；已记录的普通擦除不得重复计数。这样可检测同一列中普通损坏与另一条自洽伪造记录并存的情况。
5. 从重建索引记录读取根表，核对 bootstrap 中的根摘要，再按需读取并校验叶页；完整验证检查全部叶页及页尾补零。
6. 根据已验证叶页中的预期摘要检查内容区，按每个内容条带的 M 额度修复；不能只信任块尾的局部摘要。
7. 保留原 UUID、凭据、密文及格式，重建索引区、内容区和封装，重新打开完整输出卷集复验，成功后才发布。

普通 list/extract 可以在内存恢复所需索引页，但不发布修复后的卷集；损坏的内容块仍要求先执行 repair。列表读取必要页，不等于完成全部索引卷和内容的全量验证。

任意 M 整卷丢失的保证要求剩余卷完整且有可定位 bootstrap。普通随机损坏在内容区和索引区分别按条带计算额度。对攻击者构造的自洽伪造，不保证所有理论可纠正分布都可恢复；必须发现不一致并拒绝未经验证的输出。

所有可定位 bootstrap 失效时不能扫描裸块重建目录；`.rzkey` 不受 RS 保护。有效旧 profile sidecar、旧 profile 卷头或另一 UUID 混入时必须拒绝，不能把已验证的身份冲突当作普通缺卷。

### 6.11 profile 5 空间例子与取舍

仅演示几何：K=4、M=2、S=700000、未加密、私有目录1帧，因此 n=1、E=0：

```text
D = ceil(700000/(4*65536)) = 3
P = ceil(3*6*32/65536) = 1
root_size = 44+32 = 76
I = ceil((65536+76)/(4*65536)) = 1
b = 132+16+32*6 = 340
V = 240+2*340+(3+1)*65568 = 263192 字节
sidecar = b+32 = 372 字节
卷集总大小 = 6*V+372 = 1579524 字节
```

数据块载荷786432字节，恢复块载荷393216字节；索引区、局部摘要和重复 bootstrap 另计。新格式减少大归档重复完整索引的开销，但增加 RS 索引条带的固定填充，小归档可能比 profile 4 更大。

公共摘要表通过分页扩展，私有目录仍为最多16 MiB的 `RZPRI003`；1 TiB上限不代表无限条目、任意路径分布或已完成1 TiB实盘测试。旧程序不能读取 profile 5，旧归档无需转换即可由新程序读取。

## 7. 私有索引、条目与文件属性

### 7.1 私有索引 `RZPRI003`

profile 4/5 **继续使用**以下 profile 3 布局。所列内容是解密、解压后字节：

```text
magic[8] = "RZPRI003"
metadata_end:u64
entry_count:u32
repeat entry_count:
    kind:u32                        # 0=file，1=directory
    path_length:u32
    path[path_length]               # 相对 UTF-8 原始字节，无 NUL
    original_size:u64
    original_digest[32]
    frame_count:u32
    repeat frame_count:
        offset:u64
        stored:u32
        plain:u32
metadata_entry_count:u32             # 必须等于 entry_count
repeat entry_count:
    metadata_original_size:u64
    metadata_digest[32]
    metadata_frame_count:u32
    repeat metadata_frame_count:
        offset:u64
        stored:u32
        plain:u32
```

逻辑流中三段边界必须连续：

```text
0                          metadata_end                  index_start           S
| 全部属性记录              | 全部内容记录                 | 私有索引记录         |
```

内容映射按条目 / 帧顺序从 metadata_end 连续覆盖到 index_start；属性映射按条目 / 帧顺序从 0 连续覆盖到 metadata_end；index_start 取公开索引的首个私有索引 frame.offset。不能有重叠、空洞或未索引记录。

每个文件帧的 plain 总和必须等于文件 original_size，数量必须为 `ceil(size/F)`；目录 original_size=0、无内容帧，摘要是 BLAKE3 空串。关闭属性保存时每个条目的属性长度和帧数均为 0；当前写入器此时写入全零 metadata_digest，解析器不把这个未使用字段当成空串摘要。保存属性时每条目属性长度必须非零，帧数为 `ceil(metadata_size/F)`，解码后核对属性摘要。

条目总数最多100,000；内容与属性原始总量在 profile 3/4 中最多64 GiB，在 profile 5 中最多1 TiB；各版本私有索引本体仍限16 MiB。索引解析必须消耗所有字节，不能忽略尾随数据。

### 7.2 属性记录 `RZMET001`

```text
magic[8] = "RZMET001"
platform:u32                      # 1=macOS，2=Linux
mode:u32                          # 原权限位，允许范围 07777
uid:u32
gid:u32
atime.seconds:u64                 # 二补码 int64 解释
atime.nanoseconds:u32
mtime.seconds:u64
mtime.nanoseconds:u32
birth_present:u32                 # 0 或 1
if birth_present:
    birth.seconds:u64
    birth.nanoseconds:u32
bsd_flags:u32
acl_present:u32                   # 0 或 1
acl_length:u32
acl_text[acl_length]
xattr_count:u32
repeat xattr_count:
    name_length:u32
    name[name_length]
    value_length:u64
    value[value_length]
```

时间纳秒 `<1,000,000,000`；秒允许 `-62135596800..253402300799`。属性记录最多 64 MiB，最多 4096 个 xattr，名称 1–1024 字节且无 NUL、不重复；值保留原始二进制，不使用 Base64。ACL 文本最多 1 MiB，无 NUL；`acl_present=0` 时长度必须为 0。当前写入器按名称排序 xattr，解析器检查唯一性但不要求排序。

macOS 的资源叉、FinderInfo 作为对应 xattr 保存，birth time 单独保存，ACL 为原生文本及原身份 UUID。Linux 使用可读取的原生 xattr，birth/专用 ACL 字段按当前平台支持情况写入。不能假设两种系统权限语义完全可互换。

捕获时不复制 `com.apple.decmpfs`、`com.apple.system.cprotect`、`com.apple.system.Security` 等物理存储 / 原生安全表示。

### 7.3 属性恢复政策

内容通过摘要验证后再应用属性；条目逆序处理，让目录在子项完成后恢复。当前用户所有权保留，不进行提权 chown；原组在权限允许时尝试恢复。普通 rwx 位恢复，setuid/setgid/sticky 不施加并产生警告。

尝试恢复 atime、mtime、macOS birth time、ACL、普通 xattr、FinderInfo、资源叉及 hidden/nodump。`security.*`、`trusted.*`、`com.apple.rootless`、`com.apple.macl` 等受保护属性跳过并报告；immutable/append-only 不施加。

可恢复政策造成的属性警告允许发布已验证内容，退出码为 5，报告总数并最多列出 16 条详情。损坏的属性记录、认证失败或致命 IO 错误不属于“部分恢复成功”，仍会失败。`--no-attributes` 明确跳过属性恢复及该阶段读取校验；不能把这次解压称为全部属性认证通过。

ctime、物理压缩状态、稀疏布局不承诺恢复；源目录没有快照语义，捕获与内容读取之间仍可能发生变化。

## 8. 读取、验证、修复和解压

### 8.1 找到可用公开索引或启动元数据

以下为 profile 1–4 的索引查找流程：

1. 尝试 `manifest.rzm` 的长度、末尾摘要及索引结构。
2. 扫描 `.rzv/.rzr`，检查 120 字节头 / 尾摘要和版本，用其中 L/P 定位索引副本。尾部作为提示时还要求实际文件长度与头部几何一致。
3. 获得索引后，检查规范卷名、所有可解析卷头 / 尾的 UUID、profile、索引摘要和几何是否一致。遇到有效身份冲突必须报错，不能静默按多数投票选归档。
4. 使用索引中的 L 和几何定位各卷载荷，即使该卷自身头尾坏了也可检查其块。
5. 对 sidecar 及每个卷封装检查完整副本；缺失 / 不一致计入 `metadata_issues`。

“至少一份有效索引”还包含**能够定位它**的要求。当前不扫描裸压缩流重建目录，也不在所有头尾和 sidecar 都失效时盲搜索引。全部可定位索引失效时，RS 载荷即使足够也无法启动修复。

profile 5 查找的是至多8 KiB的 bootstrap，而非完整块摘要表。核对副本和所有有效卷身份后，根据 D/I/P 定位受保护索引区，再按第6.8–6.10节读取根表和叶页。bootstrap 全失效时具有相同的启动限制。

### 8.2 不同命令提供不同保证

| 操作 | 当前实际校验范围 |
|---|---|
| `list` 未解锁 | 公开索引、卷身份和公开摘要；不扫描所有内容块，不认证加密私有内容 |
| `list` 已解锁 | 先认证公开索引，再检查读取私有索引所涉及的存储块、记录 AEAD 和目录结构；不等于所有文件已验证 |
| `verify` 无凭据，加密归档 | 扫描全部数据 / 恢复块和封装副本；不提供加密认证 |
| `verify` 有正确凭据 | 先认证公开索引；存储扫描返回 0 时进一步认证 / 解压私有索引、全部文件和属性并核对摘要 |
| `verify` 未加密 profile 3/4/5 | 存储扫描返回 0 后同样核对私有索引、文件和属性 |
| `repair` | 重建存储块及封装，不要求凭据，不重新加密 |
| `extract` | 认证所需密钥 / 索引、检查读取的数据块、按记录解压并核对文件摘要，按选项恢复属性；不自动修复内容区 |
| 创建后复验，profile 3/4/5 | 重新打开暂存产物；加密时复用创建密钥完整认证、解压并核对内容及属性，不重复KDF |

若 `verify` 存储扫描返回 2/3，当前不会继续完整的私有记录验证；应先修复，再带凭据验证，不能把“已提供凭据”理解为所有内容已经认证。

私有索引所在数据块损坏时，list 可返回 `directoryUnavailable=true` 并保留修复入口。它不能把损坏目录当成一个正常的空目录。

### 8.3 修复顺序

下列为 profile 1–4 的内容块恢复流程；profile 5 先完成第6.10节的索引区恢复和认证，再应用对应的内容恢复及最终复验。

```text
加载公开索引、校验身份
对每个条带：
    读取 K+M 块并检查摘要
    收集擦除列表 missing
    若 len(missing)>M：失败
    RS.decode(blocks, missing)
    对重建后全部块重新计算原索引中的 BLAKE3
    一致才写入新卷集
复制原公开索引，重建头尾和 sidecar
重新打开完整输出卷集并复验
同步后发布到新目录
```

修复保持 UUID、密钥槽、nonce、tag、公开索引及密文原值，在可修复损坏的预期条件下恢复原卷字节，不是创建另一个新归档。不修改输入卷，不生成新密钥，不用重新压缩填补坏块。

### 8.4 解压顺序

先取得凭据并认证公开索引或 bootstrap。profile 2–5 按需校验私有索引及文件记录涉及的完整存储块，不预扫全部数据/恢复载荷；profile 1 保留原有预检查路径。profile 5 还须核对根表及必要叶页。

解开目录后，在私有暂存目录按安全路径创建文件，协调者读取记录，worker认证、解压，结果按原顺序写入并计算原文件BLAKE3，最后恢复选定属性、同步并发布。所需内容块损坏时要求先repair。

缺少恢复卷或部分封装副本不必阻止提取，只要所需索引及读取的内容完整。profile 5可在内存恢复必要索引页；完整存储健康状态仍由verify检查。错误密码、错配密钥、认证失败、文件摘要不符或路径冲突均不得发布部分明文。

## 9. 版本差异与旧版兼容规则

### 9.1 差异总表

| 项目 | profile 1 | profile 2 | profile 3 | profile 4 |
|---|---|---|---|---|
| 索引 / 卷头 / 卷尾后缀 | `001` | `002` | `003` | `004` |
| 编码组 | 固定 10+2，每组可有多条带 | 每组最多 100 数据块，自适应 m | 同 profile 2 | 每条带 K+M；一组即一条带 |
| 物理分卷 | 一个 shard 一卷，组内数据按 shard 顺序填充 | 全局块交错映射，用户指定卷上限 | 同 profile 2 | 恰好 K+M 个等大卷 |
| 文件条目 | 公开索引中 | 公开索引中 | 私有索引中 | 同 profile 3 |
| 属性 / 加密 | 不支持 | 不支持 | 支持 | 支持 |
| 块摘要域 | `rz-block-v1`，含 stripe_id | `rz-block-v2` | `rz-block-v2` | `rz-block-v2` |
| 整卷恢复保证 | 每组任意 2 卷，其他块及索引完整 | 取决于每组损坏分布 | 同 profile 2 | 任意 M 卷，其他块及索引完整 |

profile 5 相对于 profile 4 的差异：

| 项目 | profile 4 | profile 5 |
|---|---|---|
| 索引/卷头/卷尾后缀 | `004` | `005`，根表另为 `RZROOT05` |
| 编码区域 | 内容区 | 内容区与索引区各自K+M编码 |
| 每块物理记录 | 65536字节 | 65568字节，附32字节局部摘要 |
| 摘要表冗余 | 全表在每卷首尾复制 | 分页表受RS保护，复制bootstrap |
| 加密索引认证 | MAC直接覆盖全表 | MAC覆盖bootstrap，绑定根表和各索引卷摘要 |
| 私有目录/记录加密 | `RZPRI003`、suite 1/2 | 沿用相同字节协议 |
| 内容+属性上限 | 64 GiB，可能先触及公开索引限制 | 1 TiB，仍受16 MiB私有目录限制 |
| 整卷恢复条件 | 剩余卷和至少一份公开索引完整 | 剩余卷完整且至少一份bootstrap可定位 |

### 9.2 profile 1 必须保留的数学与布局

```text
K=10，M=2，B=65536
A[r,c] = inverse_GF256(r XOR (2+c))
block_hash = BLAKE3(ASCII("rz-block-v1") || UUID
                   || LE32(group) || LE32(shard) || LE32(stripe)
                   || block[65536])
```

一个组有效流长度为 valid，`stripes=max(1,ceil(valid/(10*B)))`，每 shard 载荷长 `stripes*B`。流依次填入 d00、d01…d09，同一块号横跨 12 卷形成条带；组摘要按 **shard-major 再 stripe** 排列。不能套用 profile 4 的“连续 K 个逻辑块一个条带”映射。

卷名为 `gNNNNNN.dSS.rzv` / `gNNNNNN.pSS.rzr`。头部偏移 32/36 是 group/shard，而非后续版本的 volume/reserved。parity 文件编号 00/01 对应 shard 10/11。索引含组 stripes、valid 及所有哈希，随后直接写文件条目。

profile 1 CLI 卷上限最多 1 GiB、恢复比例固定，最多 4096 组。完整历史字段见 [FORMAT.md](FORMAT.md)；不得用新版 Cauchy 系数替换其旧矩阵。

### 9.3 profile 2/3 的恢复预算和分卷

```text
D = max(1, ceil(S/B))
G = ceil(D/100)
每组 k_i = min(100, 剩余数据块数)

百分比模式：R = ceil(D * requested_value / 10000)
             requested_value=100..10000，20% 写 2000
容量模式：  R = ceil(requested_bytes/B)
要求 G <= R <= D
```

每组先分配一个恢复块，剩余按 `k_i-1` 加权，用累计整数取整：

```text
W = D-G
C_i = sum(j<=i, k_j-1)，C_-1=0
m_i = 1 + floor(C_i*(R-G)/W) - floor(C_(i-1)*(R-G)/W)
W=0 时每组 m_i=1
```

编码矩阵和块摘要与 profile 4 相同，但 group_id 是 100 数据块分组的组号；最后一组只使用实际 k。解析器须重算相同预算和分配，不能换成另一种“总额也为 R”的取整策略。

设用户卷大小上限为 V、最终公开索引为 L：

```text
C = floor((V-240-2*L)/B)             # 每卷容量，必须 >=1
DV = ceil(D/C)，PV = ceil(R/C)
数据块 b：volume=b%DV，slot=b/DV
恢复块 q：volume=q%PV，slot=q/PV     # q 按组、再恢复行累计
```

V 允许 1 MiB–16 GiB；每种卷最多 65,536 个。这里 blocks_per_volume=C 是**容量上限**，不意味着每个卷实际有 C 块；实际卷载荷最多相差一块。profile 4 则强制每卷恰好 T 块。

profile 2/3 的索引不含偏移 56/60 的 K/M：`blocks_per_volume` 在偏移 56，S 在 60，data_blocks 在 68，recovery_blocks 在 76，group_count 在 84，组表从 88 开始。profile 2 组表后是文件条目；profile 3 组表后是第 6.4 节的安全尾部。

套件 2 和密钥文件功能虽然不改变 profile 3 的容器编号，但早于该功能的读取器不认识 suite 2 或 bit2，会拒绝这些新文件。不能因此宣称“任意 profile 3 程序都能读任意 profile 3 归档”。

## 10. 并行处理、资源限制与发布

### 10.1 并行只改变调度

`--threads auto|1..64` 是请求上限，不等于实际 worker 数。auto 以 CPU 并发数为起点；显式 N 不额外按 CPU 数截断，仍受任务数、64 上限及内存预算限制。

| 阶段 | 当前实现 |
|---|---|
| 内容压缩 | 每 worker 独立复用 Zstd 上下文；4 MiB 独立帧，级别 3 |
| 文件原始摘要 | 协调者按读取的原始字节顺序增量计算 |
| 加密 / 记录提交 | 协调者按原帧顺序分配 offset、加密、更新索引、写流 |
| profile 2/3/4/5 RS 创建 | 按组 / 条带并行，每 worker 独占 GF 上下文 |
| RS 上下文初始化 | 启动线程前串行探测 CPU、分配表及构造上下文 |
| 最终卷封装 | profile 4/5最多4路独立卷IO，回填头尾并同步；profile 2/3当前串行 |
| 存储复验 | profile 2–5最多4路按物理卷顺序读取，累计各条带错误数 |
| 内容认证、解密/解压 | profile 2–5使用有界保序池，每worker复用独立Zstd解码上下文 |
| 属性、私有目录处理 | 捕获/序列化等仍串行，按需读取校验 |
| profile 1 RS 创建与所有 repair | 当前串行调用 Jerasure |

压缩池和 RS 池分阶段运行，不叠加。不得把使用全局可变 GF 状态的 Jerasure 接口直接移入并行 worker。

压缩池每阶段估算预算 256 MiB，包括原始 / 压缩帧缓冲、Zstd 上下文及加密提交缓冲；在途队列最多为 worker 上限的两倍，按尚在途原始字节量按需启动 worker，小文件不会仅因数量多就启动满额线程。

RS池同样以256 MiB预算约束上下文和块缓冲；每任务最多100+100个64 KiB块，即12.5 MiB载荷。worker不超过组数T，在途任务为 `min(T,2*workers)`；profile 4/5均匀条带的auto模式还受 `ceil(T*(K+M)*B/1MiB)` 限制。已完成未提交的任务也占额度。

profile 4/5最终封装按卷数、请求线程数、工作量和文件句柄预算限制，最多4路IO。profile 2–5载荷直接写最终暂存卷，取消了整套临时分卷载荷的复制。异常或取消先停止派发并等待worker退出，再清理暂存。

解密/解压池估算预算256 MiB，包括在途记录、明文结果、两层解密中间缓冲及解码上下文；最多两倍worker的在途任务，包括已完成未消费结果。协调者负责读取、块校验和保序提交，worker不共享可变卷缓存；敏感任务及解码器工作区在正常和异常退出时清零。

创建时显式 `--threads N` 同样约束最终扫描及内容复验；独立verify/extract默认自动调度。profile 5按需生成均匀编码几何，不建立全量CodingGroup或逐块摘要表。

同一压缩实现、相同未加密输入且关闭可变属性时，单 / 多线程的数据和恢复**载荷**应一致；完整归档仍因随机 UUID 而不同，块摘要亦绑定 UUID。加密结果还包含随机密钥、盐和 nonce，不能要求两次创建的密文完全相同。

### 10.2 当前限制

| 项目 | 限制 |
|---|---|
| 内容+属性原始总量 | profile 1–4：64 GiB；profile 5：1 TiB |
| 逻辑存储流S | 各profile原始总量上限加其1%的整数向下取整余量 |
| profile 1–4公开索引 | 16 MiB |
| profile 5 bootstrap/根表 | 8 KiB/1 MiB；摘要表通过64 KiB页扩展 |
| 私有目录索引 | profile 3/4/5均为16 MiB |
| 每条目属性 / ACL / xattr 数 | 64 MiB / 1 MiB / 4096 |
| 条目 / 路径 | 100,000 / 4096 字节 |
| profile 4/5卷数 | `1<=M<=K<=100`，共2–200卷 |
| profile 2/3 卷数 | 每种最多 65,536 |
| 文件句柄缓存 | 按卷数和RLIMIT_NOFILE预算动态分配，多缓存/worker分摊并预留系统余量 |
| 压缩/恢复/解密解压池预算 | 各256 MiB，分阶段使用；不是进程RSS上限 |
| profile 5叶页缓存 | 每读取器最多16页，约1 MiB |
| profile 5索引RS工作集 | 每条带最多200个64 KiB块，约12.5 MiB |
| profile 5扫描错误计数 | 每内容条带2字节，最大流且K=1时约34 MiB |

池预算不含驻留索引、分页缓存、扫描计数、属性、线程栈、分配器及检查器开销。压缩可能膨胀；profile 2–5临时磁盘包含逻辑流和正在写入的最终暂存卷，profile 5另有公开摘要页临时流，不再复制整套临时分卷载荷。仍须为恢复块和索引区预留空间。

### 10.3 发布与故障处理

输出父目录必须已存在，目标必须不存在，创建输出不能置于输入目录内。普通文件以 `O_EXCL` 独占创建；暂存目录位于同一父目录下的 `.rz-stage-*`，macOS 清除继承 ACL。文件和目录同步后，以禁止覆盖的 rename 发布。

加密创建时压缩暂存流及卷载荷保存密文，原始帧和未加密压缩结果暂存在内存，敏感任务缓冲在正常完成、异常和取消时清零。秘密密钥使用 libsodium 安全分配器。

密钥文件先在私有暂存区写入并 fsync，再通过独占硬链接发布同目录 `.rzkey`，随后发布归档目录。失败只回收本次产物，不覆盖或删除晚到的其他文件；若归档已发布但父目录同步失败，保留密钥。两个独立目录项不具备共同原子提交语义，SIGKILL / 断电可能留下暂存目录或孤立密钥。

正常异常、SIGINT、SIGTERM 会停止工作并清理未发布暂存；对断电、物理介质及文件系统崩溃的一致性不能从这些软件测试直接推定。

## 11. CLI 与前端协议

### 11.1 常用命令

以下从仓库根目录执行，输入应保持不变，各输出路径必须不存在：

```sh
# 明确使用最新容器，4 个数据卷 + 2 个恢复卷
recovery/build/rz create input archive.rz --profile 5 --data-volumes 4 --recovery-volumes 2

# 密钥文件保护；默认双层，在无 AES 设备上可显式选择 standard
recovery/build/rz create input keyed.rz --profile 5 --generate-key-file

# 密码由 stdin 提供，不能附加在 argv 中
recovery/build/rz create input protected.rz --profile 5 --encrypt --password-stdin --encryption dual

recovery/build/rz list keyed.rz --json
recovery/build/rz list keyed.rz --json --no-auto-key-file
recovery/build/rz verify keyed.rz
recovery/build/rz verify keyed.rz --auto-key-file
recovery/build/rz repair keyed.rz repaired.rz
recovery/build/rz extract repaired.rz extracted --key-file keyed.rzkey

# 显式保留旧版写入行为
recovery/build/rz create input compatible.rz --profile 4 --data-volumes 4 --recovery-volumes 2
recovery/build/rz create input legacy.rz --profile 3 --volume-size 64MiB --recovery-percent 20
```

K/M必须一起指定，可与 `--profile 4|5` 同用，不能与旧profile或容量/比例选项混用。仅指定K/M仍默认profile 4。容量输入支持B/KiB/MiB/GiB、最多三位小数、字节向下取整；百分比最多两位小数。未知、重复选项及互斥凭据来源须明确拒绝。

### 11.2 退出码

| 码 | 含义 |
|---:|---|
| 0 | 当前命令完成；是否完成加密认证取决于所请求操作和凭据 |
| 1 | 参数、格式、IO、认证 / 摘要错误、冲突、无有效公开索引，或 repair 实际失败等 |
| 2 | verify：存在坏块或元数据副本缺损，每组擦除数仍在恢复额度内 |
| 3 | verify：至少一组擦除数超过恢复额度 |
| 4 | 密码缺失、错误或凭据类型不匹配的密码错误 |
| 5 | extract：内容已发布，部分属性未恢复 |
| 6 | 要求匹配的密钥文件但缺失、损坏、错配或不合法 |

2/3 是 `verify` 的结构化损坏状态；超预算 `repair` 当前抛普通异常返回 **1**。AEAD / 公开索引 MAC 失败也可能返回 1，不能把所有加密相关失败统一当作 4。双层 AES 不可用返回一般错误，不会自动改用另一套件。

### 11.3 JSON

`list --json` 的外层 `version=1`；常用字段：

| 字段 | 语义 |
|---|---|
| encrypted / locked | 是否加密 / 是否尚未打开私有索引 |
| directoryUnavailable | 目录所在数据块需要修复；不是空目录 |
| preservesMetadata / requiresKeyFile | 是否保存属性 / 是否需要密钥文件 |
| encryptionSuite | 0 未加密、1 标准、2 双层 |
| entries | 已可用的 path、size、isDirectory；锁定时不能用空数组判定归档为空 |
| recovery.profile | 磁盘 profile，profile 1 没有 recovery 对象 |
| recovery.dataBytes | 补齐后数据块总字节数 |
| recovery.payloadBytes | **恢复块**总字节数，不是全部卷的总载荷 |
| recovery.volumeLimitBytes | 旧版卷上限；profile 4/5为0 |
| recovery.dataVolumes / recoveryVolumes | 实际物理卷数 |
| recovery.requestedMode / requestedValue | profile 4/5为2/0；旧版为比例或字节参数 |
| recovery.volumeSizeBytes | profile 4/5含封装的精确每卷大小；profile 5包含局部摘要和索引区 |
| recovery.toleratedVolumeLosses | profile 4/5的M，受各自恢复条件限制 |
| recovery.metadataBytesPerVolume | profile 5：`240+2*b+32*D+65568*I` |
| recovery.contentLimitBytes | profile 5：1099511627776，即1 TiB |

profile 5中，`dataBytes=D*K*65536`、`payloadBytes=D*M*65536`，均不含索引区；`volumeSizeBytes=dataBytes/K+metadataBytesPerVolume`。前端应重算几何和bootstrap长度范围，不能仅检查这些字段为正数。

`extract --json` 返回 outputPublished、warningCount、metadataWarnings，最后一项最多 16 条但总数不截断。`--capabilities` 返回 `version=1` 及 aes256gcm 布尔值；它当前不是完整的 profile / suite 能力协商接口。

### 11.4 进度与统计

使用 `--progress` 时，stderr 逐行输出 TAB 分隔进度：

```text
RZPROGRESS1<TAB>phase<TAB>processed<TAB>total<TAB>completed_files<TAB>files<TAB>packed<TAB>elapsed_ms
```

phase 当前为 compressing、recovery、writing、verifying、completed。processed/total 是文件内容原始字节，不含属性；packed 是已提交的内容存储记录字节，加密时含 nonce/tag，不含属性、私有索引、恢复载荷和卷封装。elapsed_ms 为内容压缩阶段耗时，后续阶段不应据它推算该阶段速度。

成功创建profile 2/3/4/5后另有 `RZTIMING1<TAB>{JSON}`，包括总时长、packing_us、compression_us、recovery_wall_us、读/RS/哈希累计工作时长、payload_write_us、index_us、volume_write_us、verify_us、publish_us，以及recovery_workers、recovery_peak_jobs、recovery_estimated_bytes、volume_write_workers。

当前profile 3–5的 `verify_us` 包含创建后的完整内容复验，加密时包含认证解密，不能与旧版仅做密文存储复验的数值直接作同强度比较。`payload_write_us` 为暂存卷载荷写入，`volume_write_us` 为封装回填和同步；profile 5的 `index_us` 还包含分页索引构建、索引RS编码及bootstrap认证。

worker 累计工作时长可相互重叠，且与载荷写入重叠，不能相加当作总耗时；compression_us 是 packing_us 的一部分。前端应按前缀识别所支持的协议，忽略新增统计行；不得更改已有字段顺序、单位或含义而保留旧前缀。

## 12. 版本迭代规则

本节为后续维护要求，不能用“目前实验格式”作为静默改变已有归档解释方式的理由。

### 12.1 三种兼容目标

1. **新读旧：**新版必须保留已支持 profile / suite / 凭据类型的读取、验证、修复及解压能力，包括本次升级前的冻结样本。
2. **旧读新：**只有新写入仍使用旧读取器支持的全部格式及功能时才要求成功。真正的新特性应让不支持的读取器明确拒绝，不能误解析或降级。
3. **字节与行为稳定：**相同旧格式中的映射、数学结果、认证输入和退出状态语义不能因重构改变；线程数、硬件后端、缓存策略不得影响这些规则。

安全加固可以拒绝原先错误接受的畸形输入，但必须证明冻结的合法历史归档继续可用，并记录拒绝范围，不能以“更严格”为由删除合法旧数据支持。

### 12.2 变更如何编号

| 拟修改内容 | 编号 / 兼容处理 |
|---|---|
| worker 调度、缓存、IO、SIMD、GF 后端优化 | 可保持 profile；结果及映射必须与旧实现一致 |
| Zstd 实现 / 级别调整 | 在旧独立帧、大小及解码约束内可保持 profile，但必须旧读新；不要求跨库版本压缩字节相同 |
| 换压缩算法、引入字典、改变帧大小或帧串联语义 | 新容器 profile 或先设计有版本的压缩能力字段；现有 profile 无算法协商空间 |
| 改 64 KiB 块、RS 多项式 / 矩阵、补零、组预算或卷映射 | 新 profile；旧分支原样保留 |
| 改公开索引字段宽度、顺序、卷头结构或必需语义 | 新 profile / 对应 magic；不得直接附加未定义尾部 |
| 新 AEAD、KDF 成本 / 上下文、AAD、nonce、标签或包装方案 | 新 suite 或先定义可区分的 KDF / 凭据版本；不能重定义 suite 1/2 的既有分支 |
| 新功能位 | 分配未使用位并记录最低读取能力；旧读者明确拒绝，不宣称旧读新兼容 |
| 私有索引 / 属性 / 密钥文件结构变化 | 新对应 magic，并提供容器可识别的能力或版本区分；保留旧结构解析 |
| JSON 新可选字段 / 新统计行 | 消费者能忽略时可增量添加；改含义、类型、单位或必需字段则升级协议 |
| CLI 默认、默认套件、参数解释、退出码改变 | 属于行为兼容变更，须显式迁移设计、回归和说明，不能因容器新增而顺带改变 |

suite 2 和 key-file bit2 是当前“按显式判别值扩展”的实例：旧 suite 1 密码路径字节保持不变，新功能由不支持的读者拒绝。后续不得把“profile 相同”当成唯一能力检查。

### 12.3 不可静默更改清单

- 所有现有 magic、版本、枚举、位含义、字段字节宽度、小端序、保留零字段及无尾随字节要求。
- `F=4194304`、`B=65536`、各 profile 的填充、组编号、shard 编号、路径排序及连续记录映射。
- profile 1与2/3/4/5各自的RS矩阵、`0x11d`、逐字节域表示、恢复行次序、内容块摘要域和profile 5索引块独立域。
- 密码原始字节处理、Argon2id13 固定参数、密钥文件来源标志和两种凭据隔离。
- KDF context 的精确 8 字节、ID、所有 AAD 域与字段顺序、nonce 规则、标签长度、公开索引 MAC 规范化输入。
- 旧头部偏移32/36的两种语义，profile 4/5仍复用 `RZPRI003` 和内容区 `rz-block-v2` 的事实。
- profile 5的65568字节块记录、D/P/I公式、根表字段、索引卷摘要次序，以及包含全部bootstrap尾部的MAC输入。
- 原始文件摘要、属性摘要和普通存储摘要的覆盖范围，及“无凭据修复不等于加密认证”的操作语义。
- 修复保留 UUID 与原密文字节、既有输出不覆盖、失败不发布半成品、先发布密钥再发布归档的行为。

禁止“顺手统一”旧版与新版的域名、字段或算法常量。禁止遇到未知 suite 后尝试已知算法直到某个成功，禁止无 AES 时静默降低安全模式。

### 12.4 演进步骤

1. 变更前保存发布版二进制、固定归档、创建选项、明文预期及摘要，先用新版代码跑旧样本确认当前基线。
2. 将改动归类为实现优化或格式 / 行为扩展，明确“新读旧”“旧读新”的支持范围。
3. 格式扩展先定义编号、字段、公式、认证覆盖和资源限额，再写读取器；保留显式旧版创建路径。
4. 同步提供黄金向量、负向测试、旧版样本和跨版本双向测试；不要让新 writer 与新 reader 的同一个错误相互掩盖。
5. 新读取能力先于默认写入策略发布；只有前端具备读取能力后才切换默认。CLI无卷数的profile 3默认、仅卷数的profile 4默认继续保留；GUI随新读取器显式切换为profile 5。
6. 更新本文、专项格式说明、CLI / GUI 文案及验证记录，记录实际执行平台与未完成验证。

### 12.5 已有归档的迁移边界

repair 是原样重建，不能顺便升级 profile、改 K/M 或轮换密码。当前没有原地追加、重分卷、追加恢复行、修改密码或密钥轮换命令。

当前迁移路径是：带凭据验证旧归档 → 解压到新目录 → 检查内容及属性警告 → 用明确目标 profile / suite 创建新归档及新密钥 → 再验证 / 解压比对 → 由调用者决定何时退休旧归档。迁移属性受平台恢复政策限制，不保证跨系统无损。

不得对加密数据仅修改索引中的 offset、UUID 或几何后宣称重封装完成：offset/UUID 参与 AEAD，几何和块摘要参与索引 MAC。新创建应生成新的 UUID、主密钥、盐与所需随机 nonce；复用旧主密钥重写 suite 2 相同位置可能重用其每记录 AES 密钥及 nonce。

## 13. 兼容性验证与发布检查表

### 13.1 当前已有测试

上轮profile 5实现的验证记录（2026-09-27）：Release **24/24**、ASan/UBSan **24/24**，TSan选定的6个并发相关入口通过，macOS Swift 59个测试函数通过。Profile5黑盒最终19个用例另行复测通过。实际65 GiB稀疏输入创建及完整校验通过；1 TiB仅完成有界合成几何测试，未完成同规模实盘测试。详情见 [VALIDATION.md](VALIDATION.md)。本次仅整合文档，不将既有结果表述为本次重新执行。

以 [CMakeLists.txt](../CMakeLists.txt) 注册项为准，当前24个CTest入口：

| 测试入口 | 主要保证 |
|---|---|
| codec / codec_scalar | 摘要向量、Zstd 独立帧、RS 与独立 GF 运算对照、擦除恢复 |
| format / configurable_format | 长度、偏移、路径、几何、截断及畸形输入拒绝 |
| crypto / dual_crypto / key_file_codec | AEAD 向量、包装、AAD、KDF / 凭据隔离和索引认证 |
| metadata | 属性序列化及约束 |
| compression_pool / recovery_pool / recovery_pool_scalar | 有界队列、按序提交、独立上下文及后端一致性 |
| fault_injection / configurable | 旧布局、缺卷 / 坏块、索引回退、超预算、清理与发布 |
| protected_archive / dual_archive / no_aes / key_file | 加密 / 属性、旧样本、无 AES、密钥匹配与密文修复 |
| parallel_archive / parallel_recovery | 线程参数、载荷一致性、失败和取消 |
| counted_volumes | profile 4 的等大卷、任意 M 卷缺失、私有索引 / 属性保护、资源与参数边界 |
| decompression_pool | 有界保序解密/解压、异常清零、取消、上下文复用及大偏移约束 |
| paged_format | profile 5的1 TiB几何、bootstrap/根表/卷头边界、MAC及旧上限保持 |
| paged_security | 索引载荷与局部摘要一起伪造、混合损坏、预算内精确恢复和超限不发布 |
| paginated_archive | profile 5多页、缺卷、索引RS、启动回退、混入旧profile拒绝、冻结样本及前端默认兼容 |

`counted_volumes` 覆盖4+2的全部15种两卷丢失组合、1+1/3+1/7+3/10+2/100+100、空归档、补齐、混合损坏、超预算不发布、索引回退、标准/双层密码及标准密钥文件、单/多线程载荷一致、句柄限制、按需提取和失败清理。双层测试依赖硬件能力，检查报告时须确认是否跳过。

### 13.2 已有冻结样本

以下是测试用公开样本，不能用新程序重新生成后覆盖来“修复”兼容失败：

| 样本 | 用途 | SHA-256 |
|---|---|---|
| [profile1.tar.gz](../tests/fixtures/profile1.tar.gz) | 旧 profile 1 | `c20ed5c08bd13c8b775507a61d588d6bbaf17e9b75d91a524b601915ba880834` |
| [profile2.tar.gz](../tests/fixtures/profile2.tar.gz) | 旧 profile 2 | `d30ac0bf122d797ffb765531b119283b7d93e3e7d90252cb9905cbab5b76d57c` |
| [profile3-standard.tar.gz](../tests/fixtures/profile3-standard.tar.gz) | 增加 suite 2 之前的 profile 3 / suite 1 | `7ce5988197eb4469d19ffbc09bfb751ae20d45da34c52b3987fa554532d6eb68` |
| [profile5.tar.gz](../tests/fixtures/profile5.tar.gz) | profile 5，K=2/M=1，无加密、无属性，固定legacy.txt | `402d601b563acd401bfc8993e8fc92ec61ba6ac806eb5d047ecd2617971eca4a` |

suite 1 样本的公开测试密码为 `fixture-password`。历史样本测试见 `test_protected.py::test_legacy_fixed_fixtures_remain_readable`、`test_frozen_standard_encryption_fixture`，另有 profile 1 的旧版修复回归。摘要用于防止样本被无意替换，不代替归档内验证。

Profile5样本读取见 `test_paginated.py`，预期文件内容为 `RZ profile 5 compatibility fixture\n`，末尾为一个LF。

**尚待补齐：**当前fixtures没有冻结的profile 4归档，也没有suite 2或密钥文件模式的冻结归档，尚无持续自动执行的完整发布二进制双向互操作矩阵。动态往返测试不等同于冻结历史证据；下次涉及格式/加密/序列化变更前，应先以当前基线补齐相应样本。

建议新增样本至少覆盖：profile 4 未加密、suite 1/2 密码、suite 1/2 密钥文件；多帧内容、跨块 / 跨条带、二进制属性、空文件 / 目录。每份保存原程序版本 / 源码 revision、创建参数、fixture SHA-256、文件预期摘要和明确标记的测试凭据；不要提交真实用户秘密。

### 13.3 双向互操作矩阵

| 生产者 → 消费者 | 必须检查 |
|---|---|
| 历史发布 writer → 新 reader | list / verify / extract；带凭据认证；模拟预算内损坏后 repair 再验证 |
| 新 writer，以旧 profile / suite / flags 写入 → 支持这些能力的旧 reader | 同样读取、验证、修复、解压；不能只测新版往返 |
| 新 writer，启用旧 reader 不支持的功能 → 旧 reader | 明确拒绝，无降级、无部分明文发布 |
| 单线程 ↔ 多线程、NEON ↔ scalar | 固定输入下编码载荷一致，跨后端修复结果一致 |
| macOS ↔ Linux | 结构、内容与修复互通；属性差异按政策明确报告，不冒充逐项还原 |

固定密码也不会使随机加密归档确定化。比较新旧实现时，使用同一冻结归档进行读取 / 修复，或在**测试专用**构造中固定完整输入与密码学向量；不得为了测试在生产环境引入固定随机种子、nonce 或主密钥。

### 13.4 发布前检查

- [ ] 确认变更涉及的 profile、suite、magic、flags、默认行为和前端协议；文档逐项说明。
- [ ] 所有旧冻结样本保持摘要不变，并通过新版读取 / 验证 / 恢复检查。
- [ ] 原格式优化通过“新版写、旧版读”；新功能通过“旧版明确拒绝”。
- [ ] RS 与独立 GF 运算逐字节对照，测试最大额度擦除和超额度拒绝。
- [ ] 块 / 索引 / nonce / tag / AAD / KDF 成本篡改、尾随字节、溢出和未知字段拒绝回归通过。
- [ ] 目录、空文件、尾部填充、跨帧 / 块 / 条带、私有索引与属性损坏路径通过。
- [ ] 无凭据密文修复、修复后正确凭据解压、缺钥和无 AES 路径通过。
- [ ] 取消、写失败、目标晚到冲突不覆盖既有文件、不发布不完整结果。
- [ ] 改并发代码时通过 TSan；改解析、内存或依赖时通过 ASan/UBSan；对应 CI 平台结果已核对。
- [ ] 确认命令默认值、退出码、JSON 单位和旧 GUI 进度解析未发生静默变化。
- [ ] 更新验证记录，区分本地执行、历史记录、远程 CI、跳过项和仍待验证项。

在仓库根目录可使用以下现有命令，构建目录分别隔离：

```sh
cmake -S recovery -B recovery/build -DCMAKE_BUILD_TYPE=Release
cmake --build recovery/build --parallel 4
ctest --test-dir recovery/build --output-on-failure

cmake -S recovery -B recovery/build-sanitize -DCMAKE_BUILD_TYPE=RelWithDebInfo -DRZ_SANITIZE=ON
cmake --build recovery/build-sanitize --parallel 4
UBSAN_OPTIONS=halt_on_error=1 ctest --test-dir recovery/build-sanitize --output-on-failure

cmake -S recovery -B recovery/build-tsan -DCMAKE_BUILD_TYPE=RelWithDebInfo -DRZ_THREAD_SANITIZE=ON
cmake --build recovery/build-tsan --parallel 4
TSAN_OPTIONS=halt_on_error=1 ctest --test-dir recovery/build-tsan --output-on-failure
```

上述命令是复验流程，不表示本文编写期间重新执行了所有检查器或远程 CI。历史实测范围见 [VALIDATION.md](VALIDATION.md)。

## 14. 实现导航与文档维护

| 源文件 | 核对入口 |
|---|---|
| [codec.cpp](../src/codec.cpp) / [codec.hpp](../src/codec.hpp) | compress_frame、decompress_frame、block_hash_v2、RecoveryEncoder、ReedSolomon |
| [inputs.cpp](../src/inputs.cpp) | 输入规划、pack_contents、原始文件摘要、按序提交 |
| [format.cpp](../src/format.cpp) / [binary.hpp](../src/binary.hpp) | 路径、通用条目、小端序列化、profile 1 |
| [configurable_format.cpp](../src/configurable_format.cpp) | configure、serialize、parse_configurable_manifest、头尾、预算 / 几何 |
| [configurable_archive.cpp](../src/configurable_archive.cpp) | profile 2–4读写及分页格式分派、按需块校验、并行扫描和提取 |
| [paged.hpp](../src/paged.hpp) / [paged_format.cpp](../src/paged_format.cpp) | profile 5限额、paged_layout、bootstrap、根表、索引摘要域和卷头 |
| [paged_create.cpp](../src/paged_create.cpp) | 流式建页、两个RS区域、索引卷摘要、bootstrap认证、创建复验 |
| [paged_archive.cpp](../src/paged_archive.cpp) | bootstrap回退、页缓存、局部/整体校验、可疑索引列、修复与提取 |
| [crypto.cpp](../src/crypto.cpp) | slot_aad、record_aad、password_key、ArchiveKeys、密钥文件 |
| [protected.cpp](../src/protected.cpp) | 记录次序、private_index / parse_private、sign_manifest、认证和属性读取 |
| [metadata.cpp](../src/metadata.cpp) | RZMET001、捕获 / 恢复政策 |
| [compression_pool.cpp](../src/compression_pool.cpp) / [recovery_pool.cpp](../src/recovery_pool.cpp) | 内存估算、调度、有界队列及故障收束 |
| [decompression_pool.cpp](../src/decompression_pool.cpp) | 可复用解码器、有界保序解密/解压、敏感任务清零 |
| [io.cpp](../src/io.cpp) | O_NOFOLLOW、短IO、定位写、Staging、commit_with_key |
| [main.cpp](../src/main.cpp) | CLI 默认、参数、凭据发现、JSON、退出码 |
| [compression_progress.hpp](../src/compression_progress.hpp) / [creation_timing.hpp](../src/creation_timing.hpp) | 进度与统计协议 |

专项格式文档：[profile 1](FORMAT.md)、[profile 2](FORMAT-V2.md)、[profile 3](FORMAT-V3.md)、[profile 4](FORMAT-V4.md)、[profile 5](FORMAT-V5.md)、[suite 2](ENCRYPTION-SUITE-2.md)、[密钥文件](KEY-FILES.md)。旧文档中“新写入器默认”可能指当时版本，当前默认以本文第1.2节及 `main.cpp` 为准。当前工作区未找到独立的recovery.yml工作流，不能把本地检查器结果表述为远程CI已通过。

每次格式相关修改应同步更新受影响章节和专项说明，保留旧编号定义与样本；不要只覆盖“最新版说明”而丢失历史解析依据。代码与文档不符时先根据历史样本和发布实现确定旧行为，再决定修正实现还是为新行为分配新编号。

| 文档日期 | 基线 / 更新内容 |
|---|---|
| 2026-09-27 | 初次统一整理工作区 CLI 0.6.0 / profile 4，纳入 suite 1/2、RZKEY001、profile 1/2/3 差异与兼容性维护要求 |
| 2026-09-27 | 整合CLI 0.7.0/profile 5完整布局、分页摘要及RS索引区、bootstrap/索引卷认证、1 TiB上限、并行读取、JSON扩展、冻结样本和既有验证记录 |
