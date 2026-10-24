import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../app/constants/app_constants.dart';
import '../../../core/l10n/app_strings.dart';
import '../application/library_providers.dart';
import '../domain/table_document.dart';
import '../domain/table_formula.dart';

class TableScreen extends ConsumerStatefulWidget {
  const TableScreen({required this.path, super.key});

  final String path;

  @override
  ConsumerState<TableScreen> createState() => _TableScreenState();
}

class _TableScreenState extends ConsumerState<TableScreen> {
  static const _uuid = Uuid();

  TableDocument? _draft;
  String? _loadedSignature;
  bool _editing = false;
  bool _dirty = false;
  bool _saving = false;
  bool _showHiddenColumns = false;
  final _columnControllers = <String, TextEditingController>{};
  final _cellControllers = <String, TextEditingController>{};
  final _defaultColumnsMenu = MenuController();

  void _toggleHiddenColumns([AppStrings? strings]) {
    HapticFeedback.mediumImpact();
    setState(() {
      _showHiddenColumns = !_showHiddenColumns;
    });
    if (strings != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              _showHiddenColumns
                  ? strings.showHiddenColumns
                  : strings.hideHiddenColumns,
            ),
            duration: const Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  @override
  void dispose() {
    for (final controller in _columnControllers.values) {
      controller.dispose();
    }
    for (final controller in _cellControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _syncDraft(TableDocument table) {
    final signature = table.toPrettyJson();
    if (_dirty || _loadedSignature == signature) return;
    _draft = table;
    _loadedSignature = signature;
    _resetControllers(table);
  }

  void _resetControllers(TableDocument table) {
    for (final controller in _columnControllers.values) {
      controller.dispose();
    }
    for (final controller in _cellControllers.values) {
      controller.dispose();
    }
    _columnControllers
      ..clear()
      ..addEntries(table.columns.map(
        (column) => MapEntry(
          column.id,
          TextEditingController(text: column.title),
        ),
      ));
    _cellControllers.clear();
    for (final row in table.rows) {
      for (final column in table.columns) {
        _cellControllers[_cellKey(row.id, column.id)] =
            TextEditingController(text: row.cells[column.id] ?? '');
      }
    }
  }

  String _cellKey(String rowId, String columnId) => '$rowId::$columnId';

  void _markDirty(TableDocument table) {
    _draft = table;
    _dirty = true;
  }

  // Typing rebuilds the screen so formulas recompute live.
  void _updateColumnTitle(String columnId, String value) {
    final table = _draft;
    if (table == null) return;
    setState(() {
      _markDirty(TableDocument(
        columns: [
          for (final column in table.columns)
            column.id == columnId
                ? TableColumnDef(
                    id: column.id,
                    title: value.trim().isEmpty ? column.title : value,
                    type: column.type,
                  )
                : column,
        ],
        rows: table.rows,
      ));
    });
  }

  void _updateCell(String rowId, String columnId, String value) {
    final table = _draft;
    if (table == null) return;
    setState(() {
      _markDirty(TableDocument(
        columns: table.columns,
        rows: [
          for (final row in table.rows)
            row.id == rowId
                ? TableRowData(
                    id: row.id,
                    cells: {
                      ...row.cells,
                      columnId: value,
                    },
                  )
                : row,
        ],
      ));
    });
  }

  /// Makes [next] the draft and brings the text fields in line with it (a
  /// structural change may have rewritten formulas, or restored old values).
  void _commit(TableDocument next) {
    for (final column in next.columns) {
      final controller = _columnControllers.putIfAbsent(
          column.id, () => TextEditingController(text: column.title));
      if (controller.text != column.title) controller.text = column.title;
    }
    for (final row in next.rows) {
      for (final column in next.columns) {
        final value = row.cells[column.id] ?? '';
        final controller = _cellControllers.putIfAbsent(
            _cellKey(row.id, column.id),
            () => TextEditingController(text: value));
        if (controller.text != value) controller.text = value;
      }
    }
    setState(() => _markDirty(next));
  }

  /// Applies a move / delete and rewrites the formulas so they keep pointing
  /// at the same cells, as a spreadsheet does.
  TableDocument _restructure(TableDocument before, TableDocument after) {
    final next = TableFormula.rewriteReferences(before, after);
    _commit(next);
    return next;
  }

  void _addColumn(AppStrings strings) {
    final table = _draft;
    if (table == null) return;
    final id = _uuid.v4();
    final title = '${strings.columnName} ${table.columns.length + 1}';
    setState(() {
      _columnControllers[id] = TextEditingController(text: title);
      for (final row in table.rows) {
        _cellControllers[_cellKey(row.id, id)] = TextEditingController();
      }
      _markDirty(TableDocument(
        columns: [...table.columns, TableColumnDef(id: id, title: title)],
        rows: [
          for (final row in table.rows)
            TableRowData(
              id: row.id,
              cells: {
                ...row.cells,
                id: '',
              },
            ),
        ],
      ));
    });
  }

  void _addRow() {
    final table = _draft;
    if (table == null) return;
    final id = _uuid.v4();
    final cells = {
      for (final column in table.columns) column.id: '',
    };
    setState(() {
      for (final column in table.columns) {
        _cellControllers[_cellKey(id, column.id)] = TextEditingController();
      }
      _markDirty(TableDocument(
        columns: table.columns,
        rows: [
          ...table.rows,
          TableRowData(id: id, cells: cells),
        ],
      ));
    });
  }

  /// Drag & drop: the dragged column takes the target column's place.
  void _moveColumn(String draggedId, String targetId) {
    final table = _draft;
    if (table == null || draggedId == targetId) return;
    final columns = [...table.columns];
    final from = columns.indexWhere((c) => c.id == draggedId);
    final to = columns.indexWhere((c) => c.id == targetId);
    if (from < 0 || to < 0) return;
    columns.insert(to, columns.removeAt(from));
    HapticFeedback.selectionClick();
    _restructure(table, TableDocument(columns: columns, rows: table.rows));
  }

  /// Drag & drop: the dragged row takes the target row's place.
  void _moveRow(String draggedId, String targetId) {
    final table = _draft;
    if (table == null || draggedId == targetId) return;
    final rows = [...table.rows];
    final from = rows.indexWhere((r) => r.id == draggedId);
    final to = rows.indexWhere((r) => r.id == targetId);
    if (from < 0 || to < 0) return;
    rows.insert(to, rows.removeAt(from));
    HapticFeedback.selectionClick();
    _restructure(table, TableDocument(columns: table.columns, rows: rows));
  }

  // Deleted columns / rows keep their controllers until the next reset, so
  // an undo finds them intact. Undo right after the delete restores the exact
  // previous table (formulas that turned into #REF! included); after other
  // edits it puts the column / row back in place.
  void _deleteColumn(String columnId, AppStrings strings) {
    final table = _draft;
    if (table == null) return;
    // A table file needs at least one column to stay readable.
    if (table.columns.length <= 1) {
      _showMessage(strings.tableKeepsOneColumn);
      return;
    }
    final index = table.columns.indexWhere((c) => c.id == columnId);
    if (index < 0) return;
    final column = table.columns[index];
    final values = {
      for (final row in table.rows) row.id: row.cells[columnId] ?? '',
    };
    HapticFeedback.mediumImpact();
    final after = _restructure(
      table,
      TableDocument(
        columns: [...table.columns]..removeAt(index),
        rows: [
          for (final row in table.rows)
            TableRowData(
              id: row.id,
              cells: Map.of(row.cells)..remove(columnId),
            ),
        ],
      ),
    );
    _showUndo(strings.tableColumnDeleted, strings, () {
      final current = _draft;
      if (current == null || current.columns.any((c) => c.id == columnId)) {
        return;
      }
      if (identical(current, after)) {
        _commit(table);
        return;
      }
      _restructure(
        current,
        TableDocument(
          columns: [...current.columns]
            ..insert(math.min(index, current.columns.length), column),
          rows: [
            for (final row in current.rows)
              TableRowData(
                id: row.id,
                cells: {...row.cells, columnId: values[row.id] ?? ''},
              ),
          ],
        ),
      );
    });
  }

  void _deleteRow(String rowId, AppStrings strings) {
    final table = _draft;
    if (table == null) return;
    final index = table.rows.indexWhere((r) => r.id == rowId);
    if (index < 0) return;
    final row = table.rows[index];
    HapticFeedback.mediumImpact();
    final after = _restructure(
      table,
      TableDocument(
        columns: table.columns,
        rows: [...table.rows]..removeAt(index),
      ),
    );
    _showUndo(strings.tableRowDeleted, strings, () {
      final current = _draft;
      if (current == null || current.rows.any((r) => r.id == rowId)) return;
      if (identical(current, after)) {
        _commit(table);
        return;
      }
      // Columns may have changed meanwhile: keep only the current ones.
      final cells = {
        for (final column in current.columns)
          column.id: row.cells[column.id] ?? '',
      };
      _restructure(
        current,
        TableDocument(
          columns: current.columns,
          rows: [...current.rows]..insert(
              math.min(index, current.rows.length),
              TableRowData(id: rowId, cells: cells),
            ),
        ),
      );
    });
  }

  /// Hidden-by-default columns are the bracketed ones (`[Title]`): checking a
  /// column in the save menu removes its brackets, unchecking adds them.
  void _setColumnShownByDefault(
    String columnId,
    bool shown,
    AppStrings strings,
  ) {
    final table = _draft;
    if (table == null) return;
    final column = table.columns.firstWhere(
      (c) => c.id == columnId,
      orElse: () => const TableColumnDef(id: '', title: ''),
    );
    if (column.id.isEmpty || column.isBracketed == !shown) return;
    final base = _plainTitle(column.title);
    final title = shown
        ? (base.isEmpty ? strings.columnName : base)
        : '[${base.isEmpty ? strings.columnName : base}]';
    HapticFeedback.selectionClick();
    setState(() {
      _columnControllers[columnId]?.text = title;
      _markDirty(TableDocument(
        columns: [
          for (final c in table.columns)
            c.id == columnId
                ? TableColumnDef(id: c.id, title: title, type: c.type)
                : c,
        ],
        rows: table.rows,
      ));
    });
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ));
  }

  void _showUndo(String message, AppStrings strings, VoidCallback onUndo) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: strings.undo,
          onPressed: () {
            if (mounted) onUndo();
          },
        ),
      ));
  }

  Future<void> _save(AppStrings strings) async {
    final table = _draft;
    if (table == null) return;
    _defaultColumnsMenu.close();
    setState(() => _saving = true);
    try {
      await ref.read(libraryControllerProvider).saveTable(widget.path, table);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _editing = false;
        _dirty = false;
        _showHiddenColumns = false;
        _loadedSignature = table.toPrettyJson();
      });
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(strings.noteSaved)));
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(strings.genericError)));
    }
  }

  Widget _saveButton(AppStrings strings, TableDocument table) {
    return MenuAnchor(
      controller: _defaultColumnsMenu,
      menuChildren: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Text(
            strings.defaultVisibleColumns,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
          ),
        ),
        for (final column in table.columns)
          CheckboxMenuButton(
            value: !column.isBracketed,
            closeOnActivate: false,
            onChanged: (value) =>
                _setColumnShownByDefault(column.id, value ?? false, strings),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                switch (TableFormula.parseHeader(column.title).label) {
                  '' => column.title,
                  final label => label,
                },
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
      ],
      // Long press lists the columns to show by default; double tap toggles
      // the hidden ([…]) columns, as on the edit button. The tooltip only
      // shows on mouse hover so it doesn't swallow the long press.
      builder: (context, controller, _) => Tooltip(
        message: '${strings.save}\n${strings.longPressSaveForColumns}\n'
            '${strings.doubleTapToggleHiddenColumns}',
        triggerMode: TooltipTriggerMode.manual,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPress: _saving
              ? null
              : () {
                  HapticFeedback.mediumImpact();
                  controller.isOpen ? controller.close() : controller.open();
                },
          onDoubleTap: _saving ? null : () => _toggleHiddenColumns(strings),
          child: IconButton(
            icon: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            onPressed: _saving ? null : () => _save(strings),
          ),
        ),
      ),
    );
  }

  Widget _canvas(TableDocument table, AppStrings strings) {
    return _TableCanvas(
      table: table,
      editing: _editing,
      showHiddenColumns: _showHiddenColumns,
      strings: strings,
      columnControllers: _columnControllers,
      cellControllers: _cellControllers,
      onColumnChanged: _updateColumnTitle,
      onCellChanged: _updateCell,
      onAddColumn: () => _addColumn(strings),
      onAddRow: _addRow,
      onMoveColumn: _moveColumn,
      onMoveRow: _moveRow,
      onDeleteColumn: (id) => _deleteColumn(id, strings),
      onDeleteRow: (id) => _deleteRow(id, strings),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final table = ref.watch(tableDocumentProvider(widget.path));
    // Sync before the app bar is built: its edit button needs the draft, and
    // the body (which also syncs) is built after it.
    if (table.value case final data?) _syncDraft(data);

    return Scaffold(
      appBar: AppBar(
        title: Text(p.basenameWithoutExtension(widget.path)),
        actions: [
          if (_draft != null)
            // Long press or double tap toggles the hidden ([…]) columns. The
            // tooltip only shows on mouse hover: as a long-press tooltip (the
            // touch default) it would swallow that gesture.
            Tooltip(
              message: '${_editing ? strings.cancel : strings.edit}\n'
                  '${strings.toggleHiddenColumnsHint}',
              triggerMode: TooltipTriggerMode.manual,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPress:
                    _saving ? null : () => _toggleHiddenColumns(strings),
                onDoubleTap:
                    _saving ? null : () => _toggleHiddenColumns(strings),
                child: IconButton(
                  icon: Icon(_editing ? Icons.close : Icons.edit_outlined),
                  onPressed: _saving
                      ? null
                      : () => setState(() {
                            _editing = !_editing;
                            if (!_editing) {
                              _showHiddenColumns = false;
                              _defaultColumnsMenu.close();
                            }
                          }),
                ),
              ),
            ),
          if (_editing && _draft != null) _saveButton(strings, _draft!),
        ],
      ),
      body: table.when(
        loading: () => _draft == null
            ? const Center(child: CircularProgressIndicator())
            : _canvas(_draft!, strings),
        error: (_, __) => Center(child: Text(strings.genericError)),
        data: (data) {
          if (data == null) {
            return Center(child: Text(strings.incompatibleTable));
          }
          _syncDraft(data);
          return _canvas(_draft ?? data, strings);
        },
      ),
    );
  }
}

