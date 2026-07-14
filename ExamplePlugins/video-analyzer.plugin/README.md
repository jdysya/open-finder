# Video Analyzer Plugin

This built-in developer-mode plugin analyzes selected local video files through the existing
`video-analyzer` Python checkout.

Configure it in OpenFinder Settings → Plugins:

- **Video Analyzer checkout:** absolute path to the `video-analyzer` repository.
- **Analyzer Python executable:** Python from the environment containing ffmpeg, NudeNet,
  PySceneDetect, Torch, JoyTag, and the source project's other dependencies.
- **Enable JoyTag:** disable this for a faster NudeNet-only pass.

The lightweight protocol worker is bundled with the plugin and bootstrapped with `uv`. Analysis
reports and keyframes are written to the task temporary directory, not beside the selected videos.
The initial model download may require network access; inference remains local after dependencies
and model files are available.

This phase emits a structured `videoAnalysisResult` artifact through the existing plugin task
protocol. Native result browsing and Finder-tag application are intentionally deferred until the
scoped file-tag feature reaches its integration checkpoint.
