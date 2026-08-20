# 聆述载录（ཉན་འབྲི དཔོད་འབྲི）

简单易用的sherpa-onnx命令行工具。

## 便携版（无需安装任何系统包）

Linux x86_64 用户直接下载 `dist/lszl-0.1.0-linux-x86_64-portable.tar.gz`，
不依赖 zig / ffmpeg / ffmpeg-devel / jq / sherpa-onnx / cuDNN 等任何系统包。
包内已自带全部 4 个 ASR 模型，**完全离线可用**。

### 安装到 ~/.local（推荐）

```shell
tar -xzf lszl-0.1.0-linux-x86_64-portable.tar.gz
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
tar -xzf lszl-0.1.0-linux-x86_64-portable.tar.gz
cd lszl-portable
./lszl transcribe "录音.m4a"        # 或 ln -s 到 PATH 里任意目录
```

包内自带：静态链接的 `lszl`、静态 FFmpeg 7.1.5、静态 jq、裁剪后的
sherpa-onnx CPU/GPU 运行时、cuDNN 9、标点模型，以及全部模型；模型与转写
结果都存放在包内 `./data` 目录，整个文件夹可随意移动、拷贝。有 NVIDIA
驱动 + CUDA 13 库的机器会自动走 GPU（provider=cuda）。打包与复现方式见
`scripts/portable-pack.sh` 和 `doc/agents/portable-pack.md`。

需要更小体积的包时：

```shell
scripts/portable-pack.sh --models zipformer,paraformer   # 只带部分模型
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
