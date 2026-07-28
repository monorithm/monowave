import 'dart:typed_data';

import '../model/waveform_peaks.dart';
import '../model/waveform_selection.dart';
import '../model/waveform_timeline.dart';

/// A slice of the source, with what to do to it on the way out.
///
/// Regions never hold audio - only a range in the source and a few numbers. An
/// edit is a value, which is what makes both undo and preview cheap.
class WaveformRegion {
  const WaveformRegion({
    required this.sourceStart,
    required this.sourceEnd,
    this.gain = 1.0,
    this.fadeIn = 0,
    this.fadeOut = 0,
  });

  /// Range in the source, in samples. Half-open.
  final int sourceStart;
  final int sourceEnd;

  /// Linear amplitude multiplier. 1.0 leaves the audio alone.
  final double gain;

  /// Fade lengths in samples, applied at the region's own edges.
  final int fadeIn;
  final int fadeOut;

  int get length => sourceEnd - sourceStart;

  bool get isEmpty => length <= 0;

  WaveformRegion copyWith({
    int? sourceStart,
    int? sourceEnd,
    double? gain,
    int? fadeIn,
    int? fadeOut,
  }) => WaveformRegion(
    sourceStart: sourceStart ?? this.sourceStart,
    sourceEnd: sourceEnd ?? this.sourceEnd,
    gain: gain ?? this.gain,
    fadeIn: fadeIn ?? this.fadeIn,
    fadeOut: fadeOut ?? this.fadeOut,
  );

  @override
  bool operator ==(Object other) =>
      other is WaveformRegion &&
      other.sourceStart == sourceStart &&
      other.sourceEnd == sourceEnd &&
      other.gain == gain &&
      other.fadeIn == fadeIn &&
      other.fadeOut == fadeOut;

  @override
  int get hashCode =>
      Object.hash(sourceStart, sourceEnd, gain, fadeIn, fadeOut);

  @override
  String toString() =>
      'WaveformRegion($sourceStart..$sourceEnd, gain: $gain, '
      'fades: $fadeIn/$fadeOut)';
}

/// One editing operation, as a value.
///
/// Sealed so a renderer or an exporter can switch over the set exhaustively and
/// the compiler catches a new kind that was not handled.
sealed class WaveformEdit {
  const WaveformEdit();

  /// A short label, for an undo menu.
  String get label;
}

/// Keeps [selection] and discards everything else.
final class TrimEdit extends WaveformEdit {
  const TrimEdit(this.selection);
  final WaveformSelection selection;

  @override
  String get label => 'Trim';
}

/// Removes [selection], closing the gap.
final class DeleteEdit extends WaveformEdit {
  const DeleteEdit(this.selection);
  final WaveformSelection selection;

  @override
  String get label => 'Delete';
}

/// Cuts the region containing [sample] in two, changing nothing audible.
///
/// Useful on its own only as a setup move: it gives the next edit an edge to
/// act on.
final class SplitEdit extends WaveformEdit {
  const SplitEdit(this.sample);
  final int sample;

  @override
  String get label => 'Split';
}

/// Scales everything overlapping [selection] by [gain].
final class GainEdit extends WaveformEdit {
  const GainEdit(this.selection, this.gain);
  final WaveformSelection selection;
  final double gain;

  @override
  String get label => 'Gain';
}

/// Fades the edges of whatever overlaps [selection].
final class FadeEdit extends WaveformEdit {
  const FadeEdit(this.selection, {this.fadeIn = 0, this.fadeOut = 0});
  final WaveformSelection selection;
  final int fadeIn;
  final int fadeOut;

  @override
  String get label => 'Fade';
}

/// An arrangement of the source: what would be written if it were exported now.
///
/// Non-destructive. Nothing here decodes, copies or mutates audio; the source
/// is untouched until an export reads it.
class WaveformDocument {
  const WaveformDocument(this.regions);

  /// The whole source, unedited.
  factory WaveformDocument.of(WaveformPeaks peaks) => WaveformDocument([
    WaveformRegion(sourceStart: 0, sourceEnd: peaks.lengthInSamples),
  ]);

  final List<WaveformRegion> regions;

  /// Length of the result, in samples.
  int get lengthInSamples =>
      regions.fold(0, (total, region) => total + region.length);

  bool get isEmpty => lengthInSamples == 0;

  Duration durationIn(WaveformTimeline timeline) =>
      timeline.timeAt(lengthInSamples);

  /// Where [outputSample] came from, or null past the end.
  ///
  /// The output timeline and the source timeline diverge as soon as anything is
  /// deleted, and confusing the two is the classic editing bug.
  int? sourceOf(int outputSample) {
    var remaining = outputSample;
    for (final region in regions) {
      if (remaining < region.length) return region.sourceStart + remaining;
      remaining -= region.length;
    }
    return null;
  }

