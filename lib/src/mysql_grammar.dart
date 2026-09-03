import 'package:seshat/seshat.dart';

/// MySQL query grammar: backtick-quoted identifiers, no `RETURNING`,
/// `TRUNCATE TABLE`, and `DATETIME` literals that carry no zone.
///
/// Everything else — placeholders, `where`, joins, pagination — is the ANSI
/// SQL the base [Grammar] already emits.
class MysqlGrammar extends Grammar {
  const MysqlGrammar();

  @override
  String get name => 'mysql';

  /// MySQL quotes identifiers with backticks and doubles an embedded one.
  ///
  /// [Grammar.wrap] runs every name through `assertColumn` first, so a name
  /// containing a backtick is rejected long before it reaches here — this
  /// escaping is the second line of defence behind that gate, not a
  /// substitute for it.
  @override
  String wrapValue(String value) => '`${value.replaceAll('`', '``')}`';

  @override
  Object? encode(Object? value) {
    if (value is DateTime) return _dateTime(value);
    return super.encode(value);
  }

  /// A MySQL `DATETIME` has no time zone, so values are stored as UTC in
  /// `yyyy-MM-dd HH:mm:ss.SSS` — ISO-8601 with the `T` and the `Z` removed,
  /// both of which MySQL rejects.
  static String _dateTime(DateTime value) {
    final iso = value.toUtc().toIso8601String(); // always ends in 'Z'
    return iso.substring(0, iso.length - 1).replaceFirst('T', ' ');
  }

  /// MySQL has no `RETURNING`, so the insert is left plain and
  /// `MysqlConnection.insertGetId` reads `LAST_INSERT_ID()` off the OK
  /// packet instead.
  @override
  Compiled compileInsertGetId(
    String table,
    Map<String, Object?> row,
    String primaryKey,
  ) => compileInsert(table, [row]);

  /// `TRUNCATE` resets `AUTO_INCREMENT` and is far cheaper than `DELETE`.
  @override
  String compileTruncate(String table) => 'truncate table ${wrapTable(table)}';
}
