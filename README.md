# 聆述载录（ཉན་འབྲི དཔོད་འབྲི）

简单易用的sherpa-onnx命令行工具。

编译（Fedora 44）：

```shell
sudo dnf install zig ffmpeg ffmpeg-devel just

just test
just install
```

使用：
```shell
lszl model list
lszl model install paraformer
lszl model default paraformer
lszl doctor
lszl transcribe "录音.m4a"

# 临时指定模型
lszl transcribe --model zipformer-ctc "视频.mp4"
```
