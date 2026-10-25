import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppLanguage {
  static const system = 'system';
  static const traditionalChinese = 'zh_TW';
  static const simplifiedChinese = 'zh_CN';
  static const english = 'en';

  static String resolve(String preference, List<Locale> systemLocales) {
    if (preference != system) return preference;
    return fromLocale(
      systemLocales.isEmpty
          ? WidgetsBinding.instance.platformDispatcher.locale
          : systemLocales.first,
    );
  }

  static String fromLocale(Locale locale) {
    if (locale.languageCode.toLowerCase() == 'en') return english;
    if (locale.languageCode.toLowerCase() != 'zh') return english;
    if (locale.scriptCode?.toLowerCase() == 'hant') {
      return traditionalChinese;
    }
    if (locale.scriptCode?.toLowerCase() == 'hans') {
      return simplifiedChinese;
    }
    return {'tw', 'hk', 'mo'}.contains(locale.countryCode?.toLowerCase())
        ? traditionalChinese
        : simplifiedChinese;
  }

  static Locale? materialLocale(String preference) => switch (preference) {
    traditionalChinese => const Locale('zh', 'TW'),
    simplifiedChinese => const Locale('zh', 'CN'),
    english => const Locale('en'),
    _ => null,
  };
}

class SimplifiedChinese {
  static const _charactersAsset = 'assets/opencc/TSCharacters.txt';
  static const _phrasesAsset = 'assets/opencc/TSPhrases.txt';
  static const _variantPhrasesAsset = 'assets/opencc/TWVariantsRevPhrases.txt';
  static const _taiwanPhrasesAsset = 'assets/opencc/TWPhrasesRev.txt';
  static Map<String, String> _characters = const {};
  static Map<String, String> _phrases = const {};
  static final Map<String, String> _cache = {};
  static int _maxPhraseLength = 1;
  static Future<void>? _loading;

  static Future<void> initialize({AssetBundle? bundle}) =>
      _loading ??= _load(bundle ?? rootBundle);

  static Future<void> _load(AssetBundle bundle) async {
    final results = await Future.wait([
      bundle.loadString(_charactersAsset),
      bundle.loadString(_phrasesAsset),
      bundle.loadString(_variantPhrasesAsset),
      bundle.loadString(_taiwanPhrasesAsset),
    ]);
    _characters = _parseDictionary(results[0], singleCharacters: true);
    _phrases = {
      ..._parseDictionary(results[1]),
      ..._parseDictionary(results[2]),
      ..._parseDictionary(results[3]),
    };
    _maxPhraseLength = _phrases.keys.fold(
      1,
      (longest, phrase) => math.max(longest, phrase.length),
    );
    _cache.clear();
  }

  static Map<String, String> _parseDictionary(
    String source, {
    bool singleCharacters = false,
  }) {
    final result = <String, String>{};
    for (final raw in source.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final separator = line.indexOf('\t');
      if (separator <= 0) continue;
      final sourceText = line.substring(0, separator);
      if (singleCharacters && sourceText.length != 1) continue;
      final target = line
          .substring(separator + 1)
          .trim()
          .split(RegExp(r'\s+'))
          .firstOrNull;
      if (target != null && target.isNotEmpty) {
        result[sourceText] = target;
      }
    }
    return result;
  }

  static String convert(String text) {
    if (text.isEmpty || _characters.isEmpty) return text;
    final cached = _cache[text];
    if (cached != null) return cached;
    final output = StringBuffer();
    var index = 0;
    while (index < text.length) {
      String? phrase;
      final remaining = text.length - index;
      for (
        var length = math.min(_maxPhraseLength, remaining);
        length >= 2;
        length--
      ) {
        phrase = _phrases[text.substring(index, index + length)];
        if (phrase != null) {
          output.write(_convertCharacters(phrase));
          index += length;
          break;
        }
      }
      if (phrase != null) continue;
      final character = text[index];
      output.write(_characters[character] ?? character);
      index++;
    }
    final result = output.toString();
    if (_cache.length >= 4096) _cache.clear();
    _cache[text] = result;
    return result;
  }

  static String _convertCharacters(String text) {
    final output = StringBuffer();
    for (var index = 0; index < text.length; index++) {
      final character = text[index];
      output.write(_characters[character] ?? character);
    }
    return output.toString();
  }
}
