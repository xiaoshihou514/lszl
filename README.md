# 聆述载录（ཉན་འབྲི དཔོད་འབྲི）

简单易用的sherpa-onnx命令行工具。

## 便携版（无需安装任何系统包）

Linux x86_64 用户下载主包，再按需下载用到的模型包：

- `dist/lszl-0.1.1-linux-x86_64-portable.tar.gz` —— 主包（程序 + 运行时 + FFmpeg + jq + 标点模型，**不含 ASR 模型**，体积小）
- `dist/lszl-0.1.1-linux-x86_64-models-<name>.tar.gz` —— 单个模型包，一个模型一个包，按需下载：
  - `models-paraformer`（默认，中英流式）
  - `models-zipformer`（中英流式）
  - `models-zipformer-ctc`（中文大模型）
  - `models-nemo`（英文离线）
  - `models-japanese`（日英离线，ReazonSpeech）
  - `models-korean`（韩语流式）
  - `models-vietnamese`（越南语离线）
  - `models-multilingual`（8 语流式：阿/英/印尼/日/俄/泰/越/中）

> **v0.1.1 发版说明**：本版新增 `japanese`、`korean`、`vietnamese`、`multilingual`
> 四个模型包。`paraformer`、`zipformer`、`zipformer-ctc`、`nemo` 四个旧模型包与
> v0.1.0 内容一致，**不再重复发布**，请从 v0.1.0 发布页下载对应的
> `lszl-0.1.0-linux-x86_64-models-*.tar.gz`，解压到 v0.1.1 主包旁即可正常使用。

不依赖 zig / ffmpeg / ffmpeg-devel / jq / sherpa-onnx / cuDNN 等任何系统包。

### 安装到 ~/.local（推荐）

```shell
tar -xzf lszl-0.1.1-linux-x86_64-portable.tar.gz
tar -xzf lszl-0.1.1-linux-x86_64-models-paraformer.tar.gz   # 需要的模型，解压到同一目录
cd lszl-portable
./install.sh            # 装到 ~/.local/bin/lszl + ~/.local/share/lszl/
```

之后直接 `lszl transcribe "录音.m4a"` 即可（默认模型 paraformer，开箱即用）。
`~/.local/bin` 若不在 PATH，把它加进 `~/.bashrc`：

```shell
export PATH="$HOME/.local/bin:$PATH"
```

卸载：`~/.local/share/lszl/install.sh --uninstall`。
自定义前缀：`PREFIX=$HOME/.local ./install.sh`（也支持 `DESTDIR` 风格部署）。

### 绿色运行（不解压到固定位置）

```shell
tar -xzf lszl-0.1.1-linux-x86_64-portable.tar.gz
tar -xzf lszl-0.1.1-linux-x86_64-models-paraformer.tar.gz   # 同一目录解压，合并 data/models
cd lszl-portable
./lszl transcribe "录音.m4a"        # 或 ln -s 到 PATH 里任意目录
```

不想下载模型包也可以在线安装单个模型：`./lszl model install paraformer`。

包内自带：静态链接的 `lszl`、静态 FFmpeg 7.1.5、静态 jq、裁剪后的
sherpa-onnx CPU/GPU 运行时、cuDNN 9、标点模型；模型与转写结果都存放在包内
`./data` 目录，整个文件夹可随意移动、拷贝。有 NVIDIA 驱动 + CUDA 13 库的
机器会自动走 GPU（provider=cuda）。打包与复现方式见 `scripts/portable-pack.sh`
和 `doc/agents/portable-pack.md`。

需要更小体积的包时：

```shell
scripts/portable-pack.sh --models zipformer,paraformer   # 模型嵌入主包（模型包同样只含这两）
scripts/portable-pack.sh --no-models-pack                # 只要主包，不产模型包
scripts/portable-pack.sh --no-models --no-gpu            # 最小 CPU 包
```

## 从源码构建（面向开发者）

编译（Fedora 44）：

```shell
sudo dnf install zig ffmpeg ffmpeg-devel just

just test
just install
```

自包含构建（不需要 ffmpeg-devel，产出静态二进制）：

```shell
zig build -Dportable -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe
```

使用方式与便携版相同。
