import 'package:flutter_test/flutter_test.dart';

import 'package:applock_win/main.dart';

void main() {
  testWidgets('locked dashboard renders core sections', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(find.text('Biometric Desktop Lock'), findsOneWidget);
    expect(find.text('First-Time Setup'), findsOneWidget);
    expect(find.text('System Snapshot'), findsOneWidget);
    expect(find.text('Protected Apps'), findsOneWidget);
    expect(find.text('Windows Hello'), findsOneWidget);
    expect(find.text('Unlock Console'), findsOneWidget);
    expect(find.text('Launch Sequence'), findsOneWidget);
    expect(find.text('Unlock Session'), findsOneWidget);
  });
}