/// `[Title]` → `Title`; other titles are returned trimmed.
String _plainTitle(String title) {
  final trimmed = title.trim();
  return TableDocument.isBracketColumnTitle(trimmed)
      ? trimmed.substring(1, trimmed.length - 1).trim()
      : trimmed;
}

/// Payload of a column or row being dragged in edit mode.
class _TableDrag {
  const _TableDrag.column(this.id) : isColumn = true;
  const _TableDrag.row(this.id) : isColumn = false;

  final String id;
  final bool isColumn;
}

class _TableCanvas extends StatefulWidget {
  const _TableCanvas({
    required this.table,
    required this.editing,
    required this.showHiddenColumns,
    required this.strings,
    required this.columnControllers,
    required this.cellControllers,
    required this.onColumnChanged,
    required this.onCellChanged,
    required this.onAddColumn,
    required this.onAddRow,
    required this.onMoveColumn,
    required this.onMoveRow,
    required this.onDeleteColumn,
    required this.onDeleteRow,
  });

  final TableDocument table;
  final bool editing;
  final bool showHiddenColumns;
  final AppStrings strings;
  final Map<String, TextEditingController> columnControllers;
  final Map<String, TextEditingController> cellControllers;
  final void Function(String columnId, String value) onColumnChanged;
  final void Function(String rowId, String columnId, String value)
      onCellChanged;
  final VoidCallback onAddColumn;
  final VoidCallback onAddRow;
  final void Function(String draggedId, String targetId) onMoveColumn;
  final void Function(String draggedId, String targetId) onMoveRow;
  final ValueChanged<String> onDeleteColumn;
  final ValueChanged<String> onDeleteRow;

