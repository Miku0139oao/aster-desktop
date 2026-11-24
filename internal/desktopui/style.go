package desktopui

import (
	"fmt"
	"github.com/Miku0139oao/aster-desktop/assets"
	"github.com/egoist/mygo/ui"
	"sync"
)

// These tokens mirror asterTheme in lib/main.dart and the checked-in Flutter
// screenshots. Keep layout and colors shared across every native page.
const (
	SidebarWidth        float32 = 208
	CompactSidebarWidth float32 = 164
	PagePadding         float32 = 28
	PanelRadius         float32 = 20
	PanelPadding        float32 = 24
	ControlRadius       float32 = 14
)

type palette struct{ background, panel, primary, primaryContainer, onPrimaryContainer, selected, text, muted, outline, input ui.Color }

func colors(dark bool) palette {
	if dark {
		return palette{ui.Hex("#141218"), ui.Hex("#1d1b20"), ui.Hex("#d2bcfd"), ui.Hex("#4f3d73"), ui.Hex("#eaddff"), ui.Hex("#4a4358"), ui.Hex("#e7e0e9"), ui.Hex("#cac4d0"), ui.Hex("#49454f"), ui.Hex("#2b272f")}
	}
	return palette{ui.Hex("#fef7ff"), ui.Hex("#f8f1fa"), ui.Hex("#67548e"), ui.Hex("#eaddff"), ui.Hex("#503a73"), ui.Hex("#e9def8"), ui.Hex("#1d1b20"), ui.Hex("#49454f"), ui.Hex("#cac4d0"), ui.Hex("#eee7f3")}
}
func (a *App) theme(c *ui.Context) {
	dark := c.Theme().Dark
	switch a.settings().Theme {
	case "dark":
		dark = true
	case "light":
		dark = false
	}
	p := colors(dark)
	a.palette = p
	t := ui.LightTheme()
	if dark {
		t = ui.DarkTheme()
	}
	t = t.WithPreferences(c.Preferences()).WithAccent(p.primary)
	t.Background = p.background
	t.Surface = p.input
	t.SurfaceHover = p.selected
	t.SurfacePressed = p.primaryContainer
	t.Text = p.text
	t.TextMuted = p.muted
	t.Border = p.outline
	t.Selection = p.selected
	t.Radius = ControlRadius
	t.Font = "NotoSansTC"
	t.FontSize = 14 * c.Preferences().TextScale
	if t.FontSize <= 0 {
		t.FontSize = 14
	}
	t.InactiveAccent = p.primary
	c.SetTheme(t)
	c.SetMenuPresentation(ui.PopoverMenus)
}

var setupOnce sync.Once
var setupErr error
var mark *ui.SVG

func Setup() error {
	setupOnce.Do(func() { setupErr = ui.RegisterFont(assets.Font, "NotoSansTC"); mark = ui.MustParseSVG(assets.Mark) })
	return setupErr
}

func (a *App) panel(c *ui.Context, body func()) ui.Element {
	return ui.Column(c).FillWidth().Padding(PanelPadding).Radius(PanelRadius).Background(a.palette.panel).Gap(16).Children(body)
}
func (a *App) title(c *ui.Context, s string) {
	ui.Text(c, s).FontSize(16).Bold().Role(ui.RoleHeading).Level(2)
}
func (a *App) hint(c *ui.Context, s string) { ui.Text(c, s).TextColor(a.palette.muted).LineHeight(1.6) }
func (a *App) button(c *ui.Context, label string, primary bool) ui.Element {
	if primary {
		return ui.PrimaryButton(c, label).Padding(16, 24).Radius(16).FontSize(14).FontWeight(600)
	}
	return ui.Button(c, label).Padding(12, 18).Radius(16).Background(ui.Transparent).Border(1, a.palette.outline)
}
func (a *App) iconButton(c *ui.Context, name, label string) ui.Element {
	return ui.Button(c.Key(label), "").Size(42, 42).Radius(21).Background(ui.Transparent).Border(0, ui.Transparent).Label(label).Tooltip(label).Children(func() { icon(c, name, 22) })
}
func (a *App) action(c *ui.Context, name, label string) ui.Element {
	return ui.PrimaryButton(c, "").Label(label).Height(56).Padding(0, 24).Gap(8).Radius(16).Children(func() {
		icon(c, name, 18)
		ui.Text(c, label).SingleLine().FontSize(14).FontWeight(600)
	})
}
func (a *App) badge(c *ui.Context, text string) {
	ui.Text(c, text).FontSize(11).Padding(4, 8).Radius(6).Background(a.palette.selected).TextColor(a.palette.muted).SingleLine()
}
func (a *App) search(c *ui.Context, value *string, label string) ui.Element {
	return ui.SearchField(c, value).Placeholder(label).Label(label).Padding(12, 16).Radius(ControlRadius).Grow(1)
}
func (a *App) empty(c *ui.Context, title, detail string) {
	a.panel(c, func() {
		ui.Text(c, title).FontSize(18).Bold()
		a.hint(c, detail)
		a.button(c, a.tr("匯入訂閱或設定", "Import a subscription"), true).OnClick(a.showImport)
	})
}

