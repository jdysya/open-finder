# Renderer Catalog

Status: current reference. The end-to-end lifecycle is explained in [插件机制](plugin-system.md#10-result-handler-与-renderer).

`PluginRendererCatalog` is the single presentation registry for plugin results. Each entry contains
a result schema identifier, a renderer descriptor, and a typed-projection predicate.

The standard catalog has one structured entry:

| Schema | Projection | Renderer |
| --- | --- | --- |
| `mediaAnalysis.v1` | `MediaAnalysisDocument` | shared media analysis workspace |

Everything else uses the generic artifact renderer. A matching schema string without the expected
typed projection also falls back to generic presentation.

To add another media-producing plugin, declare `output.resultType: "mediaAnalysis.v1"` and emit the
corresponding document artifact. Do not add a plugin-ID branch or a dedicated SwiftUI view. A new
catalog entry is appropriate only for a genuinely new published result schema with its own typed
handler and renderer.

The test suite proves two distinct plugin IDs traverse the same result handler, artifact commit,
projection, catalog lookup, renderer interactions, and Finder-tag ledger. The second package is a
test resource and is explicitly excluded from `BuiltinPlugins`.
