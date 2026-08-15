import 'package:flutter_test/flutter_test.dart';
import 'package:chitchat/main.dart';

void main() {
  testWidgets('App loads', (WidgetTester tester) async {
    await tester.pumpWidget(const ChitChatApp());
    expect(find.text('ChitChat'), findsWidgets);
  });
}