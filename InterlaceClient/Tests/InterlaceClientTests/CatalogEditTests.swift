import Foundation
import Testing
@testable import InterlaceClient

private func progress(_ position: Double, of duration: Double = 100, at updated: Int) -> PlaybackProgress {
    PlaybackProgress(path: nil, position: position, duration: duration,
                     finished: duration > 0 && position >= 0.9 * duration, updated: updated)
}

private func file(_ path: String, episode: Int? = nil, duration: Double? = nil, progress: PlaybackProgress? = nil) -> CatalogFile {
    let media = duration.map {
        CatalogMedia(duration: $0, video: .init(codec: "h264", width: 1920, height: 1080, bitDepth: 8, hdr: nil),
                     audio: [], subtitles: [])
    }
    return CatalogFile(path: path, name: path, size: 1, season: episode.map { _ in 1 }, episode: episode, lastEpisode: nil,
                       episodeTitle: nil, episodeOverview: nil, airDate: nil, runtime: nil, still: false, media: media,
                       subtitles: [], progress: progress)
}

private func title(_ id: String, _ kind: CatalogKind = .movie, added: Int = 0, watched: Int? = nil,
                   name: String? = nil, files: [CatalogFile]) -> CatalogTitle {
    CatalogTitle(id: id, kind: kind, title: name ?? id, year: nil, overview: nil, tmdbId: nil, poster: false, backdrop: false,
                 logo: false, runtime: nil, certification: nil, genres: [], crew: [], matched: nil, cast: [],
                 added: added, watched: watched, files: files)
}

