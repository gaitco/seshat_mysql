import 'package:seshat/seshat.dart';
import 'package:seshat_mysql/seshat_mysql.dart';
import 'package:test/test.dart';

/// `mysql_client` binds by name; the grammar emits positional `?`. These
/// tests pin the translation between the two, because getting the order
/// wrong binds the right values to the wrong columns silently — a
/// corruption bug that no live query would announce.
void main() {
  test('rewrites ? marks in order and pairs each with its binding', () {
    final (sql, params) = toNamedParameters(
      'update `users` set `name` = ?, `age` = ? where `id` = ?',
      ['Ann', 31, 7],
    );
    expect(
      sql,
      'update `users` set `name` = :p0, `age` = :p1 where `id` = :p2',
    );
    expect(params, {'p0': 'Ann', 'p1': 31, 'p2': 7});
  });

  test('numbers past nine without colliding on a prefix', () {
    final (sql, params) = toNamedParameters(
      List.filled(12, '?').join(','),
      List.generate(12, (i) => i),
    );
    expect(sql, [for (var i = 0; i < 12; i++) ':p$i'].join(','));
    expect(params['p1'], 1);
    expect(params['p11'], 11);
  });

  test('leaves a ? inside a single-quoted string alone', () {
    final (sql, params) = toNamedParameters(
      "select * from `t` where `q` = 'what? really?' and `id` = ?",
      [1],
    );
    expect(sql, "select * from `t` where `q` = 'what? really?' and `id` = :p0");
    expect(params, {'p0': 1});
  });

  test('a doubled quote does not end the string early', () {
    final (sql, params) = toNamedParameters(
      "select 'it''s a ? mark' as `x` where `id` = ?",
      [1],
    );
    expect(sql, "select 'it''s a ? mark' as `x` where `id` = :p0");
    expect(params, {'p0': 1});
  });

  // The next two document a driver quirk, not MySQL's grammar. The driver
  // decides "is this :pN inside a string?" by counting raw ' and " in the
  // prefix, taking no notice of backslash escapes or of which quote opened
  // the literal. Rewriting a ? it would then refuse to substitute sends a
  // literal :pN to the server, so these inputs are rejected up front instead.
  test('a backslash escape leaves the rest unbindable, and says so', () {
    expect(
      () => toNamedParameters(r"select 'it\'s a ? mark' where `id` = ?", [1]),
      throwsA(
        isA<DatabaseException>().having(
          (e) => e.message,
          'message',
          contains('0 bindable'),
        ),
      ),
    );
  });

  test('a quote of the other kind inside a literal is unbindable too', () {
    expect(
      () => toNamedParameters("""select 'a"b' as `x`, ?""", [1]),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('leaves a ? inside a double-quoted string alone', () {
    final (sql, params) = toNamedParameters('select "a ? b", ?', [1]);
    expect(sql, 'select "a ? b", :p0');
    expect(params, {'p0': 1});
  });

  test('leaves a ? inside a backtick identifier alone', () {
    final (sql, params) = toNamedParameters('select `wh?at` from `t` = ?', [1]);
    expect(sql, 'select `wh?at` from `t` = :p0');
    expect(params, {'p0': 1});
  });

  test('a backslash inside a backtick identifier is not an escape', () {
    // MySQL honours no backslash escapes inside `...`, so the closing
    // backtick here really does close the identifier.
    final (sql, params) = toNamedParameters(r'select `a\` , ? from `t`', [1]);
    expect(sql, r'select `a\` , :p0 from `t`');
    expect(params, {'p0': 1});
  });

  test('no bindings leaves the statement untouched', () {
    final (sql, params) = toNamedParameters('select 1', const []);
    expect(sql, 'select 1');
    expect(params, isEmpty);
  });

  test('too few bindings for the ? marks throws', () {
    expect(
      () => toNamedParameters('select ?, ?', [1]),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('too many bindings for the ? marks throws', () {
    expect(
      () => toNamedParameters('select ?', [1, 2]),
      throwsA(isA<DatabaseException>()),
    );
  });
}
