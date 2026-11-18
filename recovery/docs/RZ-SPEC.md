# RZ 第 5 版算法与磁盘格式

## 1. 版本与实现

当前 CLI 与 macOS 应用只支持内部格式 profile 5，默认封装为 [容器 v1](CONTAINER-V1.md) 单文件，也兼容旧目录。创建归档默认使用 10 个数据卷和 2 个恢复卷。命令行的 `--profile 5` 可省略。卷头、卷尾和启动元数据分别使用 `RZVOL005`、`RZEND005`、`RZIDX005`。

容器版本、加密套件和前端协议独立编号。第 5 版使用 `RZPRI003` 私有索引、`RZMET001` 属性记录、`RZKEY001` 独立密钥文件、加密套件 1 或 2，以及版本 1 的 JSON 列表。对应标识和算法域均属于第 5 版的字节格式。

### 固定依赖

| 组件 | 基线版本 / revision | 用途 |
|---|---|---|
| Zstd | 1.5.7 | 独立帧压缩 |
| BLAKE3 | 1.8.2 | 内容、存储块与结构摘要；加密索引 MAC |
| libsodium | 1.0.22 | Argon2id、BLAKE2b KDF、XChaCha20-Poly1305、AES-GCM、随机数和秘密内存 |
| Jerasure | `de1739cc8483696506829b52e7fda4f6bb195e6a` | 条带擦除恢复 |
| GF-Complete | `a6862d10c9db467148f20eef2c6445ac9afd94d8` | GF(256) 运算及独立并行编码上下文 |

源码归档及 SHA-256 见 [依赖来源](../vendor/PROVENANCE.md)；CMake 从本地归档构建。Zstd 内部多线程关闭，多核压缩由本项目按独立帧调度。更换依赖版本不能自动视为格式兼容，应使用固定的第 5 版样本验证读写互操作性。

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
| volume | 容器中的一个等长区域，或旧目录中的 `.rzv` / `.rzr` 文件；包含索引或启动副本、载荷及头尾 |

记录可以跨块、跨卷、跨条带。读取记录必须先恢复逻辑流顺序，不能直接对一个物理数据卷运行 Zstd 解压。

### 2.3 profile 5 的创建顺序

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
    ↓ 回填各卷首尾 bootstrap/头尾，写 sidecar，封装为单文件（--directory 跳过封装）
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

内容区的数据块和恢复块使用同一摘要公式。

```text
BLAKE3(
    ASCII("rz-block-v2") || UUID[16]
    || LE32(group_id) || LE32(shard_id)
    || block[65536]
)
```

内容区中，`group_id` 就是从 0 起的条带号 `t`，数据 `shard_id=0..K-1`，恢复 `shard_id=K..K+M-1`。这里**没有额外 stripe_id**，也不能另改域名。profile 5 索引区使用独立的 `rz5-index-block` 域，定义见第 6.3 节。

普通 BLAKE3 用于发现损坏及定位擦除，不能证明来源真实性。攻击者能重新计算未加密归档的摘要。加密归档通过密钥包装、公开索引 MAC 和记录 AEAD 获得认证；无凭据修复只能提供存储一致性。

### 4.2 系统 Cauchy Reed–Solomon

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

数据列域元素 `0..99` 与恢复行域元素 `128..227` 在当前允许范围内不相交，分母非零。增减 M 不改变已有恢复行的系数；不能把恢复行重排成其他“等价 RS”矩阵。

恢复时从存活 shard 对应的生成矩阵行中取 K 行，求逆并恢复数据，进而重建恢复块。实际由 Jerasure 擦除解码完成。`jerasure_matrix_decode` 的 `row_k_ones` 必须为 **0**：此 Cauchy 矩阵首个恢复行并非全 1，不能使用该快捷假设。

### 4.3 从损坏检测到擦除恢复

对每个条带的 K+M 个块，读取不足、缺卷或摘要不匹配均视为整块不可用；一个字节损坏也消耗一个块的额度。设条带 t 的不可用块数为 `e_t`：

```text
所有条带 e_t <= M  →  在有效公开索引和其他块完整的前提下可重建
任一条带 e_t > M   →  当前修复器拒绝完整修复
```

