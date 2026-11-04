import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Represents a single mapped segment within a SourceMap v3.
class SourceMapSegment {
  final int generatedColumn;
  final String? sourceFile;
  final int? originalLine; // 1-based
  final int? originalColumn; // 0-based
  final String? name;

  const SourceMapSegment({
    required this.generatedColumn,
    this.sourceFile,
    this.originalLine,
    this.originalColumn,
    this.name,
  });

  @override
  String toString() =>
      'Segment(genCol: $generatedColumn, source: $sourceFile, orig: $originalLine:$originalColumn, name: $name)';
}

/// SourceMap v3 consumer capable of decoding VLQ mappings and mapping generated coordinates back to source coordinates.
class SourceMapConsumer {
  final int version;
  final String? file;
  final List<String> sources;
  final List<String?> sourcesContent;
  final List<String> names;
  final Map<int, List<SourceMapSegment>> _lines;

  SourceMapConsumer({
    required this.version,
    this.file,
    required this.sources,
    required this.sourcesContent,
    required this.names,
    required Map<int, List<SourceMapSegment>> lines,
  }) : _lines = lines;

  /// Look up original position for a given generated line (1-based) and column (0-based).
  SourceMapSegment? findOriginalPosition(int line, int column) {
    final lineSegments = _lines[line];
    if (lineSegments == null || lineSegments.isEmpty) return null;

    // Find the rightmost segment where generatedColumn <= column
    SourceMapSegment? bestMatch;
    for (final seg in lineSegments) {
      if (seg.generatedColumn <= column) {
        bestMatch = seg;
      } else {
        break;
      }
    }
    return bestMatch ?? lineSegments.first;
  }

  /// Retrieve the source code line for a given source file and 1-based original line.
  String? getCodeContext(String sourceFile, int line) {
    if (line <= 0) return null;
    final idx = sources.indexWhere((s) => s == sourceFile || p.basename(s) == p.basename(sourceFile));
    if (idx < 0 || idx >= sourcesContent.length) return null;
    final content = sourcesContent[idx];
    if (content == null) return null;

    final contentLines = content.split(RegExp(r'\r?\n'));
    if (line - 1 < contentLines.length) {
      return contentLines[line - 1].trimRight();
    }
    return null;
  }

  /// Parse SourceMap JSON content.
  static SourceMapConsumer? parse(String jsonString) {
    try {
      final map = jsonDecode(jsonString);
      if (map is! Map) return null;

      final version = (map['version'] as num?)?.toInt() ?? 3;
      final file = map['file']?.toString();
      final sources = (map['sources'] as List?)?.map((e) => e.toString()).toList() ?? [];
      final sourcesContent = (map['sourcesContent'] as List?)
              ?.map((e) => e?.toString())
              .toList() ??
          [];
      final names = (map['names'] as List?)?.map((e) => e.toString()).toList() ?? [];
      final mappings = map['mappings']?.toString() ?? '';

      final lines = _decodeMappings(mappings, sources: sources, names: names);

      return SourceMapConsumer(
        version: version,
        file: file,
        sources: sources,
        sourcesContent: sourcesContent,
        names: names,
        lines: lines,
      );
    } catch (e) {
      debugPrint('[SourceMapResolver] Failed to parse SourceMap JSON: $e');
      return null;
    }
  }

