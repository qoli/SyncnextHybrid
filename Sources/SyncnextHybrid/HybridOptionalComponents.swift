import AetherEngine

/// Compiled capabilities; actual use still depends on the source and device.
public typealias HybridOptionalComponent = AetherEngine.OptionalComponent

/// APAC rendering is opt-in, requires OS 26+, and uses lossy spatial encoding.
public typealias HybridObjectAudioRendering = ObjectAudioRendering

/// The speaker layout must match the receiver's physical configuration.
public typealias HybridSpatialSpeakerLayout = SpatialSpeakerLayout
