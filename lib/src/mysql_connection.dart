import 'dart:async';

import 'package:seshat/seshat.dart';
import 'package:mysql_client/exception.dart' as my;
import 'package:mysql_client/mysql_client.dart' as my;

import 'mysql_grammar.dart';

/// MySQL error numbers for "that value is already there".
const _duplicateEntry = {1062, 1586};

/// Rewrites the positional `?` marks the grammar emits into the `:p0, :p1,
/// …` marks `mysql_client` binds by name, and pairs each with its value.
///
/// The ordering is the whole point: `p0` is the value for the first `?`, and
/// getting that wrong binds the right values to the wrong columns without
/// ever raising an error. A `?` inside a quoted string or a backtick-quoted
/// identifier is data, not a placeholder, and is copied through untouched.
///
/// A `?` is only rewritten where this scanner *and* the driver agree it sits
/// outside every string. The driver decides that by counting raw `'` and `"`
/// in the prefix (`_substitureParams` in `mysql_client`), which is not
/// MySQL's grammar: it takes no notice of backslash escapes or of backticks.
/// Where the two disagree — SQL carrying a `\'` escape, say — rewriting
/// anyway would produce a `:p0` the driver then refuses to substitute and
/// MySQL rejects as a syntax error, so the placeholder is left alone and the
/// count check below turns it into a clear exception instead. **The parity
/// test deliberately mirrors that driver quirk; do not "correct" it to
/// MySQL's real rule while the driver still does the substituting.**
///
/// Throws [DatabaseException] when the number of `?` marks and the number of
/// bindings disagree — loudly, rather than silently writing a wrong row.
///
// ponytail: string and identifier quoting only. A `?` inside a `--`, `#` or
// `/* */` comment would still be rewritten; this grammar never emits
// comments, so that only bites hand-written RawSql. Extend the scanner if it
// ever does.
(String, Map<String, dynamic>) toNamedParameters(
  String sql,
  List<Object?> bindings,
) {
  final out = StringBuffer();
  final params = <String, dynamic>{};
  var next = 0; // index of the binding the next ? consumes
  var quote = ''; // the delimiter we are inside; empty when outside one
  var singles = 0; // raw ' and " counts, tallied the way the driver tallies
  var doubles = 0; // them: every occurrence, escaped or backticked or not
  for (var i = 0; i < sql.length; i++) {
    var char = sql[i];
    if (char == "'") {
      singles++;
    } else if (char == '"') {
      doubles++;
    }
    if (quote.isNotEmpty) {
      out.write(char);
      if (char == r'\' && quote != '`' && i + 1 < sql.length) {
        char = sql[++i]; // backslash escape: the next char is literal
        if (char == "'") {
          singles++;
        } else if (char == '"') {
          doubles++;
        }
        out.write(char);
      } else if (char == quote) {
        // A doubled delimiter (`'it''s'`) needs no special case: closing on
        // the first and reopening on the second classifies every character
        // between them identically.
        quote = '';
      }
      continue;
    }
    if (char == "'" || char == '"' || char == '`') {
      quote = char;
    } else if (char == '?' && singles.isEven && doubles.isEven) {
      if (next >= bindings.length) {
        throw DatabaseException(
          'More ? placeholders than the ${bindings.length} bindings given.',
          sql: sql,
          bindings: bindings,
        );
      }
      params['p$next'] = bindings[next];
      out.write(':p$next');
      next++;
      continue;
    }
    out.write(char);
  }
  if (next != bindings.length) {
    throw DatabaseException(
      'Got ${bindings.length} bindings for $next bindable ? placeholders. A '
      "? the driver would read as inside a string literal (its raw ' and \" "
      'counting ignores backslash escapes) is left unbound on purpose.',
      sql: sql,
      bindings: bindings,
    );
  }
  return (out.toString(), params);
}

/// A connection to MySQL via `package:mysql_client` (pure Dart).
///
/// ```dart
/// final db = await MysqlConnection.open(
///   host: 'localhost', database: 'app', username: 'app', password: '...',
/// );
/// DB.use(db);
/// ```
///
/// Statements run on a pool. A [transaction] pins one connection from that
/// pool for its whole duration, so `begin`, every statement inside, and the
/// final `commit` all reach the same server session; the object handed to
/// the callback is that pinned session, so use it (`User.using(tx)`) for
/// everything that must be inside the transaction.
class MysqlConnection extends _MysqlSession {
  MysqlConnection._(this._pool) : super(null);

  /// Opens a pool and proves it can reach the server, so a bad host or
  /// password fails here rather than on the first query.
  ///
  /// [secure] keeps the driver's own default of TLS on. Turn it off only for
  /// a local server that cannot negotiate TLS, never for a remote one.
  static Future<MysqlConnection> open({
    String host = 'localhost',
    int port = 3306,
    required String database,
    String username = 'root',
    String? password,
    int maxConnections = 5,
    bool secure = true,
    String collation = 'utf8mb4_general_ci',
    int timeoutMs = 10000,
  }) async {
    final pool = my.MySQLConnectionPool(
      host: host,
      port: port,
      userName: username,
      password: password ?? '',
      databaseName: database,
      maxConnections: maxConnections,
      secure: secure,
      collation: collation,
      timeoutMs: timeoutMs,
    );
    try {
      await pool.execute('select 1');
      return MysqlConnection._(pool);
    } catch (e) {
      await pool.close();
      throw ConnectionException(
        'Cannot connect to MySQL at $host:$port/$database: $e',
        cause: e,
      );
    }
  }

  final my.MySQLConnectionPool _pool;

  @override
  Future<my.IResultSet> send(String sql, Map<String, dynamic> params) =>
      _pool.execute(sql, params);

  @override
  int get transactionDepth => 0;

  /// Runs [body] against one pinned pool connection.
  ///
  // ponytail: the driver's own `pool.transactional` leaks the connection
  // when the callback throws — it releases only on the success path — so a
  // rolled-back transaction would cost a pool slot and enough of them would
  // wedge the pool. Catching here and rethrowing after release avoids that
  // without forking the driver.
  @override
  Future<R> transaction<R>(Future<R> Function(Connection tx) body) async {
    final completer = Completer<R>();
    my.MySQLConnection? broken;
    await _pool.withConnection((connection) async {
      final tx = _MysqlTransaction(connection, this);
      try {
        await tx.execute('start transaction');
        final result = await body(tx);
        await tx.execute('commit');
        completer.complete(result);
      } catch (e, stack) {
        try {
          await tx.execute('rollback');
        } catch (_) {
          // The rollback itself failed, so the transaction is still open on
          // this connection and the next borrower would inherit it. Drop it
          // rather than hand it back; the failure must not mask the original
          // error either, so it is swallowed here.
          broken = connection;
        }
        completer.completeError(e, stack);
      }
    });
    // withConnection returns the connection to the idle list unconditionally,
    // so a poisoned one has to be closed afterwards: the driver's onClose
    // hook is what actually removes it from the pool.
    if (broken != null) {
      try {
        await broken!.close();
      } catch (_) {
        // Already gone. Nothing left to reclaim.
      }
    }
    return completer.future;
  }

  /// Connections currently checked out of the pool. Zero between statements;
  /// anything else once a transaction has finished means one leaked, which
  /// eventually wedges the pool in an unkillable busy-wait.
  int get borrowedConnections => _pool.activeConnectionsQty;

  @override
  Future<void> close() => _pool.close();
}

/// One open transaction, pinned to the connection `begin` ran on. Nested
/// calls become savepoints on that same connection.
class _MysqlTransaction extends _MysqlSession {
  _MysqlTransaction(this._connection, _MysqlSession root, [this._depth = 1])
    : super(root);

  final my.MySQLConnection _connection;
  final int _depth;

  @override
  Future<my.IResultSet> send(String sql, Map<String, dynamic> params) =>
      _connection.execute(sql, params);

  @override
  int get transactionDepth => _depth;

  @override
  Future<R> transaction<R>(Future<R> Function(Connection tx) body) async {
    final savepoint = 'sp$_depth';
    await execute('savepoint $savepoint');
    try {
      final result = await body(
        _MysqlTransaction(_connection, root!, _depth + 1),
      );
      await execute('release savepoint $savepoint');
      return result;
    } catch (_) {
      await execute('rollback to savepoint $savepoint');
      rethrow;
    }
  }

  @override
  Future<void> close() async {}
}

/// Shared statement execution for the pool and for pinned transactions.
/// Listeners and the query log live on the root; transactions forward.
abstract class _MysqlSession extends ConnectionBase {
  _MysqlSession(this.root);

  final _MysqlSession? root;

  @override
  Grammar get grammar => const MysqlGrammar();

  /// Where a statement actually goes: the pool, or one pinned connection.
  Future<my.IResultSet> send(String sql, Map<String, dynamic> params);

  Future<R> _run<R>(
    String sql,
    List<Object?> bindings,
    FutureOr<R> Function() fn,
  ) => (root ?? this).logged(sql, bindings, fn);

  Future<my.IResultSet> _execute(String sql, List<Object?> bindings) {
    final (named, params) = toNamedParameters(sql, bindings);
    return send(named, params);
  }

  @override
  Future<List<Row>> select(String sql, [List<Object?> bindings = const []]) =>
      _run(sql, bindings, () async {
        final result = await _execute(sql, bindings);
        return [for (final row in result.rows) row.typedAssoc()];
      });

  @override
  Future<int> execute(String sql, [List<Object?> bindings = const []]) => _run(
    sql,
    bindings,
    () async => (await _execute(sql, bindings)).affectedRows.toInt(),
  );

  /// The generated key, read from `LAST_INSERT_ID()` on the OK packet.
  ///
  /// Returns `null` when the table's primary key is not `auto_increment` (a
  /// `uuid`/`char(36)` key, say), because MySQL reports `LAST_INSERT_ID()` as
  /// 0 there. The Postgres adapter returns the real key in that case, through
  /// `RETURNING`, which MySQL has no equivalent of — supply such a key
  /// yourself rather than expecting it back.
  @override
  Future<Object?> insertGetId(
    String sql,
    List<Object?> bindings, {
    String? primaryKey,
  }) => _run(sql, bindings, () async {
    final id = (await _execute(sql, bindings)).lastInsertID;
    return id == BigInt.zero ? null : id.toInt();
  });

  @override
  void listen(void Function(QueryEvent event) listener) =>
      root == null ? super.listen(listener) : root!.listen(listener);

  @override
  void enableQueryLog() =>
      root == null ? super.enableQueryLog() : root!.enableQueryLog();

  @override
  List<QueryEvent> get queryLog =>
      root == null ? super.queryLog : root!.queryLog;

  @override
  QueryException wrapError(Object error, String sql, List<Object?> bindings) {
    if (error is my.MySQLServerException &&
        _duplicateEntry.contains(error.errorCode)) {
      return UniqueConstraintException(
        error.message,
        sql: sql,
        bindings: bindings,
        cause: error,
      );
    }
    return super.wrapError(error, sql, bindings);
  }
}
