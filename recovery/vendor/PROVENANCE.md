# 固定依赖源码

以下完整上游源码归档随仓库保存，CMake 使用本地 URL 和 `URL_HASH SHA256=...` 校验后解包。
没有修改归档中的上游源码；GF-Complete/Jerasure 使用本项目的 CMake target 编译。
获取日期：2026-09-27。

| 文件 | 上游版本 / 来源 | SHA-256 |
|---|---|---|
| zstd-1.5.7.tar.gz | [facebook/zstd v1.5.7](https://codeload.github.com/facebook/zstd/tar.gz/refs/tags/v1.5.7) | `37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3` |
| blake3-1.8.2.tar.gz | [BLAKE3-team/BLAKE3 1.8.2](https://codeload.github.com/BLAKE3-team/BLAKE3/tar.gz/refs/tags/1.8.2) | `6b51aefe515969785da02e87befafc7fdc7a065cd3458cf1141f29267749e81f` |
| jerasure-de1739c.tar.gz | [ceph/jerasure de1739cc8483696506829b52e7fda4f6bb195e6a](https://codeload.github.com/ceph/jerasure/tar.gz/de1739cc8483696506829b52e7fda4f6bb195e6a) | `aee50eac40da833541086d32240cfe4de4cbe1881c65d6462fb5a7b691c422c9` |
| gf-complete-a6862d1.tar.gz | [ceph/gf-complete a6862d10c9db467148f20eef2c6445ac9afd94d8](https://codeload.github.com/ceph/gf-complete/tar.gz/a6862d10c9db467148f20eef2c6445ac9afd94d8) | `f7a8f61eb3c6718b4d8011c75b75a1bedd820e6851d71a65e491af805e8749aa` |
| libsodium-1.0.22.tar.gz | [libsodium 官方 1.0.22](https://download.libsodium.org/libsodium/releases/libsodium-1.0.22.tar.gz) | `adbdd8f16149e81ac6078a03aca6fc03b592b89ef7b5ed83841c086191be3349` |

许可证原文同时保存在 `licenses/`：Zstd 为 BSD 3-Clause 分支；BLAKE3 提供
Apache-2.0 with LLVM exception / CC0 选项；Jerasure 与 GF-Complete 为 BSD 3-Clause。
完整源码归档内另保留全部上游版权信息。
libsodium 为 ISC 许可，原文保存在 `licenses/libsodium.txt`。使用随源码提供的 configure/Makefile
离线构建静态库，部署目标与应用一致。加密套件不依赖系统 Homebrew 动态库。

`tests/fixtures/xchacha20-poly1305.json` 的密文向量来自该版本的
`test/default/aead_xchacha20poly1305.c` / `.exp`；测试独立核对已知明文的 SHA-256。

## 初始化适配

在 Apple Silicon / NEON 的 ASan 测试中，Jerasure 的 `galois_init_field()` 先调用
`gf_scratch_size()`，再由 `gf_init_hard()` 探测 CPU。首次调用时，前者按标量表分配，
后者按更大的 SIMD 表初始化，触发堆缓冲区越界。

`src/codec.cpp` 使用 `gf_init_hard(..., scratch_memory=nullptr)`，让 GF-Complete
按“先 CPU 探测、后分配”的顺序自行管理 scratch，然后通过
`galois_change_technique()` 注册给 Jerasure。退出时调用 `galois_uninit_field()` 释放。
该适配不改变有限域、编码矩阵或磁盘格式，不需要修改上游源码。

测试会在默认 NEON 和禁用 NEON 两种路径下比较独立 GF 算术结果，并进行跨后端卷恢复。
