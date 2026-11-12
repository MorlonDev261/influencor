import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../../../core/l10n/app_strings.dart';
import '../../../../core/providers/workspace_providers.dart';
import '../../../accounting/application/accounting_providers.dart';
import '../../../accounting/domain/ledger_entry.dart';
import '../../../accounting/presentation/ledger_chart.dart';
import '../../../accounting/presentation/ledger_format.dart';
import '../../../cleaner/presentation/clean_report_card.dart';
import '../../../library/domain/library_entry.dart';
import '../../../library/domain/table_document.dart';
import '../../../library/domain/table_formula.dart';
import '../../../tasks/application/task_providers.dart';
import '../../../tasks/domain/task_doc.dart';
import '../../application/tools/app_tools.dart';
import 'data_blocks.dart';
import 'chat_image.dart';
import 'rich_common.dart';
import 'rich_message.dart';

// Live views of the app's own data inside the conversation: a task (its
// checklist can be ticked), an accounting statement, a fee comparison, a
// gallery, a preview of a note or table, and a Deganeo metadata report.

String? _s(Object? v) => v == null || '$v'.trim().isEmpty ? null : '$v'.trim();

Future<void> _open(BuildContext context, String abs) async {
  final route = await routeForPath(abs);
  if (context.mounted) unawaited(context.push(route));
}

// --- Task --------------------------------------------------------------------

/// A task of the Tasks screen, read from disk: title, progress, text and
/// checklists; ticking an item saves it.
class TaskCardBlock extends ConsumerStatefulWidget {
  const TaskCardBlock({required this.id, super.key});

  final String id;

  static String? idOf(Object? json) => json is Map
      ? _s(json['id'] ?? json['task_id'])
      : (json is String ? _s(json) : null);

  @override
  ConsumerState<TaskCardBlock> createState() => _TaskCardBlockState();
}

