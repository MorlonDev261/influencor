import 'package:flutter_test/flutter_test.dart';
import 'package:influencor/features/fees/data/madagascar_tariffs.dart';
import 'package:influencor/features/fees/domain/mobile_money_fees.dart';

void main() {
  const optimizer = FeeOptimizer();
  OperatorTariff t(String n) =>
      madagascarTariffs.firstWhere((x) => x.name == n);

  test('official grids: spot checks', () {
    // MVola → MVola 5 001–10 000 = 150; withdrawal 25 001–50 000 = 1 300.
    expect(FeeOptimizer.directFee(t('MVola').transfer, 8000), 150);
    expect(FeeOptimizer.directFee(t('MVola').withdraw, 40000), 1300);
    // MVola → other operators 10 001–25 000 = 1 000.
    expect(FeeOptimizer.directFee(t('MVola').transferOther!, 20000), 1000);
    // Orange: Orange→Orange, app (-50 %), other network, withdrawal.
    expect(FeeOptimizer.directFee(t('Orange Money').transfer, 30000), 500);
    expect(FeeOptimizer.directFee(t('Orange Money').transferApp!, 30000), 250);
    expect(
        FeeOptimizer.directFee(t('Orange Money').transferOther!, 30000), 900);
    expect(FeeOptimizer.directFee(t('Orange Money').withdraw, 30000), 1300);
  });

  test('splitting saves money across a bracket boundary', () {
    // MVola: 10 001 direct = 250; 10 000 (150) + 1 → below min, so use
    // 5 001..10 000 then the rest.
    final p = optimizer.plan(t('MVola'), FeeKind.transfer, 25000)!;
    expect(p.totalFee <= p.directFee!, isTrue);
    expect(p.amount, 25000);
  });

  test('parts sum to the amount, fee never exceeds direct', () {
    for (final tariff in madagascarTariffs) {
      for (final kind in FeeKind.values) {
        for (final target in TransferTarget.values) {
          for (final a in [300, 999, 26000, 120000, 1000000, 7300000]) {
            final p = optimizer.plan(tariff, kind, a, target: target);
            if (p == null) continue;
            expect(p.amount, a);
            expect(p.totalFee <= (p.directFee ?? 1 << 40), isTrue,
                reason: '${tariff.name} $kind $target $a');
          }
        }
      }
    }
  });

  test('large amounts are split when one operation cannot carry them', () {
    final p = optimizer.plan(t('Orange Money'), FeeKind.transfer, 12000000)!;
    expect(p.directFee, isNull);
    expect(p.parts.length, greaterThan(1));
    expect(p.amount, 12000000);
  });

  test('stays fast on worst cases', () {
    final sw = Stopwatch()..start();
    for (final tariff in madagascarTariffs) {
      for (final a in [49999, 250001, 1999999, 9999999, 19999999]) {
        optimizer.plan(tariff, FeeKind.withdraw, a);
        optimizer.plan(tariff, FeeKind.transfer, a);
      }
    }
    expect(sw.elapsedMilliseconds, lessThan(5000));
  });
  test('fees included: amount + fees fits the balance, as large as possible',
      () {
    for (final tariff in madagascarTariffs) {
      for (final kind in FeeKind.values) {
        for (final budget in [500, 10150, 26000, 51300, 250000, 3000000]) {
          final p = optimizer.planWithin(tariff, kind, budget);
          if (p == null) continue;
          expect(p.amount + p.totalFee, lessThanOrEqualTo(budget));
          // One more Ariary no longer fits.
          final next = optimizer.plan(tariff, kind, p.amount + 1);
          if (next != null) {
            expect(p.amount + 1 + next.totalFee, greaterThan(budget),
                reason: '${tariff.name} $kind $budget');
          }
        }
      }
    }
  });

  test('fees included: MVola withdrawal from a 51 300 Ar balance', () {
    // 50 000 + 1 300 = 51 300: the whole balance is used.
    final p = optimizer.planWithin(t('MVola'), FeeKind.withdraw, 51300)!;
    expect(p.amount + p.totalFee, lessThanOrEqualTo(51300));
    expect(p.amount, greaterThanOrEqualTo(50000));
  });

  test('fees included: balance below the smallest operation', () {
    expect(optimizer.planWithin(t('MVola'), FeeKind.withdraw, 50), isNull);
  });
}
