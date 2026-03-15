import CoreGraphics
import Foundation

final class SimpleTracker {
    private struct TrackState {
        var id: Int
        var detection: Detection
        var velocity: CGPoint
        var misses: Int
    }

    private var tracks: [TrackState] = []
    private var nextTrackID: Int = 1

    private let matchThreshold: CGFloat
    private let maxMisses: Int

    init(matchThreshold: CGFloat = 0.3, maxMisses: Int = 8) {
        self.matchThreshold = matchThreshold
        self.maxMisses = maxMisses
    }

    func update(detections: [Detection]) -> [TrackResult] {
        var unmatchedTrackIndices = Set(tracks.indices)
        var unmatchedDetectionIndices = Set(detections.indices)
        var matches: [(trackIndex: Int, detectionIndex: Int)] = []

        while true {
            var bestMatch: (trackIndex: Int, detectionIndex: Int, score: CGFloat)?

            for trackIndex in unmatchedTrackIndices {
                for detectionIndex in unmatchedDetectionIndices {
                    let track = tracks[trackIndex]
                    let detection = detections[detectionIndex]

                    guard track.detection.classID == detection.classID else { continue }

                    let score = iou(lhs: track.detection.rect, rhs: detection.rect)
                    guard score >= matchThreshold else { continue }

                    if bestMatch == nil || score > bestMatch!.score {
                        bestMatch = (trackIndex, detectionIndex, score)
                    }
                }
            }

            guard let bestMatch else { break }

            matches.append((bestMatch.trackIndex, bestMatch.detectionIndex))
            unmatchedTrackIndices.remove(bestMatch.trackIndex)
            unmatchedDetectionIndices.remove(bestMatch.detectionIndex)
        }

        var nextTracks: [TrackState] = []

        for match in matches {
            var track = tracks[match.trackIndex]
            let newDetection = detections[match.detectionIndex]

            let oldCenter = track.detection.rect.center
            let newCenter = newDetection.rect.center

            track.velocity = CGPoint(
                x: newCenter.x - oldCenter.x,
                y: newCenter.y - oldCenter.y
            )
            track.detection = newDetection
            track.misses = 0

            nextTracks.append(track)
        }

        for trackIndex in unmatchedTrackIndices {
            var track = tracks[trackIndex]
            track.misses += 1

            if track.misses <= maxMisses {
                nextTracks.append(track)
            }
        }

        for detectionIndex in unmatchedDetectionIndices {
            let newTrack = TrackState(
                id: nextTrackID,
                detection: detections[detectionIndex],
                velocity: .zero,
                misses: 0
            )
            nextTrackID += 1
            nextTracks.append(newTrack)
        }

        tracks = nextTracks.sorted { $0.id < $1.id }

        return tracks.map {
            TrackResult(trackID: $0.id, detection: $0.detection, isPredictionOnly: false)
        }
    }

    func predictOnly() -> [TrackResult] {
        var nextTracks: [TrackState] = []

        for var track in tracks {
            track.misses += 1
            guard track.misses <= maxMisses else { continue }

            var predicted = track.detection.rect.offsetBy(
                dx: track.velocity.x,
                dy: track.velocity.y
            )
            predicted = predicted.clampedToUnit()

            track.detection = Detection(
                rect: predicted,
                confidence: track.detection.confidence,
                classID: track.detection.classID,
                className: track.detection.className
            )

            nextTracks.append(track)
        }

        tracks = nextTracks.sorted { $0.id < $1.id }

        return tracks.map {
            TrackResult(trackID: $0.id, detection: $0.detection, isPredictionOnly: true)
        }
    }

    private func iou(lhs: CGRect, rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        if intersection.isNull || intersection.isEmpty { return 0.0 }

        let intersectionArea = intersection.width * intersection.height
        let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
        guard unionArea > 0 else { return 0.0 }
        return intersectionArea / unionArea
    }
}
