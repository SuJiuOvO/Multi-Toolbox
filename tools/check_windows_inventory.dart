// Read-only smoke check. This file never invokes an uninstaller or deletes data.
import 'dart:io';

import 'package:app/services/windows_uninstaller_service.dart';

Future<void> main() async {
  final result = await WindowsUninstallerService().loadApps();
  if (result.apps.isEmpty) {
    throw StateError('No desktop application registrations found.');
  }
  final residue =
      await WindowsUninstallerService().scanResidue(result.apps.first);
  stdout.writeln('Read-only inventory OK: ${result.apps.length} applications; '
      '${result.warnings.length} warnings; '
      'UTF-8 names decoded: ${result.apps.any((app) => app.name.runes.any((rune) => rune > 127))}; '
      '${residue.length} read-only residue candidates.');
}
