import 'dart:io';

import 'ffmpeg_locator.dart';

final _durationPattern = RegExp(
  r'Duration:\s*(\d{2}):(\d{2}):(\d{2})\.(\d+)',
);

/// Probes container duration via existing ffmpeg.exe (`-i` stderr).
/// Returns null when ffmpeg is missing or duration cannot be parsed.
Future<int?> probeDurationMs(
  String filePath, {
  FfmpegLocator locator = const FfmpegLocator(),
}) async {
  final ffmpegPath = await locator.find();
  if (ffmpegPath == null || filePath.trim().isEmpty) {
    return null;
  }

  try {
    final result = await Process.run(ffmpegPath, <String>[
      '-hide_banner',
      '-i',
      filePath,
    ]);
    return parseDurationMsFromFfmpegStderr('${result.stderr}');
  } catch (_) {
    return null;
  }
}

int? parseDurationMsFromFfmpegStderr(String stderr) {
  final match = _durationPattern.firstMatch(stderr);
  if (match == null) {
    return null;
  }

  final hours = int.parse(match.group(1)!);
  final minutes = int.parse(match.group(2)!);
  final seconds = int.parse(match.group(3)!);
  final fraction = match.group(4)!;
  final millis = (double.parse('0.$fraction') * 1000).round();
  final totalMs = (((hours * 60) + minutes) * 60 + seconds) * 1000 + millis;
  return totalMs > 0 ? totalMs : null;
}
