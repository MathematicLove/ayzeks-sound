import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import MediaPlayer
import UIKit

struct Track: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var localRelativePath: String
    var duration: Double
    var artworkURLString: String?
}

final class LibraryStore: ObservableObject {
    @Published var tracks: [Track] = [] { didSet { saveTracks() } }
    @Published var recentIDs: [UUID] = [] { didSet { saveRecents() } }

    private let tracksKey  = "tracks_v2"
    private let recentsKey = "recents_v1"
    private let recentsLimit = 20

    init() {
        loadTracks()
        loadRecents()
    }

    private func loadTracks() {
        guard let data = UserDefaults.standard.data(forKey: tracksKey) else { return }
        if let decoded = try? JSONDecoder().decode([Track].self, from: data) {
            tracks = decoded
        }
    }
    private func saveTracks() {
        if let data = try? JSONEncoder().encode(tracks) {
            UserDefaults.standard.set(data, forKey: tracksKey)
        }
    }
 
    private func loadRecents() {
        guard let data = UserDefaults.standard.data(forKey: recentsKey) else { return }
        if let decoded = try? JSONDecoder().decode([UUID].self, from: data) {
            recentIDs = decoded
        }
    }
    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recentIDs) {
            UserDefaults.standard.set(data, forKey: recentsKey)
        }
    }
 
    func addToRecents(_ track: Track) {
        recentIDs.removeAll { $0 == track.id }
        recentIDs.insert(track.id, at: 0)
        if recentIDs.count > recentsLimit {
            recentIDs.removeLast(recentIDs.count - recentsLimit)
        }
    }
    var recentTracks: [Track] {
        recentIDs.compactMap { id in tracks.first(where: { $0.id == id }) }
    }
    func clearRecents() {
        recentIDs.removeAll()
    }

    private func libraryDir() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Imported", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func absoluteURL(for track: Track) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent(track.localRelativePath)
    }

    func add(urls: [URL]) {
        let destDir = libraryDir()
        for srcURL in urls {
            let accessed = srcURL.startAccessingSecurityScopedResource()
            defer { if accessed { srcURL.stopAccessingSecurityScopedResource() } }

            let base = srcURL.deletingPathExtension().lastPathComponent
            let ext  = srcURL.pathExtension.isEmpty ? "mp3" : srcURL.pathExtension

            var dest = destDir.appendingPathComponent("\(base).\(ext)")
            var n = 1
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = destDir.appendingPathComponent("\(base) (\(n)).\(ext)")
                n += 1
            }

            do {
                _ = try? FileManager.default.startDownloadingUbiquitousItem(at: srcURL)
                try FileManager.default.copyItem(at: srcURL, to: dest)
                let asset = AVURLAsset(url: dest)
                let secs = CMTimeGetSeconds(asset.duration)
                let title = dest.deletingPathExtension().lastPathComponent
                let relPath = "Imported/\(dest.lastPathComponent)"
                let t = Track(title: title, localRelativePath: relPath, duration: secs, artworkURLString: nil)
                if !tracks.contains(where: { $0.localRelativePath == t.localRelativePath }) {
                    tracks.append(t)
                }
            } catch {
                print("Copy error: \(error)")
            }
        }
    }

    func remove(at offsets: IndexSet) {
        let items = offsets.map { tracks[$0] }
        for t in items {
            try? FileManager.default.removeItem(at: absoluteURL(for: t))
            recentIDs.removeAll { $0 == t.id }
        }
        tracks.remove(atOffsets: offsets)
    }
    
    func track(after currentTrack: Track) -> Track? {
        guard let currentIndex = tracks.firstIndex(where: { $0.id == currentTrack.id }) else {
            return nil
        }
        let nextIndex = tracks.index(after: currentIndex)
        return nextIndex < tracks.count ? tracks[nextIndex] : tracks.first
    }
}
 
final class AudioEnginePlayer: ObservableObject {
    enum State { case idle, loaded, playing, paused }
    enum RepeatMode { case none, single, all }

