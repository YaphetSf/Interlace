import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    let store: InterlaceStore
    @State private var isImportingSubtitle = false
    @State private var subtitleTarget: LibraryItem?
    @State private var searchQuery = ""

    private var subtitleContentTypes: [UTType] {
        [
            UTType(filenameExtension: "srt"),
            UTType(filenameExtension: "ass"),
            UTType(filenameExtension: "vtt"),
            .text
        ].compactMap { $0 }
    }

    private var filteredItems: [LibraryItem] {
        if searchQuery.isEmpty {
            return store.library
        }
        return store.library.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
    }

    private let columns = [
        GridItem(.adaptive(minimum: 155, maximum: 240), spacing: 12)
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Top Search Bar
                searchBar
                
                ScrollView {
                    LazyVStack(spacing: 16) {
                        // Breadcrumbs & micro back arrow
                        LibraryPathRow(
                            libraryPath: store.libraryPath,
                            onRoot: { Task { await store.goToLibraryPath("") } },
                            onPath: { path in Task { await store.goToLibraryPath(path) } },
                            onUp: { Task { await store.goUpLibrary() } }
                        )
                        .equatable()
                        
                        if !store.uploads.isEmpty {
                            UploadsInlineView(uploads: store.uploads)
                        }
                        
                        // Media Content Grid
                        if store.isLoadingLibrary {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(0..<6, id: \.self) { _ in
                                    LibrarySkeletonCard()
                                }
                            }
                        } else if filteredItems.isEmpty {
                            VStack(spacing: 16) {
                                Spacer()
                                    .frame(height: 60)
                                Image(systemName: searchQuery.isEmpty ? "film.stack" : "magnifyingglass")
                                    .font(.system(size: 32))
                                    .foregroundStyle(Color(white: 0.25))
                            }
                        } else {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(filteredItems) { item in
                                    LibraryCard(
                                        item: item,
                                        baseURLText: store.baseURLText,
                                        onOpenDirectory: { Task { await store.openDirectory(item) } },
                                        onPlay: { Task { await store.play(item) } },
                                        onDelete: { Task { await store.deleteLibraryItem(item) } },
                                        onUploadSubtitle: {
                                            subtitleTarget = item
                                            isImportingSubtitle = true
                                        }
                                    )
                                    .equatable()
                                }
                            }
                        }
                    }
                    .padding(16)
                    Spacer()
                        .frame(height: 40)
                }
                .refreshable {
                    await store.refreshLibrary()
                }
            }
        }
        .fileImporter(
            isPresented: $isImportingSubtitle,
            allowedContentTypes: subtitleContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let target = subtitleTarget, let url = urls.first else { return }
                Task {
                    await store.uploadSubtitle(for: target, fileURL: url)
                }
            case .failure(let error):
                store.errorMessage = error.localizedDescription
            }
            subtitleTarget = nil
        }
    }

    private var searchBar: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(white: 0.4))
                
                TextField("Search library items...", text: $searchQuery)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color(white: 0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(white: 0.05))
            .clipShape(.rect(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(white: 0.16), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black)
            
            Divider()
                .background(Color(white: 0.16))
        }
    }
}

struct LibraryPathRow: View, Equatable {
    let libraryPath: String
    let onRoot: () -> Void
    let onPath: (String) -> Void
    let onUp: () -> Void

    static func == (lhs: LibraryPathRow, rhs: LibraryPathRow) -> Bool {
        lhs.libraryPath == rhs.libraryPath
    }