class _TaskCardBlockState extends ConsumerState<TaskCardBlock> {
  TaskDoc? _task;
  var _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = ref.read(taskStoreProvider);
    TaskDoc? task;
    try {
      task = await store?.load(widget.id);
    } catch (_) {}
    if (mounted) {
      setState(() {
        _task = task;
        _loaded = true;
      });
    }
  }

  Future<void> _toggle(ChecklistItem item) async {
    final task = _task;
    final store = ref.read(taskStoreProvider);
    if (task == null || store == null) return;
    setState(() {
      item.done = !item.done;
      task.updatedAt = DateTime.now();
    });
    await store.save(task);
    ref.invalidate(taskListProvider);
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final task = _task;
    if (!_loaded) {
      return BlockLoading(label: strings.richLoading, icon: Icons.task_alt);
    }
    if (task == null) {
      return BlockCard(
        child: Row(
          children: [
            Icon(Icons.link_off, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Text(strings.richTaskNotFound,
                style: TextStyle(color: scheme.onSurfaceVariant)),
          ],
        ),
      );
    }
    final total = task.totalItems;
    final done = task.doneItems;
    return BlockCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BlockHeader(
            icon: Icons.task_alt,
            title: task.title.isEmpty ? strings.richTask : task.title,
            subtitle: total == 0 ? null : '$done / $total',
            trailing: [
              TinyIconButton(
                icon: Icons.open_in_new,
                tooltip: strings.open,
                onPressed: () => context.push(
                    Uri(path: '/task/edit', queryParameters: {'id': task.id})
                        .toString()),
              ),
            ],
          ),
          if (total > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: done / total,
                  minHeight: 6,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              ),
            ),
          for (final b in task.blocks)
            if (b.kind == TaskBlockKind.text)
              if (b.text.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(b.text,
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium),
                )
              else
                const SizedBox.shrink()
            else ...[
              if (b.text.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(b.text,
                      style: theme.textTheme.labelLarge
                          ?.copyWith(fontWeight: FontWeight.w700)),
                ),
              for (final item in b.items)
                InkWell(
                  key: ValueKey('degany-task-item-${item.id}'),
                  onTap: () => _toggle(item),
                  borderRadius: BorderRadius.circular(8),
                  child: Row(
                    children: [
                      Checkbox(
                        value: item.done,
                        visualDensity: VisualDensity.compact,
                        onChanged: (_) => _toggle(item),
                      ),
                      Expanded(
                        child: Text(
                          item.text,
                          style: item.done
                              ? TextStyle(
                                  decoration: TextDecoration.lineThrough,
                                  color: scheme.onSurfaceVariant)
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
        ],
      ),
    );
  }
}

// --- Ledger ------------------------------------------------------------------

/// A statement of the accounting ledger: totals, the trend chart and the
/// latest operations, filtered by period, account or type.
class LedgerBlock extends ConsumerWidget {
  const LedgerBlock({required this.json, super.key});

  final Object? json;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final spec = json is Map
        ? (json as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final ledger = ref.watch(ledgerProvider);
    final value = ledger.value;
    if (value == null) {
      return BlockLoading(
          label: strings.richLoading,
          icon: Icons.account_balance_wallet_outlined);
    }
    final from = DateTime.tryParse('${spec['from']}');
    final to = DateTime.tryParse('${spec['to']}');
    final account = '${spec['account'] ?? ''}'
        .toLowerCase()
        .replaceAll(RegExp(r'[\s_-]'), '');
    final type = '${spec['type'] ?? ''}'.toLowerCase();
    final sheet = '${spec['sheet'] ?? 'current'}';
    final limit = toNumber(spec['limit'])?.round() ?? 6;
    final source = sheet == 'all'
        ? value.entries
        : (value.sheetById(sheet) != null
            ? value.entriesOf(sheet)
            : value.currentEntries);
    final entries = [
      for (final e in source)
        if ((from == null || !e.date.isBefore(from)) &&
            (to == null || e.date.isBefore(to.add(const Duration(days: 1)))) &&
            (account.isEmpty || e.account.name.toLowerCase() == account) &&
            (type.isEmpty || e.type.name == type))
          e,
    ]..sort((a, b) => b.date.compareTo(a.date));
    final credit = entries
        .where((e) => e.direction == LedgerDirection.credit)
        .fold<int>(0, (s, e) => s + e.amount);
    final debit = entries
        .where((e) => e.direction == LedgerDirection.debit)
        .fold<int>(0, (s, e) => s + e.amount);
    final net = credit - debit;

    Widget figure(String label, String value, Color color) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(color: color, fontWeight: FontWeight.w800)),
              ),
            ],
          ),
        );

    return BlockCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BlockHeader(
            icon: Icons.account_balance_wallet_outlined,
            title: _s(spec['title']) ?? strings.richLedger,
            subtitle: [
              if (from != null || to != null)
                '${from == null ? '…' : formatDate(from)} → ${to == null ? '…' : formatDate(to)}',
              strings.richOperations(entries.length),
            ].join(' · '),
            trailing: [
              TinyIconButton(
                icon: Icons.open_in_new,
                tooltip: strings.open,
                onPressed: () => context.push('/accounting'),
              ),
            ],
          ),
          Row(
            children: [
              figure(strings.credit, '+${formatAr(credit)} Ar',
                  scheme.ledgerCredit),
              figure(
                  strings.debit, '-${formatAr(debit)} Ar', scheme.ledgerDebit),
              figure(
                  strings.richNet,
                  '${net < 0 ? '-' : '+'}${formatAr(net)} Ar',
                  net < 0 ? scheme.ledgerDebit : scheme.ledgerCredit),
            ],
          ),
          if (spec['chart'] != false && entries.length > 1) ...[
            const SizedBox(height: 10),
            LedgerChartCard(
              entries: entries,
              strings: strings,
              from: from,
              to: to,
              height: 140,
            ),
          ],
          if (limit > 0 && entries.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final e in entries.take(limit))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      e.direction == LedgerDirection.credit
                          ? Icons.south_west
                          : Icons.north_east,
                      size: 16,
                      color: e.direction == LedgerDirection.credit
                          ? scheme.ledgerCredit
                          : scheme.ledgerDebit,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            e.note.isEmpty ? e.type.name : e.note,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                          Text('${formatDate(e.date)} · ${e.account.label}',
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    Text(
                      '${e.direction == LedgerDirection.credit ? '+' : '-'}${formatAr(e.amount)} Ar',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: e.direction == LedgerDirection.credit
                            ? scheme.ledgerCredit
                            : scheme.ledgerDebit,
                      ),
                    ),
                  ],
                ),
              ),
            if (entries.length > limit)
              Text(strings.richMoreItems(entries.length - limit),
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }
}

