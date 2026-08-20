# 聆述载录（ཉན་འབྲི དཔོད་འབྲི）

简单易用的sherpa-onnx命令行工具。

## 便携版（无需安装任何系统包）

Linux x86_64 用户直接下载 `dist/lszl-0.1.0-linux-x86_64-portable.tar.gz`，
解压即用，不依赖 zig / ffmpeg / ffmpeg-devel / jq 等任何系统包：

```shell
tar -xzf lszl-0.1.0-linux-x86_64-portable.tar.gz
cd lszl-portable
./lszl model list
./lszl model install paraformer   # 只需下载一次模型（~1 GB）
./lszl model default paraformer
./lszl doctor
./lszl transcribe "录音.m4a"

# 临时指定模型
./lszl transcribe --model zipformer-ctc "视频.mp4"
```

包内自带静态链接的 `lszl`、FFmpeg、jq 以及 sherpa-onnx 运行时和标点模型；
模型与转写结果都存放在包内 `./data` 目录，整个文件夹可随意移动、拷贝。
打包与复现方式见 `scripts/portable-pack.sh` 和 `doc/agents/portable-pack.md`。

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