var icons = map[string]*ui.SVG{}

func icon(c *ui.Context, name string, size float32) {
	svg := icons[name]
	if svg == nil {
		paths := map[string]string{
			"overview":    `<rect x="3" y="3" width="7" height="18" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>`,
			"nodes":       `<circle cx="12" cy="12" r="3"/><circle cx="12" cy="3" r="2"/><circle cx="4" cy="8" r="2"/><circle cx="20" cy="8" r="2"/><circle cx="5" cy="20" r="2"/><circle cx="19" cy="20" r="2"/><path d="M12 5v4M6 9l3 2m6 0 3-2M7 18l3-4m4 0 3 4"/>`,
			"profiles":    `<path d="M3 7v14h15M6 3h6l2 3h7v12H6z"/>`,
			"apps":        `<path d="M3 3h4v4H3zm7 0h4v4h-4zm7 0h4v4h-4zM3 10h4v4H3zm7 0h4v4h-4zm7 0h4v4h-4zM3 17h4v4H3zm7 0h4v4h-4zm7 0h4v4h-4z"/>`,
			"connections": `<path d="M4 17V7a3 3 0 0 1 6 0v10a3 3 0 0 0 6 0V7m-15 7 3 3 3-3m6-4 3-3 3 3"/>`,
			"stats":       `<path d="M5 20V10m7 10V3m7 17v-6" stroke-width="3"/>`,
			"rules":       `<path d="M12 21V11m0 4L5 8m7 7 7-7M2 8h6V2m8 0v6h6M9 4l3-3 3 3"/>`,
			"diagnostics": `<circle cx="10" cy="10" r="7"/><path d="m15 15 6 6M3 10h4l2-4 3 8 2-4h3"/>`,
			"logs":        `<path d="M6 3h12v18l-3-2-3 2-3-2-3 2zM9 7h6m-6 4h6m-6 4h4"/>`,
			"settings":    `<path d="M3 6h5m4 0h9M3 12h11m4 0h3M3 18h2m4 0h12M8 3v6m6 0v6m-9 0v6"/>`,
			"search":      `<circle cx="10" cy="10" r="6"/><path d="m15 15 6 6"/>`,
			"moon":        `<path d="M21 13a9 9 0 1 1-10-10 7 7 0 0 0 10 10z"/>`,
			"sun":         `<circle cx="12" cy="12" r="4"/><path d="M12 1v2m0 18v2M1 12h2m18 0h2M4 4l2 2m12 12 2 2M4 20l2-2M18 6l2-2"/>`,
			"shield":      `<path d="m12 2 8 3v6c0 5-4 8-8 11-4-3-8-6-8-11V5z"/>`,
			"down":        `<path d="M12 3v18m-6-6 6 6 6-6"/>`,
			"up":          `<path d="M12 21V3M6 9l6-6 6 6"/>`,
			"check":       `<circle cx="12" cy="12" r="9"/><path d="m6 12 4 4 8-9"/>`,
			"link":        `<path d="M10 7H7a5 5 0 0 0 0 10h3m4-10h3a5 5 0 0 1 0 10h-3M7 12h10m3 4v6m-3-3h6"/>`,
			"plus":        `<path d="M12 5v14M5 12h14"/>`,
			"chevron":     `<path d="m9 5 7 7-7 7"/>`,
			"play":        `<path d="m8 4 12 8-12 8z" fill="currentColor" stroke="none"/>`,
			"stop":        `<rect x="5" y="5" width="14" height="14" rx="3"/>`,
			"star":        `<path d="m12 2 3 6 7 1-5 5 1 8-6-4-6 4 1-8-5-5 7-1z"/>`,
			"refresh":     `<path d="M20 7V2m0 5h-5m5 0a9 9 0 1 0 1 8"/>`,
			"close":       `<path d="m5 5 14 14M5 19 19 5"/>`,
		}
		p := paths[name]
		if p == "" {
			p = paths["settings"]
		}
		svg = ui.MustParseSVG([]byte(fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">%s</svg>`, p)))
		icons[name] = svg
	}
	ui.Icon(c, svg).Size(size, size)
}
