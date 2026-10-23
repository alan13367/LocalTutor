import Foundation

struct RetrievalEvaluationMetrics: Equatable, Sendable {
    var hitAtOne: Double
    var recallAtFive: Double
    var meanReciprocalRankAtTen: Double
}

enum RetrievalEvaluator {
    static func metrics(
        rankedChunkIDs: [[String]],
        relevantChunkIDs: [Set<String>]
    ) -> RetrievalEvaluationMetrics {
        guard rankedChunkIDs.count == relevantChunkIDs.count, !rankedChunkIDs.isEmpty else {
            return RetrievalEvaluationMetrics(hitAtOne: 0, recallAtFive: 0, meanReciprocalRankAtTen: 0)
        }
        var hits = 0.0
        var recall = 0.0
        var reciprocalRank = 0.0

        for (ranked, relevant) in zip(rankedChunkIDs, relevantChunkIDs) {
            guard !relevant.isEmpty else { continue }
            if let first = ranked.first, relevant.contains(first) {
                hits += 1
            }
            let found = Set(ranked.prefix(5)).intersection(relevant).count
            recall += Double(found) / Double(relevant.count)
            if let rank = ranked.prefix(10).firstIndex(where: relevant.contains) {
                reciprocalRank += 1 / Double(rank + 1)
            }
        }

        let count = Double(rankedChunkIDs.count)
        return RetrievalEvaluationMetrics(
            hitAtOne: hits / count,
            recallAtFive: recall / count,
            meanReciprocalRankAtTen: reciprocalRank / count
        )
    }
}
