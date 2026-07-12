# OpenFinder Design System

## 1. Atmosphere & Identity

OpenFinder is a native macOS file workspace: information-dense, quiet, and immediately familiar to Finder users. Its signature is system-native chrome with precise table behavior; metadata supports the files instead of competing with them. The scoped tag editor follows Finder's compact assignment flow while making Kodbox personal and team ownership explicit.

## 2. Color

All UI colors use dynamic Apple semantic colors so Light, Dark, Increased Contrast, and accent-color preferences remain authoritative.

| Role | AppKit / SwiftUI token | Usage |
|---|---|---|
| Primary text | `NSColor.labelColor` / `.primary` | File and tag names |
| Secondary text | `NSColor.secondaryLabelColor` / `.secondary` | Scope, hints, overflow |
| Disabled text | `NSColor.disabledControlTextColor` | Unavailable actions |
| Selection | System selected-content colors | Table selection and focus |
| Neutral tag | `NSColor.tertiaryLabelColor` | Local/custom and unknown-style tags |
| Known local label | `NSWorkspace.fileLabelColors` | Public Finder label-name matches only |
| Remote tag colors | Canonical `FileTagColor` mapped to dynamic system colors | Kodbox styles |
| Error | `NSColor.systemRed` / `.red` | Mutation and permission errors |

No production UI reads private Finder color metadata or introduces fixed light-only RGB/hex values.

## 3. Typography

- Primary: the system San Francisco family through `NSFont` and SwiftUI semantic styles.
- Table/body: standard control font at the table's native row density.
- Metadata/scope: `.caption` or `NSFont.smallSystemFontSize`.
- Monospaced text is reserved for paths and technical identifiers, never tag names.
- Truncation never alters tooltip or accessibility content.

## 4. Spacing & Layout

The base unit is 4 points. Existing pane chrome uses 4, 6, 8, 12, 16, 20, and 24 point steps.

- File table: native medium row size; cell horizontal insets 6-8 points.
- Tag cell: compact inline rhythm, 4-point dot-to-label and 8-point tag-to-tag spacing.
- Tags column: resizable, placed after Name, with a useful minimum width and no fixed maximum.
- Tag editor: compact sheet, one searchable assignment list grouped by scope; management is secondary.
- Layout follows window resizing rather than web breakpoints. Narrow widths reduce visible tags and expose `+N` without changing source order.

## 5. Components

### File Table Cell

- Structure: native `NSTableCellView`, optional icon, one metadata presentation.
- States: default, selected, focused, reused, empty, truncated.
- Accessibility: full value and role survive truncation; selection remains owned by `NSTableView`.

### Tag Cell

- Structure: reusable AppKit cell containing compact color markers/names and optional `+N`.
- Variants: empty, one tag, multiple tags, overflow, neutral/known color.
- States: default, selected-row contrast, resized, reused, Light/Dark, Increased Contrast.
- Accessibility: one complete localized label including every full tag name; tooltip contains untruncated names.
- Reuse rule: arranged subviews, tooltip, and accessibility value are cleared before every configure.

### Scoped Tag Editor

- Structure: search, scope sections, tri-state rows, Create in..., Apply/Cancel, optional Manage page.
- States: loading, checked, mixed, empty, read-only/retry, applying, partial failure, catalog mutation, empty search.
- Accessibility: scope, name, known color, tri-state, permissions, and progress are announced; keyboard Apply/Cancel return focus to the table.

### Context Menu Tag Action

- Label: `标签…`.
- Availability: nonempty selection with a common editable tag scope; empty-area and unsupported selections do not expose an actionable item.
- Context-clicking an unselected row first normalizes selection to that row.

## 6. Motion & Interaction

- Use native AppKit/SwiftUI transitions and progress indicators only.
- No decorative animation. State changes communicate loading, selection, sheet presentation, or completion.
- Respect Reduce Motion and Reduce Transparency automatically through system materials and controls.
- Return applies associations; Escape cancels; standard Command/Shift table selection remains unchanged.

## 7. Depth & Surface

Strategy: system tonal shift and native materials.

- Pane toolbar/status surfaces use existing `.bar` and `.regularMaterial` treatments.
- The file table keeps native alternating rows and selected-row rendering.
- Sheets, menus, focus rings, separators, and shadows are system-owned.
- Tag chips/markers do not add custom card shadows, glass, or decorative gradients.

## 8. Accessibility Constraints & Accepted Debt

### Constraints

- Target: native macOS accessibility plus WCAG 2.2 AA-equivalent contrast for custom content.
- Every tag cell and editor control has a useful VoiceOver label/value.
- Full keyboard operation covers table selection, menu invocation, tri-state editing, Apply, Cancel, and Retry.
- Unknown tag colors remain neutral; meaning is never encoded by color alone.
- Long CJK, emoji, combining marks, and RTL names remain intact in tooltips and accessibility values.
- Unsupported WebDAV/read-only states are disabled at both presentation and model boundaries.

### Accepted Debt

None for the scoped-tag feature. Any live Kodbox scenario that cannot run without a disposable account is reported as unexecuted evidence, not accepted UI debt.
