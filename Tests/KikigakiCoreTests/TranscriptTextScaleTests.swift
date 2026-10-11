import Foundation
import Testing
@testable import KikigakiCore

@Test func transcriptScaleStepsAndClamps() {
    var value = TranscriptTextScale(percent: 80)
    #expect(value.decreased() == value)
    for percent in TranscriptTextScale.percentages {
        #expect(value.percent == percent)
        #expect(value.multiplier == Double(percent) / 100)
        #expect(value.canIncrease == (percent < 200))
        #expect(value.canDecrease == (percent > 80))
        value = value.increased()
    }
    #expect(value.increased() == value)
    for percent in TranscriptTextScale.percentages.reversed() {
        #expect(value.percent == percent)
        value = value.decreased()
    }
}

@Test func transcriptScaleSavedValues() {
    for percent in TranscriptTextScale.percentages {
        #expect(TranscriptTextScale(savedValue: NSNumber(value: percent)).percent == percent)
    }
    for value: Any? in [nil, "125", true, 0, 79, 101, 201, 125.5, Double.nan, Double.infinity] {
        #expect(TranscriptTextScale(savedValue: value) == .actual)
    }
    #expect(TranscriptTextScale(percent: 120) == .actual)
}
