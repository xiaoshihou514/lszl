/// The only place application code may import native headers.
pub const ffmpeg = @cImport({
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libavutil/avutil.h");
    @cInclude("libswresample/swresample.h");
});

pub const sherpa = @cImport({
    @cInclude("sherpa-onnx/c-api/c-api.h");
});
