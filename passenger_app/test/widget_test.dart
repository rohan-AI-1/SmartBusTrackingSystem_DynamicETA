import 'package:flutter_test/flutter_test.dart';

import 'package:passenger_app/main.dart';

void main() {
  testWidgets('Passenger app renders the search screen', (WidgetTester tester) async {
    await tester.pumpWidget(const PassengerApp());

    expect(find.text('Know where your bus is at'), findsOneWidget);
    expect(find.text('Find my bus'), findsOneWidget);
  });
}
