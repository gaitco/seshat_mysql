// Runs only when MYSQL_TEST_URL is set, e.g.
//   MYSQL_TEST_URL=mysql://root:secret@127.0.0.1:3306/maat_test \
//     dart test --tags=mysql
//
// The `mysql` tag is skipped by default in dart_test.yaml, exactly as
// seshat's postgres_test.dart is skipped without PG_TEST_URL.
@Tags(['mysql'])
library;

import 'dart:io';

import 'package:seshat/seshat.dart';
import 'package:seshat_mysql/seshat_mysql.dart';
import 'package:test/test.dart';

/// `secure: false` because the local test server does not offer TLS. It is
/// on by default everywhere else, and `DB_SECURE=false` is the documented
/// escape hatch for a development server.
Future<MysqlConnection> _open(Uri url) => MysqlConnection.open(
  secure: false,
  host: url.host,
  port: url.port == 0 ? 3306 : url.port,
  database: url.path.substring(1),
  username: url.userInfo.split(':').first,
  password: url.userInfo.contains(':') ? url.userInfo.split(':').last : null,
);

// Through Schema.on rather than a hand-built SchemaBuilder, so the first
// real run also exercises the schema-grammar registration.
Future<void> _schema(Connection db) async {
  final schema = Schema.on(db);
  await schema.dropIfExists('posts');
  await schema.dropIfExists('users');
  await schema.create('users', (t) {
    t.id();
    t.string('name');
    t.string('email').unique();
    t.boolean('active').defaultValue(true);
    t.integer('age').nullable();
    t.dateTime('seen_at').nullable();
  });
  await schema.create('posts', (t) {
    t.id();
    t.unsignedBigInteger('user_id');
    t.string('title');
  });
}