// --- Fees --------------------------------------------------------------------

/// Mobile money options side by side, the cheapest one highlighted.
class FeesBlock extends ConsumerWidget {
  const FeesBlock({required this.json, super.key});

  final Object? json;

  static List<Map<String, dynamic>> _options(Object? json) => [
        for (final o in blockItems(json, key: 'options'))
          if (toNumber(o['fee'] ?? o['total_fee'] ?? o['cost']) != null) o,
      ];

  static bool canShow(Object? json) => _options(json).isNotEmpty;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final options = _options(json)
      ..sort((a, b) => toNumber(a['fee'] ?? a['total_fee'] ?? a['cost'])!
          .compareTo(toNumber(b['fee'] ?? b['total_fee'] ?? b['cost'])!));
    final best = toNumber(options.first['fee'] ??
        options.first['total_fee'] ??
        options.first['cost'])!;
    final spec = json is Map ? json as Map : const {};
    final amount = toNumber(spec['amount']);
    const good = Color(0xFF16A34A);
    return BlockCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BlockHeader(
            icon: Icons.payments_outlined,
            title: _s(spec['title']) ?? strings.richFees,
            subtitle: [
              if (_s(spec['operation']) case final o?) o,
              if (amount != null) '${formatAr(amount.round())} Ar',
            ].join(' · '),
          ),
          for (final (k, o) in options.indexed) ...[
            if (k > 0) Divider(height: 1, color: scheme.outlineVariant),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              decoration: k == 0
                  ? BoxDecoration(
                      color: good.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    )
                  : null,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                _s(o['label'] ?? o['operator'] ?? o['name']) ??
                                    '',
                                style: theme.textTheme.bodyMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                            if (k == 0) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 7, vertical: 1),
                                decoration: BoxDecoration(
                                  color: good,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(strings.richCheapest,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700)),
                              ),
                            ],
                          ],
                        ),
                        if (_s(o['detail'] ?? o['description'] ?? o['split'])
                            case final d?)
                          Text(d,
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${formatAr(toNumber(o['fee'] ?? o['total_fee'] ?? o['cost'])!.round())} Ar',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: k == 0 ? good : null,
                        ),
                      ),
                      if (k > 0)
                        Text(
                          '+${formatAr((toNumber(o['fee'] ?? o['total_fee'] ?? o['cost'])! - best).round())} Ar',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: scheme.error),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
          if (_s(spec['note']) case final n?)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(n,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            ),
        ],
      ),
    );
  }
}

// --- Gallery -----------------------------------------------------------------

/// Thumbnails of library pictures and videos; a tap opens one.
class GalleryBlock extends ConsumerWidget {
  const GalleryBlock({required this.json, super.key});

  final Object? json;

  static List<String> paths(Object? json) {
    final raw =
        json is Map ? json['paths'] ?? json['images'] ?? json['items'] : json;
    return [
      if (raw is List)
        for (final e in raw)
          if (e is Map ? _s(e['path']) : _s(e) case final pth?) pth,
    ];
  }

  static bool canShow(Object? json) => paths(json).isNotEmpty;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final root = ref.watch(workspaceRootProvider);
    final files = [
      for (final pth in paths(json))
        if (resolveWorkspacePath(pth, root) case final abs?) abs,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (blockTitle(json) case final t?)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(t,
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
          ChatImageGallery(
            sources: [for (final f in files) ChatImageSource.file(f)],
          ),
        ],
      ),
    );
  }
}

