import Foundation

/// Each edit lists the catalog as the server does once the client call it names has succeeded, so an app
/// can show the change at once and let its next read confirm it. An unknown title or path changes nothing.
extension CatalogResponse {
    /// After `deleteTitle`: a watched title stays without its files, an unwatched one goes.
    public mutating func deleteTitle(titleID: String) {
        guard var title = title(titleID) else { return }
        guard title.watched != nil else { return remove(titleID) }
        title.files = []
        put(title)
    }

    /// After `deleteLibraryItem` for one file: the files left decide whether the title is watched, and a
    /// title with none left goes. A new `added`, the entry's mtime, or `kind` waits for the read.
    public mutating func deleteLibraryItem(path: String) {
        let listed = (titles + watched).first { $0.files.contains { $0.path == path } }
        guard var title = listed else { return }
        title.files.removeAll { $0.path == path }
        guard !title.files.isEmpty else { return remove(title.id) }
        title.watched = title.finished
        put(title)
    }

    /// After `markWatched` at `date`: every unfinished file is finished at its known duration.
    public mutating func markWatched(titleID: String, at date: Date) {
        guard var title = title(titleID), !title.files.isEmpty else { return }
        for index in title.files.indices where title.files[index].progress?.finished != true {
            let file = title.files[index]
            let duration = [file.progress?.duration, file.media?.duration].compactMap { $0 }.first { $0 > 0 } ?? 1
            title.files[index].progress = PlaybackProgress(
                path: nil, position: duration, duration: duration, finished: true,
                updated: Int(date.timeIntervalSince1970)
            )
        }
        title.watched = title.finished
        put(title)
    }

    /// After `markUnwatched`: no file has progress.
    public mutating func markUnwatched(titleID: String) {
        guard var title = title(titleID), !title.files.isEmpty else { return }
        for index in title.files.indices { title.files[index].progress = nil }
        title.watched = nil
        put(title)
    }

    /// After `setMatch` or `clearMatch`, with the title it returned.
    public mutating func replace(_ title: CatalogTitle) {
        guard self.title(title.id) != nil else { return }
        put(title)
    }

    private func title(_ id: String) -> CatalogTitle? {
        titles.first { $0.id == id } ?? watched.first { $0.id == id }
    }

    private mutating func remove(_ titleID: String) {
        titles.removeAll { $0.id == titleID }
        continueWatching.removeAll { $0.titleId == titleID }
        watched.removeAll { $0.id == titleID }
    }

    /// Lists the title where its `added` and `watched` put it, with the Continue entry its progress gives it.
    private mutating func put(_ title: CatalogTitle) {
        remove(title.id)
        if let finished = title.watched {
            let next = watched.firstIndex { ($0.watched ?? 0, title.id) < (finished, $0.id) }
            watched.insert(title, at: next ?? watched.endIndex)
            return
        }
        let next = titles.firstIndex { ($0.added, title.id) < (title.added, $0.id) }
        titles.insert(title, at: next ?? titles.endIndex)
        guard let resume = title.resume else { return }
        let later = continueWatching.firstIndex { item in
            self.title(item.titleId)?.resume.map { $0.played < resume.played } ?? true
        }
        continueWatching.insert(ContinueItem(titleId: title.id, path: resume.path),
                                at: later ?? continueWatching.endIndex)
    }
}

private extension CatalogTitle {
    /// The latest finish once every movie file or episode is finished.
    var finished: Int? {
        let counted = files.filter { kind == .movie || $0.episode != nil }.map(\.progress)
        guard counted.allSatisfy({ $0?.finished == true }) else { return nil }
        return counted.compactMap { $0?.updated }.max()
    }

    /// The last played file if unfinished, else a show's next one, with when that last play was. Files
    /// marked in the same second were marked in order.
    var resume: (path: String, played: Int)? {
        let plays = files.indices.compactMap { index in files[index].progress.map { (index, $0) } }
        guard let (index, progress) = plays.max(by: { ($0.1.updated, $0.0) < ($1.1.updated, $1.0) }) else { return nil }
        guard progress.finished else { return (files[index].path, progress.updated) }
        guard kind == .show, index + 1 < files.count else { return nil }
        return (files[index + 1].path, progress.updated)
    }
}
