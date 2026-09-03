import 'package:seshat_mysql/seshat_mysql.dart';

void main() {
  final connection = mysqlConnectionArgs({
    'host': '127.0.0.1',
    'port': 3306,
    'database': 'app',
    'username': 'app',
    'password': 'secret',
    'pool': {'max': 10},
    'secure': true,
  });

  print(
    '${connection.username}@${connection.host}:${connection.port}/'
    '${connection.database}',
  );
}
