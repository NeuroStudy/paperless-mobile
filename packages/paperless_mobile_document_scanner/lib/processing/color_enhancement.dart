import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

/// Immutable, crop-specific data; no native allocations cross isolate boundaries.
class EnhancementProfile {
  final int width;
  final int height;
  final Uint8List? paper;
  final Uint8List? protection;
  final double contrast;

  const EnhancementProfile(
    this.width,
    this.height,
    this.paper,
    this.protection,
    this.contrast,
  );
}

/// Analysis is shared by preview, rotation, toggles and the saved result.
Future<EnhancementProfile> analyzeEnhancement(Uint8List bytes) =>
    Isolate.run(() => _analyze(bytes));

Future<Uint8List> enhanceDocument(
  Uint8List bytes, {
  bool reduceShadows = true,
  EnhancementProfile? profile,
}) async {
  final resolved = reduceShadows
      ? profile ?? await analyzeEnhancement(bytes)
      : null;
  return Isolate.run(() => _render(bytes, resolved));
}

const enhancementAnalysisEdge = 768;

EnhancementProfile _analyze(Uint8List bytes) {
  final owned = <cv.Mat>[];
  cv.Mat own(cv.Mat mat) {
    owned.add(mat);
    return mat;
  }

  const fallback = EnhancementProfile(0, 0, null, null, 1.08);
  try {
    final source = own(cv.imdecode(bytes, cv.IMREAD_COLOR));
    if (source.isEmpty) throw const FormatException('Cannot decode scan');
    final scale = math.min(
      1.0,
      enhancementAnalysisEdge / math.max(source.cols, source.rows),
    );
    final small = own(
      cv.resize(source, (
        math.max(2, (source.cols * scale).round()),
        math.max(2, (source.rows * scale).round()),
      ), interpolation: cv.INTER_AREA),
    );
    cv.Mat closing(cv.Mat mat, int size) {
      final radius = math.max(
        1,
        (size *
                    math.min(
                      1.0,
                      math.max(source.cols, source.rows) /
                          enhancementAnalysisEdge,
                    ))
                .round() ~/
            2,
      );
      final kernel = own(
        cv.getStructuringElement(cv.MORPH_RECT, (
          radius * 2 + 1,
          radius * 2 + 1,
        )),
      );
      return own(
        cv.morphologyEx(
          mat,
          cv.MORPH_CLOSE,
          kernel,
          borderType: cv.BORDER_REPLICATE,
        ),
      );
    }

    final pixels = small.data;
    final fine = closing(small, 15).data;
    final broad = closing(small, 31).data;
    final w = small.cols, h = small.rows, count = w * h;
    final hist = List.generate(3, (_) => List.filled(256, 0));
    final brightness = List.filled(256, 0);
    for (var i = 0; i < count; i++) {
      for (var c = 0; c < 3; c++) {
        hist[c][pixels[i * 3 + c]]++;
      }
      brightness[(broad[i * 3] + broad[i * 3 + 1] + broad[i * 3 + 2]) ~/ 3]++;
    }
    final reference = [
      for (final channel in hist) _percentile(channel, count, .9),
    ];
    final referenceMean = reference.reduce((a, b) => a + b) / 3;
    if (referenceMean < 90 ||
        (reference.reduce(math.max) - reference.reduce(math.min)) /
                referenceMean >
            .35) {
      return fallback;
    }
    final varying =
        _percentile(brightness, count, .9) -
            _percentile(brightness, count, .1) >
        6;
    final invalid = Uint8List(count), content = Uint8List(count);
    for (var i = 0; i < count; i++) {
      var low = 10.0,
          high = 0.0,
          colorLow = 10.0,
          colorHigh = 0.0,
          colorTotal = 0.0;
      var difference = 0;
      for (var c = 0; c < 3; c++) {
        final ratio = fine[i * 3 + c] / math.max(1, reference[c]);
        low = math.min(low, ratio);
        high = math.max(high, ratio);
        difference = math.max(difference, broad[i * 3 + c] - fine[i * 3 + c]);
        final color = broad[i * 3 + c] / math.max(1, reference[c]);
        colorLow = math.min(colorLow, color);
        colorHigh = math.max(colorHigh, color);
        colorTotal += color;
      }
      if (high - low > .12 || difference > 18) invalid[i] = 1;
      if ((colorHigh - colorLow) / math.max(.01, colorTotal / 3) > .35) {
        content[i] = 1;
      }
    }
    for (var top = 0; top < h; top += 16) {
      for (var left = 0; left < w; left += 16) {
        var dark = 0, edges = 0, samples = 0;
        for (var y = top; y < math.min(h, top + 16); y++) {
          for (var x = left; x < math.min(w, left + 16); x++) {
            final i = (y * w + x) * 3;
            if (pixels[i] + pixels[i + 1] + pixels[i + 2] <
                (fine[i] + fine[i + 1] + fine[i + 2]) * .78) {
              dark++;
            }
            if (x > 0 &&
                (pixels[i] - pixels[i - 3]).abs() +
                        (pixels[i + 1] - pixels[i - 2]).abs() +
                        (pixels[i + 2] - pixels[i - 1]).abs() >
                    120) {
              edges++;
            }
            samples++;
          }
        }
        if (dark > samples * .4 && edges > samples * .45) {
          for (var y = top; y < math.min(h, top + 16); y++) {
            for (var x = left; x < math.min(w, left + 16); x++) {
              content[y * w + x] = 1;
            }
          }
        }
      }
    }
    _protectPanels(fine, content, w, h, referenceMean);
    for (var i = 0; i < count; i++) {
      if (content[i] != 0) invalid[i] = 1;
    }
    if (invalid.where((x) => x != 0).length > count * .45) return fallback;
    final protection = _expand(content, w, h, 2);
    final paper = Uint8List.fromList(pixels);
    if (varying) {
      final luminance = Uint8List(count);
      for (var i = 0; i < count; i++) {
        luminance[i] =
            (pixels[i * 3] + pixels[i * 3 + 1] + pixels[i * 3 + 2] + 1) ~/ 3;
      }
      final gray = own(cv.Mat.fromList(h, w, cv.MatType.CV_8UC1, luminance));
      final narrow = closing(gray, 5).data, wide = closing(gray, 15).data;
      final ink = Uint8List(count);
      for (var i = 0; i < count; i++) {
        if (luminance[i] < narrow[i] * .97 || luminance[i] < wide[i] * .80) {
          ink[i] = 1;
        }
      }
      final missing = _expand(ink, w, h, 1);
      for (var i = 0; i < count; i++) {
        if (protection[i] != 0) missing[i] = 1;
      }
      if (missing.where((x) => x == 0).length < count * .05) return fallback;
      _fillPaper(paper, missing, w, h);
    } else {
      for (var i = 0; i < count; i++) {
        for (var c = 0; c < 3; c++) {
          paper[i * 3 + c] = reference[c];
        }
      }
    }
    final inkHistogram = List.filled(256, 0);
    var inkCount = 0;
    for (var i = 0; i < count; i++) {
      var total = 0.0, low = 255.0, high = 0.0;
      for (var c = 0; c < 3; c++) {
        final channel = math.min(
          255.0,
          pixels[i * 3 + c] * 255 / math.max(1, paper[i * 3 + c]),
        );
        total += channel;
        low = math.min(low, channel);
        high = math.max(high, channel);
      }
      final value = (total / 3).round();
      if (invalid[i] == 0 && value >= 20 && value <= 190 && high - low < 40) {
        inkHistogram[value]++;
        inkCount++;
      }
    }
    final contrast = inkCount > count * .002
        ? (207 / (255 - _percentile(inkHistogram, inkCount, .1))).clamp(
            1.08,
            1.6,
          )
        : 1.08;
    final map = own(cv.Mat.fromList(h, w, cv.MatType.CV_8UC3, paper));
    final smoothed = own(cv.medianBlur(map, 3));
    return EnhancementProfile(
      w,
      h,
      Uint8List.fromList(smoothed.data),
      protection,
      contrast,
    );
  } finally {
    for (final mat in owned.reversed) {
      mat.dispose();
    }
  }
}