private func catalog(_ titles: [CatalogTitle], resuming: [(String, String)] = [], watched: [CatalogTitle] = []) throws -> CatalogResponse {
    var catalog = try JSONDecoder().decode(CatalogResponse.self, from: Data(#"{"titles":[],"continue":[],"watched":[]}"#.utf8))
    catalog.titles = titles
    catalog.continueWatching = resuming.map { ContinueItem(titleId: $0.0, path: $0.1) }
    catalog.watched = watched
    return catalog
}

private extension CatalogResponse {
    func edited(_ edit: (inout CatalogResponse) -> Void) -> CatalogResponse {
        var copy = self
        edit(&copy)
        return copy
    }

    var resuming: [String] { continueWatching.map(\.path) }

    func listed(_ id: String) -> CatalogTitle? { (titles + watched).first { $0.id == id } }
}

@Test func deletingAnUnwatchedTitleRemovesItEverywhere() throws {
    let before = try catalog(
        [title("new", added: 2, files: [file("new.mkv", progress: progress(10, at: 5))]),
         title("old", added: 1, files: [file("old.mkv", progress: progress(10, at: 4))])],
        resuming: [("new", "new.mkv"), ("old", "old.mkv")],
        watched: [title("seen", watched: 3, files: [])]
    )
    let after = before.edited { $0.deleteTitle(titleID: "new") }
    #expect(after.titles == [before.titles[1]])
    #expect(after.resuming == ["old.mkv"])
    #expect(after.watched == before.watched)
}

@Test func deletingAWatchedTitleKeepsItsPlaceWithoutFiles() throws {
    let seen = title("seen", added: 1, watched: 8, files: [file("seen.mkv", progress: progress(100, at: 8))])
    let before = try catalog([], watched: [title("later", watched: 9, files: []), seen, title("earlier", watched: 7, files: [])])
    let after = before.edited { $0.deleteTitle(titleID: "seen") }
    #expect(after.watched == [before.watched[0], title("seen", added: 1, watched: 8, files: []), before.watched[2]])
    #expect(after.titles.isEmpty)
}

@Test func deletingOneFileKeepsTheRestOfItsTitle() throws {
    let show = title("show", .show, added: 5, files: [file("e1", episode: 1), file("e2", episode: 2), file("extra")])
    let before = try catalog([title("newer", added: 6, files: [file("newer")]), show, title("older", added: 4, files: [file("older")])])
    let after = before.edited { $0.deleteLibraryItem(path: "e1") }
    #expect(after.titles.map(\.id) == ["newer", "show", "older"])
    #expect(after.titles[1].files == [file("e2", episode: 2), file("extra")])
    #expect(after.titles[0] == before.titles[0] && after.titles[2] == before.titles[2])
    #expect(after.resuming.isEmpty && after.watched.isEmpty)
}

@Test func deletingTheLastFileRemovesItsTitleWatchedOrNot() throws {
    let before = try catalog(
        [title("film", files: [file("film.mkv", progress: progress(10, at: 2))])], resuming: [("film", "film.mkv")],
        watched: [title("seen", watched: 3, files: [file("seen.mkv", progress: progress(95, at: 3))])]
    )
    let film = before.edited { $0.deleteLibraryItem(path: "film.mkv") }
    #expect(film.titles.isEmpty && film.resuming.isEmpty && film.watched == before.watched)
    let seen = before.edited { $0.deleteLibraryItem(path: "seen.mkv") }
    #expect(seen.watched.isEmpty && seen.titles == before.titles && seen.resuming == ["film.mkv"])
}

@Test func deletingTheLastUnfinishedEpisodeMovesAShowToWatched() throws {
    let show = title("show", .show, added: 5, files: [
        file("e1", episode: 1, progress: progress(100, at: 10)), file("e2", episode: 2, progress: progress(95, at: 20)),
        file("e3", episode: 3), file("extra"),
    ])
    let before = try catalog([show], resuming: [("show", "e3")], watched: [title("seen", watched: 15, files: [])])
    let after = before.edited { $0.deleteLibraryItem(path: "e3") }
    #expect(after.titles.isEmpty && after.resuming.isEmpty)
    #expect(after.watched.map(\.id) == ["show", "seen"])
    #expect(after.watched[0].watched == 20)
    #expect(after.watched[0].files.map(\.path) == ["e1", "e2", "extra"])
}

@Test func deletingTheLatestFinishMovesAWatchedShowBackToTheOneBefore() throws {
    let show = title("show", .show, watched: 20, files: [
        file("e1", episode: 1, progress: progress(100, at: 10)), file("e2", episode: 2, progress: progress(100, at: 20)),
    ])
    let before = try catalog([], watched: [show, title("seen", watched: 15, files: [])])
    let after = before.edited { $0.deleteLibraryItem(path: "e2") }
    #expect(after.watched.map(\.id) == ["seen", "show"])
    #expect(after.listed("show")?.watched == 10)
}

@Test func continueFollowsTheLastPlayLeftInTheTitle() throws {
    let show = title("show", .show, added: 5, files: [
        file("e1", episode: 1, progress: progress(100, at: 10)), file("e2", episode: 2, progress: progress(100, at: 30)),
        file("e3", episode: 3, progress: progress(40, at: 50)), file("e4", episode: 4),
    ])
    let film = title("film", added: 4, files: [file("film.mkv", progress: progress(40, at: 20))])
    let before = try catalog([show, film], resuming: [("show", "e3"), ("film", "film.mkv")])
    // The unfinished episode: the one after the last finished episode takes its place.
    let third = before.edited { $0.deleteLibraryItem(path: "e3") }
    #expect(third.resuming == ["e4", "film.mkv"])
    // Then that last finished episode: the one before it was played before the film.
    let second = third.edited { $0.deleteLibraryItem(path: "e2") }
    #expect(second.resuming == ["film.mkv", "e4"])
    // Nothing played is left.
    let first = second.edited { $0.deleteLibraryItem(path: "e1") }
    #expect(first.resuming == ["film.mkv"] && first.listed("show")?.files.map(\.path) == ["e4"])
}

@Test func continueDropsAShowWhoseLastFileIsFinished() throws {
    let show = title("show", .show, files: [
        file("e1", episode: 1), file("e2", episode: 2, progress: progress(100, at: 10)), file("e3", episode: 3),
    ])
    let before = try catalog([show], resuming: [("show", "e3")])
    #expect(before.edited { $0.deleteLibraryItem(path: "e3") }.resuming.isEmpty)
}

@Test func markingWatchedFinishesUnfinishedFilesAtTheirKnownDuration() throws {
    let finished = progress(95, at: 3)
    let show = title("show", .show, added: 5, files: [
        file("e1", episode: 1, duration: 60, progress: finished),
        file("e2", episode: 2, duration: 60, progress: progress(10, of: 80, at: 4)),
        file("e3", episode: 3, duration: 60, progress: progress(0, of: 0, at: 4)),
        file("e4", episode: 4, duration: 60), file("e5", episode: 5), file("extra"),
    ])
    let before = try catalog([show, title("film", added: 1, files: [file("film.mkv")])], resuming: [("show", "e2")],
                             watched: [title("seen", watched: 50, files: [])])
    let after = before.edited { $0.markWatched(titleID: "show", at: Date(timeIntervalSince1970: 100.9)) }
    #expect(after.titles.map(\.id) == ["film"] && after.resuming.isEmpty)
    #expect(after.watched.map(\.id) == ["show", "seen"])
    let marked = after.watched[0]
    #expect(marked.watched == 100)
    #expect(marked.files[0].progress == finished)
    #expect(marked.files.dropFirst().map { $0.progress?.duration } == [80, 60, 60, 1, 1])
    #expect(marked.files.dropFirst().allSatisfy { file in
        file.progress.map { $0.finished && $0.position == $0.duration && $0.updated == 100 } == true
    })
}

