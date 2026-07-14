import OpenFinderCore

actor VideoAnalysisResultBox {
    private var storedResult: VideoAnalysisResult?

    func store(_ result: VideoAnalysisResult) {
        storedResult = result
    }

    var value: VideoAnalysisResult? { storedResult }
}
