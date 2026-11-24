package desktopui

import (
	"bufio"
	"github.com/Miku0139oao/aster-desktop/assets"
	"strings"
	"sync"
)

var dictionaryOnce sync.Once
var dictionary map[string]string
var longestPhrase int

func simplified(s string) string {
	dictionaryOnce.Do(func() {
		dictionary = map[string]string{}
		longestPhrase = 1
		for _, name := range []string{"TSCharacters", "TSPhrases", "TWVariantsRevPhrases", "TWPhrasesRev"} {
			f, err := assets.Dictionaries.Open("opencc/" + name + ".txt")
			if err != nil {
				continue
			}
			sc := bufio.NewScanner(f)
			for sc.Scan() {
				line := strings.TrimSpace(sc.Text())
				if strings.HasPrefix(line, "#") {
					continue
				}
				parts := strings.SplitN(line, "\t", 2)
				if len(parts) != 2 {
					continue
				}
				targets := strings.Fields(parts[1])
				if len(targets) == 0 {
					continue
				}
				dictionary[parts[0]] = targets[0]
				if n := len([]rune(parts[0])); n > longestPhrase {
					longestPhrase = n
				}
			}
			f.Close()
		}
	})
	runes := []rune(s)
	var out strings.Builder
	for i := 0; i < len(runes); {
		found := false
		for n := min(longestPhrase, len(runes)-i); n > 0; n-- {
			if text, ok := dictionary[string(runes[i:i+n])]; ok {
				out.WriteString(text)
				i += n
				found = true
				break
			}
		}
		if !found {
			out.WriteRune(runes[i])
			i++
		}
	}
	return out.String()
}
func resolveLanguage(pref, locale string) string {
	if pref != "system" && pref != "" {
		return pref
	}
	locale = strings.ToLower(strings.ReplaceAll(locale, "_", "-"))
	if !strings.HasPrefix(locale, "zh") {
		return "en"
	}
	if strings.Contains(locale, "-hans") {
		return "zh_CN"
	}
	if strings.Contains(locale, "-hant") || strings.Contains(locale, "-tw") || strings.Contains(locale, "-hk") || strings.Contains(locale, "-mo") {
		return "zh_TW"
	}
	return "zh_CN"
}
func (a *App) tr(zh, en string) string {
	switch resolveLanguage(a.settings().Language, a.systemLocale) {
	case "en":
		return en
	case "zh_CN":
		if cached, ok := a.translations[zh]; ok {
			return cached
		}
		s := simplified(zh)
		a.translations[zh] = s
		return s
	default:
		return zh
	}
}