  @override
  State<_TableCanvas> createState() => _TableCanvasState();
}

class _TableCanvasState extends State<_TableCanvas> {
  static const _handleColumnWidth = 80.0;
  static const _autoScrollEdge = 56.0;
  static const _autoScrollStep = 14.0;

  final _vertical = ScrollController();
  final _horizontal = ScrollController();
  final _viewportKey = GlobalKey();
  Timer? _autoScrollTimer;
  Offset? _dragPosition;
  _ActiveField? _active;

  // Kanban-style drag & drop: the whole row / column follows the pointer and
  // the others make room for it right away; the new order is applied on
  // release.
  _TableDrag? _drag;

  /// Where the dragged row / column sits for now, as an index in
  /// [_baseRowIds] / [_baseColumnIds]; null while it is still in its place.
  int? _dragIndex;

  /// Order of the table (base) and order on screen (with the drag preview),
  /// as of the last build.
  List<String> _baseRowIds = const [];
  List<String> _baseColumnIds = const [];
  List<String> _shownRowIds = const [];
  List<String> _shownColumnIds = const [];

  /// Each row's handle cell and each column's header cell, to measure them.
  final _rowProbes = <String, BuildContext>{};
  final _columnProbes = <String, BuildContext>{};

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  // ── Drag & drop ─────────────────────────────────────────────────────────

