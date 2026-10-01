import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:to_do/constants.dart';
import 'package:to_do/screens/task_screen.dart';

/// True when [greeting] is what you get from substituting [name] into one of
/// [variants]. Lets a test assert "the greeting came from this bucket"
/// without pinning down which specific variant a seed picks — so reordering
/// or adding variants does not break the test.
bool _matchesBucket(List<String> variants, String greeting, String name) {
  for (final variant in variants) {
    if (variant.replaceAll(kGreetingNamePlaceholder, name) == greeting) {
      return true;
    }
  }
  return false;
}

void main() {
  group('greetingFor picks from the right bucket', () {
    const name = 'Alex';

    test('night-owl hours: 22:00–04:59', () {
      for (final hour in [22, 23, 0, 3, 4]) {
        expect(
          _matchesBucket(
            kGreetingNightOwlUnnamed,
            greetingFor(hour, null, random: Random(1)),
            '',
          ),
          isTrue,
          reason:
              'hour $hour with no name should be an unnamed night-owl '
              'greeting',
        );
        expect(
          _matchesBucket(
            kGreetingNightOwlNamed,
            greetingFor(hour, name, random: Random(1)),
            name,
          ),
          isTrue,
          reason:
              'hour $hour with a name should be a named night-owl '
              'greeting',
        );
      }
    });

    test('morning hours: 05:00–11:59', () {
      for (final hour in [5, 9, 11]) {
        expect(
          _matchesBucket(
            kGreetingMorningUnnamed,
            greetingFor(hour, null, random: Random(1)),
            '',
          ),
          isTrue,
          reason:
              'hour $hour with no name should be an unnamed morning '
              'greeting',
        );
        expect(
          _matchesBucket(
            kGreetingMorningNamed,
            greetingFor(hour, name, random: Random(1)),
            name,
          ),
          isTrue,
          reason: 'hour $hour with a name should be a named morning greeting',
        );
      }
    });

    test('afternoon hours: 12:00–16:59', () {
      for (final hour in [12, 14, 16]) {
        expect(
          _matchesBucket(
            kGreetingAfternoonUnnamed,
            greetingFor(hour, null, random: Random(1)),
            '',
          ),
          isTrue,
          reason:
              'hour $hour with no name should be an unnamed afternoon '
              'greeting',
        );
        expect(
          _matchesBucket(
            kGreetingAfternoonNamed,
            greetingFor(hour, name, random: Random(1)),
            name,
          ),
          isTrue,
          reason:
              'hour $hour with a name should be a named afternoon '
              'greeting',
        );
      }
    });

    test('evening hours: 17:00–21:59', () {
      for (final hour in [17, 19, 21]) {
        expect(
          _matchesBucket(
            kGreetingEveningUnnamed,
            greetingFor(hour, null, random: Random(1)),
            '',
          ),
          isTrue,
          reason:
              'hour $hour with no name should be an unnamed evening '
              'greeting',
        );
        expect(
          _matchesBucket(
            kGreetingEveningNamed,
            greetingFor(hour, name, random: Random(1)),
            name,
          ),
          isTrue,
          reason: 'hour $hour with a name should be a named evening greeting',
        );
      }
    });
  });

  test('an empty name falls back to the unnamed variants', () {
    // SKIP stores '' rather than null; both must read as "no name".
    for (final hour in [9, 14, 19, 23]) {
      expect(
        _matchesBucket(
          hour >= 22 || hour < 5
              ? kGreetingNightOwlUnnamed
              : hour < 12
              ? kGreetingMorningUnnamed
              : hour < 17
              ? kGreetingAfternoonUnnamed
              : kGreetingEveningUnnamed,
          greetingFor(hour, '', random: Random(1)),
          '',
        ),
        isTrue,
      );
    }
  });

  test('a named greeting contains the name and no leftover placeholder', () {
    // Sweep seeds so we hit every variant in each named list at least once,
    // and assert none of them leaks the raw {name} token or drops the name.
    for (final hour in [9, 14, 19, 23]) {
      for (var seed = 0; seed < 20; seed++) {
        final greeting = greetingFor(hour, 'Alex', random: Random(seed));
        expect(
          greeting,
          contains('Alex'),
          reason: 'hour $hour seed $seed lost the name',
        );
        expect(
          greeting,
          isNot(contains(kGreetingNamePlaceholder)),
          reason: 'hour $hour seed $seed leaked the placeholder',
        );
      }
    }
  });
}