Uint8List _render(Uint8List bytes, EnhancementProfile? profile) {
  final mat = cv.imdecode(bytes, cv.IMREAD_COLOR);
  try {
    if (mat.isEmpty) throw const FormatException('Cannot decode scan');
    final pixels = mat.data;
    final map = profile?.paper;
    if (map == null) {
      for (var i = 0; i < pixels.length; i++) {
        pixels[i] = (pixels[i] * 1.08 - 20.4).round().clamp(0, 255);
      }
    } else {
      final p = profile!;
      final protection = p.protection;
      final sx = p.width / mat.cols, sy = p.height / mat.rows;
      // Interpolate the small map directly, keeping float storage independent of export size.
      for (var y = 0; y < mat.rows; y++) {
        final fy = ((y + .5) * sy - .5).clamp(0.0, p.height - 1.0);
        final y0 = fy.floor(),
            y1 = math.min(p.height - 1, fy.floor() + 1),
            dy = fy - fy.floor();
        for (var x = 0; x < mat.cols; x++) {
          final fx = ((x + .5) * sx - .5).clamp(0.0, p.width - 1.0);
          final x0 = fx.floor(),
              x1 = math.min(p.width - 1, fx.floor() + 1),
              dx = fx - fx.floor();
          final a = y0 * p.width + x0, b = y0 * p.width + x1;
          final c = y1 * p.width + x0, d = y1 * p.width + x1;
          double sample(Uint8List data, int channels, int channel) =>
              (data[a * channels + channel] * (1 - dx) +
                      data[b * channels + channel] * dx) *
                  (1 - dy) +
              (data[c * channels + channel] * (1 - dx) +
                      data[d * channels + channel] * dx) *
                  dy;
          final i = (y * mat.cols + x) * 3;
          final blue = math.min(
            255.0,
            pixels[i] * 255 / math.max(63.75, sample(map, 3, 0)),
          );
          final green = math.min(
            255.0,
            pixels[i + 1] * 255 / math.max(63.75, sample(map, 3, 1)),
          );
          final red = math.min(
            255.0,
            pixels[i + 2] * 255 / math.max(63.75, sample(map, 3, 2)),
          );
          final minimum = math.min(blue, math.min(green, red));
          final t = ((255 - minimum - 2.125) / 12.75).clamp(0.0, 1.0);
          var factor = t * t * (3 - 2 * t);
          if (protection != null) {
            factor = math.max(factor, sample(protection, 1, 0));
          }
          pixels[i] = (255 + (blue - 255) * factor * p.contrast).round().clamp(
            0,
            255,
          );
          pixels[i + 1] = (255 + (green - 255) * factor * p.contrast)
              .round()
              .clamp(0, 255);
          pixels[i + 2] = (255 + (red - 255) * factor * p.contrast)
              .round()
              .clamp(0, 255);
        }
      }
    }
    final encoded = cv.imencode('.png', mat);
    if (!encoded.$1) throw const FormatException('Cannot encode scan');
    return encoded.$2;
  } finally {
    mat.dispose();
  }
}

