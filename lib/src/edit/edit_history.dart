import 'waveform_document.dart';

/// Undo and redo over a [WaveformDocument].
///
/// Snapshots rather than inverse operations, following the same reasoning
/// monolens's `EditHistory` uses: undo is cheap precisely because an edit is a
/// value. There is nothing to invert, and some edits have no inverse anyway -
/// a fade destroys the samples it fades.
///
/// A document is a handful of regions, so a snapshot costs nothing. A hundred
/// steps of history on a heavily cut file is still a few kilobytes.
///
/// Deliberately not a `ChangeNotifier`: `lib/` must not import Flutter's widget
/// layer, and a host can wrap this in whatever state management it already
/// uses.
class EditHistory {
  EditHistory(WaveformDocument initial) : _stack = [initial];

  /// How many steps back are kept. Older ones fall off the bottom.
  static const maxDepth = 100;

  final List<WaveformDocument> _stack;
  int _cursor = 0;

  /// The document as it stands.
  WaveformDocument get current => _stack[_cursor];

  /// Edits applied since construction, most recent last. For an undo menu.
  final List<String> appliedLabels = [];

  bool get canUndo => _cursor > 0;
  bool get canRedo => _cursor < _stack.length - 1;

  /// Steps taken, not counting the initial state.
  int get depth => _cursor;

  /// Applies [edit] and pushes the result.
  ///
  /// Anything that had been undone is discarded - the usual branch-and-forget
  /// behaviour, because keeping a tree would need UI nobody asked for.
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

  /// Label of the edit [undo] would reverse, for a menu item.
  String? get undoLabel => canUndo ? appliedLabels[_cursor - 1] : null;

  /// Label of the edit [redo] would reapply.
  String? get redoLabel => canRedo ? appliedLabels[_cursor] : null;

  /// Drops all history, keeping the current document as the new baseline.
  void reset() {
    final keep = current;
    _stack
      ..clear()
      ..add(keep);
    appliedLabels.clear();
    _cursor = 0;
  }
}