// --- Preview -----------------------------------------------------------------

/// The beginning of a note, the first rows of a table, a picture, or the
/// content of a folder, with a button to open it.
class PreviewBlock extends ConsumerStatefulWidget {
  const PreviewBlock({required this.path, super.key});

  final String path;

  static String? pathOf(Object? json) =>
      json is Map ? _s(json['path']) : (json is String ? _s(json) : null);

  @override
  ConsumerState<PreviewBlock> createState() => _PreviewBlockState();
}

class _PreviewBlockState extends ConsumerState<PreviewBlock> {
  late final Future<_Preview?> _preview = _load();

  Future<_Preview?> _load() async {
    final abs =
        resolveWorkspacePath(widget.path, ref.read(workspaceRootProvider));
    if (abs == null) return null;
    final type = await FileSystemEntity.type(abs);
    if (type == FileSystemEntityType.notFound) return null;
    if (type == FileSystemEntityType.directory) {
      final names = <String>[];
      await for (final e in Directory(abs).list()) {
        final name = p.basename(e.path);
        if (name.startsWith('.')) continue;
        names.add(e is Directory ? '$name/' : name);
        if (names.length > 40) break;
      }
      names.sort();
      return _Preview(abs, folder: names);
    }
    final kind = await kindForFilePath(abs);
    switch (kind) {
      case EntryKind.note:
        var text = await File(abs).readAsString();
        if (text.length > 1200) text = '${text.substring(0, 1200)}…';
        return _Preview(abs, note: text);
      case EntryKind.table:
        final table =
            TableDocument.tryParse(jsonDecode(await File(abs).readAsString()));
        return table == null ? _Preview(abs) : _Preview(abs, table: table);
      default:
        return _Preview(abs, kind: kind);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return FutureBuilder<_Preview?>(
      future: _preview,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return BlockLoading(
              label: strings.richLoading, icon: Icons.visibility_outlined);
        }
        final pv = snap.data;
        if (pv == null) {
          return BlockCard(
            child: Row(children: [
              Icon(Icons.link_off, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(child: Text('${strings.itemNotFound} : ${widget.path}')),
            ]),
          );
        }
        final Widget body;
        if (pv.note != null) {
          body = ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: ClipRect(
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                child: RichMessage(text: pv.note!, color: scheme.onSurface),
              ),
            ),
          );
        } else if (pv.table != null) {
          body = _TablePreview(table: pv.table!, strings: strings);
        } else if (pv.folder != null) {
          body = Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final n in pv.folder!.take(24))
                Chip(
                  visualDensity: VisualDensity.compact,
                  avatar: Icon(
                      n.endsWith('/')
                          ? Icons.folder_outlined
                          : Icons.insert_drive_file_outlined,
                      size: 16),
                  label:
                      Text(n.endsWith('/') ? n.substring(0, n.length - 1) : n),
                ),
              if (pv.folder!.length > 24)
                Chip(
                    label: Text(strings.richMoreItems(pv.folder!.length - 24))),
            ],
          );
        } else if (pv.kind == EntryKind.image || pv.kind == EntryKind.video) {
          body = ChatImageGallery(
              sources: [ChatImageSource.file(pv.path)], maxHeight: 320);
        } else {
          body = const SizedBox.shrink();
        }
        return BlockCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BlockHeader(
                icon: pv.folder != null
                    ? Icons.folder_outlined
                    : pv.table != null
                        ? Icons.table_chart_outlined
                        : pv.note != null
                            ? Icons.description_outlined
                            : Icons.image_outlined,
                title: p.basenameWithoutExtension(pv.path),
                subtitle: widget.path,
                trailing: [
                  TextButton.icon(
                    onPressed: () => _open(context, pv.path),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: Text(strings.open),
                  ),
                ],
              ),
              body,
            ],
          ),
        );
      },
    );
  }
}

