import 'package:flutter_test/flutter_test.dart';
import 'package:nas_server/core/storage/ffmpeg_duration_probe.dart';

void main() {
  test('parseDurationMsFromFfmpegStderr reads HH:MM:SS.xx', () {
    const stderr = '''
Input #0, matroska,webm, from 'clip.webm':
  Duration: 01:05:12.40, start: 0.000000, bitrate: 1200 kb/s
    Stream #0:0: Video: vp9
''';
    expect(parseDurationMsFromFfmpegStderr(stderr), 3912400);
  });

  test('parseDurationMsFromFfmpegStderr returns null when missing', () {
    expect(parseDurationMsFromFfmpegStderr('no duration here'), isNull);
  });
}
