// Copyright AudioKit. All Rights Reserved. Revision History at http://github.com/AudioKit/AudioKit/

/// Psuedo abstract base class for players that wish to use AKFader based automation.
open class AKAbstractPlayer: AKNode {
    /// Since AVAudioEngineManualRenderingMode is only available in 10.13, iOS 11+, this enum duplicates it
    public enum RenderingMode {
        case realtime, offline
    }

    // MARK: - Fade struct

    public struct Fade {
        // a few presets for lack of a better place to put them at the moment
        public static var linearTaper = (in: AUValue(1.0), out: AUValue(1.0))

        // half pipe
        public static var audioTaper = (in: AUValue(3.0), out: AUValue(0.3333))

        // flipped half pipe
        public static var reverseAudioTaper = (in: AUValue(0.3333), out: AUValue(3.0))

        /// An init is requited for the Fade struct to be used outside of AKPlayer
        // AKAbstractPlayer.Fade()
        public init() {}

        /// a constant
        public static var minimumGain: AUValue = 0 // 0.0002

        /// the value that the fader should fade to, settable
        public var maximumGain: AUValue = 1

        // In properties
        public var inTime: AVMusicTimeStamp = 0 {
            willSet {
                if newValue != inTime { needsUpdate = true }
            }
        }

        // if you want to start midway into a fade
        // public var inTimeOffset: Double = 0

        public var inTaper: AUValue = audioTaper.in {
            willSet {
                if newValue != inTaper { needsUpdate = true }
            }
        }

        // the slope adjustment in the taper
        public var inSkew: AUValue = 0.3333

        // Out properties
        public var outTime: Double = 0 {
            willSet {
                if newValue != outTime { needsUpdate = true }
            }
        }

        public var outTaper: AUValue = audioTaper.out {
            willSet {
                if newValue != outTaper { needsUpdate = true }
            }
        }

        // the slope adjustment in the taper
        public var outSkew: AUValue = 1

        // the needsUpdate flag is used by the buffering scheme
        var needsUpdate: Bool = false
    }

    // MARK: - Loop struct

    public struct Loop {
        /// So that the Loop struct can be used outside of AKPlayer
        public init() {}

        public var start: Double = 0 {
            willSet {
                if newValue != start { needsUpdate = true }
            }
        }

        public var end: Double = 0 {
            willSet {
                if newValue != end { needsUpdate = true }
            }
        }

        var needsUpdate: Bool = false
    }

    // MARK: - public properties

    /// Will return whether the engine is rendering offline or realtime
    public var renderingMode: RenderingMode {
        if #available(iOS 11, macOS 10.13, tvOS 11, *) {
            // AVAudioEngineManualRenderingMode
            if outputNode.engine?.manualRenderingMode == .offline {
                return .offline
            }
        }
        return .realtime
    }

    /// Holds characteristics about the fade options.
    public var fade = Fade()

    /// Holds characteristics about the loop options.
    public var loop = Loop()

    /// The underlying gain booster and main output which controls fades as well.
    @objc public var faderNode: AKFader?

    /// Amplification Factor, in the range of 0 to 2
    @objc public var gain: AUValue {
        get {
            return fade.maximumGain
        }

        set {
            if newValue != 1 {
                startFader()
            } else if newValue == 1 {
                bypassFader()
            }
            // this is the value that the fader will fade to
            fade.maximumGain = newValue

            // this is the current value of the fader, set immediately
            faderNode?.gain = newValue
        }
    }

    private var _startTime: Double = 0

    /// Get or set the start time of the player.
    @objc open var startTime: Double {
        get {
            return _startTime
        }

        set {
            _startTime = max(0, newValue)
        }
    }

    private var _endTime: Double = 0

    /// Get or set the end time of the player.
    @objc open var endTime: Double {
        get {
            return isLooping ? loop.end : _endTime
        }

        set {
            var newValue = newValue
            if newValue == 0 {
                newValue = duration
            }
            _endTime = min(newValue, duration)
        }
    }

    public var offsetTime: Double = 0

    // MARK: - public flags

    @objc open internal(set) var isPlaying: Bool = false

    @objc open var isLooping: Bool = false

    /// true if the player has any fades, in or outƒ
    @objc open var isFaded: Bool {
        return fade.inTime > 0 || fade.outTime > 0
    }

    // MARK: - abstract items, to be implemented in subclasses

    @objc open var duration: Double {
        return 0
    }

    internal var editedDuration: Double {
        return (duration - startTime) - (duration - endTime)
    }

    @objc open var sampleRate: Double {
        return AKSettings.sampleRate
    }

    // this can optionally be overridden by subclasses.
    // In the main class for scheduling purposes. See AKDynamicPlayer
    internal var _rate: Double {
        return 1.0
    }

    internal var stopEnvelopeTimer: Timer?

    /// Stub function to be implemented on route changes in subclasses
    open func initialize(restartIfPlaying: Bool = true) {}

    @objc open func play() {}
    @objc open func stop() {}

    // MARK: internal functions to be used by subclasses

    /// This is used to schedule the fade in and out for a region. It uses values from the fade struct.
    internal func scheduleFader() {
        guard let faderNode = faderNode else { return }

        faderNode.clearAutomationPoints()

        if fade.inTime > 0 {
            // realtime, turn the gain off to be sure it's off before the fade starts
            faderNode.gain = Fade.minimumGain

            // add this extra point for the case where it is offline processing
            faderNode.addAutomationPoint(value: Fade.minimumGain,
                                         at: 0,
                                         rampDuration: 0)

            // then fade it in. fade.maximumGain is the ceiling it should fade to
            faderNode.addAutomationPoint(value: fade.maximumGain,
                                         at: 0.000_1,
                                         rampDuration: fade.inTime,
                                         taper: fade.inTaper,
                                         skew: fade.inSkew)
        }

        if fade.outTime > 0 {
            // when the start of the fade out should occur
            var timeTillFadeOut = offsetTime + editedDuration - fade.outTime

            // adjust the scheduled fade out based on the playback rate
            timeTillFadeOut /= _rate

            faderNode.addAutomationPoint(value: Fade.minimumGain,
                                         at: timeTillFadeOut,
                                         rampDuration: fade.outTime / _rate,
                                         taper: fade.outTaper,
                                         skew: fade.outSkew)
        }

//        AKLog("LEFT POINTS, offsetTime", offsetTime, faderNode.parameterAutomation?.getPoints(of: faderNode.leftGain.identifier))
    }

    func secondsToFrames(_ value: Double) -> AUAudioFrameCount {
        return AUAudioFrameCount(value * sampleRate)
    }

    // Enables the internal fader from the signal chain if it is bypassed
    public func startFader() {
        if faderNode?.isBypassed == true {
            faderNode?.start()
        }
    }

    // Bypasses the internal fader from the signal chain
    public func bypassFader() {
        if faderNode?.isBypassed == false {
            faderNode?.bypass()
        }
    }

    public func resetFader() {
        faderNode?.gain = fade.maximumGain
    }

    public func fadeOut(with duration: Double, taper: AUValue? = nil) {
        faderNode?.parameterAutomation?.stopPlayback()
        faderNode?.clearAutomationPoints()
        faderNode?.addAutomationPoint(value: Fade.minimumGain,
                                      at: 0,
                                      rampDuration: duration,
                                      taper: taper ?? fade.outTaper)
        faderNode?.parameterAutomation?.startPlayback()
    }

    open override func detach() {
        super.detach()
        faderNode?.detach()
        faderNode = nil
    }
}
