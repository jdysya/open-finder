import OpenFinderCore

actor PluginResultProjectionBox {
    private var storedProjection: PluginResultProjection?

    func store(_ projection: PluginResultProjection) {
        storedProjection = projection
    }

    var value: PluginResultProjection? { storedProjection }
}