  bool _isDragged(String id, {required bool column}) =>
      _drag != null && _drag!.id == id && _drag!.isColumn == column;

  /// [items] in the order on screen: the dragged one moved to [_dragIndex].
  List<T> _preview<T>(
    List<T> items,
    String Function(T item) idOf, {
    required bool columns,
  }) {
    final drag = _drag;
    final to = _dragIndex;
    if (drag == null || to == null || drag.isColumn != columns) return items;
    final from = items.indexWhere((item) => idOf(item) == drag.id);
    if (from < 0 || from == to || to >= items.length) return items;
    final list = [...items];
    list.insert(to, list.removeAt(from));
    return list;
  }

  Rect? _rectOf(String id, {required bool column}) {
    final context = (column ? _columnProbes : _rowProbes)[id];
    if (context == null || !context.mounted) return null;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _onDragStarted(_TableDrag data) {
    HapticFeedback.mediumImpact();
    setState(() {
      _drag = data;
      _dragIndex = null;
    });
    _autoScrollTimer?.cancel();
    _autoScrollTimer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _autoScroll(),
    );
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _dragPosition = details.globalPosition;
    _updatePreview();
  }

  void _onDragEnded() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _dragPosition = null;
    final drag = _drag;
    final to = _dragIndex;
    if (drag == null) return;
    final base = drag.isColumn ? _baseColumnIds : _baseRowIds;
    setState(() {
      _drag = null;
      _dragIndex = null;
    });
    final from = base.indexOf(drag.id);
    if (to == null || from < 0 || to == from || to >= base.length) return;
    if (drag.isColumn) {
      widget.onMoveColumn(drag.id, base[to]);
    } else {
      widget.onMoveRow(drag.id, base[to]);
    }
  }

  /// Moves the dragged row / column to the place under the pointer. It only
  /// moves when it would still be under the pointer once there, so rows of
  /// different heights don't swap back and forth.
  void _updatePreview() {
    final drag = _drag;
    final position = _dragPosition;
    if (drag == null || position == null) return;
    final column = drag.isColumn;
    final ids = column ? _shownColumnIds : _shownRowIds;
    final current = ids.indexOf(drag.id);
    final dragged = _rectOf(drag.id, column: column);
    if (current < 0 || dragged == null) return;
    double start(Rect r) => column ? r.left : r.top;
    double end(Rect r) => column ? r.right : r.bottom;
    final at = column ? position.dx : position.dy;
    final size = end(dragged) - start(dragged);

    int? to;
    if (at < start(dragged)) {
      for (var i = current - 1; i >= 0; i--) {
        final r = _rectOf(ids[i], column: column);
        if (r == null) return;
        if (at >= start(r) || i == 0) {
          to = at < start(r) + size ? i : (i + 1 < current ? i + 1 : null);
          break;
        }
      }
    } else if (at >= end(dragged)) {
      for (var i = current + 1; i < ids.length; i++) {
        final r = _rectOf(ids[i], column: column);
        if (r == null) return;
        if (at < end(r) || i == ids.length - 1) {
          to = at >= end(r) - size ? i : (i - 1 > current ? i - 1 : null);
          break;
        }
      }
    }
    if (to == null || to == current) return;
    // The others keep their relative order, so moving it to `to` on screen
    // is moving it to `to` in the base order.
    HapticFeedback.selectionClick();
    setState(() => _dragIndex = to);
  }

  /// Scrolls the table while a dragged column / row is held near an edge, so
  /// it can reach the part of the table that is off screen.
  void _autoScroll() {
    final position = _dragPosition;
    final drag = _drag;
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (position == null || drag == null || box == null || !box.hasSize) {
      return;
    }
    final local = box.globalToLocal(position);
    if (drag.isColumn) {
      _nudge(_horizontal, local.dx, box.size.width);
    } else {
      _nudge(_vertical, local.dy, box.size.height);
    }
    _updatePreview();
  }

  void _nudge(ScrollController controller, double at, double extent) {
    if (!controller.hasClients) return;
    final double delta;
    if (at < _autoScrollEdge) {
      delta = -_autoScrollStep;
    } else if (at > extent - _autoScrollEdge) {
      delta = _autoScrollStep;
    } else {
      return;
    }
    final position = controller.position;
    final target = (position.pixels + delta)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (target != position.pixels) controller.jumpTo(target);
  }

  /// The empty slot the dragged row / column leaves (and moves along): the
  /// same tree whether dragged or not, so the drag survives the rebuilds.
  Widget _slot(bool dragged, Widget cell) => DecoratedBox(
        decoration: BoxDecoration(
          color: dragged
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.10)
              : Colors.transparent,
        ),
        child: Opacity(opacity: dragged ? 0.2 : 1, child: cell),
      );

  Widget _dragHandle({
    required _TableDrag data,
    required Widget Function() feedback,
    required Color color,
  }) {
    final handle = Semantics(
      label: widget.strings.dragToMove,
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: SizedBox(
          width: 32,
          height: 32,
          child: Icon(Icons.drag_indicator, size: 20, color: color),
        ),
      ),
    );
    // The feedback is the whole row / column, built when the drag starts and
    // held where it was grabbed.
    final picture = Builder(builder: (_) => feedback());
    Offset anchor(Draggable<Object> d, BuildContext context, Offset position) {
      final rect = _rectOf(data.id, column: data.isColumn);
      return rect == null
          ? childDragAnchorStrategy(d, context, position)
          : position - rect.topLeft;
    }

    // A row only moves up and down, a column left and right.
    final axis = data.isColumn ? Axis.horizontal : Axis.vertical;

    // Mouse: drag right away. Touch: a short hold first, so a quick swipe
    // on the handle still scrolls the table.
    final isDesktop = switch (defaultTargetPlatform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux =>
        true,
      _ => false,
    };
    if (isDesktop) {
      return Draggable<_TableDrag>(
        data: data,
        axis: axis,
        feedback: picture,
        dragAnchorStrategy: anchor,
        onDragStarted: () => _onDragStarted(data),
        onDragUpdate: _onDragUpdate,
        onDragEnd: (_) => _onDragEnded(),
        child: handle,
      );
    }
    return LongPressDraggable<_TableDrag>(
      data: data,
      axis: axis,
      delay: const Duration(milliseconds: 180),
      feedback: picture,
      dragAnchorStrategy: anchor,
      onDragStarted: () => _onDragStarted(data),
      onDragUpdate: _onDragUpdate,
      onDragEnd: (_) => _onDragEnded(),
      child: handle,
    );
  }

  /// The dragged row or column as it looks in the table, lifted.
  Widget _feedbackFrame(Widget child) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 10,
      color: scheme.surface,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: Border.all(color: scheme.primary, width: 2),
          borderRadius: BorderRadius.circular(6),
        ),
        child: child,
      ),
    );
  }

  Widget _feedbackCell(
    String text, {
    required double width,
    required double height,
    Color? color,
    TextStyle? style,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      alignment: AlignmentDirectional.centerStart,
      decoration: BoxDecoration(
        color: color,
        border: Border.all(color: scheme.outlineVariant, width: 0.5),
      ),
      child: Text(
        text,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    );
  }

  // ── Formula references ─────────────────────────────────────────────────

  void _onFieldFocus(bool focused, _ActiveField field) {
    if (focused) {
      if (_active?.key != field.key) setState(() => _active = field);
    } else if (_active?.key == field.key) {
      setState(() => _active = null);
    }
  }

  Widget _watchFocus(_ActiveField field, Widget child) => Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) => _onFieldFocus(focused, field),
        child: child,
      );

  /// While a formula is being typed (a cell starting with `=`, or a title
  /// holding `=`), tapping another cell inserts its reference, like Excel.
  bool get _pickingReferences {
    final field = _active;
    if (field == null || !widget.editing) return false;
    final text = field.controller.text;
    return field.isHeader
        ? text.contains('=')
        : text.trimLeft().startsWith('=');
  }

  void _insertReference(String reference) {
    final field = _active;
    if (field == null) return;
    final controller = field.controller;
    final text = controller.text;
    final selection = controller.selection;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final next = text.replaceRange(start, end, reference);
    controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + reference.length),
    );
    HapticFeedback.selectionClick();
    field.onChanged(next);
  }

  /// Puts a tap catcher over [cell] while references are being picked. The
  /// Stack is always there so the cell's text field keeps its state.
  Widget _pickTarget(
    Widget cell, {
    required String key,
    required String Function(bool forHeader) reference,
  }) {
    final picking = _pickingReferences && _active?.key != key;
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        cell,
        if (picking)
          Positioned.fill(
            // Inside the text fields' tap region: the formula being typed
            // keeps the focus (and the keyboard stays up).
            child: TextFieldTapRegion(
              child: MouseRegion(
                cursor: SystemMouseCursors.cell,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _insertReference(reference(_active!.isHeader)),
                  child: ColoredBox(
                    color: scheme.tertiary.withValues(alpha: 0.06),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ── Layout ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final table = widget.table;
    final editing = widget.editing;
    final strings = widget.strings;
    final scheme = Theme.of(context).colorScheme;
    final borderColor = scheme.outlineVariant;
    final isMobile =
        MediaQuery.sizeOf(context).width < AppConstants.desktopBreakpoint;
    final padding = isMobile ? 12.0 : 20.0;
    final cellConstraints = isMobile
        ? const BoxConstraints(minWidth: 120, maxWidth: 240)
        : const BoxConstraints(minWidth: 140, maxWidth: 260);
    final evaluator = TableEvaluator(
      table,
      decimalSeparator: strings.locale.languageCode == 'en' ? '.' : ',',
    );
    final columnIndex = {
      for (final (i, c) in table.columns.indexed) c.id: i,
    };
    // The title being typed stays visible even once it gets brackets.
    final activeColumn = _active?.isHeader ?? false ? _active!.columnId : null;

    final displayedColumns = widget.showHiddenColumns
        ? table.columns
        : table.columns
            .where((c) =>
                !TableDocument.isBracketColumnTitle(c.title) ||
                c.id == activeColumn)
            .toList();
    // On screen: the dragged row / column at the place it is held over.
    final shownColumns = _preview(displayedColumns, (c) => c.id, columns: true);
    final shownRows = _preview(
      table.rows.indexed.toList(),
      (r) => r.$2.id,
      columns: false,
    );
    _baseColumnIds = [for (final c in displayedColumns) c.id];
    _shownColumnIds = [for (final c in shownColumns) c.id];
    _baseRowIds = [for (final r in table.rows) r.id];
    _shownRowIds = [for (final (_, r) in shownRows) r.id];

    final Widget tableWidget;
    if (displayedColumns.isEmpty) {
      tableWidget = DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: borderColor),
          borderRadius: BorderRadius.circular(8),
          color: scheme.surfaceContainerLow,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.visibility_off_outlined,
                  size: 36, color: scheme.primary),
              const SizedBox(height: 10),
              Text(
                strings.allColumnsHidden,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                strings.longPressToToggleColumns,
                style: TextStyle(fontSize: 13, color: scheme.outline),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    } else {
      double widthOf(TableColumnDef column) =>
          _rectOf(column.id, column: true)?.width ?? cellConstraints.minWidth;
      double heightOf(TableRowData row) =>
          _rectOf(row.id, column: false)?.height ?? 44;

      Widget rowFeedback(int rowIndex, TableRowData row) {
        final height = heightOf(row);
        return _feedbackFrame(Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: _handleColumnWidth,
              height: height,
              child: Icon(Icons.drag_indicator, color: scheme.primary),
            ),
            for (final column in shownColumns)
              _feedbackCell(
                evaluator.displayAt(rowIndex, columnIndex[column.id]!),
                width: widthOf(column),
                height: height,
              ),
          ],
        ));
      }

      Widget columnFeedback(TableColumnDef column) {
        final index = columnIndex[column.id]!;
        final width = widthOf(column);
        return _feedbackFrame(Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _feedbackCell(
              TableFormula.parseHeader(column.title).display,
              width: width,
              height: _rectOf(column.id, column: true)?.height ?? 48,
              color: scheme.primaryContainer,
              style: TextStyle(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
            for (final (rowIndex, row) in table.rows.indexed)
              _feedbackCell(
                evaluator.displayAt(rowIndex, index),
                width: width,
                height: heightOf(row),
              ),
          ],
        ));
      }

      Widget headerCell(TableColumnDef column) {
        final index = columnIndex[column.id]!;
        final letters = TableFormula.columnLetters(index);
        final key = 'h:${column.id}';
        final controller = widget.columnControllers[column.id];
        void onChanged(String value) =>
            widget.onColumnChanged(column.id, value);
        Widget cell = _HeaderCell(
          controller: controller,
          header: TableFormula.parseHeader(column.title),
          letters: letters,
          editing: editing,
          onChanged: onChanged,
          formulaTooltip: strings.formulaColumn,
          dragHandle: editing
              ? _dragHandle(
                  data: _TableDrag.column(column.id),
                  feedback: () => columnFeedback(column),
                  color: scheme.onPrimaryContainer.withValues(alpha: 0.7),
                )
              : null,
          onDelete: editing ? () => widget.onDeleteColumn(column.id) : null,
          deleteTooltip: strings.deleteTableColumn,
        );
        if (editing && controller != null) {
          cell = _watchFocus(
            _ActiveField(
              key: key,
              controller: controller,
              onChanged: onChanged,
              isHeader: true,
              columnId: column.id,
            ),
            cell,
          );
        }
        final sized = ConstrainedBox(
          constraints: cellConstraints,
          child: editing
              ? _pickTarget(
                  cell,
                  key: key,
                  reference: (forHeader) =>
                      forHeader ? letters : '$letters:$letters',
                )
              : cell,
        );
        // Keyed (unique in the whole table): a moved column keeps its cells
        // and an ongoing drag.
        return KeyedSubtree(
          key: ValueKey('h:${column.id}'),
          child: editing
              ? _Probe(
                  id: column.id,
                  registry: _columnProbes,
                  child: _slot(_isDragged(column.id, column: true), sized),
                )
              : sized,
        );
      }

      Widget bodyCell(int rowIndex, TableRowData row, TableColumnDef column) {
        final index = columnIndex[column.id]!;
        final letters = TableFormula.columnLetters(index);
        final key = '${row.id}::${column.id}';
        final controller = widget.cellControllers[key];
        final value = evaluator.valueAt(rowIndex, index);
        final columnFormula = evaluator.hasColumnFormula(index);
        final ownFormula =
            TableFormula.cellFormula(row.cells[column.id] ?? '') != null;
        void onChanged(String text) =>
            widget.onCellChanged(row.id, column.id, text);
        Widget cell = _BodyCell(
          controller: columnFormula ? null : controller,
          display: evaluator.displayAt(rowIndex, index),
          isError: value is ErrorValue,
          isComputed: columnFormula || ownFormula,
          editing: editing,
          onChanged: onChanged,
        );
        if (editing && controller != null && !columnFormula) {
          cell = _watchFocus(
            _ActiveField(
              key: key,
              controller: controller,
              onChanged: onChanged,
              isHeader: false,
              columnId: column.id,
            ),
            cell,
          );
        }
        final sized = ConstrainedBox(
          constraints: cellConstraints,
          child: editing
              ? _pickTarget(
                  cell,
                  key: key,
                  reference: (forHeader) =>
                      forHeader ? letters : '$letters${rowIndex + 1}',
                )
              : cell,
        );
        return KeyedSubtree(
          key: ValueKey('${row.id}:${column.id}'),
          child: editing
              ? _slot(
                  _isDragged(column.id, column: true) ||
                      _isDragged(row.id, column: false),
                  sized,
                )
              : sized,
        );
      }

      tableWidget = DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: borderColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Table(
            // Columns size to their content (clamped by the cells) and the
            // table scrolls when wider than the screen; on a phone the flex
            // stretches a narrow table to the full width.
            defaultColumnWidth: const IntrinsicColumnWidth(flex: 1),
            columnWidths: editing
                ? const {0: FixedColumnWidth(_handleColumnWidth)}
                : null,
            defaultVerticalAlignment:
                TableCellVerticalAlignment.intrinsicHeight,
            border: TableBorder.all(color: borderColor),
            children: [
              TableRow(
                key: const ValueKey('header'),
                decoration: BoxDecoration(color: scheme.primaryContainer),
                children: [
                  if (editing)
                    Center(
                      key: const ValueKey('fx'),
                      child: Icon(
                        Icons.functions,
                        size: 18,
                        color: scheme.onPrimaryContainer.withValues(alpha: 0.5),
                      ),
                    ),
                  for (final column in shownColumns) headerCell(column),
                ],
              ),
              // Keyed: a moved row keeps its cells (and an ongoing drag).
              for (final (rowIndex, row) in shownRows)
                TableRow(
                  key: ValueKey(row.id),
                  children: [
                    if (editing)
                      _Probe(
                        key: ValueKey('handle:${row.id}'),
                        id: row.id,
                        registry: _rowProbes,
                        child: _slot(
                          _isDragged(row.id, column: false),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _dragHandle(
                                data: _TableDrag.row(row.id),
                                feedback: () => rowFeedback(rowIndex, row),
                                color: scheme.outline,
                              ),
                              IconButton(
                                tooltip: strings.deleteTableRow,
                                visualDensity: VisualDensity.compact,
                                iconSize: 20,
                                color: scheme.error,
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => widget.onDeleteRow(row.id),
                              ),
                            ],
                          ),
                        ),
                      ),
                    for (final column in shownColumns)
                      bodyCell(rowIndex, row, column),
                  ],
                ),
            ],
          ),
        ),
      );
    }

    // Keyed on the set of visible columns (not their order) so showing /
    // hiding columns cross-fades while a drag & drop reorder is instant.
    final visibleKey =
        (displayedColumns.map((c) => c.id).toList()..sort()).join('_');
    final animatedTable = AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          return FadeTransition(
            opacity: animation,
            child: child,
          );
        },
        child: KeyedSubtree(
          key: ValueKey('table_view_${editing}_$visibleKey'),
          child: tableWidget,
        ),
      ),
    );

    final addColumn = _PlusButton(
      tooltip: strings.addTableColumn,
      onPressed: widget.onAddColumn,
    );
    final addRow = _PlusButton(
      tooltip: strings.addTableRow,
      onPressed: widget.onAddRow,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final Widget content;
        if (isMobile) {
          // Phone: at least the screen width, wider tables scroll sideways.
          // The plus buttons sit under the table, always reachable.
          content = ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: math.max(0, constraints.maxWidth - padding * 2),
            ),
            child: animatedTable,
          );
        } else {
          content = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  animatedTable,
                  if (editing) ...[const SizedBox(width: 8), addColumn],
                ],
              ),
              if (editing) ...[const SizedBox(height: 8), addRow],
            ],
          );
        }

        // Vertical scroll outside, horizontal inside: the table can exceed
        // the screen in both directions.
        final scroller = Center(
          key: _viewportKey,
          child: Scrollbar(
            controller: _vertical,
            child: SingleChildScrollView(
              controller: _vertical,
              padding: EdgeInsets.only(
                top: padding,
                // Room for the formula banner over the last rows.
                bottom: padding + (editing ? 64 : 0),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: isMobile
                    ? CrossAxisAlignment.start
                    : CrossAxisAlignment.center,
                children: [
                  Scrollbar(
                    controller: _horizontal,
                    child: SingleChildScrollView(
                      controller: _horizontal,
                      scrollDirection: Axis.horizontal,
                      padding: EdgeInsets.symmetric(horizontal: padding),
                      child: content,
                    ),
                  ),
                  if (isMobile && editing)
                    Padding(
                      padding: EdgeInsets.fromLTRB(padding, 8, padding, 0),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          addColumn,
                          const SizedBox(width: 8),
                          addRow,
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        );

        return Stack(
          children: [
            scroller,
            if (_pickingReferences)
              Positioned(
                left: padding,
                right: padding,
                bottom: padding,
                child: TextFieldTapRegion(
                  child: _FormulaBanner(
                    hint: strings.formulaPickHint,
                    doneLabel: strings.done,
                    onDone: () => FocusManager.instance.primaryFocus?.unfocus(),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Registers its element under [id] so the table can measure the cell
/// (the drag & drop needs each row's and column's place on screen).
class _Probe extends StatefulWidget {
  const _Probe({
    required this.id,
    required this.registry,
    required this.child,
    super.key,
  });

  final String id;
  final Map<String, BuildContext> registry;
  final Widget child;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    widget.registry[widget.id] = context;
  }

  @override
  void didUpdateWidget(covariant _Probe old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id || old.registry != widget.registry) {
      if (old.registry[old.id] == context) old.registry.remove(old.id);
      widget.registry[widget.id] = context;
    }
  }

  @override
  void dispose() {
    if (widget.registry[widget.id] == context) {
      widget.registry.remove(widget.id);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The text field currently focused in edit mode, for formula references.
class _ActiveField {
  const _ActiveField({
    required this.key,
    required this.controller,
    required this.onChanged,
    required this.isHeader,
    required this.columnId,
  });

  final String key;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final bool isHeader;
  final String columnId;
}

class _FormulaBanner extends StatelessWidget {
  const _FormulaBanner({
    required this.hint,
    required this.doneLabel,
    required this.onDone,
  });

  final String hint;
  final String doneLabel;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 3,
      color: scheme.tertiaryContainer,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
        child: Row(
          children: [
            Icon(Icons.functions, size: 20, color: scheme.onTertiaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                hint,
                style: TextStyle(color: scheme.onTertiaryContainer),
              ),
            ),
            TextButton(onPressed: onDone, child: Text(doneLabel)),
          ],
        ),
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell({
    required this.controller,
    required this.header,
    required this.letters,
    required this.editing,
    required this.onChanged,
    required this.deleteTooltip,
    required this.formulaTooltip,
    this.dragHandle,
    this.onDelete,
  });

  final TextEditingController? controller;
  final ColumnHeader header;
  final String letters;
  final bool editing;
  final ValueChanged<String> onChanged;
  final String deleteTooltip;
  final String formulaTooltip;
  final Widget? dragHandle;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onPrimaryContainer.withValues(alpha: 0.7);

    if (editing && controller != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          children: [
            if (dragHandle != null) dragHandle!,
            // Column letter, for formulas (A, B, C…).
            Container(
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: scheme.onPrimaryContainer.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                letters,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: muted,
                ),
              ),
            ),
            Expanded(
              child: TextField(
                controller: controller,
                onChanged: onChanged,
                style: TextStyle(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  filled: false,
                  contentPadding: EdgeInsets.zero,
                  prefixIcon: header.hidden
                      ? Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Icon(
                            Icons.visibility_off_outlined,
                            size: 16,
                            color: muted,
                          ),
                        )
                      : null,
                  prefixIconConstraints:
                      const BoxConstraints(minWidth: 20, maxHeight: 20),
                ),
              ),
            ),
            if (onDelete != null)
              IconButton(
                tooltip: deleteTooltip,
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                color: scheme.error,
                icon: const Icon(Icons.delete_outline),
                onPressed: onDelete,
              ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (header.hidden) ...[
            Icon(Icons.visibility_off_outlined, size: 15, color: muted),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              header.display,
              style: TextStyle(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (header.formula != null) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: '$formulaTooltip : =${header.formula}',
              child: Icon(Icons.functions, size: 15, color: muted),
            ),
          ],
        ],
      ),
    );
  }
}

class _BodyCell extends StatelessWidget {
  const _BodyCell({
    required this.controller,
    required this.display,
    required this.isError,
    required this.isComputed,
    required this.editing,
    required this.onChanged,
  });

  /// Null for a read-only cell (view mode, or a calculated column).
  final TextEditingController? controller;

  /// The cell's value, or its formula's result.
  final String display;
  final bool isError;
  final bool isComputed;
  final bool editing;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final resultStyle = TextStyle(
      color: isError ? scheme.error : null,
      fontWeight: isError ? FontWeight.w600 : null,
    );
    final Widget child;
    if (editing && controller != null) {
      // The text field stays the first child so typing `=` (which adds the
      // result line) doesn't rebuild it and drop the focus.
      child = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: controller,
            onChanged: onChanged,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              filled: false,
              contentPadding: EdgeInsets.zero,
            ),
          ),
          if (isComputed)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '= $display',
                style: resultStyle.copyWith(
                  fontSize: 12,
                  color: isError ? scheme.error : scheme.tertiary,
                ),
              ),
            ),
        ],
      );
    } else if (editing && isComputed) {
      // Calculated column: the value comes from the title's formula.
      child = Row(
        children: [
          Icon(Icons.functions, size: 14, color: scheme.tertiary),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              display.isEmpty ? ' ' : display,
              style: resultStyle.copyWith(
                fontStyle: FontStyle.italic,
                color: isError ? scheme.error : scheme.tertiary,
              ),
            ),
          ),
        ],
      );
    } else {
      child = Text(display.isEmpty ? ' ' : display, style: resultStyle);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: child,
    );
  }
}

class _PlusButton extends StatelessWidget {
  const _PlusButton({
    required this.tooltip,
    required this.onPressed,
  });

  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 40,
        height: 40,
        child: Material(
          color: scheme.secondaryContainer,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: Center(
              child: Icon(
                Icons.add,
                size: 24,
                color: scheme.onSecondaryContainer,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
