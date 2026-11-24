package desktopui

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/egoist/mygo/ui"
	"github.com/egoist/mygo/ui/editor"
	"gopkg.in/yaml.v3"
)

type dialogKind uint8

const (
	importDialog dialogKind = iota
	jumpDialog
	metadataDialog
	yamlDialog
	previewDialog
	confirmDialog
	objectDialog
	ruleDialog
	routeDialog
	connectionDialog
	logDialog
	updateDialog
	portDialog
	dnsDialog
	testDialog
)

type dialog struct {
	open                              bool
	kind                              dialogKind
	id, title, err, notice            string
	name, source, file, input, choice string
	mode                              int
	data                              Object
	code                              *editor.State
	action                            func()
}

func (a *App) showImport() { a.dialog = dialog{open: true, kind: importDialog} }
func (a *App) showJump()   { a.dialog = dialog{open: true, kind: jumpDialog} }
func (a *App) dismiss()    { a.dialog.open = false }
func (a *App) confirm(title, detail string, action func()) {
	a.dialog = dialog{open: true, kind: confirmDialog, title: title, source: detail, action: action}
}

func (a *App) showDialog(c *ui.Context) {
	if !a.dialog.open {
		return
	}
	d := &a.dialog
	width, height := float32(560), float32(520)
	windowW, windowH := c.Size()
	if d.kind == yamlDialog || d.kind == objectDialog {
		width, height = 880, 660
	}
	if d.kind == connectionDialog {
		width = 680
	}
	width, height = min(width, windowW-48), min(height, windowH-64)
	modal := ui.DialogBase(c.Key(d.kind), &d.open, func(backdrop, panel ui.Element) {
		backdrop.Background(ui.RGBA(0, 0, 0, .48))
		panel.Width(width).MaxHeight(height).Padding(24).Gap(18).Radius(28).Background(a.palette.panel)
		switch d.kind {
		case importDialog:
			a.importForm(c)
		case jumpDialog:
			a.jumpForm(c)
		case metadataDialog:
			a.metadataForm(c)
		case yamlDialog:
			a.yamlForm(c, height)
		case previewDialog:
			a.previewForm(c)
		case confirmDialog:
			a.dialogTitle(c, d.title)
			a.hint(c, d.source)
			a.dialogButtons(c, a.tr("確認", "Confirm"), d.action)
		case objectDialog:
			a.objectForm(c, height)
		case ruleDialog:
			a.ruleForm(c)
		case routeDialog:
			a.routeForm(c)
		case connectionDialog:
			a.connectionDetail(c)
		case logDialog:
			a.logDetail(c)
		case updateDialog:
			a.updateForm(c)
		case portDialog:
			a.portForm(c)
		case dnsDialog:
			a.dnsForm(c)
		case testDialog:
			a.latencyForm(c)
		}
	})
	if modal.Dismissed() && a.busy {
		d.open = true
	}
}

func (a *App) dialogTitle(c *ui.Context, title string) {
	ui.Text(c, title).FontSize(22).Bold().Role(ui.RoleHeading).Level(2)
}

func (a *App) dialogFeedback(c *ui.Context) {
	if a.dialog.err != "" {
		ui.Text(c, a.dialog.err).MaxLines(4).TextColor(c.Theme().Danger).Role(ui.RoleAlert)
	} else if a.dialog.notice != "" {
		ui.Text(c, a.dialog.notice).MaxLines(4).TextColor(a.palette.primary).Role(ui.RoleStatus)
	} else if a.busy {
		ui.Spinner(c).Size(16, 16).AlignSelf(ui.End).Label(a.tr("處理中", "Working"))
	}
}

func (a *App) dialogButtons(c *ui.Context, label string, action func()) {
	a.dialogFeedback(c)
	ui.Row(c).Gap(8).Justify(ui.End).Wrap().Children(func() {
		a.button(c, a.tr("取消", "Cancel"), false).Disabled(a.busy).OnClick(a.dismiss)
		if action != nil {
			a.button(c, label, true).Disabled(a.busy).OnClick(action)
		}
	})
}

func (a *App) field(c *ui.Context, label string, value *string) ui.Element {
	return ui.TextInput(c, value).Label(label).Placeholder(label).Padding(12, 16).Radius(ControlRadius).
		Border(0, ui.Transparent).Background(a.palette.input).Disabled(a.busy)
}

