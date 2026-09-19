# 聆述载录（ཉན་འབྲི དཔོད་འབྲི）

简单易用的 sherpa-onnx 命令行工具，**纯原生 Zig 实现**：FFmpeg 库解码音频、
sherpa-onnx C API 推理（dlopen，CPU/CUDA 按机器自动选择）、标点恢复、模型
下载校验（SHA-256）、bz2+tar 安全解压——全部进程内完成，没有内嵌脚本，
不调用外部 ffmpeg/jq/curl。

## 使用

```shell
lszl model list
lszl model install paraformer
lszl model default paraformer
lszl doctor
lszl transcribe "录音.m4a"

# 临时指定模型
lszl transcribe --model zipformer-ctc "视频.mp4"
```

模型预设（8 个，详见 `lszl model list`）：`paraformer`/`zipformer`（中英流式）、
`zipformer-ctc`（中文大模型）、`nemo`（英文离线）、`japanese`（日英离线）、
`korean`（韩语流式）、`vietnamese`（越南语离线）、`multilingual`（8 语流式）。

退出码：2 用法错误；3 模型未装/名字不支持；4 媒体解码失败；5 推理失败；
6 运行时缺失；7 下载/校验/解压失败。

## GPU：显存以内最大化速度

`transcribe` 自动探测 NVIDIA 设备（进程内 NVML，无子进程）：有驱动 + cuDNN 9 +
CUDA 13 运行库时走 `provider=cuda`，否则回退 CPU 并明确提示；
CUDA 在创建识别器时被拒也会降级到同一运行时的 CPU provider。
`LSZL_PROVIDER=cpu|cuda` 可强制指定。

喂入策略按模型家族自动选择：

- **流式模型**（paraformer/zipformer/korean/multilingual）：工作集与音频长度
  无关，整个文件单趟喂完——完全不切片。
- **离线模型**（nemo/japanese/vietnamese）：激活内存随长度增长。从 20 秒起步，
  每次解码后用 NVML 实测显存增速，仅当「实测增速 × 安全系数」可证明放得下时
  才放大切片（×1.5 渐进，上限 300 秒）。识别器全程只加载一次——不像旧版
  每个 60 秒分块都重新起进程、重新把模型搬上 GPU。ONNX Runtime arena 不归还
  显存，因此规划器只对超出已验证长度的增长做预算，稳态下零额外分配。

实测参考（RTX 3050 Ti 4GB，17 分钟中文播客）：流式 paraformer 单趟 8x 实时；
离线 japanese 切片自适应收敛到 45 秒、45.8x 实时、峰值显存 1.4 GiB。

cuDNN 9 未安装时：`just install-cudnn`（NVIDIA 官方 redist，SHA-256 校验）。

## 便携版

见 `scripts/portable-pack.sh` 与 `doc/agents/portable-pack.md`。主包自带
程序 + 共享 FFmpeg + sherpa-onnx CPU/GPU 运行时 + cuDNN 9 + 标点模型；
模型包一个模型一个 tarball，按需解压合并；`install.sh` 可装入 `~/.local`。
注意：原生方案要求随包分发共享 FFmpeg 库（`-Dffmpeg_prefix` 构建进 BtbN
shared 树），不再是 musl 静态二进制。

## 从源码构建（面向开发者）

Fedora 44：

```shell
sudo dnf install zig ffmpeg ffmpeg-devel just bzip2-libs

just test
just install
```

- `bzip2-libs`：解压模型归档时 dlopen 的运行库（几乎所有发行版自带）。
- FFmpeg 开发包：构建期需要（头文件 + 链接）；运行机只需 FFmpeg 运行库。
- sherpa-onnx 运行时**不参与链接**：构建只引用其 C API 头文件
  （`just bootstrap-runtime` 负责下载校验），运行时按机器在首次使用时
  dlopen（CPU/CUDA 双份按需自动拉取并校验 SHA-256）。