class _Preview {
  _Preview(this.path, {this.note, this.table, this.folder, this.kind});

  final String path;
  final String? note;
  final TableDocument? table;
  final List<String>? folder;
  final EntryKind? kind;
}

class _TablePreview extends StatelessWidget {
  const _TablePreview({required this.table, required this.strings});

  final TableDocument table;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final decimal = strings.locale.languageCode == 'en' ? '.' : ',';
    final eval = TableEvaluator(table, decimalSeparator: decimal);
    final headers = [
      for (final c in table.columns) TableFormula.parseHeader(c.title)
    ];
    const max = 6;
    final style = theme.textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder(
              horizontalInside:
                  BorderSide(color: scheme.outlineVariant, width: 0.6),
            ),
            children: [
              TableRow(
                decoration: BoxDecoration(color: scheme.surfaceContainerHigh),
                children: [
                  for (final h in headers)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      child: Text(h.label,
                          style: style?.copyWith(fontWeight: FontWeight.w700)),
                    ),
                ],
              ),
              for (var r = 0; r < table.rows.length && r < max; r++)
                TableRow(children: [
                  for (var c = 0; c < table.columns.length; c++)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      child: Text(
                        headers[c].hidden ? '••••••' : eval.displayAt(r, c),
                        style: style,
                      ),
                    ),
                ]),
            ],
          ),
        ),
        if (table.rows.length > max)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(strings.richMoreItems(table.rows.length - max),
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ),
      ],
    );
  }
}

// --- Deganeo report ----------------------------------------------------------

/// The metadata Deganeo found in a file, grouped (EXIF, GPS, XMP…), values
/// hidden until the user shows them.
class MetaBlock extends ConsumerStatefulWidget {
  const MetaBlock({required this.json, super.key});

  final Object? json;

  static List<(String, List<MetaRow>)> groups(Object? json) {
    final raw = json is Map ? json['groups'] ?? json['metadata'] : json;
    final out = <(String, List<MetaRow>)>[];
    List<MetaRow> rows(Object? r) => [
          if (r is List)
            for (final e in r)
              if (e is List && e.length >= 2)
                MetaRow('${e[0]}', '${e[1]}')
              else if (e is Map)
                MetaRow(
                    '${e['name'] ?? e['field'] ?? ''}', '${e['value'] ?? ''}'),
          if (r is Map)
            for (final e in r.entries) MetaRow('${e.key}', '${e.value}'),
        ];
    if (raw is List) {
      for (final g in raw) {
        if (g is Map) {
          out.add((
            '${g['title'] ?? g['name'] ?? ''}',
            rows(g['rows'] ?? g['fields'])
          ));
        }
      }
    } else if (raw is Map) {
      for (final e in raw.entries) {
        out.add(('${e.key}', rows(e.value)));
      }
    }
    return out;
  }

  static bool canShow(Object? json) => groups(json).isNotEmpty;

  @override
  ConsumerState<MetaBlock> createState() => _MetaBlockState();
}

class _MetaBlockState extends ConsumerState<MetaBlock> {
  var _show = false;

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final scheme = Theme.of(context).colorScheme;
    final json = widget.json;
    final spec = json is Map ? json : const {};
    final groups = MetaBlock.groups(json);
    final risk = _s(spec['risk'] ?? spec['summary']);
    return BlockCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BlockHeader(
            icon: Icons.cleaning_services_outlined,
            title: _s(spec['file'] ?? spec['title']) ?? 'Deganeo',
            subtitle: risk,
            trailing: [
              TinyIconButton(
                icon: _show
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                tooltip:
                    _show ? strings.richHideValues : strings.richShowValues,
                onPressed: () => setState(() => _show = !_show),
              ),
            ],
          ),
          for (final (title, rows) in groups)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: MetaTable(
                title: title,
                rows: rows,
                showValues: _show,
                fg: scheme.onSurface,
              ),
            ),
        ],
      ),
    );
  }
}