系统先哈希判坏，再把已知位置传给 erasure 解码器；不进行未知错误位置的盲纠错，也不尝试滚动重同步插入 / 删除的字节。

profile 5 在内容区与索引区分别应用相同 K+M 几何；任意 M 整卷丢失的保证要求剩余卷完整且至少一份 bootstrap 可定位、可校验。索引区先恢复，再恢复内容区，具体认证与擦除判断见第 6.4–6.5 节。

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

### 5.5 启动元数据认证

使用 keyed BLAKE3，以公开索引 MAC 密钥对固定域和整个 bootstrap 认证。计算时将 public_mac 的 32 字节置零。

```text
public_mac = keyed_BLAKE3(mac_key, ASCII("rz3-public-index") || bootstrap_with_zero_mac)
```

读取时先验证 MAC，再加载私有索引。根表摘要和所有索引卷摘要均在认证范围内。

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

## 6. 分卷与分页索引

### 6.1 profile 5 几何与物理布局

profile 5 只支持等大卷数模式：`1<=M<=K<=100`，保持 `d000000.rzv` / `p000000.rzr` 卷名及 `manifest.rzm` sidecar。原始内容与属性合计最多 **1 TiB**（`2^40=1099511627776` 字节）；路径、条目与私有目录限制见第 7 节。

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

### 6.2 profile 5 卷头与 bootstrap 字段

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
| 112 | u32 | security_flags，加密=1、保存属性=2、独立密钥=4，其余位必须为零 |
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

密钥槽使用第 5 节的定义。独立密钥标志要求同时设置加密位。私有目录帧的偏移和长度须连续。私有目录最后一帧末尾必须等于 S；不能忽略尾随字节。尾部的 `index_volume_hashes` 无论是否加密都存在，且计数必须恰好等于 K+M。

```text
E = 0（不加密），140（suite 1），200（suite 2）
b = 132 + 16*n + E + 32*(K+M) <= 8192
```

bootstrap 的长度由卷数、密钥槽和私有目录帧数决定。每卷首尾及 sidecar 复制相同 bootstrap，共 `2*(K+M)+1` 个副本，但仍至少需要一份可定位的有效副本才能开始恢复。

### 6.3 profile 5 摘要叶页、根表及局部摘要

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

索引逻辑流为 `leaf[0] || ... || leaf[P-1] || root`，根表起点为 P*B。它按第 6.1 节映射至索引区，使用相同 K/M、Cauchy 系数和 `0x11d`；索引条带号从0重新开始。索引块局部摘要为：

```text
BLAKE3(
    ASCII("rz5-index-block") || UUID[16]
    || LE32(index_stripe) || LE32(column)
    || payload[65536]
)
```

内容区与索引区局部摘要不可互换。局部摘要用于定位普通擦除；单独验证局部摘要不能证明归档没有被主动改写。

### 6.4 profile 5 索引卷摘要与认证链

对每个物理卷 s，按索引条带号递增，计算包含局部摘要的整体摘要：

```text
index_volume_hash[s] = BLAKE3(
    index_payload[0,s] || index_local_digest[0,s]
    || ...
    || index_payload[I-1,s] || index_local_digest[I-1,s]
)
```

它不包含卷头、bootstrap 或内容区，覆盖索引数据块、恢复块和尾部填充。结果写入 bootstrap。加密时，MAC 输入为第 6.2 节的**全部 bootstrap 字节**，仅将 public_mac 置零，保留包括索引卷摘要在内的其他字段。

读取内容的校验链为：bootstrap MAC（加密时）→ 根表摘要 → 叶页摘要 → 内容块预期摘要 → 记录 AEAD（加密时）→ 原始文件摘要。完整存储验证还必须核对每卷索引区整体摘要。

不能只根据索引块局部摘要判定完整验证成功：攻击者可一起改写载荷和局部摘要。索引卷整体摘要将这种改写与已认证的 bootstrap 绑定，也覆盖未直接列入叶页表的索引恢复块。