@Test func markingUnwatchedClearsProgressAndReturnsTheTitleToItsPlace() throws {
    let before = try catalog(
        [title("newer", added: 6, files: [file("newer")]), title("a", added: 5, files: [file("a")]),
         title("c", added: 5, files: [file("c")]), title("older", added: 4, files: [file("older")])],
        watched: [title("b", added: 5, watched: 9, files: [file("b", progress: progress(100, at: 9))])]
    )
    let after = before.edited { $0.markUnwatched(titleID: "b") }
    #expect(after.titles.map(\.id) == ["newer", "a", "b", "c", "older"])
    #expect(after.titles[2] == title("b", added: 5, files: [file("b")]))
    #expect(after.watched.isEmpty && after.resuming.isEmpty)
    #expect(after.edited { $0.markWatched(titleID: "b", at: Date(timeIntervalSince1970: 9)) }.titles.map(\.id)
        == before.titles.map(\.id))
}

@Test func watchedListsTheLatestFirstAndTiesByID() throws {
    let before = try catalog([title("b", files: [file("b")])],
                             watched: [title("a", watched: 9, files: []), title("c", watched: 9, files: [])])
    #expect(before.edited { $0.markWatched(titleID: "b", at: Date(timeIntervalSince1970: 9)) }.watched.map(\.id) == ["a", "b", "c"])
    #expect(before.edited { $0.markWatched(titleID: "b", at: Date(timeIntervalSince1970: 8)) }.watched.map(\.id) == ["a", "c", "b"])
}

@Test func replacingATitleKeepsItsPlaceAndContinueEntry() throws {
    let show = title("show", .show, added: 5, files: [file("e1", episode: 1, progress: progress(40, at: 30))])
    let film = title("film", added: 4, files: [file("film.mkv", progress: progress(40, at: 50))])
    let before = try catalog([show, film], resuming: [("film", "film.mkv"), ("show", "e1")],
                             watched: [title("seen", watched: 2, files: []), title("gone", watched: 1, files: [])])
    let matched = title("show", .show, added: 5, name: "The Show", files: show.files)
    let after = before.edited { $0.replace(matched) }
    #expect(after.titles == [matched, film])
    #expect(after.resuming == before.resuming && after.watched == before.watched)
    let seen = title("seen", watched: 2, name: "Seen", files: [])
    #expect(before.edited { $0.replace(seen) }.watched == [seen, before.watched[1]])
}

@Test func editsOfUnlistedTitlesAndPathsChangeNothing() throws {
    let before = try catalog([title("film", files: [file("film.mkv")])], watched: [title("seen", watched: 2, files: [])])
    #expect(before.edited { $0.deleteTitle(titleID: "other") } == before)
    #expect(before.edited { $0.deleteLibraryItem(path: "other.mkv") } == before)
    #expect(before.edited { $0.markWatched(titleID: "other", at: .now) } == before)
    #expect(before.edited { $0.markUnwatched(titleID: "other") } == before)
    #expect(before.edited { $0.replace(title("other", files: [file("other.mkv")])) } == before)
    // The server marks only titles on disk.
    #expect(before.edited { $0.markWatched(titleID: "seen", at: .now) } == before)
    #expect(before.edited { $0.markUnwatched(titleID: "seen") } == before)
}

@Test func editsHoldOnTheServersCatalog() throws {
    let before = try decodeFixture("catalog", as: CatalogResponse.self)
    let show = before.titles[1]
    let seen = before.edited { $0.markWatched(titleID: show.id, at: Date(timeIntervalSince1970: 1763600000)) }
    #expect(seen.titles == [before.titles[0]] && seen.continueWatching.isEmpty)
    #expect(seen.watched.map(\.id) == [show.id, before.watched[0].id])
    #expect(seen.watched[0].files.map { $0.progress?.duration } == [1320, 1])
    let deleted = before.edited { $0.deleteLibraryItem(path: show.files[0].path) }
    #expect(deleted.titles[1].files == [show.files[1]] && deleted.continueWatching.isEmpty)
    let encoded = try JSONEncoder().encode(seen)
    #expect(try JSONDecoder().decode(CatalogResponse.self, from: encoded) == seen)
}
