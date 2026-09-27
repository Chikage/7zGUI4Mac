# RZ profile 3：加密与文件元数据

新写入器默认使用 profile 3，可选密码加密，默认保存文件属性。
profile 1/2 的读取、测试、修复与解压兼容；也保留显式旧版写入模式。
本格式仍为实验格式，尚未经过独立密码协议审计。

## 复用的存储层

沿用 [profile 2](FORMAT-V2.md) 的 64 KiB 存储块、可配置 RS 分组、物理分卷映射、
BLAKE3 存储块校验和多份公开索引。存储块哈希仍使用 `rz-block-v2` 域。
公开索引 magic 为 `RZIDX003`，卷头/尾为 `RZVOL003` / `RZEND003`，版本字段为 3。
卷头布局仍为 120 字节。

编码顺序：元数据记录 → 文件内容记录 → 私有目录索引记录，合并为逻辑流后再分块及生成恢复载荷。
每条记录最多 4 MiB 原始字节，先压缩为独立 Zstd frame，再按需加密。
这样内容、资源叉、属性和私有索引都受到 RS 保护；大型属性不会重复塞进每卷的公开索引。

## 密码套件 1

套件 1 保持默认和向后兼容。可选的 XChaCha + AES 双层加密使用套件 2，
字段布局、密钥包装及 nonce 规则见 [ENCRYPTION-SUITE-2](ENCRYPTION-SUITE-2.md)。

- AEAD：XChaCha20-Poly1305-IETF，256 位密钥、24 字节 nonce、16 字节认证标签。
- 密码派生：Argon2id v1.3，随机盐 16 字节，opslimit=3，memlimit=67,108,864 字节。
  固定使用 `crypto_pwhash_ALG_ARGON2ID13`，不使用可变化的默认算法编号。
  对应 Argon2 参数 t=3、m=65536 KiB、p=1，输出 32 字节。
- 每个归档随机生成 32 字节主数据密钥，使用密码派生密钥进行 AEAD 包装。
- 子密钥：libsodium BLAKE2b KDF，8 字节 context `RZ3KEYS!`；ID 1/2/3/4
  分别用于内容、属性、私有索引、公开索引认证。
- 公开索引认证：以子密钥 4 执行 keyed BLAKE3。
- nonce 均由 libsodium CSPRNG 独立生成。密码、主密钥和子密钥使用清零释放的安全分配器。

密钥包装的附加认证数据：

```text
ASCII("rz3-keyslot") || UUID[16] || LE32(1) || LE64(3) || LE64(67108864) || salt[16]
```

密码通过标准输入传递，UTF-8 原始字节，不做 Unicode 规范化；单行、1–1024 字节。
不放入 argv、偏好设置或操作日志。GUI 仅在当前会话内保留打开归档所需的密码。
读者在派生密钥前检查套件和成本字段，拒绝未知或不符的参数，避免恶意巨量分配。

## 独立记录

启用加密时，每条记录保存：

```text
nonce[24] || ciphertext[compressed_size] || tag[16]
```

附加认证数据为：

```text
ASCII("rz3-record") || UUID[16] || LE32(kind) || LE64(stream_offset) || LE32(original_size)
```

kind=1 内容，2 元数据，3 私有索引。stream_offset 是逻辑存储流中的记录起点。
不使用贯穿整个归档的有状态加密链。记录被移位、换类、换归档或改变原始长度均不能通过认证。
未启用加密时，记录仅为独立 Zstd frame。

密码解开随机主密钥后，先认证公开索引，再读取私有索引；认证失败不发布任何解密输出。
读取记录涉及的存储块会按公开索引检查 BLAKE3，避免未经验证的明文私有索引进入目录浏览。
加密写入过程中，压缩临时流与恢复载荷均只保存密文及公开恢复数据。

## 公开索引尾部

profile 2 的通用字段和 RS 组表保持原顺序，但不再在公开索引中保存文件条目。
组表之后依次为：

```text
security_flags:u32             # bit0 加密，bit1 保存属性，bit2 独立密钥文件；其余位必须为零
private_index_original_size:u64
private_index_frame_count:u32
private_index_frames[]         # offset:u64, stored:u32, plain:u32
if encrypted:
    crypto_suite:u32 = 1
    password_opslimit:u64 = 3            # 独立密钥文件模式为 0
    password_memlimit:u64 = 67108864     # 独立密钥文件模式为 0
    salt[16]
    wrap_nonce[24]
    wrapped_master_key[48]
    public_mac[32]
```

私有索引帧连续位于逻辑流末尾，原始总长最多 16 MiB。
公开索引 MAC 的输入为 `ASCII("rz3-public-index") || canonical_public_manifest`，其中 public_mac 字段置零。
MAC 绑定分卷/编码参数、全部存储块哈希、私有索引映射和密钥槽，之后再生成公开索引的普通 BLAKE3 摘要。

