import 'package:flutter_test/flutter_test.dart';

import 'package:airmic_mobile/main.dart';

void main() {
  testWidgets('Connection Screen smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const AirMicClientApp());

    // Verify that the title is rendered.
    expect(find.text('Airmic'), findsOneWidget);
    expect(find.text('Connect to PC'), findsOneWidget);
  });
}
