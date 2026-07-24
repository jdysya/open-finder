# OpenFinder architecture

OpenFinder separates durable work, provider capabilities, artifact persistence, and presentation.
`AppModel` is a `@MainActor` façade over application services; it publishes UI state and forwards
intent but does not decode result documents or own persistence engines.

## Plugin result flow

1. A plugin manifest declares an action's result schema.
2. The durable plugin task resolves the exact plugin version and credentials, runs it, and validates
   its output workspace.
3. `PluginResultHandlerRegistry` selects a handler by schema identifier. `mediaAnalysis.v1` is
   decoded into `MediaAnalysisDocument`; unknown schemas become a generic artifact projection.
4. `ArtifactResultService` commits artifacts and documents before task workspace cleanup.
5. `PluginRendererCatalog` maps the projection's schema and typed value to a renderer.
6. `AppModel` publishes only `presentedPluginResult`; SwiftUI requests the catalog descriptor and
   displays the shared media renderer or generic artifact UI.

Plugin IDs do not participate in result-handler or renderer selection. This keeps process and HTTP
plugins, including analyzers for different media types, on the same typed path.

## Compatibility boundary

Published `Location` and generic configuration decoders remain supported. GRDB migrations are
roll-forward only, and startup diagnostics preserve an unreadable or future database for recovery.
The removed Video-specific result store and decoder were never published contracts; OpenFinder does
not import or migrate those files.

See [task recovery](task-recovery.md) and the [Renderer Catalog](renderer-catalog.md) for the two
runtime boundaries.