  static Map<int, List<SourceMapSegment>> _decodeMappings(
    String mappings, {
    required List<String> sources,
    required List<String> names,
  }) {
    final result = <int, List<SourceMapSegment>>{};
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    final charMap = <String, int>{};
    for (var i = 0; i < chars.length; i++) {
      charMap[chars[i]] = i;
    }

    final rawLines = mappings.split(';');
    var sourceIndex = 0;
    var originalLine = 0;
    var originalColumn = 0;
    var nameIndex = 0;

    for (var lineIdx = 0; lineIdx < rawLines.length; lineIdx++) {
      final lineStr = rawLines[lineIdx];
      final currentLineNum = lineIdx + 1; // 1-based
      if (lineStr.isEmpty) continue;

      final segments = <SourceMapSegment>[];
      var generatedColumn = 0;

      final rawSegments = lineStr.split(',');
      for (final segStr in rawSegments) {
        if (segStr.isEmpty) continue;

        // Decode VLQ values
        final values = <int>[];
        var shift = 0;
        var value = 0;

        for (var i = 0; i < segStr.length; i++) {
          final c = segStr[i];
          final integer = charMap[c];
          if (integer == null) continue;

          final hasContinuation = (integer & 32) != 0;
          final payload = integer & 31;
          value += payload << shift;

          if (hasContinuation) {
            shift += 5;
          } else {
            final isNegative = (value & 1) != 0;
            final finalVal = isNegative ? -(value >> 1) : (value >> 1);
            values.add(finalVal);
            value = 0;
            shift = 0;
          }
        }

        if (values.isEmpty) continue;

        generatedColumn += values[0];
        String? srcFile;
        int? origLine;
        int? origCol;
        String? name;

        if (values.length >= 4) {
          sourceIndex += values[1];
          originalLine += values[2];
          originalColumn += values[3];

          if (sourceIndex >= 0 && sourceIndex < sources.length) {
            srcFile = sources[sourceIndex];
          }
          origLine = originalLine + 1; // Convert 0-based to 1-based
          origCol = originalColumn;

          if (values.length >= 5) {
            nameIndex += values[4];
            if (nameIndex >= 0 && nameIndex < names.length) {
              name = names[nameIndex];
            }
          }
        }

        segments.add(SourceMapSegment(
          generatedColumn: generatedColumn,
          sourceFile: srcFile,
          originalLine: origLine,
          originalColumn: origCol,
          name: name,
        ));
      }

      if (segments.isNotEmpty) {
        result[currentLineNum] = segments;
      }
    }

    return result;
  }
}

/// Utility for compensating QuickJS error stack line offsets, resolving SourceMaps, and extracting WASI Panics.
class SourceMapResolver {
  /// Regular expression to match inline data URI SourceMaps:
  /// `//# sourceMappingURL=data:application/json;base64,...` or `/*# sourceMappingURL=... */`
  static final RegExp _inlineSourceMapRegex = RegExp(
    r'(?://|/\*)#\s*sourceMappingURL=data:(?:application/json|text/plain);(?:charset=[^;]+;)?base64,([A-Za-z0-9+/=]+)',
    multiLine: true,
  );

  /// Regular expression to match external sourceMappingURL:
  /// `//# sourceMappingURL=filename.js.map`
  static final RegExp _externalSourceMapRegex = RegExp(
    r'(?://|/\*)#\s*sourceMappingURL=([^\s*]+)',
    multiLine: true,
  );

  /// Extracts inline base64 SourceMap content or returns null if not present.
  static String? extractInlineSourceMap(String scriptSource) {
    final match = _inlineSourceMapRegex.firstMatch(scriptSource);
    if (match != null && match.groupCount >= 1) {
      try {
        final b64 = match.group(1)!.trim();
        return utf8.decode(base64Decode(b64));
      } catch (e) {
        debugPrint('[SourceMapResolver] Failed to decode base64 SourceMap: $e');
      }
    }
    return null;
  }

  /// Extracts external SourceMap file name (e.g. `entry.js.map`) if referenced at the end of the script.
  static String? extractExternalSourceMapFileName(String scriptSource) {
    final match = _externalSourceMapRegex.firstMatch(scriptSource);
    if (match != null && match.groupCount >= 1) {
      final pathOrUrl = match.group(1)!.trim();
      if (!pathOrUrl.startsWith('data:')) {
        return pathOrUrl;
      }
    }
    return null;
  }