int _percentile(List<int> histogram, int count, double fraction) {
  final target = math.max(1, (count * fraction).ceil());
  var total = 0;
  for (var i = 0; i < histogram.length; i++) {
    total += histogram[i];
    if (total >= target) return i;
  }
  return 255;
}

Iterable<int> _neighbors(int i, int w, int h) sync* {
  if (i % w > 0) yield i - 1;
  if (i % w + 1 < w) yield i + 1;
  if (i >= w) yield i - w;
  if (i + w < w * h) yield i + w;
}

void _protectPanels(
  Uint8List paper,
  Uint8List content,
  int w,
  int h,
  double reference,
) {
  final visited = Uint8List(w * h), queue = Int32List(w * h);
  bool dark(int i) =>
      paper[i * 3] + paper[i * 3 + 1] + paper[i * 3 + 2] < reference * 3 * .97;
  for (var start = 0; start < visited.length; start++) {
    if (visited[start] != 0 || !dark(start)) continue;
    var head = 0, tail = 1, x0 = w, y0 = h, x1 = 0, y1 = 0;
    queue[0] = start;
    visited[start] = 1;
    while (head < tail) {
      final i = queue[head++], x = i % w, y = i ~/ w;
      x0 = math.min(x0, x);
      y0 = math.min(y0, y);
      x1 = math.max(x1, x);
      y1 = math.max(y1, y);
      for (final next in _neighbors(i, w, h)) {
        if (visited[next] == 0 && dark(next)) {
          visited[next] = 1;
          queue[tail++] = next;
        }
      }
    }
    if (x0 > 1 &&
        y0 > 1 &&
        x1 < w - 2 &&
        y1 < h - 2 &&
        tail > w * h * .005 &&
        tail < w * h * .4 &&
        tail > (x1 - x0 + 1) * (y1 - y0 + 1) * .9) {
      for (var j = 0; j < tail; j++) {
        content[queue[j]] = 1;
      }
    }
  }
}

Uint8List _expand(Uint8List mask, int w, int h, int radius) {
  final expanded = Uint8List.fromList(mask);
  for (var i = 0; i < mask.length; i++) {
    if (mask[i] == 0) continue;
    final x = i % w, y = i ~/ w;
    for (
      var yy = math.max(0, y - radius);
      yy <= math.min(h - 1, y + radius);
      yy++
    ) {
      for (
        var xx = math.max(0, x - radius);
        xx <= math.min(w - 1, x + radius);
        xx++
      ) {
        expanded[yy * w + xx] = 1;
      }
    }
  }
  return expanded;
}

void _fillPaper(Uint8List paper, Uint8List missing, int w, int h) {
  final known = Uint8List(missing.length), queue = Int32List(missing.length);
  var head = 0, tail = 0;
  for (var i = 0; i < known.length; i++) {
    if (missing[i] == 0) {
      known[i] = 1;
      queue[tail++] = i;
    }
  }
  while (head < tail) {
    final i = queue[head++];
    for (final next in _neighbors(i, w, h)) {
      if (known[next] != 0) continue;
      for (var c = 0; c < 3; c++) {
        paper[next * 3 + c] = paper[i * 3 + c];
      }
      known[next] = 1;
      queue[tail++] = next;
    }
  }
  var current = Uint8List.fromList(paper), next = Uint8List.fromList(paper);
  for (var iteration = 0; iteration < 12; iteration++) {
    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        final i = y * w + x;
        if (missing[i] == 0) continue;
        for (var c = 0; c < 3; c++) {
          next[i * 3 + c] =
              (current[(i - 1) * 3 + c] +
                  current[(i + 1) * 3 + c] +
                  current[(i - w) * 3 + c] +
                  current[(i + w) * 3 + c] +
                  2) ~/
              4;
        }
      }
    }
    final swap = current;
    current = next;
    next = swap;
  }
  paper.setAll(0, current);
}
