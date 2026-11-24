// Package assets contains the shared artwork, font and Chinese dictionaries.
package assets

import "embed"

//go:embed NotoSansTC.ttf
var Font []byte

//go:embed aster.png
var Icon []byte

//go:embed aster.svg
var Mark []byte

//go:embed opencc/*.txt
var Dictionaries embed.FS
