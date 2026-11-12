import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:influencor/core/widgets/smooth_wheel_scroll.dart';

class _Smooth extends MaterialScrollBehavior {
  const _Smooth();

  @override
  Widget buildOverscrollIndicator(
          BuildContext context, Widget child, ScrollableDetails details) =>
      SmoothWheelScroll(controller: details.controller, child: child);
}

void main() {
  Future<ScrollController> pumpList(WidgetTester tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      scrollBehavior: const _Smooth(),
      home: ListView.builder(
        controller: controller,
        itemCount: 100,
        itemBuilder: (_, i) => SizedBox(height: 50, child: Text('$i')),
      ),
    ));
    return controller;
  }

  Future<void> wheel(WidgetTester tester, double dy,
      {PointerDeviceKind kind = PointerDeviceKind.mouse}) async {
    final pointer = TestPointer(1, kind);
    pointer.hover(tester.getCenter(find.byType(ListView)));
    await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  }

  testWidgets('the mouse wheel glides instead of jumping', (tester) async {
    final controller = await pumpList(tester);
    await wheel(tester, 200);
    await tester.pump();
    // Nothing moved yet: the view glides from where it was.
    expect(controller.offset, 0);
    await tester.pump(const Duration(milliseconds: 60));
    expect(controller.offset, inExclusiveRange(0, 200));
    await tester.pumpAndSettle();
    expect(controller.offset, 200);
  });

  testWidgets('quick wheel steps add up', (tester) async {
    final controller = await pumpList(tester);
    await wheel(tester, 200);
    await tester.pump(const Duration(milliseconds: 50));
    await wheel(tester, 200);
    await tester.pumpAndSettle();
    expect(controller.offset, 400);
  });

  testWidgets('stops at the end of the list', (tester) async {
    final controller = await pumpList(tester);
    final max = controller.position.maxScrollExtent;
    await wheel(tester, max - 100);
    await tester.pump(const Duration(milliseconds: 50));
    await wheel(tester, 400);
    await tester.pumpAndSettle();
    expect(controller.offset, max);
  });
}
