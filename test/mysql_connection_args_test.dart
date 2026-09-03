import 'package:maat_seshat_mysql/maat_seshat_mysql.dart';
import 'package:test/test.dart';

/// `maat_ptah`'s skeleton ships `'pool': {'max': ...}` — a nested
/// map, not an int — for both mysql and pgsql. `mysqlConnectionArgs` is the
/// pure argument mapping `registerMysqlDriver` calls before ever opening a
/// socket, so this proves the shipped shape is read correctly with no
/// server involved.
void main() {
  test('reads pool.max out of the nested map the skeleton ships', () {
    final args = mysqlConnectionArgs({
      'driver': 'mysql',
      'host': '127.0.0.1',
      'port': 3306,
      'database': 'maat',
      'username': 'root',
      'password': '',
      'pool': {'max': 10},
    });

    expect(args.maxConnections, 10);
    expect(args.host, '127.0.0.1');
    expect(args.database, 'maat');
  });

  test('defaults maxConnections to 5 when pool is absent', () {
    final args = mysqlConnectionArgs({'database': 'maat'});
    expect(args.maxConnections, 5);
  });

  test('secure defaults to true, disable with secure: false', () {
    expect(mysqlConnectionArgs({'database': 'd'}).secure, isTrue);
    expect(
      mysqlConnectionArgs({'database': 'd', 'secure': false}).secure,
      isFalse,
    );
  });
}
