import Foundation

struct RetrievalEvaluationMetrics: Equatable, Sendable {
    var recallAtFive: Double
    var meanReciprocalRankAtTen: Double
}

enum RetrievalEvaluator {
    static func metrics(
        rankedChunkIDs: [[String]],
        relevantChunkIDs: [Set<String>]
    ) -> RetrievalEvaluationMetrics {
        guard rankedChunkIDs.count == relevantChunkIDs.count, !rankedChunkIDs.isEmpty else {
            return RetrievalEvaluationMetrics(recallAtFive: 0, meanReciprocalRankAtTen: 0)
        }
        var recall = 0.0
        var reciprocalRank = 0.0

        for (ranked, relevant) in zip(rankedChunkIDs, relevantChunkIDs) {
            guard !relevant.isEmpty else { continue }
            let hits = Set(ranked.prefix(5)).intersection(relevant).count
            recall += Double(hits) / Double(relevant.count)
            if let rank = ranked.prefix(10).firstIndex(where: relevant.contains) {
                reciprocalRank += 1 / Double(rank + 1)
            }
        }

        let count = Double(rankedChunkIDs.count)
        return RetrievalEvaluationMetrics(
            recallAtFive: recall / count,
            meanReciprocalRankAtTen: reciprocalRank / count
        )
    }
}
