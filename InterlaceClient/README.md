# InterlaceClient

Interlace's `/api` contract for iOS, macOS, and watchOS. Requires Swift 6 and OS 26.

```swift
import InterlaceClient

let client = InterlaceClient(key: { deviceKey }) {
    // Read the app's current configuration on every request.
    InterlaceEndpoint(url: serverURL)
}
let library = try await client.library(path: "Series")
try await client.play(path: library.items[0].path)
```

The endpoint URL is the server root, optionally including a reverse proxy's base
path, without `/api`. The endpoint closure is `@Sendable`; the app owns its
synchronization. A nil endpoint throws `InterlaceError.notConfigured`.
Every HTTP request carries `Authorization: Bearer <device key>` from the key closure the app passes in.

For the watch, implement `Transport.perform(_:)` and initialize
`InterlaceClient(transport: relay)`. Put `JSONEncoder().encode(request)` in a
WatchConnectivity message dictionary as `Data`. On the phone, decode the request,
call its `HTTPTransport.perform(_:)`, and send the encoded `InterlaceResponse`
back. Requests contain no endpoint; the phone supplies its own.
Transports return non-2xx statuses unchanged; the client maps them to typed errors.

`catalog()` and `art(titleID:kind:)` fetch titles and images; `progress(path:)`, `saveProgress(path:position:duration:)`, and `clearProgress(path:)` manage playback progress. `markWatched(titleID:)` and `markUnwatched(titleID:)` finish or clear a whole title; `deleteTitle(titleID:)` deletes its files. `subtitleChoice(path:)` and `saveSubtitleChoice(path:choice:)` read and store the subtitle picked for a file.
`HTTPTransport.fileRequest(path:)` builds an authenticated request for file streaming.
Only `HTTPTransport` streams files; a watch relay cannot.

`upload(fileURL:to:fileName:progress:)` requires `FileUploadTransport`, which `HTTPTransport`
implements. HTTP uploads stream the multipart headers, the file in chunks, and the
closing boundary as the request body, so they need no copy of the file; `progress`
gets the fraction sent. Cancelling the calling Task cancels the upload and throws
`CancellationError`.
Torrent and subtitle uploads also accept `Data` for a relay, or a file URL for
streaming. A subtitle upload without `videoPath` attaches to whatever Kodi is
playing, library file or online stream. There is no in-memory video upload API.

Response models and transport values are `Sendable`. Client calls can be made
from a main-actor app, and actor-based relays can conform to `Transport`.

The models follow the current backend dictionaries rather than the old remote's
permissive coercions. Wire enums decode a value newer than the client as `other`;
the catalog leaves out a title it cannot decode, and a subtitle choice of a newer
kind reads as none. An error status without a string `detail` reads as a plain
sentence, never the server's JSON. Library directory sizes are absent; inactive player fields
default to zero/empty, and Kodi's empty current-stream objects become nil. Volume
and mute remain optional because Kodi's application properties can be null.
Request arguments are sent unchanged; validation and path policy belong to the
server. Stream quality defaults to `1080p`, matching `StreamIn`.

```sh
swift build
swift test
```

In an environment that prevents SwiftPM's nested sandbox, use
`swift build --disable-sandbox` and `swift test --disable-sandbox`.
