import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/presentation/storage_limits_section.dart';

void main() {
  test('sizes read in KB, MB and GB', () {
    expect(formatStorageSize(240 * 1024), '240 KB');
    expect(formatStorageSize(12 * 1024 * 1024), '12 MB');
    expect(formatStorageSize(2 * 1024 * 1024 * 1024), '2 GB');
    expect(formatStorageSize(1536 * 1024 * 1024), '1.5 GB');
  });

  test('the page lists the enforced limits with their real values', () {
    final Map<String, String> rows = <String, String>{
      for (final StorageLimitRow r in storageLimitRows(const AppSettings()))
        r.label: r.limit,
    };
    expect(rows['Posty znajomych'], '12 miesięcy');
    expect(rows['Zdjęcia i filmy jednego znajomego'], '2 GB');
    expect(rows['Zdjęcia i filmy pozostałych osób (pamięć podręczna)'], '1 GB');
  });
}
