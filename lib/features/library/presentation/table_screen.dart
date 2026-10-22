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
  static const _handleColumnWidth = 108.0;
  static const _autoScrollEdge = 56.0;
  static const _autoScrollStep = 14.0;

  final _vertical = ScrollController();
  final _horizontal = ScrollController();
  final _viewportKey = GlobalKey();
  Timer? _autoScrollTimer;
  Offset? _dragPosition;
  String? _hoverColumnId;
  String? _hoverRowId;
  _ActiveField? _active;

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  // ── Drag & drop ─────────────────────────────────────────────────────────

  void _onDragStarted() {
    HapticFeedback.mediumImpact();
    _autoScrollTimer?.cancel();
    _autoScrollTimer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _autoScroll(),
    );
  }

  void _onDragEnded() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _dragPosition = null;
    if (_hoverColumnId != null || _hoverRowId != null) {
      setState(() {
        _hoverColumnId = null;
        _hoverRowId = null;
      });
    }
  }

  /// Scrolls the table while a dragged column / row is held near an edge, so
  /// it can reach the part of the table that is off screen.
  void _autoScroll() {
    final position = _dragPosition;
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (position == null || box == null || !box.hasSize) return;
    final local = box.globalToLocal(position);
    _nudge(_horizontal, local.dx, box.size.width);
    _nudge(_vertical, local.dy, box.size.height);
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

  void _setHover({String? columnId, String? rowId}) {
    if (_hoverColumnId == columnId && _hoverRowId == rowId) return;
    setState(() {
      _hoverColumnId = columnId;
      _hoverRowId = rowId;
    });
  }

  /// Wraps a cell so a dragged column (or row, when [rowId] is set) can be
  /// dropped on it. The whole target column / row is highlighted.
  Widget _dropTarget(
    Widget cell, {
    required String? columnId,
    String? rowId,
  }) {
    if (!widget.editing) return cell;
    final scheme = Theme.of(context).colorScheme;
    final highlighted = (columnId != null && columnId == _hoverColumnId) ||
        (rowId != null && rowId == _hoverRowId);
    return DragTarget<_TableDrag>(
      onWillAcceptWithDetails: (details) {
        final drag = details.data;
        final target = drag.isColumn ? columnId : rowId;
        final accept = target != null && target != drag.id;
        _setHover(
          columnId: accept && drag.isColumn ? columnId : null,
          rowId: accept && !drag.isColumn ? rowId : null,
        );
        return accept;
      },
      onLeave: (_) => _setHover(),
      onAcceptWithDetails: (details) {
        final drag = details.data;
        _setHover();
        if (drag.isColumn) {
          widget.onMoveColumn(drag.id, columnId!);
        } else {
          widget.onMoveRow(drag.id, rowId!);
        }
      },
      builder: (context, _, __) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        color: highlighted
            ? scheme.primary.withValues(alpha: 0.16)
            : Colors.transparent,
        child: cell,
      ),
    );
  }

  Widget _dragHandle({
    required _TableDrag data,
    required String label,
    required Color color,
  }) {
    final scheme = Theme.of(context).colorScheme;
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
    final feedback = Material(
      elevation: 6,
      color: scheme.primaryContainer,
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                data.isColumn ? Icons.view_column_outlined : Icons.table_rows,
                size: 18,
                color: scheme.onPrimaryContainer,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final faded = Opacity(opacity: 0.3, child: handle);
    void onUpdate(DragUpdateDetails details) =>
        _dragPosition = details.globalPosition;

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
        feedback: feedback,
        childWhenDragging: faded,
        onDragStarted: _onDragStarted,
        onDragUpdate: onUpdate,
        onDragEnd: (_) => _onDragEnded(),
        child: handle,
      );
    }
    return LongPressDraggable<_TableDrag>(
      data: data,
      delay: const Duration(milliseconds: 180),
      feedback: feedback,
      childWhenDragging: faded,
      onDragStarted: _onDragStarted,
      onDragUpdate: onUpdate,
      onDragEnd: (_) => _onDragEnded(),
      child: handle,
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
      String rowLabel(int row) {
        for (final column in displayedColumns) {
          final value =
              evaluator.displayAt(row, columnIndex[column.id]!).trim();
          if (value.isNotEmpty) return value;
        }
        return '…';
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
                  label: TableFormula.parseHeader(column.title).label,
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
        return _dropTarget(
          columnId: column.id,
          ConstrainedBox(
            constraints: cellConstraints,
            child: editing
                ? _pickTarget(
                    cell,
                    key: key,
                    reference: (forHeader) =>
                        forHeader ? letters : '$letters:$letters',
                  )
                : cell,
          ),
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
        return _dropTarget(
          columnId: column.id,
          rowId: row.id,
          ConstrainedBox(
            constraints: cellConstraints,
            child: editing
                ? _pickTarget(
                    cell,
                    key: key,
                    reference: (forHeader) =>
                        forHeader ? letters : '$letters${rowIndex + 1}',
                  )
                : cell,
          ),
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
                decoration: BoxDecoration(color: scheme.primaryContainer),
                children: [
                  if (editing)
                    Center(
                      child: Icon(
                        Icons.functions,
                        size: 18,
                        color: scheme.onPrimaryContainer.withValues(alpha: 0.5),
                      ),
                    ),
                  for (final column in displayedColumns) headerCell(column),
                ],
              ),
              for (final (rowIndex, row) in table.rows.indexed)
                TableRow(
                  children: [
                    if (editing)
                      _dropTarget(
                        columnId: null,
                        rowId: row.id,
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 24,
                              child: Text(
                                '${rowIndex + 1}',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: scheme.outline,
                                ),
                              ),
                            ),
                            _dragHandle(
                              data: _TableDrag.row(row.id),
                              label: rowLabel(rowIndex),
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
                    for (final column in displayedColumns)
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
