import 'package:aster_desktop/controller.dart';
import 'package:aster_desktop/localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => SimplifiedChinese.initialize());

  test('system locale resolves Traditional, Simplified, and English', () {
    expect(
      AppLanguage.resolve(AppLanguage.system, const [Locale('zh', 'TW')]),
      AppLanguage.traditionalChinese,
    );
    expect(
      AppLanguage.resolve(AppLanguage.system, const [Locale('zh', 'HK')]),
      AppLanguage.traditionalChinese,
    );
    expect(
      AppLanguage.resolve(AppLanguage.system, const [
        Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      ]),
      AppLanguage.traditionalChinese,
    );
    expect(
      AppLanguage.resolve(AppLanguage.system, const [Locale('zh', 'CN')]),
      AppLanguage.simplifiedChinese,
    );
    expect(
      AppLanguage.resolve(AppLanguage.system, const [
        Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
      ]),
      AppLanguage.simplifiedChinese,
    );
    expect(
      AppLanguage.resolve(AppLanguage.system, const [Locale('zh')]),
      AppLanguage.simplifiedChinese,
    );
    expect(
      AppLanguage.resolve(AppLanguage.system, const [Locale('en', 'US')]),
      AppLanguage.english,
    );
  });

  test('new settings follow the system language', () {
    expect(const AppSettings().language, AppLanguage.system);
  });

  test('Traditional UI strings convert to Simplified Chinese', () async {
    await SimplifiedChinese.initialize();
    expect(SimplifiedChinese.convert('這份應用程式設定與連線資訊'), '这份应用程序设置与连接信息');
  });
}
