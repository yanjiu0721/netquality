import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netquality/main.dart';
import 'package:netquality/models/port_field.dart';
import 'package:netquality/ui/expandable_hint.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('short hint text is not a button', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ExpandableHint(text: 'HTTP 默认 5000 毫秒')),
      ),
    );
    expect(find.byType(InkWell), findsNothing);
    final text = tester.widget<Text>(find.text('HTTP 默认 5000 毫秒'));
    expect(text.maxLines, isNull);
    expect(text.overflow, TextOverflow.clip);
  });

  testWidgets('a long hint expands and collapses', (tester) async {
    const long =
        'only the current port follows the previous default when it is empty or still that default';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 160, child: ExpandableHint(text: long)),
        ),
      ),
    );
    Text shown() => tester.widget<Text>(find.text(long));
    expect(shown().maxLines, 1);
    expect(shown().overflow, TextOverflow.ellipsis);
    expect(find.byType(InkWell), findsOneWidget);

    await tester.tap(find.text(long));
    await tester.pump();
    expect(shown().maxLines, isNull);

    await tester.tap(find.text(long));
    await tester.pump();
    expect(shown().maxLines, 1);
    expect(shown().overflow, TextOverflow.ellipsis);
  });

  testWidgets('the port helper on a phone can be expanded', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const NetQualityApp());
    await tester.pumpAndSettle();

    final hint = find.text(portHelperText);
    await tester.ensureVisible(hint);
    await tester.pumpAndSettle();
    Text shown() => tester.widget<Text>(hint);
    expect(shown().maxLines, 1);
    expect(shown().overflow, TextOverflow.ellipsis);

    await tester.tap(hint);
    await tester.pumpAndSettle();
    expect(shown().maxLines, isNull);
    expect(shown().overflow, TextOverflow.clip);
    expect(find.textContaining('切换类型才会自动更换'), findsOneWidget);

    await tester.ensureVisible(hint);
    await tester.tap(hint);
    await tester.pumpAndSettle();
    expect(shown().maxLines, 1);
  });
}
