/// MySQL adapter for Maat's database layer
/// (`package:mysql_client`, pure Dart).
library;

// seshat_maat re-exports seshat, so registerSchemaGrammar
// comes in with it.
import 'package:seshat_maat/seshat_maat.dart';

import 'src/mysql_connection.dart';
import 'src/mysql_schema_grammar.dart';

export 'src/mysql_connection.dart';
export 'src/mysql_grammar.dart';
export 'src/mysql_schema_grammar.dart';

/// Maps a `config('database.connections.mysql')` entry to the arguments
/// `MysqlConnection.open` accepts.
///
/// Pulled out as a pure function, separate from the factory that calls it,
/// so the mapping — in particular that `pool.max` is read out of the nested
/// map the skeleton config ships, not off `pool` itself — is testable
/// without opening a socket.
({
  String host,
  int port,
  String database,
  String username,
  String? password,
  int maxConnections,
  bool secure,
})
mysqlConnectionArgs(Map config) => (
  host: (config['host'] ?? '127.0.0.1') as String,
  port: (config['port'] ?? 3306) as int,
  database: config['database'] as String,
  username: (config['username'] ?? 'root') as String,
  password: config['password'] as String?,
  maxConnections: ((config['pool'] as Map?)?['max'] ?? 5) as int,
  // TLS on unless the configuration says otherwise. Turn it off only for a
  // local server that cannot negotiate TLS.
  secure: (config['secure'] ?? true) as bool,
);

/// Teaches [DatabaseServiceProvider] the `mysql` driver, so an application
/// can name it in `config('database')` without this package being a
/// dependency of the framework.
///
/// Registers the schema grammar too, so `Schema`, `SchemaBuilder.on` and the
/// `migrate:*` commands work against MySQL. The two go together on purpose:
/// a caller must not be able to open a connection whose migrations would
/// then fail.
///
/// Call it before creating the application:
///
/// ```dart
/// registerMysqlDriver();
/// final app = await Application.create();
/// ```
void registerMysqlDriver() {
  registerSchemaGrammar('mysql', const MysqlSchemaGrammar());
  DatabaseServiceProvider.extend('mysql', (config) async {
    final args = mysqlConnectionArgs(config);
    return MysqlConnection.open(
      host: args.host,
      port: args.port,
      database: args.database,
      username: args.username,
      password: args.password,
      maxConnections: args.maxConnections,
      secure: args.secure,
    );
  });
}
