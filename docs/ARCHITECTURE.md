# Architecture and desktop protocol

Flutter owns Material 3 widgets, localization, keyboard focus, profile interactions, file dialogs and tray/window lifetime. Low-privilege Go owns user data, pinned link conversion, validation, updates and core lifetime. Aster Core is a separate binary. Existing controller REST/WebSocket endpoints supply proxies/groups, delay tests, rules, connections and traffic. No public core API was added.

## Protocol

Bridge stdin/stdout uses NDJSON `{id,method,params}` → `{id,result}` or `{id,error:{code,message}}`. Events are `{event,data}`. Diagnostics go to stderr. Go `Settings`, `Profile`, `State`, `CoreStatus` and `RPCError` describe stored/state shapes. Requests/configuration and responses are bounded. Storage/core transitions serialize, with request IDs allowing concurrent UI requests.

| Methods | Purpose |
|---|---|
| state, settings | Core/service status, settings, profiles, selections |
| import, refresh, activate, deleteProfile | Subscription/profile lifecycle |
| validate, edit, restore, patchProfile | YAML validation, editing, backup |
| listApplications | Read executable names/paths from running processes, without arguments or environment |
| connect, disconnect | Local or privileged core lifecycle |
| controller, logs | Restricted controller operations and bounded logs |
| installService, uninstallService | OS-authorized helper lifecycle |
| checkUpdates, updateCore | Official releases and verified replacement |
| rememberSelection | Persist offline choices and native macOS XPC selections |

## Privilege boundaries

| Platform | Transport/caller checks | Service/code location |
|---|---|---|
| Windows | Named pipe owner SID DACL + peer process token SID | SCM LocalSystem; Program Files code, ACL-protected ProgramData state |
| macOS | SMAppService XPC, root-owned trusted app, code requirement + peer executable path | Root-owned `/Applications/Aster Desktop.app`; private Library state |
| Linux | Unix socket mode 0600 + SO_PEERCRED owner UID | systemd, `/usr/lib/aster-desktop`, private `/var/lib/aster-desktop` |

The privileged protocol accepts only status/start/stop/apply/controller/logs/metrics/updateCore. macOS additionally accepts proxyStart with a bounded port and proxyStop, so its authorized helper can change network-service proxies while the normal core stays unprivileged. It cannot launch arbitrary code, accept a Controller URL/secret or execute shell commands. The helper chooses protected binary/state paths. Runtime YAML overrides management endpoints, secrets, UI, custom listeners/tunnels/authentication and network switches. HTTP provider cache paths are managed. Local providers are inlined by the low-privilege importer. Local MRS rule providers must be replaced with inline/text/YAML or HTTP providers. TUN rejects local certificates/files; inline material is allowed.

One connection owns a service session. Disconnect stops its core. Windows/Linux use a sixty-second lease renewed by polling. macOS XPC invalidation closes the supervisor's stdin for graceful cleanup. Root credentials stay in Go; Flutter routes only permitted operations through the bridge. Root updates use fixed official sources, never caller-supplied URLs or executables.

Shutdown uses a private Windows console group + CTRL_BREAK, or Unix SIGTERM, with ten seconds before forced kill. Windows also uses a kill-on-close job. Systemd supervises the Linux helper with rate-limited restarts; core failures do not trigger a restart loop. Normal broker signal/EOF stops its core. Abrupt SIGKILL of a normal Linux/macOS broker still needs host-level orphan cleanup validation.

## Recovery and updates

Imported content stays separate from runtime YAML. Content changes validate before replacing stored data and retain `backup-ID.yaml`; a failed live apply reloads the previous runtime. Subscription failure retains content. Sharing-link duplicates get numeric suffixes. The compiled converter stays pinned even when core binaries update.

Proxy adapters snapshot original and installed values before modification, restoring only when the current values remain owned by Aster. Interrupted snapshots are recovered at the next launch. Windows uses WinInet options; Mac uses networksetup; GNOME uses GSettings; KDE uses kioslaverc and a reparse signal. TUN does not modify the desktop user proxy.

Core update: official release → trusted asset URL → SHA-256 → bounded in-memory decompression → architecture check → temporary API probe → active-profile validation → stop old/start new → persist selected executable. Old binaries are retained; failure restores the old selection. User/core service updates have independent rollback, so partial failure can leave them on different valid versions and is reported. Fully atomic upgrades spanning both managers are not implemented.

macOS scheduled subscriptions run in Flutter so changes pass through XPC. Windows/Linux schedule in Go. Normal traffic uses WebSocket; TUN speed is derived from controller totals every two seconds. Lists render lazily and delay tests run at most four at a time.

Offline choices are saved before the first connection and replayed after core startup. Global mode selects the profile's chosen group in GLOBAL, so changing mode retains the user's node. Startup requires both the Controller and mixed proxy listener to be ready; TCP and UDP port conflicts fail before spawning the core.

## Release verification

No remote repository/release is created automatically. Native CI must actually run before Mac packages can be claimed as built. Ad-hoc signed DMGs contain a root-owned installation PKG. Real network, authorization, TUN, tray, desktop proxy and suspend/resume require per-platform results in `TESTING.md`.

Application routing keeps GUI override rules and explicitly removed subscription rules in Profile metadata. Refresh merges overrides before validating/applying, replacing process rules for the same kind and match. Provider node choices use a separate, exact-filtered hidden select group for each application; an empty group rejects traffic. patchProfile accepts a typed providerRoute {kind,match,provider,node} plus removeRule for atomic replacement. These are desktop operations using existing core configuration and controller endpoints. Full-profile JSON backups preserve routing metadata alongside legacy YAML backups.