func (a *App) importForm(c *ui.Context) {
	d := &a.dialog
	a.dialogTitle(c, a.tr("匯入訂閱或設定", "Import a subscription or configuration"))
	a.hint(c, a.tr("選一種方式即可。匯入後會先檢查設定，再開始使用。", "Choose one method. Your configuration is checked before use."))
	ui.Row(c).Gap(8).Wrap().Children(func() {
		for i, label := range []string{a.tr("訂閱網址", "Subscription URL"), a.tr("貼上內容", "Paste content"), a.tr("設定檔", "Local file")} {
			btn := a.button(c, label, false).Disabled(a.busy).AccessSelected(d.mode == i)
			if i == d.mode {
				btn.Background(a.palette.selected)
			}
			btn.OnClick(func() { d.mode = i; d.source, d.err = "", "" })
		}
	})
	a.field(c, a.tr("名稱（選填）", "Name (optional)"), &d.name)
	switch d.mode {
	case 0:
		a.field(c, a.tr("訂閱網址", "Subscription URL"), &d.source).Placeholder("https://…").AutoFocus().OnSubmit(a.submitImport)
	case 1:
		ui.TextArea(c.Key("import-paste"), &d.source).Height(132).Padding(12, 16).
			Label(a.tr("YAML 或節點分享連結", "YAML or node links")).
			Placeholder(a.tr("YAML 或節點分享連結", "YAML or node links")).Disabled(a.busy).AutoFocus()
	case 2:
		ui.Row(c).Gap(10).Wrap().Children(func() {
			a.button(c, a.tr("選擇設定檔", "Choose file"), false).Disabled(a.busy || a.platform.PickFile == nil).OnClick(func() {
				title := a.tr("選擇設定檔", "Choose configuration")
				a.run("file", func(context.Context) (func(), error) {
					path, err := a.platform.PickFile(title, []string{"yaml", "yml", "txt"})
					return func() {
						if path != "" {
							d.file = path
						}
					}, err
				})
			})
			if d.file != "" {
				ui.Text(c, filepath.Base(d.file)).SingleLine().MaxWidth(260).Tooltip(d.file)
			}
		})
	}
	a.dialogButtons(c, a.tr("匯入並檢查", "Import and validate"), a.submitImport)
}

func (a *App) submitImport() {
	d := &a.dialog
	values := Object{"name": strings.TrimSpace(d.name)}
	if d.mode == 2 {
		values["file"] = d.file
	} else {
		values[[]string{"url", "content"}[d.mode]] = strings.TrimSpace(d.source)
	}
	if (d.mode == 2 && d.file == "") || (d.mode != 2 && strings.TrimSpace(d.source) == "") {
		d.err = a.tr("請填入訂閱網址或選擇設定內容。", "Enter a subscription URL or choose a configuration.")
		return
	}
	d.err = ""
	a.mutate("import", values, func() { a.dismiss(); a.jump(overview) })
}

func (a *App) jumpForm(c *ui.Context) {
	a.dialogTitle(c, a.tr("前往頁面", "Jump to a page"))
	query := a.search(c, &a.dialog.input, a.tr("搜尋頁面", "Search pages")).Grow(0).AutoFocus()
	var options []pageID
	for i := range destinations {
		if matches(a.dialog.input, a.pageName(pageID(i)), destinations[i].en) {
			options = append(options, pageID(i))
		}
	}
	query.OnSubmit(func() {
		if len(options) > 0 {
			a.dismiss()
			a.jump(options[0])
		}
	})
	ui.Scroll(c).MaxHeight(325).Shrink(1).Children(func() {
		for _, page := range options {
			label := a.pageName(page)
			button := ui.ButtonBase(c.Key(page)).Height(36).Padding(0, 12).Radius(10).Gap(10).Justify(ui.Start).Label(label)
			if button.Hovered() {
				button.Background(a.palette.selected)
			}
			button.Children(func() { icon(c, destinations[page].icon, 17); ui.Text(c, label) }).
				OnClick(func() { a.dismiss(); a.jump(page) })
		}
		if len(options) == 0 {
			a.hint(c, a.tr("沒有符合的頁面", "No matching pages"))
		}
	})
}

func (a *App) profiles(c *ui.Context) {
	a.scrolled(c, func() {
		ui.Row(c).Gap(12).Wrap().Children(func() {
			a.hint(c, a.tr("管理訂閱、設定檔與更新排程。", "Manage subscriptions, configurations and refresh schedules."))
			ui.Spacer(c)
			a.button(c, a.tr("匯入訂閱或設定", "Import a subscription"), true).Disabled(a.busy).OnClick(a.showImport)
		})
		if len(a.snapshot.State.Profiles) == 0 {
			a.panel(c, func() {
				a.title(c, a.tr("還沒有設定", "No configurations yet"))
				a.hint(c, a.tr("匯入一份訂閱或設定檔即可開始。", "Import a subscription or a configuration to get started."))
			})
			return
		}
		for _, profile := range a.snapshot.State.Profiles {
			ui.Column(c.Key(profile.ID)).Children(func() { a.profileCard(c, profile) })
		}
	})
}