  /// Applies [edit], returning a new document. Never mutates this one.
  WaveformDocument applying(WaveformEdit edit) => switch (edit) {
    TrimEdit(:final selection) => _keepOnly(selection),
    DeleteEdit(:final selection) => _remove(selection),
    SplitEdit(:final sample) => WaveformDocument(_splitAt(regions, sample)),
    GainEdit(:final selection, :final gain) => _mapOverlapping(
      selection,
      (region) => region.copyWith(gain: region.gain * gain),
    ),
    FadeEdit(:final selection, :final fadeIn, :final fadeOut) =>
      _mapOverlapping(
        selection,
        (region) => region.copyWith(fadeIn: fadeIn, fadeOut: fadeOut),
      ),
  };

  /// Splits every region so that [sample] (in *source* space) is an edge.
  static List<WaveformRegion> _splitAt(
    List<WaveformRegion> regions,
    int sample,
  ) {
    final out = <WaveformRegion>[];
    for (final region in regions) {
      if (sample > region.sourceStart && sample < region.sourceEnd) {
        out
          ..add(region.copyWith(sourceEnd: sample, fadeOut: 0))
          ..add(region.copyWith(sourceStart: sample, fadeIn: 0));
      } else {
        out.add(region);
      }
    }
    return out;
  }

  WaveformDocument _keepOnly(WaveformSelection selection) {
    final kept = <WaveformRegion>[];
    for (final region in regions) {
      final start = region.sourceStart < selection.start
          ? selection.start
          : region.sourceStart;
      final end = region.sourceEnd > selection.end
          ? selection.end
          : region.sourceEnd;
      if (end > start) {
        kept.add(region.copyWith(sourceStart: start, sourceEnd: end));
      }
    }
    return WaveformDocument(kept);
  }

  WaveformDocument _remove(WaveformSelection selection) {
    final kept = <WaveformRegion>[];
    for (final region in regions) {
      // Entirely inside the cut.
      if (region.sourceStart >= selection.start &&
          region.sourceEnd <= selection.end) {
        continue;
      }
      // Straddles it: the head and the tail both survive.
      if (region.sourceStart < selection.start &&
          region.sourceEnd > selection.end) {
        kept
          ..add(region.copyWith(sourceEnd: selection.start, fadeOut: 0))
          ..add(region.copyWith(sourceStart: selection.end, fadeIn: 0));
        continue;
      }
      if (region.sourceStart < selection.start &&
          region.sourceEnd > selection.start) {
        kept.add(region.copyWith(sourceEnd: selection.start));
        continue;
      }
      if (region.sourceStart < selection.end &&
          region.sourceEnd > selection.end) {
        kept.add(region.copyWith(sourceStart: selection.end));
        continue;
      }
      kept.add(region);
    }
    return WaveformDocument(kept);
  }

  WaveformDocument _mapOverlapping(
    WaveformSelection selection,
    WaveformRegion Function(WaveformRegion) transform,
  ) {
    // Split at both edges first, so the change lands exactly on the selection
    // rather than on whichever regions happened to touch it.
    var split = _splitAt(regions, selection.start);
    split = _splitAt(split, selection.end);

    return WaveformDocument([
      for (final region in split)
        if (region.sourceStart >= selection.start &&
            region.sourceEnd <= selection.end)
          transform(region)
        else
          region,
    ]);
  }

  /// Peaks for the edited result, derived from [source] without decoding.
  ///
  /// Concatenates each region's slice of the source's finest level and scales
  /// by gain, so the waveform updates the moment an edit is applied instead of
  /// after a round trip through the decoder. This is the payoff of keeping
  /// edits non-destructive.
  ///
  /// Fades are not reflected: they act over samples, and the finest level is
  /// 128 samples wide, so a typical fade is narrower than one bar.
  WaveformPeaks previewPeaks(WaveformPeaks source) {
    final spp = source.finestSamplesPerPixel;
    final view = source.view(0);
    final available = source.pairCount(0);

    final pairs = <int>[];
    for (final region in regions) {
      if (region.isEmpty) continue;

      final firstPair = (region.sourceStart / spp).floor().clamp(0, available);
      final lastPair = (region.sourceEnd / spp).ceil().clamp(0, available);

      for (var pair = firstPair; pair < lastPair; pair++) {
        pairs
          ..add((view[pair * 2] * region.gain).round().clamp(-32768, 32767))
          ..add(
            (view[pair * 2 + 1] * region.gain).round().clamp(-32768, 32767),
          );
      }
    }

    if (pairs.isEmpty) {
      return WaveformPeaks.fromInterleaved(
        Int16List(2),
        sampleRate: source.sampleRate,
        baseSamplesPerPixel: spp,
        lengthInSamples: 0,
      );
    }

    return WaveformPeaks.fromInterleaved(
      Int16List.fromList(pairs),
      sampleRate: source.sampleRate,
      baseSamplesPerPixel: spp,
      channels: source.channels,
      lengthInSamples: lengthInSamples,
    );
  }

  @override
  String toString() =>
      'WaveformDocument(${regions.length} regions, $lengthInSamples samples)';
}