    @Published var currentTrack: Track?
    @Published private(set) var state: State = .idle
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var globalGainDB: Float = 0 {
        didSet { eq.globalGain = max(-24, min(24, globalGainDB)) }
    }
    @Published var repeatMode: RepeatMode = .none
    @Published var autoPlayNext: Bool = true

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 0)

    private var audioFile: AVAudioFile?
    private var timer: Timer?
    private var fileSampleRate: Double = 44100
    private var totalFrames: AVAudioFramePosition = 0
    private var startFrame: AVAudioFramePosition = 0
 
    private var nowPlayingInfo: [String: Any] = [:]
    private var artworkImage: UIImage?
 
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        setupSession()
        setupEngine()
        setupTimer()
        setupRemoteCommands()
        observeAudioSession()
        observeAppLifecycle()
    }

    deinit { timer?.invalidate() }
 
    private func setupSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            print("AudioSession error: \(error)")
        }
    }

    private func setupEngine() {
        engine.attach(playerNode)
        engine.attach(eq)
        engine.connect(playerNode, to: eq, format: nil)
        engine.connect(eq, to: engine.mainMixerNode, format: nil)
        engine.prepare()
        do { try engine.start() } catch { print("Engine start error: \(error)") }
    }

    private func restartEngineIfNeeded() {
        if !engine.isRunning {
            do { try engine.start() } catch { print("Engine restart error: \(error)") }
        }
    }

    private func setupTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self = self, self.state == .playing,
                  let nodeTime = self.playerNode.lastRenderTime,
                  let pTime = self.playerNode.playerTime(forNodeTime: nodeTime) else { return }
            let currentFrame = self.startFrame + AVAudioFramePosition(pTime.sampleTime)
            self.currentTime = min(Double(currentFrame) / self.fileSampleRate, self.duration)
            self.nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = self.currentTime
            MPNowPlayingInfoCenter.default().nowPlayingInfo = self.nowPlayingInfo
            if self.currentTime >= self.duration {
                self.trackDidFinish()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    
    private func trackDidFinish() {
        switch repeatMode {
        case .single:
            seek(to: 0)
            play()
        case .all, .none:
            if autoPlayNext || repeatMode == .all, let nextTrack = nextTrackProvider?() {
                load(track: nextTrack, library: libraryProvider?())
                play()
            } else {
                stop()
            }
        }
    }
 
    func load(track: Track, library: LibraryStore?) {
        stop()
        currentTrack = track
        guard let library = library else { return }
        let url = library.absoluteURL(for: track)
        do {
            let file = try AVAudioFile(forReading: url)
            audioFile = file
            fileSampleRate = file.processingFormat.sampleRate
            totalFrames = file.length
            duration = Double(totalFrames) / fileSampleRate
            currentTime = 0
            startFrame = 0
            schedule(from: 0)
            state = .loaded

            library.addToRecents(track)
            updateNowPlayingInfo(forceArtworkReload: true)
        } catch {
            print("AudioFile error: \(error)")
        }
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let file = audioFile else { return }
        let framesCount = AVAudioFrameCount(max(0, totalFrames - frame))
        startFrame = frame
        playerNode.stop()
        playerNode.scheduleSegment(file, startingFrame: frame, frameCount: framesCount, at: nil, completionHandler: nil)
    }

    func play() {
        guard state == .loaded || state == .paused else { return }
        restartEngineIfNeeded()
        if !playerNode.isPlaying { playerNode.play() }
        state = .playing
        updateNowPlayingInfo()
        beginBackgroundTaskIfNeeded()
    }

    func pause() {
        guard playerNode.isPlaying else { return }
        playerNode.pause()
        state = .paused
        updateNowPlayingInfo()
        endBackgroundTaskIfPossible()
    }

    func stop() {
        if playerNode.isPlaying { playerNode.stop() }
        currentTime = 0
        state = .idle
        clearNowPlaying()
        endBackgroundTaskIfPossible()
    }

    func seek(to seconds: Double) {
        guard duration > 0 else { return }
        let clamped = max(0, min(seconds, duration))
        let targetFrame = AVAudioFramePosition(clamped * fileSampleRate)
        schedule(from: targetFrame)
        if state == .playing { playerNode.play() }
        currentTime = clamped
        updateNowPlayingInfo()
    }
 
    var nextTrackProvider: (() -> Track?)?
    var libraryProvider: (() -> LibraryStore?)?

    // MARK: Now Playing + Remote Commands
    private func setupRemoteCommands() {
        UIApplication.shared.beginReceivingRemoteControlEvents()
        let r = MPRemoteCommandCenter.shared()
        r.playCommand.isEnabled = true
        r.pauseCommand.isEnabled = true
        r.togglePlayPauseCommand.isEnabled = true

        r.playCommand.addTarget { [weak self] _ in
            self?.play(); return .success
        }
        r.pauseCommand.addTarget { [weak self] _ in
            self?.pause(); return .success
        }
        r.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            (self.state == .playing) ? self.pause() : self.play()
            return .success
        }

        if #available(iOS 9.1, *) {
            r.changePlaybackPositionCommand.isEnabled = true
            r.changePlaybackPositionCommand.addTarget { [weak self] event in
                guard let self = self,
                      let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
                self.seek(to: e.positionTime)
                return .success
            }
        }
    }

    func updateNowPlayingInfo(forceArtworkReload: Bool = false) {
        guard let track = currentTrack else { return }

        nowPlayingInfo[MPMediaItemPropertyTitle] = track.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = "Local File"
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = (state == .playing ? 1.0 : 0.0)

        if forceArtworkReload { artworkImage = nil }
        if artworkImage == nil, let s = track.artworkURLString, let url = URL(string: s) {
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let self = self, let data = data, let img = UIImage(data: data) else { return }
                DispatchQueue.main.async {
                    self.artworkImage = img
                    self.applyNowPlayingInfo()
                }
            }.resume()
        }
        applyNowPlayingInfo()
    }

    private func applyNowPlayingInfo() {
        if let img = artworkImage {
            let artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
 
    private func observeAudioSession() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleInterruption(_:)), name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
        nc.addObserver(self, selector: #selector(handleRouteChange(_:)), name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance())
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            if state == .playing { playerNode.pause(); state = .paused; updateNowPlayingInfo() }
        case .ended:
            let optsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt
            let shouldResume = optsValue.map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
            do { try AVAudioSession.sharedInstance().setActive(true) } catch {}
            restartEngineIfNeeded()
            if shouldResume && state == .paused {
                playerNode.play()
                state = .playing
                updateNowPlayingInfo()
            }
        @unknown default: break
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        restartEngineIfNeeded()
    }
 
    private func observeAppLifecycle() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @objc private func appDidEnterBackground() {
        if state == .playing {
            beginBackgroundTaskIfNeeded()
            do { try AVAudioSession.sharedInstance().setActive(true, options: []) } catch {}
            restartEngineIfNeeded()
        }
    }

    @objc private func appWillEnterForeground() {
        endBackgroundTaskIfPossible()
        restartEngineIfNeeded()
    }

    private func beginBackgroundTaskIfNeeded() {
        if bgTask == .invalid {
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "AudioPlayback") { [weak self] in
                self?.endBackgroundTaskIfPossible()
            }
        }
    }

    private func endBackgroundTaskIfPossible() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }
}
 
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var library = LibraryStore()
    @StateObject private var player = AudioEnginePlayer()
    @State private var showingImporter = false
    @State private var search = ""
    @State private var showingArtworkURLSheet = false
    @State private var artworkURLDraft = ""

    var filteredTracks: [Track] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return q.isEmpty ? library.tracks : library.tracks.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
 
                HStack {
                    TextField("Поиск по трекам", text: $search)
                        .textFieldStyle(.roundedBorder)
                    Button { showingImporter = true } label: {
                        Label("Добавить MP3", systemImage: "plus")
                    }
                }
                .padding()

                List {
                    if !library.recentTracks.isEmpty {
                        Section(header: Text("Недавно проигрывали")) {
                            ForEach(library.recentTracks) { track in
                                TrackRow(track: track,
                                         isPlaying: player.currentTrack?.id == track.id && player.state == .playing)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    player.load(track: track, library: library)
                                    player.play()
                                    artworkURLDraft = track.artworkURLString ?? ""
                                }
                            }
                            .onDelete { idx in
                                for i in idx {
                                    let t = library.recentTracks[i]
                                    library.recentIDs.removeAll { $0 == t.id }
                                }
                            }
                            Button(role: .destructive) {
                                library.clearRecents()
                            } label: {
                                Label("Очистить недавние", systemImage: "trash")
                            }
                        }
                    }
 
                    Section(header: Text("Все треки")) {
                        ForEach(filteredTracks) { track in
                            TrackRow(track: track,
                                     isPlaying: player.currentTrack?.id == track.id && player.state == .playing)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                player.load(track: track, library: library)
                                player.play()
                                artworkURLDraft = track.artworkURLString ?? ""
                            }
                            .contextMenu {
                                Button(role: .destructive) { delete(track: track) } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                        }
                        .onDelete(perform: library.remove)
                    }
                }
 
                PlayerPane(player: player, library: library, showingArtworkURLSheet: $showingArtworkURLSheet)
                    .padding(.horizontal)
            }
            .navigationTitle("Ayzek's Sound")
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.mp3, .audio],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls): library.add(urls: urls)
                case .failure(let error): print("Importer error: \(error)")
                }
            }
            .sheet(isPresented: $showingArtworkURLSheet) {
                ArtworkURLSheet(artworkURLDraft: $artworkURLDraft, player: player, library: library)
            }
            .onAppear {
                player.nextTrackProvider = { [weak library, weak player] in
                    guard let currentTrack = player?.currentTrack,
                          let nextTrack = library?.track(after: currentTrack) else {
                        return nil
                    }
                    return nextTrack
                }
                player.libraryProvider = { [weak library] in
                    return library
                }
            }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                do { try AVAudioSession.sharedInstance().setActive(true, options: []) } catch {}
            }
        }
    }

    private func delete(track: Track) {
        if let idx = library.tracks.firstIndex(where: { $0.id == track.id }) {
            library.tracks.remove(at: idx)
        }
    }
}
 
