# RZ profile 3：可选双层加密套件 2

套件 1 的布局和算法保持不变，仍为默认。套件 2 将 XChaCha20-Poly1305-IETF 与
AES-256-GCM 串联，覆盖文件内容、保存的属性、私有索引和归档密钥包装。
容器仍用 profile 3，通过 `crypto_suite = 2` 区分；未知套件必须拒绝，禁止降级。
这仍是实验性自定义协议，未经过独立密码协议审计。双层不增加用户密码的熵，
不能防止密码被猜中、进程内存或两层主密钥同时泄露，也不提供来源签名或防回滚。

## 处理顺序与恢复边界

`原始记录 → 独立 Zstd frame → XChaCha AEAD → AES-GCM AEAD → BLAKE3 存储哈希 → RS → 物理分卷`。
恢复预算按最终密文补齐后的存储块数计算，分卷上限仍包含索引和卷头开销。
恢复过程既不解密也不重加密，原样重建两层密文、nonce 和认证标签，因此无需密码。
无密码校验仅说明公开存储校验一致；解锁认证公开索引和私有目录，完整性测试及解压
进一步认证全部文件和属性。任何一层认证失败均不发布解压输出。

## 密钥与密码

沿用 Argon2id v1.3，t=3、m=65536 KiB、p=1，随机盐 16 字节，输出 32 字节 K。
读取器在运行 KDF 前严格检查固定成本。两层使用同一个用户密码，不要求第二个密码。

每个新归档从 CSPRNG 获取 64 字节，视为两份独立随机主密钥 Mx[32]、Ma[32]：

- 内层记录根密钥：`crypto_kdf_blake2b(Mx, context="RZ3DUAL!", id=kind)`，输出 32 字节。
- 外层记录根密钥：`crypto_kdf_blake2b(Ma, context="RZ3AES2!", id=kind)`，输出 32 字节。
- 每记录 AES 密钥：`crypto_kdf_blake2b(外层记录根密钥, context="RZ3REC2!", id=stream_offset)`。
  每个 AES 密钥仅加密一条记录（最多 4 MiB 原始内容，加上压缩及内层开销）。
- 公开索引 MAC 密钥：BLAKE2b-256，key 为 `Mx || Ma`，message 为 ASCII
  `rz3-dual-manifest-key`。之后按套件 1 的方式对规范化公开索引执行 keyed BLAKE3。
- 包装密钥 Kx、Ka：分别从 K 以 context `RZ3WRAP!`、id 1/2 派生。

包装 `Mx || Ma`：先用 Kx 和随机 24 字节 nonce 执行 XChaCha AEAD，得到 80 字节；
再用 Ka 和随机 12 字节 nonce 执行 AES-GCM，得到 96 字节。
盐和主密钥每次创建均重新生成，包装 AES 密钥仅使用一次。两层保护同一份主密钥材料，
不会把解开任意单层所需的主密钥明文放在公开索引中。

包装 AAD（内层 layer=1，外层 layer=2）：

```text
ASCII("rz3-keyslot") || UUID[16] || LE32(2)
|| LE64(3) || LE64(67108864) || salt[16] || LE32(layer)
```

## 独立记录

记录 kind：1=文件内容，2=属性，3=私有索引。每条记录布局：

```text
aes_nonce[12] || AES-GCM(XChaCha_nonce[24] || XChaCha_ciphertext || XChaCha_tag[16]) || AES_tag[16]
```

相比压缩 frame 增加 68 字节，比套件 1 增加 28 字节。AES nonce 为
`LE32(kind) || LE64(stream_offset)`，不依赖随机碰撞概率；XChaCha nonce 仍随机生成。
写入器要求全局记录范围只向前推进，拒绝重复或重叠位置。解锁得到的密钥对象只允许读取，
不能用于新增记录。此版本不支持原地追加／修改加密归档，重建新归档必须创建新主密钥。

两层 AAD 为：

```text
ASCII("rz3-record") || UUID[16] || LE32(kind) || LE64(stream_offset)
|| LE32(original_size) || LE32(2) || LE32(layer)
```

读取时先检查 AES nonce 与记录位置一致，验证外层标签，再验证内层标签，最后解压。
套件、层次、归档身份、记录类别、位置和原始大小均被绑定。AEAD 同时认证密文及其长度。

## 公开索引布局差异

沿用 FORMAT-V3 的字段，`encrypted` 为真时安全尾部变成：

```text
crypto_suite:u32 = 2
password_opslimit:u64 = 3
password_memlimit:u64 = 67108864
salt[16]
wrap_nonce[24]
aes_wrap_nonce[12]
wrapped_master_keys[96]
public_mac[32]
```

此尾部共 200 字节，比套件 1 增加 60 字节。公开索引 MAC 覆盖上述内容、
分卷映射、恢复几何及全部存储块哈希（计算时将 `public_mac` 置零）。
套件 1 固定兼容样本在 `tests/fixtures/profile3-standard.tar.gz`，密码为 `fixture-password`，
由加入套件 2 前的实际内核生成。

## API、GUI 与兼容性

- `rz create ... --encrypt --password-stdin --encryption dual`；默认 `standard`。
- `rz --capabilities` 返回 `{ "version": 1, "aes256gcm": true|false }`。
- `list --json` 增加 `encryptionSuite`：0=未加密，1=标准，2=双层。
- GUI 在“可恢复 RZ → 使用密码保护 → 加密方式”选择标准或双层；密码关闭时创建未加密归档。
- libsodium 的 AES-GCM 依赖 AES-NI 或 ARM Crypto，使用运行时能力检测；不支持时禁止
  创建／解锁双层归档，不能静默降级。无 AES 的设备仍能浏览公开摘要、校验存储和修复密文。
- 单纯增加 AES 不限制无密码修复，也不隐藏公开的归档大小、恢复比例、分卷布局和套件编号。

实现依据：[libsodium AES-GCM](https://libsodium.gitbook.io/doc/secret-key_cryptography/aead/aes-256-gcm)、
[KDF 用途隔离](https://libsodium.gitbook.io/doc/key_derivation)。
