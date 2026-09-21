/// Shared, clearly fictional people for test fixtures.
///
/// Never replace these with a real person's name. Pick distinct fictional
/// first/last names when adding a persona, and use these constants everywhere
/// a person appears in tests. See `AGENTS.md`.
///
/// Usage:
/// ```dart
/// import 'support/personas.dart';
///
/// final entry = entryWithFace('photo-1', e, name: Personas.alex.name);
/// final contact = Personas.kim.contactDisplayName; // "Kim D."
/// ```
class TestPersona {
  const TestPersona(
    this.firstName,
    this.lastName, {
    this.aliases = const [],
  });

  final String firstName;
  final String lastName;
  final List<String> aliases;

  /// Canonical name used as an identity/face tag.
  String get name => firstName;

  /// First + last, for display contexts that want a full name.
  String get fullName => '$firstName $lastName';

  /// Contact-style label, e.g. "Alex R.".
  String get contactDisplayName => '$firstName ${lastName[0]}.';

  /// Every name this persona answers to (canonical first).
  List<String> get allNames => [firstName, ...aliases];
}

/// The canonical fixture cast. Fictional names only.
abstract final class Personas {
  static const alex = TestPersona('Alex', 'Rivera');
  static const riley = TestPersona('Riley', 'Bennett');
  static const casey = TestPersona('Casey', 'Park');
  static const kim = TestPersona('Kim', 'Delgado', aliases: ['Kimmy']);
  static const jordan = TestPersona('Jordan', 'Ellis');
  static const robin = TestPersona('Robin', 'Novak', aliases: ['Rob']);
  static const alice = TestPersona('Alice', 'Nguyen', aliases: ['Al']);
  static const bob = TestPersona('Bob', 'Stone');

  static const all = [alex, riley, casey, kim, jordan, robin, alice, bob];
}