  /// Compensates QuickJS line offsets in a stack trace string and maps back to original sources if a SourceMap is available.
  ///
  /// - [rawStack]: The stack trace string returned by QuickJS (`err.stack` or string representation of error).
  /// - [headerLineOffset]: Number of preamble lines injected before the developer's script in the evaluation wrapper.
  /// - [scriptSource]: Full content of the script that was executed.
  /// - [scriptFileName]: Display name of the script (defaults to `entry.js`).
  /// - [pluginLocalDir]: Directory of the plugin, used to search for companion `.map` files.
  static String compensateStackTrace(
    String rawStack, {
    required int headerLineOffset,
    String? scriptSource,
    String scriptFileName = 'entry.js',
    String? pluginLocalDir,
  }) {
    if (rawStack.trim().isEmpty) return rawStack;

    // 1. Try to obtain a SourceMapConsumer
    SourceMapConsumer? consumer;
    if (scriptSource != null) {
      final inlineMap = extractInlineSourceMap(scriptSource);
      if (inlineMap != null) {
        consumer = SourceMapConsumer.parse(inlineMap);
      } else if (pluginLocalDir != null) {
        // Look for external map file
        final mapFileName = extractExternalSourceMapFileName(scriptSource) ?? '$scriptFileName.map';
        final mapFile = File(p.join(pluginLocalDir, mapFileName));
        if (mapFile.existsSync()) {
          try {
            consumer = SourceMapConsumer.parse(mapFile.readAsStringSync());
          } catch (_) {}
        }
      }
    }

    // 2. Parse and rewrite stack trace lines
    // QuickJS stack traces look like:
    // "    at run (<eval>:15:10)"
    // "    at <eval>:15:10"
    // "    at foo (eval:15:10)"
    // "    at <anonymous>:15:10"
    // "    at run (/path/to/entry.js:15:10)"
    final lines = rawStack.split(RegExp(r'\r?\n'));
    final rewrittenLines = <String>[];
    String? codeContextSnippet;

    for (final line in lines) {
      var processedLine = line;

      // Look for line numbers in the frame
      final match = RegExp(r'(<eval>|<input>|<anonymous>|eval|' +
              RegExp.escape(scriptFileName) +
              r'|[a-zA-Z0-9_\-\.\/\\]+\.js):(\d+)(?::(\d+))?')
          .firstMatch(line);

      if (match != null) {
        final rawLineNum = int.tryParse(match.group(2)!) ?? 0;
        final rawColNum = int.tryParse(match.group(3) ?? '0') ?? 0;

        if (rawLineNum > headerLineOffset) {
          final adjustedLine = rawLineNum - headerLineOffset;
          String targetLocation = '$scriptFileName:$adjustedLine';
          if (rawColNum > 0) targetLocation += ':$rawColNum';

          if (consumer != null) {
            final mapped = consumer.findOriginalPosition(adjustedLine, rawColNum > 0 ? rawColNum - 1 : 0);
            if (mapped != null && mapped.sourceFile != null && mapped.originalLine != null) {
              final origCol = (mapped.originalColumn ?? 0) + 1;
              targetLocation = '${mapped.sourceFile}:${mapped.originalLine}:$origCol';

              if (codeContextSnippet == null) {
                final ctx = consumer.getCodeContext(mapped.sourceFile!, mapped.originalLine!);
                if (ctx != null && ctx.isNotEmpty) {
                  codeContextSnippet = '    > ${mapped.originalLine} | $ctx';
                }
              }
            }
          }

          final oldSubstr = match.group(0)!;
          final newSubstr = targetLocation;
          processedLine = line.replaceFirst(oldSubstr, newSubstr);
        }
      }

      rewrittenLines.add(processedLine);
    }

    if (codeContextSnippet != null) {
      rewrittenLines.add('');
      rewrittenLines.add('  源码上下文:');
      rewrittenLines.add(codeContextSnippet);
    }

    return rewrittenLines.join('\n');
  }

  /// Extracts structured Rust panic information from WASI stderr output.
  ///
  /// Examples:
  /// - `panicked at 'index out of bounds: the len is 3 but the index is 5', src/main.rs:42:5`
  /// - `thread 'main' panicked at src/main.rs:18:9:\nattempt to divide by zero`
  static String? extractWasiPanic(String stderr) {
    if (stderr.trim().isEmpty) return null;

    // Pattern 1: panicked at 'msg', file:line:col
    final p1 = RegExp(r"panicked at '([^']+)',\s*([^\s:]+):(\d+):(\d+)");
    final m1 = p1.firstMatch(stderr);
    if (m1 != null) {
      final msg = m1.group(1);
      final file = m1.group(2);
      final line = m1.group(3);
      final col = m1.group(4);
      return "panicked at '$msg', $file:$line:$col";
    }

    // Pattern 2: panicked at file:line:col:\nmsg
    final p2 = RegExp(r"panicked at\s+([^\s:]+):(\d+):(\d+)(?::\s*([^\r\n]+))?");
    final m2 = p2.firstMatch(stderr);
    if (m2 != null) {
      final file = m2.group(1);
      final line = m2.group(2);
      final col = m2.group(3);
      final msg = m2.group(4);
      return (msg != null && msg.trim().isNotEmpty)
          ? "panicked at '${msg.trim()}', $file:$line:$col"
          : "panicked at $file:$line:$col";
    }

    // Pattern 3: general line containing 'panicked at'
    final p3 = RegExp(r"(panicked at[^\r\n]+)");
    final m3 = p3.firstMatch(stderr);
    if (m3 != null) {
      return m3.group(1)!.trim();
    }

    return null;
  }
}
