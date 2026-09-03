import 'package:seshat/seshat.dart';
import 'package:seshat/sqlite.dart';
import 'package:seshat_mysql/seshat_mysql.dart';
import 'package:test/test.dart';

void main() {
  const grammar = MysqlGrammar();
  const schema = MysqlSchemaGrammar();

  group('MysqlGrammar', () {
    test('names itself mysql', () => expect(grammar.name, 'mysql'));

    test('quotes identifiers with backticks', () {
      expect(grammar.wrap('email'), '`email`');
      expect(grammar.wrap('users.email'), '`users`.`email`');
      expect(grammar.wrapTable('users'), '`users`');
    });

    test('wrapValue doubles an embedded backtick', () {
      expect(grammar.wrapValue('we`ird'), '`we``ird`');
    });

    // The escaping above is defence in depth: wrap() never reaches it,
    // because assertColumn rejects the name first. Both levels matter.
    test('wrap rejects a name containing a backtick', () {
      expect(
        () => grammar.wrap('we`ird'),
        throwsA(isA<InvalidIdentifierException>()),
      );
    });

    test('leaves star unwrapped', () {
      expect(grammar.wrap('*'), '*');
      expect(grammar.wrap('users.*'), '`users`.*');
    });

    test('wraps an alias', () {
      expect(
        grammar.wrap('users.name as author'),
        '`users`.`name` as `author`',
      );
    });

    // Inherited from the base Grammar, which this package does not own: no
    // MySQL-side change can break it. Kept as cheap insurance against a
    // seshat change, not as coverage of anything here.
    test('passes RawSql through untouched', () {
      expect(grammar.wrap(RawSql('count(*)')), 'count(*)');
    });

    test('encodes DateTime as a zoneless UTC datetime literal', () {
      final value = DateTime.utc(2026, 9, 2, 14, 30, 15, 250);
      expect(grammar.encode(value), '2026-09-02 14:30:15.250');
      // A local-zone value is converted, not merely reformatted.
      final local = DateTime.utc(2026, 1, 2, 3, 4, 5).toLocal();
      expect(grammar.encode(local), '2026-01-02 03:04:05.000');
    });

    test('insertGetId emits no RETURNING clause', () {
      final (sql, bindings) = grammar.compileInsertGetId('users', {
        'name': 'Ann',
      }, 'id');
      expect(sql, 'insert into `users` (`name`) values (?)');
      expect(sql, isNot(contains('returning')));
      expect(bindings, ['Ann']);
    });

    test('truncate uses TRUNCATE TABLE', () {
      expect(grammar.compileTruncate('users'), 'truncate table `users`');
    });

    test('compiles a select with backticks and ? placeholders', () {
      final scratch = SqliteConnection.inMemory();
      addTearDown(scratch.close);
      final query = DB.table('users', connection: scratch)
        ..where('age', '>', 18)
        ..orderBy('name')
        ..limit(10);
      final (sql, bindings) = grammar.compileSelect(query);
      expect(
        sql,
        'select * from `users` where `age` > ? order by `name` asc limit 10',
      );
      expect(bindings, [18]);
    });
  });

  group('registerMysqlDriver', () {
    test('makes the schema grammar reachable for migrations', () {
      // Nothing else registers 'mysql', so a run of this test alone and a run
      // inside the full suite see the same empty starting point.
      expect(
        () => schemaGrammarFor(_MysqlishConnection()),
        throwsA(isA<DatabaseException>()),
        reason: 'mysql must not already be registered',
      );
      registerMysqlDriver();
      expect(
        schemaGrammarFor(_MysqlishConnection()),
        isA<MysqlSchemaGrammar>(),
      );
    });
  });

  group('MysqlSchemaGrammar', () {
    test('names itself mysql', () => expect(schema.name, 'mysql'));

    test('wraps identifiers with backticks', () {
      expect(schema.wrap('users'), '`users`');
      expect(schema.wrap('app.users'), '`app`.`users`');
    });

    test('creates a table with MySQL column types', () {
      final blueprint = Blueprint('users')
        ..id()
        ..string('email')
        ..string('code', 8)
        ..boolean('active').defaultValue(true)
        ..integer('age').nullable()
        ..dateTime('seen_at')
        ..decimal('balance', precision: 10, scale: 4);
      expect(
        schema.compileCreate(blueprint).first,
        [
          'create table `users` (',
          '`id` bigint unsigned auto_increment primary key not null, ',
          '`email` varchar(255) not null, ',
          '`code` varchar(8) not null, ',
          '`active` tinyint(1) not null default 1, ',
          '`age` int null, ',
          '`seen_at` datetime(3) not null, ',
          '`balance` decimal(10, 4) not null)',
        ].join(),
      );
    });

    test('a unique column adds a create index statement', () {
      final blueprint = Blueprint('users')
        ..id()
        ..string('email').unique();
      expect(
        schema.compileCreate(blueprint).last,
        'create unique index `users_email_unique` on `users` (`email`)',
      );
    });

    test('dropping an index names its table', () {
      expect(
        schema.compileCommand('users', const DropIndexCommand('users_email')),
        'drop index `users_email` on `users`',
      );
    });

    test('other alter commands keep the base spelling, backticked', () {
      expect(
        schema.compileCommand('users', const DropColumnCommand('age')),
        'alter table `users` drop column `age`',
      );
      expect(
        schema.compileCommand('users', const RenameColumnCommand('a', 'b')),
        'alter table `users` rename column `a` to `b`',
      );
    });

    test('catalogue queries read information_schema of the current db', () {
      final (existsSql, existsBindings) = schema.compileTableExists();
      expect(existsSql, contains('information_schema.tables'));
      expect(existsSql, contains('table_schema = database()'));
      expect(existsSql, endsWith('table_name = ?'));
      expect(existsBindings, isEmpty);

      final (columnsSql, columnsBindings) = schema.compileColumnListing(
        'users',
      );
      // SchemaBuilder.columnListing reads r['name'], so the alias is load
      // bearing: information_schema names the column COLUMN_NAME.
      expect(columnsSql, contains('column_name as name'));
      expect(columnsSql, contains('order by ordinal_position'));
      expect(columnsBindings, ['users']);

      expect(schema.compileTableListing(), contains('table_name as name'));
      expect(schema.compileTableListing(), contains("'BASE TABLE'"));
    });
  });
}

/// schemaGrammarFor only reads `connection.grammar.name`, so that is all this
/// stands up. noSuchMethod supplies the rest of the Connection surface.
class _MysqlishConnection extends ConnectionBase {
  @override
  Grammar get grammar => const MysqlGrammar();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
