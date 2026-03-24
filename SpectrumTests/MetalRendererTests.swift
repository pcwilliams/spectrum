import Foundation
import Testing
@testable import Spectrum

struct MetalRendererTests {

    // MARK: - gradientColor stops

    @Test func gradientColor_atZero_isBlue() {
        let c = MetalRenderer.gradientColor(at: 0)
        #expect(c.x == 0)  // red
        #expect(c.y == 0)  // green
        #expect(c.z == 1)  // blue
        #expect(c.w == 1)  // alpha
    }

    @Test func gradientColor_atQuarter_isCyan() {
        let c = MetalRenderer.gradientColor(at: 0.25)
        #expect(c.x == 0)
        #expect(c.y == 1)
        #expect(c.z == 1)
        #expect(c.w == 1)
    }

    @Test func gradientColor_atHalf_isGreen() {
        let c = MetalRenderer.gradientColor(at: 0.5)
        #expect(c.x == 0)
        #expect(c.y == 1)
        #expect(c.z == 0)
        #expect(c.w == 1)
    }

    @Test func gradientColor_atThreeQuarters_isYellow() {
        let c = MetalRenderer.gradientColor(at: 0.75)
        #expect(c.x == 1)
        #expect(c.y == 1)
        #expect(c.z == 0)
        #expect(c.w == 1)
    }

    @Test func gradientColor_atOne_isRed() {
        let c = MetalRenderer.gradientColor(at: 1.0)
        #expect(c.x == 1)
        #expect(c.y == 0)
        #expect(c.z == 0)
        #expect(c.w == 1)
    }

    // MARK: - gradientColor interpolation

    @Test func gradientColor_interpolatesBetweenStops() {
        // Midway between blue (0) and cyan (0.25) should have intermediate green
        let c = MetalRenderer.gradientColor(at: 0.125)
        #expect(c.x == 0)           // red stays 0
        #expect(abs(c.y - 0.5) < 0.001)  // green interpolates to 0.5
        #expect(c.z == 1)           // blue stays 1
    }

    @Test func gradientColor_alphaAlwaysOne() {
        let testValues: [Float] = [0, 0.1, 0.25, 0.4, 0.5, 0.6, 0.75, 0.9, 1.0]
        for t in testValues {
            let c = MetalRenderer.gradientColor(at: t)
            #expect(c.w == 1.0)
        }
    }

    @Test func gradientColor_allComponentsNonNegative() {
        for i in 0..<100 {
            let t = Float(i) / 99.0
            let c = MetalRenderer.gradientColor(at: t)
            #expect(c.x >= 0 && c.y >= 0 && c.z >= 0 && c.w >= 0)
        }
    }

    @Test func gradientColor_smoothTransitions() {
        // Adjacent gradient values should not have huge jumps
        var prev = MetalRenderer.gradientColor(at: 0)
        for i in 1..<100 {
            let t = Float(i) / 99.0
            let curr = MetalRenderer.gradientColor(at: t)
            let maxDiff = max(abs(curr.x - prev.x), max(abs(curr.y - prev.y), abs(curr.z - prev.z)))
            #expect(maxDiff < 0.1, "Jump too large at t=\(t): \(maxDiff)")
            prev = curr
        }
    }

    // MARK: - heatmapColor

    @Test func heatmapColor_atZero_isBlack() {
        let c = MetalRenderer.heatmapColor(0)
        #expect(c.x == 0)
        #expect(c.y == 0)
        #expect(c.z == 0)
    }

    @Test func heatmapColor_atOne_isRed() {
        let c = MetalRenderer.heatmapColor(1.0)
        #expect(c.x == 1)
        #expect(c.z == 0)
    }

    @Test func heatmapColor_clampsNegative() {
        let c = MetalRenderer.heatmapColor(-0.5)
        let cZero = MetalRenderer.heatmapColor(0)
        #expect(c.x == cZero.x)
        #expect(c.y == cZero.y)
        #expect(c.z == cZero.z)
    }

    @Test func heatmapColor_clampsAboveOne() {
        let c = MetalRenderer.heatmapColor(1.5)
        let cOne = MetalRenderer.heatmapColor(1.0)
        #expect(c.x == cOne.x)
        #expect(c.y == cOne.y)
        #expect(c.z == cOne.z)
    }

    @Test func heatmapColor_alphaAlwaysOne() {
        let testValues: [Float] = [0, 0.25, 0.5, 0.75, 1.0]
        for v in testValues {
            let c = MetalRenderer.heatmapColor(v)
            #expect(c.w == 1.0)
        }
    }

    @Test func heatmapColor_midValue_hasCyanish() {
        // At 0.5, should be roughly cyan (0, 1, 1)
        let c = MetalRenderer.heatmapColor(0.5)
        #expect(c.x == 0)
        #expect(c.y == 1)
        #expect(c.z == 1)
    }

    @Test func heatmapColor_lowValues_areDark() {
        // Low values should have low total brightness
        let c = MetalRenderer.heatmapColor(0.1)
        let brightness = c.x + c.y + c.z
        #expect(brightness < 1.0)
    }

    @Test func heatmapColor_increasingBrightness() {
        // Overall brightness should generally increase with value
        let low = MetalRenderer.heatmapColor(0.1)
        let mid = MetalRenderer.heatmapColor(0.5)
        let high = MetalRenderer.heatmapColor(0.9)
        let lowBright = low.x + low.y + low.z
        let midBright = mid.x + mid.y + mid.z
        let highBright = high.x + high.y + high.z
        #expect(midBright > lowBright)
        #expect(highBright > lowBright)
    }
}
