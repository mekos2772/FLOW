import Foundation
import SwiftData

/// 曲目落库形态。对外只暴露值类型 `Track`，`@Model` 不出持久化层。
@Model
final class TrackRecord {
    @Attribute(.unique) var identityKey: String
    var localID: UUID
    var sourceID: String
    var externalID: String
    var title: String
    var artist: String
    var album: String?
    var duration: Double
    var artworkData: Data?
    var lyricsData: Data?
    var persistentIdentifier: String?
    var updatedAt: Date

    init(identityKey: String,
         localID: UUID,
         sourceID: String,
         externalID: String,
         title: String,
         artist: String,
         album: String?,
         duration: Double,
         artworkData: Data?,
         lyricsData: Data?,
         persistentIdentifier: String? = nil,
         updatedAt: Date = .now) {
        self.identityKey = identityKey
        self.localID = localID
        self.sourceID = sourceID
        self.externalID = externalID
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkData = artworkData
        self.lyricsData = lyricsData
        self.persistentIdentifier = persistentIdentifier
        self.updatedAt = updatedAt
    }
}

extension TrackRecord {
    static func identityKey(_ identity: TrackIdentity) -> String {
        "\(identity.sourceID.rawValue)::\(identity.externalID)"
    }

    convenience init(_ track: Track, encoder: JSONEncoder = JSONEncoder()) {
        self.init(
            identityKey: TrackRecord.identityKey(track.identity),
            localID: track.id,
            sourceID: track.sourceID.rawValue,
            externalID: track.externalID,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            artworkData: track.artwork.flatMap { try? encoder.encode($0) },
            lyricsData: track.lyrics.flatMap { try? encoder.encode($0) },
            persistentIdentifier: track.persistentIdentifier
        )
    }

    func asTrack(decoder: JSONDecoder = JSONDecoder()) -> Track {
        Track(
            id: localID,
            sourceID: SourceID(rawValue: sourceID),
            externalID: externalID,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            artwork: artworkData.flatMap { try? decoder.decode(ArtworkReference.self, from: $0) },
            lyrics: lyricsData.flatMap { try? decoder.decode(LyricsReference.self, from: $0) },
            persistentIdentifier: persistentIdentifier
        )
    }
}
