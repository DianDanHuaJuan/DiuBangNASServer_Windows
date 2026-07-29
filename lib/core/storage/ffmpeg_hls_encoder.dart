import 'dart:io';

/// LGPL-safe H.264 encoders available in BtbN win64-lgpl FFmpeg builds.
enum FfmpegH264Encoder { h264Mf, libOpenH264 }

class FfmpegHlsEncoder {
  FfmpegHlsEncoder._();

  static String? _cachedFfmpegPath;
  static FfmpegH264Encoder? _cachedEncoder;

  static Future<FfmpegH264Encoder> resolve(String ffmpegPath) async {
    if (_cachedFfmpegPath == ffmpegPath && _cachedEncoder != null) {
      return _cachedEncoder!;
    }

    final result = await Process.run(
      ffmpegPath,
      const <String>['-hide_banner', '-encoders'],
    );
    if (result.exitCode != 0) {
      throw StateError('Failed to query ffmpeg encoders for HLS transcoding.');
    }

    final output = '${result.stdout}';
    final FfmpegH264Encoder? encoder;
    if (_encoderListed(output, 'h264_mf')) {
      encoder = FfmpegH264Encoder.h264Mf;
    } else if (_encoderListed(output, 'libopenh264')) {
      encoder = FfmpegH264Encoder.libOpenH264;
    } else {
      encoder = null;
    }

    if (encoder == null) {
      throw StateError(
        'ffmpeg has no LGPL-compatible H.264 encoder (h264_mf / libopenh264).',
      );
    }

    _cachedFfmpegPath = ffmpegPath;
    _cachedEncoder = encoder;
    return encoder;
  }

  static bool _encoderListed(String encodersOutput, String name) {
    return RegExp('^\\s*V.*\\s$name\\s', multiLine: true)
        .hasMatch(encodersOutput);
  }

  static List<String> videoEncoderArgs(FfmpegH264Encoder encoder) {
    switch (encoder) {
      case FfmpegH264Encoder.h264Mf:
        // MediaFoundation path: keep args conservative for BtbN LGPL builds.
        return const <String>[
          '-c:v',
          'h264_mf',
          '-rate_control',
          'quality',
          '-quality',
          '50',
          '-scenario',
          'live_streaming',
          '-pix_fmt',
          'yuv420p',
          '-g',
          '48',
          '-sc_threshold',
          '0',
        ];
      case FfmpegH264Encoder.libOpenH264:
        return const <String>[
          '-c:v',
          'libopenh264',
          '-profile:v',
          'main',
          '-b:v',
          '1500k',
          '-maxrate',
          '1800k',
          '-bufsize',
          '3000k',
          '-pix_fmt',
          'yuv420p',
          '-g',
          '48',
          '-keyint_min',
          '48',
          '-sc_threshold',
          '0',
          '-force_key_frames',
          'expr:gte(t,n_forced*4)',
        ];
    }
  }
}
