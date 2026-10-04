import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 20),
  responseDataCallback: (data) async {
    if (data?['desktopWorkflowCompleted'] != true) {
      throw StateError('The native desktop workflow did not finish.');
    }
    await writeResponseData(
      data,
      destinationDirectory: '.build',
      testOutputFilename: 'native-mac-results',
    );
  },
);