func (a *App) profileCard(c *ui.Context, p Profile) {
	active := a.snapshot.State.ActiveID == p.ID
	a.panel(c, func() {
		ui.Row(c).Gap(10).Children(func() {
			icon(c, "profiles", 22)
			ui.Text(c, p.Name).FontSize(18).Bold().Grow(1).MinWidth(0).SingleLine()
			if active {
				a.badge(c, a.tr("使用中", "Active"))
			}
		})
		if !p.Updated.IsZero() {
			a.hint(c, a.tr("更新時間 ", "Updated ")+p.Updated.Local().Format("2006-01-02 15:04"))
		}
		if p.LastError != "" {
			ui.Text(c, p.LastError).TextColor(c.Theme().Danger).MaxLines(3)
		}
		for _, warning := range p.Warnings {
			a.hint(c, warning)
		}
		ui.Row(c).Gap(8).Wrap().Children(func() {
			if !active {
				a.button(c, a.tr("使用此設定", "Activate"), true).Disabled(a.busy).OnClick(func() { a.mutate("activate", Object{"id": p.ID}, nil) })
			}
			if p.URL != "" {
				a.button(c, a.tr("預覽更新", "Preview update"), false).Disabled(a.busy).OnClick(func() { a.previewRefresh(p.ID) })
			}
			a.button(c, a.tr("訂閱設定", "Subscription settings"), false).Disabled(a.busy).OnClick(func() { a.editMetadata(p) })
			a.button(c, a.tr("編輯 YAML", "Edit YAML"), false).Disabled(a.busy).OnClick(func() { a.openYAML(p) })
			a.button(c, a.tr("複製設定", "Duplicate"), false).Disabled(a.busy).OnClick(func() { a.mutate("duplicateProfile", Object{"id": p.ID}, nil) })
			a.button(c, a.tr("匯出 YAML", "Export YAML"), false).Disabled(a.busy || a.platform.SaveFile == nil).OnClick(func() {
				a.saveFile(a.tr("匯出 YAML", "Export YAML"), "aster-profile.yaml", []byte(p.Content))
			})
			a.button(c, a.tr("刪除", "Delete"), false).Disabled(a.busy || (active && a.running())).OnClick(func() {
				a.confirm(a.tr("刪除這份設定？", "Delete this configuration?"), p.Name, func() { a.mutate("deleteProfile", Object{"id": p.ID}, a.dismiss) })
			})
		})
	})
}

func (a *App) saveFile(title, filename string, data []byte) {
	if a.platform.SaveFile == nil {
		return
	}
	a.run("file", func(context.Context) (func(), error) { return nil, a.platform.SaveFile(title, filename, data) })
}

func (a *App) editMetadata(p Profile) {
	interval := ""
	if p.IntervalHours != nil {
		interval = strconv.Itoa(*p.IntervalHours)
	}
	a.dialog = dialog{open: true, kind: metadataDialog, id: p.ID, name: p.Name, source: p.URL, input: interval}
}
func (a *App) metadataForm(c *ui.Context) {
	d := &a.dialog
	a.dialogTitle(c, a.tr("訂閱設定", "Subscription settings"))
	a.field(c, a.tr("名稱", "Name"), &d.name).AutoFocus()
	a.field(c, a.tr("訂閱網址", "Subscription URL"), &d.source)
	a.field(c, a.tr("更新間隔（小時）", "Refresh interval (hours)"), &d.input)
	a.hint(c, a.tr("留空使用全域設定，輸入 0 停用自動更新。", "Leave blank to use the default, or enter 0 to disable refresh."))
	a.dialogButtons(c, a.tr("儲存", "Save"), func() {
		var hours *int
		if strings.TrimSpace(d.input) != "" {
			n, err := strconv.Atoi(strings.TrimSpace(d.input))
			if err != nil || n < 0 || n > 8760 {
				d.err = a.tr("請輸入 0 至 8760 小時。", "Enter an interval from 0 to 8760 hours.")
				return
			}
			hours = &n
		}
		a.mutate("profileMetadata", Object{"id": d.id, "name": strings.TrimSpace(d.name), "url": strings.TrimSpace(d.source), "intervalHours": hours}, a.dismiss)
	})
}
func (a *App) previewRefresh(id string) {
	a.run("previewRefresh", func(ctx context.Context) (func(), error) {
		var data Object
		err := a.client.Call(ctx, "previewRefresh", Object{"id": id}, &data)
		return func() {
			if err == nil {
				a.dialog = dialog{open: true, kind: previewDialog, id: id, data: data}
			}
		}, err
	})
}
func (a *App) previewForm(c *ui.Context) {
	d := &a.dialog
	a.dialogTitle(c, a.tr("訂閱更新預覽", "Subscription update preview"))
	ui.Scroll(c).MaxHeight(290).Shrink(1).Children(func() {
		ui.Column(c).Gap(12).Children(func() {
			for _, field := range []struct{ key, label string }{{"added", a.tr("新增", "Added")}, {"removed", a.tr("移除", "Removed")}, {"changed", a.tr("變更", "Changed")}, {"warnings", a.tr("警告", "Warnings")}} {
				values := stringSlice(d.data[field.key])
				a.title(c, fmt.Sprintf("%s (%d)", field.label, len(values)))
				for _, value := range values {
					a.hint(c, value)
				}
			}
		})
	})
	a.dialogButtons(c, a.tr("套用更新", "Apply update"), func() { a.mutate("applyRefresh", Object{"id": d.id, "token": str(d.data["token"])}, a.dismiss) })
}

