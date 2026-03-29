/// Spreadsheet/CSV tools for FlutterClaw agents.
///
/// Read and write CSV files in the workspace. Useful for processing marketing
/// lists, lead tracking, data reports, and bulk operations.
///
/// Files are typically ingested via `pick_file_to_workspace` and then processed
/// with these tools.
library;

import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:flutterclaw/data/models/config.dart';
import 'package:flutterclaw/tools/registry.dart';

// ---------------------------------------------------------------------------
// spreadsheet_read
// ---------------------------------------------------------------------------

class SpreadsheetReadTool extends Tool {
  final ConfigManager configManager;

  SpreadsheetReadTool({required this.configManager});

  @override
  String get name => 'spreadsheet_read';

  @override
  String get description =>
      'Read a CSV file and return its contents as structured data.\n\n'
      'By default reads the first 100 rows. Use offset/limit for pagination.\n'
      'The file path is relative to the workspace, or an absolute path.\n'
      'Supports CSV files with comma, semicolon, or tab delimiters (auto-detected).';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description':
                'Path to the CSV file (relative to workspace or absolute)',
          },
          'offset': {
            'type': 'integer',
            'minimum': 0,
            'description': 'Number of data rows to skip (0-based, after header). Default 0.',
            'default': 0,
          },
          'limit': {
            'type': 'integer',
            'minimum': 1,
            'maximum': 500,
            'description': 'Maximum rows to return. Default 100, max 500.',
            'default': 100,
          },
          'has_header': {
            'type': 'boolean',
            'description': 'Whether the first row is a header row. Default true.',
            'default': true,
          },
        },
        'required': ['path'],
      };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    final pathStr = (args['path'] as String?)?.trim() ?? '';
    if (pathStr.isEmpty) return ToolResult.error('path is required');

    final offset = (args['offset'] as num?)?.toInt() ?? 0;
    final limit = (args['limit'] as num?)?.toInt() ?? 100;
    final hasHeader = args['has_header'] as bool? ?? true;

    final file = await _resolveFile(pathStr);
    if (!await file.exists()) {
      return ToolResult.error('File not found: ${file.path}');
    }

    try {
      final content = await file.readAsString();
      final delimiter = _detectDelimiter(content);
      final converter = CsvToListConverter(
        fieldDelimiter: delimiter,
        shouldParseNumbers: true,
        allowInvalid: true,
      );

      final allRows = converter.convert(content);
      if (allRows.isEmpty) {
        return ToolResult.success(jsonEncode({
          'ok': true,
          'total_rows': 0,
          'columns': <String>[],
          'rows': <List<dynamic>>[],
        }));
      }

      List<String> columns;
      List<List<dynamic>> dataRows;

      if (hasHeader) {
        columns = allRows.first.map((c) => c.toString()).toList();
        dataRows = allRows.skip(1).toList();
      } else {
        columns = List.generate(
          allRows.first.length,
          (i) => 'col_${i + 1}',
        );
        dataRows = allRows;
      }

      final totalDataRows = dataRows.length;
      final sliced = dataRows.skip(offset).take(limit).toList();

      // Convert rows to maps for readability
      final rowMaps = sliced.map((row) {
        final map = <String, dynamic>{};
        for (var i = 0; i < columns.length && i < row.length; i++) {
          map[columns[i]] = row[i];
        }
        return map;
      }).toList();

      return ToolResult.success(jsonEncode({
        'ok': true,
        'file': file.path,
        'delimiter': delimiter == ',' ? 'comma' : delimiter == ';' ? 'semicolon' : 'tab',
        'columns': columns,
        'total_rows': totalDataRows,
        'offset': offset,
        'limit': limit,
        'returned_rows': rowMaps.length,
        'rows': rowMaps,
      }));
    } catch (e) {
      return ToolResult.error('Failed to read CSV: $e');
    }
  }

  Future<File> _resolveFile(String path) async {
    if (path.startsWith('/')) return File(path);
    final ws = await configManager.workspacePath;
    return File('$ws/$path');
  }

  String _detectDelimiter(String content) {
    // Check first few lines for delimiter frequency
    final sample = content.length > 2000 ? content.substring(0, 2000) : content;
    final commas = ','.allMatches(sample).length;
    final semicolons = ';'.allMatches(sample).length;
    final tabs = '\t'.allMatches(sample).length;

    if (tabs > commas && tabs > semicolons) return '\t';
    if (semicolons > commas) return ';';
    return ',';
  }
}

// ---------------------------------------------------------------------------
// spreadsheet_write
// ---------------------------------------------------------------------------

class SpreadsheetWriteTool extends Tool {
  final ConfigManager configManager;

  SpreadsheetWriteTool({required this.configManager});

  @override
  String get name => 'spreadsheet_write';

  @override
  String get description =>
      'Write data to a CSV file in the workspace.\n\n'
      'Provide columns and rows as structured data. The file is created or '
      'overwritten. Use mode "append" to add rows to an existing file.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description':
                'Path for the CSV file (relative to workspace or absolute)',
          },
          'columns': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Column headers (required for new files, ignored in append mode)',
          },
          'rows': {
            'type': 'array',
            'items': {
              'type': 'array',
              'items': {},
            },
            'description':
                'Data rows as arrays of values. Each inner array is one row.',
          },
          'mode': {
            'type': 'string',
            'enum': ['write', 'append'],
            'description':
                '"write" creates/overwrites the file (default). '
                    '"append" adds rows to an existing file without headers.',
            'default': 'write',
          },
        },
        'required': ['path', 'rows'],
      };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    final pathStr = (args['path'] as String?)?.trim() ?? '';
    if (pathStr.isEmpty) return ToolResult.error('path is required');

    final columns = (args['columns'] as List<dynamic>?)
        ?.map((c) => c.toString())
        .toList();
    final rows = args['rows'] as List<dynamic>?;
    if (rows == null || rows.isEmpty) {
      return ToolResult.error('rows is required and must not be empty');
    }

    final mode = (args['mode'] as String?) ?? 'write';
    final isAppend = mode == 'append';

    final file = await _resolveFile(pathStr);

    try {
      final converter = const ListToCsvConverter();

      if (isAppend) {
        // Append mode: just add the data rows
        final dataRows = rows.map((r) => (r as List<dynamic>)).toList();
        final csvContent = converter.convert(dataRows);
        await file.parent.create(recursive: true);
        await file.writeAsString(
          '\n$csvContent',
          mode: FileMode.append,
        );

        return ToolResult.success(jsonEncode({
          'ok': true,
          'file': file.path,
          'mode': 'append',
          'rows_appended': dataRows.length,
          'message': 'Appended ${dataRows.length} row(s) to ${file.path}.',
        }));
      } else {
        // Write mode: header + data
        final allRows = <List<dynamic>>[];
        if (columns != null && columns.isNotEmpty) {
          allRows.add(columns);
        }
        allRows.addAll(rows.map((r) => (r as List<dynamic>)));

        final csvContent = converter.convert(allRows);
        await file.parent.create(recursive: true);
        await file.writeAsString(csvContent);

        return ToolResult.success(jsonEncode({
          'ok': true,
          'file': file.path,
          'mode': 'write',
          'columns': columns?.length ?? 0,
          'rows_written': rows.length,
          'message':
              'Wrote ${rows.length} row(s) to ${file.path}.',
        }));
      }
    } catch (e) {
      return ToolResult.error('Failed to write CSV: $e');
    }
  }

  Future<File> _resolveFile(String path) async {
    if (path.startsWith('/')) return File(path);
    final ws = await configManager.workspacePath;
    return File('$ws/$path');
  }
}
