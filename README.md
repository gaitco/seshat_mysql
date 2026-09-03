# Seshat MySQL

<p align="center"><img src="assets/icon.svg" width="96" alt="Seshat MySQL icon"></p>

A MySQL adapter for Maat's database layer: `MysqlConnection`,
`MysqlGrammar` and `MysqlSchemaGrammar`, plus `registerMysqlDriver()` to
expose it as the `mysql` driver in `config('database')`.

## Read this before you choose MySQL

The only pure-Dart MySQL driver on pub.dev, **`mysql_client`, was last
published in 2022 and is not actively maintained.** That is the reason this
adapter lives in its own package instead of being a dependency of
`maat_seshat_core` or `maat_seshat`: a driver the framework cannot rely on
must not be something every application carries.

**Postgres and SQLite are the better-supported choices.** Both drivers used by
`maat_seshat_core` (`package:postgres` and `package:sqlite3`) are maintained, and
both adapters ship in the core package. Reach for this one when you have a
MySQL server you do not control, not because MySQL is the default choice.

Two consequences of the driver you should know about before you deploy:

- **Parameters are interpolated, not bound.** `mysql_client` substitutes
  values into the SQL string (escaping them) rather than sending a binary
  prepared statement. Its prepared-statement path exists but reports
  `affectedRows` and `lastInsertID` as zero, which makes it unusable for
  `execute()` and `insertGetId()`, so this adapter uses the interpolating
  path. Values still never reach the server unescaped, and identifiers still
  pass through `maat_seshat_core`'s identifier gate.
- **A `?` the driver would read as inside a string is left unbound.** The
  driver decides that by counting raw `'` and `"` in the prefix, which is not
  MySQL's grammar — it ignores backslash escapes. Rewriting such a `?` anyway
  would send a literal `:p0` to the server, so `RawSql` carrying a `\'`
  escape raises a `DatabaseException` naming the mismatch instead. Use `''`
  rather than `\'` in hand-written SQL.
- **The pool leaks a connection when a transaction throws.** The driver's own
  `pool.transactional` releases the connection only on the success path.
  `MysqlConnection.transaction` therefore drives `start transaction` /
  `commit` / `rollback` itself so that a rolled-back transaction returns its
  connection to the pool.

## Use

```dart
import 'package:maat_seshat_mysql/maat_seshat_mysql.dart';

registerMysqlDriver();          // before Application.create()
```

```dart
// config/database.dart
'connections': {
  'mysql': {
    'driver': 'mysql',
    'host': env('DB_HOST', '127.0.0.1'),
    'port': envInt('DB_PORT', 3306),
    'database': env('DB_DATABASE'),
    'username': env('DB_USERNAME'),
    'password': env('DB_PASSWORD'),
    'secure': envBool('DB_SECURE', true),   // TLS; false only for local dev
  },
},
```

Or open one directly:

```dart
final db = await MysqlConnection.open(
  host: 'localhost',
  database: 'app',
  username: 'app',
  password: '...',
);
DB.use(db);
```

## Dialect differences this adapter handles

| | MySQL | Base grammar |
| --- | --- | --- |
| Identifiers | `` `users`.`email` `` | `"users"."email"` |
| Generated key | `LAST_INSERT_ID()` | `RETURNING` |
| Truncate | `truncate table` | `delete from` |
| `DateTime` | `2026-09-02 14:30:15.250` (UTC) | driver-native |
| Auto key | `bigint unsigned auto_increment` | `bigserial` |
| Booleans | `tinyint(1)`, `1`/`0` | `boolean`, `true`/`false` |
| Datetimes | `datetime(3)` — milliseconds | `timestamp` — microseconds |
| Non-auto-increment key | `insertGetId` returns `null` | the real key |
| Drop index | `drop index i on t` | `drop index i` |

The grammar emits positional `?` marks; `mysql_client` binds by name, so
`toNamedParameters` rewrites them to `:p0, :p1, …` and builds the matching
map. A `?` inside a quoted string or a backtick-quoted identifier is left
alone, and a count mismatch throws rather than binding values to the wrong
columns.

## TLS

TLS is **on by default**, matching the driver. Set `'secure': false` in the
connection config (`DB_SECURE=false`) only for a local development or CI
server that cannot negotiate TLS — never for a remote one.

## Migrations: no rollback of DDL

`registerMysqlDriver()` registers the schema grammar as well as the
connection, so `Schema`, `SchemaBuilder.on` and the `migrate:*` commands all
work against MySQL.

**But a failed migration is not undone.** MySQL commits implicitly on every
DDL statement, so the transaction `Migrator` wraps each migration in cannot
roll one back: if `up()` creates two tables and then throws, both tables are
still there, and the repository row is not — so a rerun starts from a dirty
database. SQLite and PostgreSQL both have transactional DDL and do not have
this problem. That is a property of the server, permanent and not fixable
here.

Practically: keep MySQL migrations small enough that one is one statement, or
make each `up()` idempotent (`drop table if exists` first), and check the
database by hand after a failure rather than trusting the rollback.

## Tests

`dart test` runs the grammar and parameter-binding tests, which need no
server. The connection tests are tagged `mysql` and skipped by default:

```sh
MYSQL_TEST_URL=mysql://root:secret@127.0.0.1:3306/maat_test \
  dart test --tags=mysql
```
