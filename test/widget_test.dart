import 'package:flutter_test/flutter_test.dart';
import 'package:app/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const MultiToolboxApp());
    expect(find.text('多功能百宝箱'), findsOneWidget);
  });
}