struct TrackRow: View {
    let track: Track
    let isPlaying: Bool

    var body: some View {
        HStack {
            ArtworkView(urlString: track.artworkURLString)
                .frame(width: 48, height: 48)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            VStack(alignment: .leading) {
                Text(track.title).font(.headline)
                Text(timeString(track.duration))
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if isPlaying {
                Image(systemName: "speaker.wave.2.fill").foregroundColor(.accentColor)
            }
        }
    }
}
 
struct PlayerPane: View {
    @ObservedObject var player: AudioEnginePlayer
    @ObservedObject var library: LibraryStore
    @Binding var showingArtworkURLSheet: Bool

    var body: some View {
        VStack(spacing: 12) {
            Divider()
 
            HStack(alignment: .center, spacing: 12) {
                ArtworkView(urlString: player.currentTrack?.artworkURLString)
                    .frame(width: 50, height: 50)
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))

                VStack(alignment: .leading, spacing: 4) {
                    Text(player.currentTrack?.title ?? "Ничего не выбрано")
                        .font(.subheadline)
                        .lineLimit(1)
                    Text("\(timeString(player.currentTime)) / \(timeString(player.duration))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: togglePlay) {
                    Image(systemName: player.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                }
                .disabled(player.currentTrack == nil)
                
                Button(action: { showingArtworkURLSheet = true }) {
                    Image(systemName: "plus.circle")
                        .font(.title2)
                }
                .disabled(player.currentTrack == nil)
            }
 
            Slider(value: Binding(
                get: { player.currentTime },
                set: { player.seek(to: $0) }
            ), in: 0...(max(player.duration, 0.0001)))
 
            HStack(spacing: 16) {
                Button(action: { player.repeatMode = player.repeatMode == .single ? .none : .single }) {
                    Image(systemName: player.repeatMode == .single ? "repeat.1.circle.fill" : "repeat.1.circle")
                        .foregroundColor(player.repeatMode == .single ? .accentColor : .primary)
                }
                
                Button(action: { player.repeatMode = player.repeatMode == .all ? .none : .all }) {
                    Image(systemName: player.repeatMode == .all ? "repeat.circle.fill" : "repeat.circle")
                        .foregroundColor(player.repeatMode == .all ? .accentColor : .primary)
                }
                
                Spacer()
                
                Text("Автопродолжение")
                    .font(.caption)
                
                Toggle("", isOn: $player.autoPlayNext)
                    .labelsHidden()
            }
            .font(.title3)
 
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Громкость")
                        .font(.caption)
                    Spacer()
                    Text(String(format: "%.1f дБ", player.globalGainDB))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Slider(value: Binding(
                    get: { Double(player.globalGainDB) },
                    set: { player.globalGainDB = Float($0) }
                ), in: -24...24, step: 0.1)
            }
        }
        .padding(.vertical, 8)
    }