    private var pathParts: [String] {
        libraryPath.split(separator: "/").map(String.init)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Back Arrow micro pill button
            if !libraryPath.isEmpty {
                Button {
                    onUp()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(red: 0, green: 0.55, blue: 1))
                        .frame(width: 28, height: 28)
                        .background(Color(white: 0.08))
                        .clipShape(.rect(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(white: 0.16), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button {
                        onRoot()
                    } label: {
                        Text("Downloads")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(white: 0.08))
                            .foregroundStyle(Color(white: 0.8))
                            .clipShape(.rect(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(white: 0.16), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)

                    ForEach(Array(pathParts.enumerated()), id: \.offset) { index, part in
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(white: 0.3))

                        Button {
                            let path = pathParts.prefix(index + 1).joined(separator: "/")
                            onPath(path)
                        } label: {
                            Text(part)
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(white: 0.08))
                                .foregroundStyle(Color(white: 0.8))
                                .clipShape(.rect(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color(white: 0.16), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct LibraryCard: View, Equatable {
    let item: LibraryItem
    let baseURLText: String
    let onOpenDirectory: () -> Void
    let onPlay: () -> Void
    let onDelete: () -> Void
    let onUploadSubtitle: () -> Void

    static func == (lhs: LibraryCard, rhs: LibraryCard) -> Bool {
        lhs.item == rhs.item && lhs.baseURLText == rhs.baseURLText
    }

    private func videoURL(for item: LibraryItem) -> URL? {
        let base = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        
        var candidate = base
        if !candidate.contains("://") {
            candidate = "http://\(candidate)"
        }
        
        guard var components = URLComponents(string: candidate) else { return nil }
        components.query = nil
        
        let cleanedRel = item.rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/videos/\(cleanedRel)"
        
        return components.url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if item.isDirectory {
                // Folder Card
                Button {
                    onOpenDirectory()
                } label: {
                    VStack(spacing: 12) {
                        Spacer(minLength: 0)
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(red: 0, green: 0.45, blue: 0.9).opacity(0.1))
                                .frame(width: 50, height: 50)
                            
                            Image(systemName: "folder.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(Color(red: 0, green: 0.55, blue: 1))
                                .shadow(color: Color(red: 0, green: 0.55, blue: 1).opacity(0.4), radius: 3)
                        }
                        
                        Text(item.name)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                        
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 175)
                    .glossyGlassCard(cornerRadius: 16)
                }
                .buttonStyle(.plain)
            } else {
                // File Card
                VStack(alignment: .leading, spacing: 0) {
                    // Visual Upper Half (Dynamic Remote Video Thumbnail)
                    ZStack {
                        if let vURL = videoURL(for: item) {
                            VideoThumbnailView(videoURL: vURL)
                                .clipShape(.rect(cornerRadius: 10))
                        } else {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(white: 0.04))
                            
                            Image(systemName: "film")
                                .font(.system(size: 20))
                                .foregroundStyle(Color(white: 0.3))
                        }
                        
                        if item.size > 0 {
                            VStack {
                                Spacer()
                                HStack {
                                    Spacer()
                                    Text(formatBytes(item.size))
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color(white: 0.6))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color.black.opacity(0.6))
                                        .clipShape(.rect(cornerRadius: 4))
                                }
                                .padding(6)
                            }
                        }
                    }
                    .frame(height: 70)
                    .padding(.bottom, 8)
                    
                    // Title
                    Text(item.name)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .padding(.horizontal, 4)
                    
                    Spacer(minLength: 0)
                    
                    // Compact control deck (NO TEXT! Pure symbol micro keys)
                    HStack(spacing: 8) {
                        Button {
                            onPlay()
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(Color(red: 0, green: 0.55, blue: 1))
                                .clipShape(.rect(cornerRadius: 6))
                                .shadow(color: Color(red: 0, green: 0.55, blue: 1).opacity(0.3), radius: 3)
                        }
                        .buttonStyle(.plain)
                        
                        Button {
                            onUploadSubtitle()
                        } label: {
                            Image(systemName: "captions.bubble.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color(white: 0.8))
                                .frame(width: 28, height: 24)
                                .background(Color(white: 0.12))
                                .clipShape(.rect(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        
                        Button {
                            onDelete()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                                .frame(width: 28, height: 24)
                                .background(Color(white: 0.12))
                                .clipShape(.rect(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 2)
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .frame(height: 175)
                .glossyGlassCard(cornerRadius: 16)
            }
        }
    }
}

struct UploadsInlineView: View {
    let uploads: [UploadTask]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(uploads) { upload in
                HStack(spacing: 8) {
                    Image(systemName: iconName(for: upload.status))
                        .font(.system(size: 11))
                        .foregroundStyle(color(for: upload.status))

                    Text(upload.name)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Spacer()
                    
                    Text("\(Int(upload.progress))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(color(for: upload.status))
                }
                .padding(10)
                .background(Color(white: 0.08))
                .clipShape(.rect(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(white: 0.14), lineWidth: 1)
                )
            }
        }
    }

    private func iconName(for status: UploadTaskStatus) -> String {
        switch status {
        case .uploading:
            return "arrow.up.circle.fill"
        case .done:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    private func color(for status: UploadTaskStatus) -> Color {
        switch status {
        case .uploading:
            return Color(red: 0, green: 0.55, blue: 1)
        case .done:
            return .green
        case .error:
            return .red
        }
    }
}

struct LibrarySkeletonCard: View {
    @State private var breathing = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.05))
                .frame(height: 70)
            
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(white: 0.05))
                .frame(width: 100, height: 12)
            
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(white: 0.05))
                .frame(width: 60, height: 10)
            
            Spacer(minLength: 0)
            
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(white: 0.05))
                    .frame(height: 24)
                
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(white: 0.05))
                    .frame(width: 32, height: 24)
                
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(white: 0.05))
                    .frame(width: 32, height: 24)
            }
        }
        .padding(12)
        .frame(height: 175)
        .glossyGlassCard(cornerRadius: 16)
        .opacity(breathing ? 0.6 : 0.2)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }
}