func yamlEditor(text string) *editor.State {
	buffer := editor.NewBuffer(text)
	buffer.SetLanguage(editor.LanguageFor("profile.yaml"))
	return &editor.State{Buffer: buffer}
}
func (a *App) openYAML(p Profile) {
	a.dialog = dialog{open: true, kind: yamlDialog, id: p.ID, title: p.Name, code: yamlEditor(p.Content)}
}
func (a *App) yamlForm(c *ui.Context, height float32) {
	d := &a.dialog
	if d.code == nil {
		return
	}
	a.dialogTitle(c, a.tr("編輯 YAML", "Edit YAML")+" · "+d.title)
	editor.View(c, d.code).Height(max(160, height-230)).MinHeight(100).Shrink(1).Radius(ControlRadius)
	a.dialogFeedback(c)
	ui.Row(c).Gap(8).Wrap().Justify(ui.End).Children(func() {
		a.button(c, a.tr("還原備份", "Restore backup"), false).Disabled(a.busy).OnClick(func() {
			d.mode = 1
		})
		a.button(c, a.tr("檢查設定", "Validate"), false).Disabled(a.busy).OnClick(func() {
			params := Object{"id": d.id, "content": d.code.Buffer.String()}
			a.mutate("validate", params, func() { d.err = ""; d.notice = a.tr("設定檢查通過。", "Configuration is valid.") })
		})
		a.button(c, a.tr("取消", "Cancel"), false).Disabled(a.busy).OnClick(a.dismiss)
		a.button(c, a.tr("儲存並套用", "Save and apply"), true).Disabled(a.busy).OnClick(func() {
			a.mutate("edit", Object{"id": d.id, "content": d.code.Buffer.String()}, a.dismiss)
		})
	})
	if d.mode == 1 {
		ui.Row(c).Gap(8).Wrap().Children(func() {
			a.hint(c, a.tr("以最近一次備份取代這份設定？", "Replace this configuration with its latest backup?"))
			a.button(c, a.tr("保留目前設定", "Keep current"), false).OnClick(func() { d.mode = 0 })
			a.button(c, a.tr("確認還原", "Restore"), true).Disabled(a.busy).OnClick(func() {
				a.mutate("restore", Object{"id": d.id}, func() {
					if p := a.selectedProfile(d.id); p != nil {
						d.code.Buffer.Reset(p.Content)
					}
					d.mode = 0
				})
			})
		})
	}
}

func (a *App) editObject(field, name string, value Object) {
	content, _ := yaml.Marshal(value)
	if name == "" {
		content = nil
	}
	a.dialog = dialog{open: true, kind: objectDialog, id: a.snapshot.State.ActiveID, name: name, choice: field, code: yamlEditor(string(content))}
	a.dialog.source = name
}
func (a *App) objectForm(c *ui.Context, height float32) {
	d := &a.dialog
	a.dialogTitle(c, a.tr("編輯設定項目", "Edit configuration item"))
	a.field(c, a.tr("名稱", "Name"), &d.name).ReadOnly(d.source != "")
	editor.View(c, d.code).Height(max(160, height-250)).MinHeight(100).Shrink(1).Radius(ControlRadius)
	a.dialogButtons(c, a.tr("儲存", "Save"), func() {
		var value Object
		if err := yaml.Unmarshal([]byte(d.code.Buffer.String()), &value); err != nil || value == nil {
			if err == nil {
				err = errors.New(a.tr("請輸入 YAML 物件。", "Enter a YAML object."))
			}
			d.err = err.Error()
			return
		}
		name := strings.TrimSpace(d.name)
		if name == "" {
			d.err = a.tr("請輸入名稱。", "Enter a name.")
			return
		}
		if !strings.HasSuffix(d.choice, "providers") {
			value["name"] = name
		}
		action := "save"
		if d.source == "" {
			action = "create"
		}
		a.mutate("manageObject", Object{"id": d.id, "field": d.choice, "oldName": name, "action": action, "object": value}, a.dismiss)
	})
}