    private func togglePlay() {
        switch player.state {
        case .playing: player.pause()
        case .paused, .loaded: player.play()
        default: break
        }
    }
}
 
struct ArtworkURLSheet: View {
    @Binding var artworkURLDraft: String
    @ObservedObject var player: AudioEnginePlayer
    @ObservedObject var library: LibraryStore
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("URL изображения альбома")) {
                    TextField("https://…", text: $artworkURLDraft)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .disableAutocorrection(true)
                }
            }
            .navigationTitle("Обложка альбома")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Отмена") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Сохранить") {
                        saveArtworkURL()
                        dismiss()
                    }
                    .disabled(player.currentTrack == nil || URL(string: artworkURLDraft) == nil)
                }
            }
        }
    }

    private func saveArtworkURL() {
        guard var current = player.currentTrack else { return }
        let trimmed = artworkURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        current.artworkURLString = trimmed.isEmpty ? nil : trimmed
         
        if let idx = library.tracks.firstIndex(where: { $0.id == current.id }) {
            library.tracks[idx] = current
            player.currentTrack = current
            player.updateNowPlayingInfo(forceArtworkReload: true)
        }
    }
}
 
struct ArtworkView: View {
    let urlString: String?
    var body: some View {
        if let s = urlString, let url = URL(string: s) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty: ProgressView()
                case .success(let image): image.resizable().scaledToFill()
                case .failure: placeholder
                @unknown default: placeholder
                }
            }
        } else {
            placeholder
        }
    }
    private var placeholder: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.08))
            Image(systemName: "music.note")
                .imageScale(.large)
                .foregroundColor(.secondary)
        }
    }
}
 
@main
struct PlayerApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
 
func timeString(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "--:--" }
    let total = max(0, Int(seconds.rounded()))
    let m = total / 60
    let s = total % 60
    return String(format: "%02d:%02d", m, s)
}

extension UTType {
    static var mp3: UTType { UTType(filenameExtension: "mp3") ?? .audio }
}