公开信息只用于恢复与密码派生，会暴露卷大小、编码配置、加密/属性标志和记录长度等结构信息。
文件名、目录结构、原始文件摘要与属性内容都位于私有记录内，加密时不会公开。

## 私有索引

```text
magic[8] = "RZPRI003"
metadata_end:u64
entries                        # 沿用 v1 条目；内容 frame 从 metadata_end 起连续排列
metadata_entry_count:u32        # 必须等于 entries 数量
repeat each entry:
    metadata_original_size:u64
    metadata_digest[32]        # BLAKE3(原始属性记录)
    metadata_frame_count:u32
    metadata_frames[]          # offset:u64, stored:u32, plain:u32
```

元数据记录从逻辑流起点连续排列至 metadata_end；内容记录从那里排列到私有索引起点。
关闭属性保存时各条目的属性长度和帧数为零。文件内容与属性原始长度合计最多 64 GiB。
私有索引单独限 16 MiB，公开索引仍限 16 MiB。

## 属性记录 RZMET001

依次保存：magic[8]、platform:u32（macOS=1、Linux=2）、mode:u32、uid:u32、gid:u32、
atime、mtime、birth_present:u32、可选 birth time、BSD flags:u32、acl_present:u32、
ACL 字节长度:u32 与文本、xattr_count:u32、各属性的名称长度:u32/名称/值长度:u64/原始二进制值。
每个时间是二补码秒数:u64 与纳秒:u32。名称不含 NUL，属性值不做文本编码。

限制：每条目属性总量 64 MiB、最多 4096 个 xattr、名称最多 1024 字节、ACL 文本最多 1 MiB。
macOS ACL 使用原生文本表示及原身份 UUID；无法在目标机解析的 ACL 身份会被报告。
资源叉和 FinderInfo 通过对应 xattr 保存；macOS 创建时间单独保存。
物理压缩/加密存储属性 `com.apple.decmpfs`、`com.apple.system.cprotect` 和原生 ACL 内部属性不复制。
Linux 使用原生 xattr，可保留该系统可读取的属性；macOS 与 Linux 的权限模型不保证可互换。

## 解压与恢复政策

1. 先完成认证、数据重建/解压和文件摘要校验，在新建私有目录中写出内容。
2. 然后恢复属性，目录按子项到父项的顺序最后处理。
3. 普通 rwx 位恢复；原所有者保存在归档里，输出保留当前用户所有权，不进行提权 chown。
   原组在当前权限允许时恢复。不同所有者、不可恢复的组、setuid/setgid/sticky 位均报告。
4. 尝试恢复 atime、mtime、macOS birth time、ACL、普通 xattr、FinderInfo、资源叉和 hidden/nodump 标记。
   ctime、文件系统物理布局及系统自动管理状态不承诺原样恢复。源目录没有快照语义，扫描可能改变访问时间。
5. `security.*`、`trusted.*`、`com.apple.rootless`、`com.apple.macl` 等受保护属性不恢复，明确报告。
   immutable/append-only 标记不施加，以免产生无法管理的输出，同样报告。
6. 属性限制不会丢弃已经验证的文件内容；返回退出码 5 和结构化报告。
   GUI 保留输出并显示“部分属性未恢复”，不会将它冒充完全成功。
7. `--no-attributes` / GUI 取消“恢复属性”时只输出内容，不产生属性缺失警告。

私有暂存目录会清除 macOS 继承 ACL；0700 模式本身不足以屏蔽允许访问的继承 ACL。
取消或失败清理暂存数据时先重置本次创建对象的 ACL/普通权限，不修改已发布的输出。
SIGKILL 或真实断电仍可能留下私有未提交目录，未声称覆盖真实断电验证。

## 命令与 GUI

```sh
rz create input archive.rz --encrypt --password-stdin
rz list archive.rz --json                         # 公开摘要，目录保持锁定
rz list archive.rz --json --password-stdin
rz verify archive.rz                            # 存储完整性，不等于密码认证
rz verify archive.rz --password-stdin            # 认证并校验解密内容与属性
rz repair archive.rz repaired.rz                 # 无需密码，重建密文
rz extract repaired.rz output --password-stdin --json
```

不要将密码写入命令参数；CLI 使用标准输入，GUI 使用 SecureField 和匿名管道。
创建可用 `--no-metadata` 关闭属性保存。新格式的所有加密记录都会同时保护文件名，无单独的明文目录模式。

JSON 清单新增 encrypted、locked、preservesMetadata、directoryUnavailable。
损坏的未加密私有索引仅返回公开摘要，让 GUI 保持修复入口；加密归档在解锁前同样可修复。
解压 JSON 为 outputPublished、warningCount、metadataWarnings（最多列出 16 条，总数另报）。
退出码 4 是密码缺失/错误，5 是内容已发布但属性部分恢复，其余状态沿用先前格式。
