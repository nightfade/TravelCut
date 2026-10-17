import Foundation
import SoundAnalysis

final class AudioEventAnalyzer {
    private final class Observer: NSObject, SNResultsObserving {
        private let lock = NSLock()
        private(set) var events: [AudioEvent] = []
        private(set) var error: Error?

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            let start = result.timeRange.start.seconds
            let duration = result.timeRange.duration.seconds
            let newEvents = result.classifications.prefix(4).compactMap { classification -> AudioEvent? in
                guard classification.confidence >= 0.18 else { return nil }
                return AudioEvent(
                    start: start,
                    duration: duration,
                    identifier: classification.identifier,
                    confidence: classification.confidence
                )
            }
            lock.lock()
            events.append(contentsOf: newEvents)
            lock.unlock()
        }

        func request(_ request: SNRequest, didFailWithError error: Error) {
            lock.lock()
            self.error = error
            lock.unlock()
        }
    }

    func analyze(source: SourceVideo) -> [AudioEvent] {
        guard source.hasAudio,
              let analyzer = try? SNAudioFileAnalyzer(url: source.url),
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1)
        else {
            return []
        }
        request.overlapFactor = 0.5
        request.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 600)
        let observer = Observer()
        guard (try? analyzer.add(request, withObserver: observer)) != nil else { return [] }
        analyzer.analyze()
        return observer.error == nil ? observer.events : []
    }

    func summary(for candidate: HighlightCandidate, events: [AudioEvent]) -> AudioSummary {
        let overlapping = events.filter { event in
            min(candidate.end, event.end) > max(candidate.start, event.start)
        }
        guard !overlapping.isEmpty else { return .unavailable }

        let positiveKeywords = [
            "laughter", "laugh", "giggle", "applause", "clap", "cheer", "crowd",
            "singing", "bird", "water", "ocean", "stream", "speech",
        ]
        let negativeKeywords = [
            "wind_noise", "static", "white_noise", "silence", "hiss", "distortion",
        ]
        var positive = 0.0
        var negative = 0.0
        var strongest: [String: Double] = [:]
        for event in overlapping {
            let identifier = event.identifier.lowercased()
            strongest[event.identifier] = max(strongest[event.identifier] ?? 0, event.confidence)
            if positiveKeywords.contains(where: identifier.contains) {
                positive = max(positive, event.confidence)
            }
            if negativeKeywords.contains(where: identifier.contains) {
                negative = max(negative, event.confidence)
            }
        }
        let score = min(1, max(0, 0.48 + positive * 0.42 - negative * 0.38))
        let labels = strongest
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map(\.key)
        return AudioSummary(score: score, labels: labels)
    }
}
