import 'package:maat_seshat_core/maat_seshat_core.dart';

/// MySQL DDL: backtick identifiers, `auto_increment` keys, `datetime`
/// columns and `information_schema` for the catalogue queries.
///
/// MySQL commits implicitly on every DDL statement, so DDL cannot be rolled
/// back: a migration that fails halfway leaves the tables it already created
/// behind, whatever transaction it was started in. That is a property of the
/// server, not of this class — there is nothing to switch off.
class MysqlSchemaGrammar extends SchemaGrammar {
  const MysqlSchemaGrammar();

  @override
  String get name => 'mysql';

  @override
  String wrap(String identifier) => assertIdentifier(
    identifier,
  ).split('.').map((s) => '`${s.replaceAll('`', '``')}`').join('.');

  @override
  String typeFor(ColumnDefinition column) => switch (column.type) {
    // AUTO_INCREMENT is only legal on a key column, hence the inline
    // PRIMARY KEY. MySQL accepts column attributes in any order, so the
    // `not null` that compileColumn appends after this is fine.
    ColumnType.id => 'bigint unsigned auto_increment primary key',
    ColumnType.string => 'varchar(${column.length ?? 255})',
    ColumnType.text => 'text',
    ColumnType.integer => 'int',
    ColumnType.bigInteger => 'bigint',
    ColumnType.unsignedBigInteger => 'bigint unsigned',
    ColumnType.boolean => 'tinyint(1)',
    ColumnType.double_ => 'double',
    ColumnType.decimal =>
      'decimal(${column.precision ?? 8}, ${column.scale ?? 2})',
    ColumnType.date => 'date',
    // (3) = milliseconds, matching what MysqlGrammar.encode writes. A bare
    // `datetime` stores whole seconds and truncates the fraction silently.
    ColumnType.dateTime || ColumnType.timestamp => 'datetime(3)',
    ColumnType.json => 'json',
    ColumnType.uuid => 'char(36)',
  };

  @override
  String boolLiteral(bool value) => value ? '1' : '0';

  /// An index lives inside its table in MySQL, so dropping one names the
  /// table: `drop index x on t`, not the bare `drop index x` of the base.
  @override
  String compileCommand(String table, SchemaCommand command) =>
      command is DropIndexCommand
      ? 'drop index ${wrap(command.name)} on ${wrap(table)}'
      : super.compileCommand(table, command);

  // `information_schema` reports names in upper case on some servers, so
  // every catalogue query aliases the column the SchemaBuilder reads.

  @override
  Compiled compileTableExists() => (
    'select table_name as name from information_schema.tables '
        'where table_schema = database() and table_name = ?',
    const [],
  );

  @override
  Compiled compileColumnListing(String table) => (
    'select column_name as name from information_schema.columns '
        'where table_schema = database() and table_name = ? '
        'order by ordinal_position',
    [table],
  );

  @override
  String compileTableListing() =>
      'select table_name as name from information_schema.tables '
      "where table_schema = database() and table_type = 'BASE TABLE'";
}