void main() {
  final url = Platform.environment['MYSQL_TEST_URL'];
  if (url == null) {
    test('mysql adapter (skipped: set MYSQL_TEST_URL)', () {}, skip: true);
    return;
  }

  late MysqlConnection db;
  setUp(() async {
    registerMysqlDriver();
    db = await _open(Uri.parse(url));
    DB.use(db);
    await _schema(db);
  });
  tearDown(() => db.close());

  test('connection failure is a ConnectionException', () {
    expect(
      () => MysqlConnection.open(host: '127.0.0.1', port: 1, database: 'x'),
      throwsA(isA<ConnectionException>()),
    );
  });

  test('the schema builder created the columns it was asked for', () async {
    final schema = Schema.on(db);
    expect(await schema.hasTable('users'), isTrue);
    expect(await schema.hasTable('nope'), isFalse);
    expect(await schema.columnListing('users'), [
      'id',
      'name',
      'email',
      'active',
      'age',
      'seen_at',
    ]);
  });

  test('insertGetId returns the auto_increment key', () async {
    final id = await DB.table('users').insertGetId({
      'name': 'Ann',
      'email': 'ann@x.test',
    });
    expect(id, 1);
    final second = await DB.table('users').insertGetId({
      'name': 'Bob',
      'email': 'bob@x.test',
    });
    expect(second, 2);
  });

  test('bindings land on the right columns, in order', () async {
    await DB.table('users').insert({
      'name': 'Ann',
      'email': 'ann@x.test',
      'age': 31,
    });
    final row = await DB.table('users').where('email', 'ann@x.test').first();
    expect(row!['name'], 'Ann');
    expect(row['age'], 31);

    // Two placeholders of the same type: a swapped binding order would
    // still return a row, just the wrong one.
    await DB.table('users').insert({
      'name': 'Bob',
      'email': 'bob@x.test',
      'age': 40,
    });
    final match = await DB
        .table('users')
        .where('name', 'Bob')
        .where('email', 'bob@x.test')
        .first();
    expect(match!['age'], 40);
    expect(
      await DB
          .table('users')
          .where('name', 'Bob')
          .where('email', 'ann@x.test')
          .first(),
      isNull,
    );
  });

  test('a value containing a ? is stored verbatim', () async {
    await DB.table('users').insert({
      'name': 'what? really?',
      'email': 'q@x.test',
    });
    final row = await DB.table('users').where('email', 'q@x.test').first();
    expect(row!['name'], 'what? really?');
  });

  test('a value containing quotes survives the round trip', () async {
    const nasty = "O'Brien \\ \"quoted\"";
    await DB.table('users').insert({'name': nasty, 'email': 'o@x.test'});
    final row = await DB.table('users').where('email', 'o@x.test').first();
    expect(row!['name'], nasty);
  });

  test('booleans and datetimes round trip', () async {
    final seen = DateTime.utc(2026, 9, 2, 14, 30, 15, 250);
    await DB.table('users').insert({
      'name': 'Ann',
      'email': 'ann@x.test',
      'active': false,
      'seen_at': seen,
    });
    final row = await DB.table('users').where('email', 'ann@x.test').first();
    expect(row!['active'], anyOf(false, 0));
    expect(DateTime.parse('${row['seen_at']}Z'), seen);
  });

  test('where, aggregates and pagination', () async {
    for (var i = 1; i <= 5; i++) {
      await DB.table('users').insert({
        'name': 'User $i',
        'email': 'u$i@x.test',
        'age': i,
      });
    }
    expect(await DB.table('users').count(), 5);
    expect(await DB.table('users').sum('age'), 15);
    expect(await DB.table('users').max('age'), 5);
    expect(await DB.table('users').where('age', '>', 3).count(), 2);
    expect(
      await DB.table('users').where('age', '>', 3).update({'active': false}),
      2,
    );
    final page = await DB
        .table('users')
        .orderBy('id')
        .paginate(page: 2, perPage: 2);
    expect(page.data.map((r) => r['name']), ['User 3', 'User 4']);
    expect(page.total, 5);
  });

  test('truncate empties the table and resets the key', () async {
    await DB.table('users').insert({'name': 'Ann', 'email': 'ann@x.test'});
    await DB.table('users').truncate();
    expect(await DB.table('users').count(), 0);
    expect(
      await DB.table('users').insertGetId({
        'name': 'Bob',
        'email': 'bob@x.test',
      }),
      1,
    );
  });

  test('a transaction commits on success', () async {
    await db.transaction((tx) async {
      await DB.table('users', connection: tx).insert({
        'name': 'Ann',
        'email': 'ann@x.test',
      });
    });
    expect(await DB.table('users').count(), 1);
  });

  test('a transaction rolls back on throw', () async {
    await expectLater(
      db.transaction((tx) async {
        await DB.table('users', connection: tx).insert({
          'name': 'Ann',
          'email': 'ann@x.test',
        });
        throw StateError('boom');
      }),
      throwsA(isA<StateError>()),
    );
    expect(await DB.table('users').count(), 0);
  });

  test('a nested transaction rolls back to its savepoint only', () async {
    await db.transaction((tx) async {
      await DB.table('users', connection: tx).insert({
        'name': 'Outer',
        'email': 'o@x.test',
      });
      try {
        await tx.transaction((inner) async {
          await DB.table('users', connection: inner).insert({
            'name': 'Inner',
            'email': 'i@x.test',
          });
          throw StateError('inner');
        });
      } on StateError {
        // The savepoint rollback is what is under test.
      }
    });
    expect(await DB.table('users').pluck('name'), ['Outer']);
  });

  test('rolling back returns the connection to the pool', () async {
    // The driver's own pool.transactional leaks a connection whenever the
    // callback throws. Assert on the pool's own counter rather than by
    // exhausting it: once every slot is leaked the driver spins in
    // `Future.doWhile` with a synchronous predicate, which never yields, so
    // no timer — not `.timeout`, not dart test's own — can ever fire. A test
    // that detects a regression by wedging the isolate is worse than none.
    expect(db.borrowedConnections, 0);
    await expectLater(
      db.transaction((tx) async => throw StateError('boom')),
      throwsA(isA<StateError>()),
    );
    expect(db.borrowedConnections, 0);
    // And the pool is still usable afterwards.
    expect(await DB.table('users').count(), 0);
  });

  test('a duplicate key is a UniqueConstraintException', () async {
    await DB.table('users').insert({'name': 'Ann', 'email': 'ann@x.test'});
    expect(
      () => DB.table('users').insert({'name': 'Bob', 'email': 'ann@x.test'}),
      throwsA(isA<UniqueConstraintException>()),
    );
  });

  test('a SQL error surfaces as a QueryException', () async {
    expect(
      () => db.select('select * from no_such_table'),
      throwsA(isA<QueryException>()),
    );
    expect(() => db.execute('this is not sql'), throwsA(isA<QueryException>()));
  });

  test('the query log records statements and bindings', () async {
    db.enableQueryLog();
    await DB.table('users').where('email', 'ann@x.test').get();
    expect(db.queryLog, hasLength(1));
    expect(db.queryLog.single.sql, contains('`users`'));
    expect(db.queryLog.single.bindings, ['ann@x.test']);
  });
}