所需 MAC、AEAD 和索引校验必须通过后才发布相应结果。无凭据验证和修复仍只提供存储一致性；未加密归档的普通 BLAKE3 都可被攻击者重算，不提供数字签名或可信来源认证。

### 6.5 profile 5 索引恢复与失败边界

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

所有可定位 bootstrap 失效时不能扫描裸块重建目录；`.rzkey` 不受 RS 保护。有效的外部版本标记或另一 UUID 混入时必须拒绝，不能把已验证的身份冲突当作普通缺卷。

### 6.6 profile 5 空间例子与取舍

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

数据块载荷786432字节，恢复块载荷393216字节；索引区、局部摘要和重复 bootstrap 另计。小归档也需为索引区至少分配一个完整条带。

公共摘要表通过分页扩展，私有目录仍为最多16 MiB的 `RZPRI003`；1 TiB上限不代表无限条目、任意路径分布或已完成1 TiB实盘测试。

## 7. 私有索引、条目与文件属性

### 7.1 私有索引 `RZPRI003`

私有索引解密、解压后具有以下布局。

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

条目总数最多100,000；内容与属性原始总量最多 1 TiB，私有索引本体限 16 MiB。索引解析必须消耗所有字节，不能忽略尾随数据。

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

读取器校验 manifest.rzm 的摘要，扫描分卷的卷头和卷尾。即使 sidecar 丢失，也能从任意完好的封装定位 bootstrap。所有校验有效的封装必须使用相同版本和 UUID，并与卷名、几何和 bootstrap 摘要一致。损坏的副本计入 metadata_issues，已确认的版本或归档身份冲突直接报错。

### 不同命令提供不同保证

| 操作 | 当前实际校验范围 |
|---|---|
| `list` 未解锁 | 公开索引、卷身份和公开摘要；不扫描所有内容块，不认证加密私有内容 |
| `list` 已解锁 | 先认证公开索引，再检查读取私有索引所涉及的存储块、记录 AEAD 和目录结构；不等于所有文件已验证 |
| `verify` 无凭据，加密归档 | 扫描全部数据 / 恢复块和封装副本；不提供加密认证 |
| `verify` 有正确凭据 | 先认证公开索引；存储扫描返回 0 时进一步认证 / 解压私有索引、全部文件和属性并核对摘要 |
| `verify` 未加密归档 | 存储扫描返回 0 后同样核对私有索引、文件和属性 |
| `repair` | 重建存储块及封装，不要求凭据，不重新加密 |
| `extract` | 认证所需密钥 / 索引、检查读取的数据块、按记录解压并核对文件摘要，按选项恢复属性；不自动修复内容区 |
| 创建后复验 | 重新打开暂存产物；加密时复用创建密钥完整认证、解压并核对内容及属性，不重复KDF |

若 `verify` 存储扫描返回 2/3，当前不会继续完整的私有记录验证；应先修复，再带凭据验证，不能把“已提供凭据”理解为所有内容已经认证。

私有索引所在数据块损坏时，list 可返回 `directoryUnavailable=true` 并保留修复入口。它不能把损坏目录当成一个正常的空目录。

修复先重建索引区，再重建内容区。输出保留原始 UUID、密钥槽和密文，写入新目录后复验。提取按需校验所读记录涉及的内容块和索引页，按原顺序提交解压结果，再应用选定的文件属性。

## 9. 暂存、同步与发布

输出父目录必须已存在，目标必须不存在，创建输出不能置于输入目录内。普通文件以 `O_EXCL` 独占创建；暂存目录位于同一父目录下的 `.rz-stage-*`，macOS 清除继承 ACL。文件和目录同步后，以禁止覆盖的 rename 发布。

加密创建时压缩暂存流及卷载荷保存密文，原始帧和未加密压缩结果暂存在内存，敏感任务缓冲在正常完成、异常和取消时清零。秘密密钥使用 libsodium 安全分配器。

密钥文件先在私有暂存区写入并 fsync，再通过独占硬链接发布同目录 `.rzkey`，随后发布归档目录。失败只回收本次产物，不覆盖或删除晚到的其他文件；若归档已发布但父目录同步失败，保留密钥。两个独立目录项不具备共同原子提交语义，SIGKILL / 断电可能留下暂存目录或孤立密钥。

