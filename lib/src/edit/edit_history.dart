import 'waveform_document.dart';

/// Undo and redo over a [WaveformDocument].
///
/// This class keeps snapshots, not inverse operations. It follows the same
/// reasoning as the `EditHistory` class of monolens. Undo is cheap precisely
/// because an edit is a value. There is nothing to invert, and some edits have
/// no inverse. A fade erases the samples that it fades.
///
/// A document is a handful of regions, so a snapshot costs nothing. A hundred
/// steps of history on a heavily cut file is still a few kilobytes.
///
/// This class is deliberately not a `ChangeNotifier`. `lib/` must not import
/// the widget layer of Flutter. A host can wrap this class in the state
/// management that it already uses.
class EditHistory {
  EditHistory(WaveformDocument initial) : _stack = [initial];

  /// How many steps back this class keeps. It removes older steps from the
  /// bottom.
  static const maxDepth = 100;

  final List<WaveformDocument> _stack;
  int _cursor = 0;

  /// The document as it is now.
  WaveformDocument get current => _stack[_cursor];

  /// Edits applied since construction, most recent last. For an undo menu.
  final List<String> appliedLabels = [];

  bool get canUndo => _cursor > 0;
  bool get canRedo => _cursor < _stack.length - 1;

  /// The number of steps taken. The initial state does not count.
  int get depth => _cursor;

  /// Applies [edit] and pushes the result.
  ///
  /// This method erases every step that an undo reversed. This is the usual
  /// branch-and-forget behavior. A tree of history needs a UI that nobody asked
  /// for.
  WaveformDocument apply(WaveformEdit edit) {
    final next = current.applying(edit);

    if (canRedo) {
      _stack.removeRange(_cursor + 1, _stack.length);
      appliedLabels.removeRange(_cursor, appliedLabels.length);
    }

    _stack.add(next);
    appliedLabels.add(edit.label);
    _cursor++;

    if (_stack.length > maxDepth + 1) {
      _stack.removeAt(0);
      appliedLabels.removeAt(0);
      _cursor--;
    }

    return next;
  }

  /// Steps back one edit. Returns the document either way.
  WaveformDocument undo() {
    if (canUndo) _cursor--;
    return current;
  }

  WaveformDocument redo() {
    if (canRedo) _cursor++;
    return current;
  }

  /// Label of the edit that [undo] reverses, for a menu item.
  String? get undoLabel => canUndo ? appliedLabels[_cursor - 1] : null;

  /// Label of the edit that [redo] applies again.
  String? get redoLabel => canRedo ? appliedLabels[_cursor] : null;

  /// Erases all history. The current document becomes the new baseline.
  void reset() {
    final keep = current;
    _stack
      ..clear()
      ..add(keep);
    appliedLabels.clear();
    _cursor = 0;
  }
}
