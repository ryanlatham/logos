import Accelerate
import Foundation

struct AudioSpectrumAnalyzer {
    struct Configuration: Equatable {
        var fftSize: Int = 1024
        var binCount: Int = 12
        var minimumFrequency: Float = 80
        var maximumFrequency: Float = 8_000
        var floorDB: Float = -80

        init(
            fftSize: Int = 1024,
            binCount: Int = 12,
            minimumFrequency: Float = 80,
            maximumFrequency: Float = 8_000,
            floorDB: Float = -80
        ) {
            self.fftSize = fftSize
            self.binCount = binCount
            self.minimumFrequency = minimumFrequency
            self.maximumFrequency = maximumFrequency
            self.floorDB = floorDB
        }
    }

    private let floorBinValue = 0.04
    private let maximumBinCount = 64
    private let maximumFFTSize = 4096

    func analyze(
        samples: [Float],
        sampleRate: Double,
        playheadTime: TimeInterval,
        configuration: Configuration = Configuration(),
        previousBins: [Double]? = nil
    ) -> [Double] {
        let binCount = max(1, min(configuration.binCount, maximumBinCount))
        let floorBins = Array(repeating: floorBinValue, count: binCount)
        guard sampleRate.isFinite, sampleRate > 0, samples.isEmpty == false else {
            return floorBins
        }

        let fftSize = normalizedFFTSize(configuration.fftSize)
        guard fftSize >= 2 else { return floorBins }

        var windowedSamples = sampleWindow(
            from: samples,
            sampleRate: sampleRate,
            playheadTime: playheadTime,
            fftSize: fftSize
        )
        guard windowedSamples.contains(where: { abs($0) > 0.000_001 }) else {
            return floorBins
        }
        applyHannWindow(to: &windowedSamples)

        let magnitudes = fftMagnitudes(from: windowedSamples)
        guard magnitudes.isEmpty == false else { return floorBins }

        let rawBins = mapMagnitudesToBands(
            magnitudes,
            sampleRate: sampleRate,
            fftSize: fftSize,
            configuration: configuration,
            binCount: binCount
        )
        guard let maxMagnitude = rawBins.max(), maxMagnitude > Float.ulpOfOne else {
            return floorBins
        }

        let floorDB = min(-1, configuration.floorDB)
        let normalized = rawBins.map { magnitude -> Double in
            guard magnitude > Float.ulpOfOne else { return floorBinValue }
            let relativeDB = max(floorDB, 20 * log10(magnitude / maxMagnitude))
            let scaled = 1 + Double(relativeDB / abs(floorDB))
            return max(floorBinValue, min(1, scaled))
        }

        guard let previousBins, previousBins.count == normalized.count else {
            return normalized
        }
        return zip(previousBins, normalized).map { previous, current in
            max(0, min(1, previous * 0.55 + current * 0.45))
        }
    }

    private func normalizedFFTSize(_ requestedSize: Int) -> Int {
        let minimumSize = max(2, min(requestedSize, maximumFFTSize))
        var powerOfTwo = 1
        while powerOfTwo < minimumSize {
            powerOfTwo <<= 1
        }
        return powerOfTwo
    }

    private func sampleWindow(from samples: [Float], sampleRate: Double, playheadTime: TimeInterval, fftSize: Int) -> [Float] {
        var window = Array(repeating: Float(0), count: fftSize)
        let safePlayheadTime = playheadTime.isFinite ? max(0, playheadTime) : 0
        let playheadFrame = Int((safePlayheadTime * sampleRate).rounded())
        let startFrame = playheadFrame - fftSize / 2
        for index in 0..<fftSize {
            let sourceIndex = startFrame + index
            if sourceIndex >= 0, sourceIndex < samples.count {
                window[index] = samples[sourceIndex]
            }
        }
        return window
    }

    private func applyHannWindow(to samples: inout [Float]) {
        guard samples.count > 1 else { return }
        let denominator = Double(samples.count - 1)
        for index in samples.indices {
            let window = 0.5 - 0.5 * cos((2 * Double.pi * Double(index)) / denominator)
            samples[index] *= Float(window)
        }
    }

    private func fftMagnitudes(from samples: [Float]) -> [Float] {
        let fftSize = samples.count
        let halfSize = fftSize / 2
        guard halfSize > 0 else { return [] }
        let log2Size = vDSP_Length(log2(Double(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2)) else {
            return []
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var reals = Array(repeating: Float(0), count: halfSize)
        var imaginaries = Array(repeating: Float(0), count: halfSize)
        var magnitudes = Array(repeating: Float(0), count: halfSize)

        reals.withUnsafeMutableBufferPointer { realBuffer in
            imaginaries.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var splitComplex = DSPSplitComplex(
                    realp: realBuffer.baseAddress!,
                    imagp: imaginaryBuffer.baseAddress!
                )
                samples.withUnsafeBufferPointer { sampleBuffer in
                    sampleBuffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexBuffer in
                        vDSP_ctoz(complexBuffer, 2, &splitComplex, 1, vDSP_Length(halfSize))
                    }
                }
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2Size, FFTDirection(FFT_FORWARD))
                var scale = Float(1.0 / Float(fftSize))
                vDSP_vsmul(splitComplex.realp, 1, &scale, splitComplex.realp, 1, vDSP_Length(halfSize))
                vDSP_vsmul(splitComplex.imagp, 1, &scale, splitComplex.imagp, 1, vDSP_Length(halfSize))
                vDSP_zvabs(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfSize))
            }
        }
        if magnitudes.count > 1 {
            magnitudes[0] = 0
        }
        return magnitudes
    }

    private func mapMagnitudesToBands(
        _ magnitudes: [Float],
        sampleRate: Double,
        fftSize: Int,
        configuration: Configuration,
        binCount: Int
    ) -> [Float] {
        let nyquist = Float(sampleRate / 2)
        let lowFrequency = max(1, configuration.minimumFrequency)
        let highFrequency = max(lowFrequency + 1, min(configuration.maximumFrequency, nyquist))
        let ratio = pow(highFrequency / lowFrequency, 1 / Float(binCount))

        return (0..<binCount).map { bandIndex in
            let bandLow = lowFrequency * pow(ratio, Float(bandIndex))
            let bandHigh = lowFrequency * pow(ratio, Float(bandIndex + 1))
            let startIndex = max(1, Int(floor(Double(bandLow) * Double(fftSize) / sampleRate)))
            let endIndex = min(magnitudes.count - 1, max(startIndex, Int(ceil(Double(bandHigh) * Double(fftSize) / sampleRate))))
            guard startIndex <= endIndex, startIndex < magnitudes.count else { return 0 }
            return magnitudes[startIndex...endIndex].max() ?? 0
        }
    }
}
