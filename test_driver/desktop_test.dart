import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 10),
  responseDataCallback: (data) async {
    if (data?['workflowCompleted'] != true) {
      throw StateError(
        'The native desktop workflow did not reach its final assertion.',
      );
    }
    await writeResponseData(data, destinationDirectory: '.build');
  },
);