正常异常、SIGINT、SIGTERM 会停止工作并清理未发布暂存；对断电、物理介质及文件系统崩溃的一致性不能从这些软件测试直接推定。

## 10. CLI 与前端协议

### 退出码

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

### JSON

`list --json` 的外层 `version=1`；常用字段：

| 字段 | 语义 |
|---|---|
| encrypted / locked | 是否加密 / 是否尚未打开私有索引 |
| directoryUnavailable | 目录所在数据块需要修复；不是空目录 |
| preservesMetadata / requiresKeyFile | 是否保存属性 / 是否需要密钥文件 |
| encryptionSuite | 0 未加密、1 标准、2 双层 |
| entries | 已可用的 path、size、isDirectory；锁定时不能用空数组判定归档为空 |
| recovery.profile | 固定为 5 |
| recovery.dataBytes | 补齐后数据块总字节数 |
| recovery.payloadBytes | **恢复块**总字节数，不是全部卷的总载荷 |
| recovery.volumeLimitBytes | 固定为 0 |
| recovery.dataVolumes / recoveryVolumes | 实际物理卷数 |
| recovery.requestedMode / requestedValue | 卷数模式，固定为 2 和 0 |
| recovery.volumeSizeBytes | 每卷精确大小，包含封装、局部摘要和索引区 |
| recovery.toleratedVolumeLosses | 其余分卷完整时可恢复的缺卷数 M |
| recovery.metadataBytesPerVolume | profile 5：`240+2*b+32*D+65568*I` |
| recovery.contentLimitBytes | profile 5：1099511627776，即1 TiB |

profile 5中，`dataBytes=D*K*65536`、`payloadBytes=D*M*65536`，均不含索引区；`volumeSizeBytes=dataBytes/K+metadataBytesPerVolume`。前端应重算几何和bootstrap长度范围，不能仅检查这些字段为正数。

`extract --json` 返回 outputPublished、warningCount、metadataWarnings，最后一项最多 16 条但总数不截断。`--capabilities` 返回 `version=1` 及 aes256gcm 布尔值；它当前不是完整的 profile / suite 能力协商接口。

### 进度与统计

使用 `--progress` 时，stderr 逐行输出 TAB 分隔进度：

```text
RZPROGRESS1<TAB>phase<TAB>processed<TAB>total<TAB>completed_files<TAB>files<TAB>packed<TAB>elapsed_ms
```

phase 当前为 compressing、recovery、writing、verifying、completed。processed/total 是文件内容原始字节，不含属性；packed 是已提交的内容存储记录字节，加密时含 nonce/tag，不含属性、私有索引、恢复载荷和卷封装。elapsed_ms 为内容压缩阶段耗时，后续阶段不应据它推算该阶段速度。

成功创建归档后另有 `RZTIMING1<TAB>{JSON}`，包括总时长、packing_us、compression_us、recovery_wall_us、读/RS/哈希累计工作时长、payload_write_us、index_us、volume_write_us、verify_us、publish_us，以及recovery_workers、recovery_peak_jobs、recovery_estimated_bytes、volume_write_workers。

当前的 `verify_us` 包含创建后的完整内容复验，加密时包含认证解密。`payload_write_us` 为暂存卷载荷写入，`volume_write_us` 为封装回填和同步；profile 5的 `index_us` 还包含分页索引构建、索引RS编码及bootstrap认证。

worker 累计工作时长可相互重叠，且与载荷写入重叠，不能相加当作总耗时；compression_us 是 packing_us 的一部分。前端应按前缀识别所支持的协议，忽略新增统计行；不得更改已有字段顺序、单位或含义而保留旧前缀。

## 实现与验证

磁盘布局与测试入口见 [第 5 版格式说明](FORMAT-V5.md)。CLI 示例和构建步骤见 [后端使用说明](../README.md)。固定归档样本为 [profile5.tar.gz](../tests/fixtures/profile5.tar.gz)。修复后每卷的字节应与原始完好卷完全相同。
