# InterlaceClient

Interlace's `/api` contract for iOS, macOS, and watchOS. Requires Swift 6 and OS 26.

```swift
import InterlaceClient

let client = InterlaceClient {
    // Read the app's current configuration on every request.
    InterlaceEndpoint(url: serverURL, person: "ding")
}
let library = try await client.library(path: "Series")
try await client.play(path: library.items[0].path)
```

The endpoint URL is the server root, optionally including a reverse proxy's base
path, without `/api`. The endpoint closure is `@Sendable`; the app owns its
synchronization. A nil endpoint or an empty person throws `InterlaceError.notConfigured`.
Every HTTP request carries `X-Person: <person>`.

For the watch, implement `Transport.perform(_:)` and initialize
`InterlaceClient(transport: relay)`. Put `JSONEncoder().encode(request)` in a
WatchConnectivity message dictionary as `Data`. On the phone, decode the request,
call its `HTTPTransport.perform(_:)`, and send the encoded `InterlaceResponse`
back. Requests contain no endpoint or credentials; the phone supplies its own.
Transports return non-2xx statuses unchanged; the client maps them to typed errors.

`upload(fileURL:to:fileName:)` requires `FileUploadTransport`, which `HTTPTransport`
implements. HTTP uploads copy multipart headers, file chunks, and the closing
boundary into a temporary disk file, then use URLSession's file upload API.
Memory use is bounded by the copy buffer; the temporary file is removed on
completion, failure, or cancellation. Disk space for the multipart copy is needed.
Torrent and subtitle uploads also accept `Data` for a relay, or a file URL for
streaming. There is no in-memory video upload API.

Response models and transport values are `Sendable`. Client calls can be made
from a main-actor app, and actor-based relays can conform to `Transport`.

The models follow the current backend dictionaries rather than the old remote's
permissive coercions. Library directory sizes are absent; inactive player fields
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
