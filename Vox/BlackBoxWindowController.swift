import Cocoa
import AVFoundation

/// "Black Box" — disaster recovery for voice recordings.
/// Shows the last 5 audio backups with playback and reprocess options.
class BlackBoxWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    private var window: NSWindow!
    private var tableView: NSTableView!
    private var backups: [AudioService.Backup] = []
    private var emptyLabel: NSTextField!
    private var audioPlayer: AVAudioPlayer?
    private var playingRow: Int = -1

    // MARK: - Show

    func show() {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        backups = AudioService.shared.getBackups()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 340),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Black Box"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 240)

        let root = window.contentView!

        // Header
        let header = NSTextField(labelWithString: "Recent recordings (last 5)")
        header.font = .systemFont(ofSize: 12, weight: .medium)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
        ])

        // Table
        tableView = NSTableView()
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.headerView = nil
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.dataSource = self
        tableView.delegate = self

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.title = ""
        tableView.addTableColumn(col)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        // Empty state
        emptyLabel = NSTextField(labelWithString: "No recordings saved yet.\nBackups appear here automatically.")
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = !backups.isEmpty
        root.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Actions

    @objc private func playAudio(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0 && row < backups.count else { return }

        // If already playing this row, stop
        if playingRow == row, let player = audioPlayer, player.isPlaying {
            player.stop()
            audioPlayer = nil
            playingRow = -1
            updatePlayButton(sender, playing: false)
            return
        }

        // Stop any previous playback
        audioPlayer?.stop()
        audioPlayer = nil
        if playingRow >= 0 {
            // Reset previous play button (find it in table)
            tableView.reloadData()
        }

        do {
            audioPlayer = try AVAudioPlayer(contentsOf: backups[row].url)
            audioPlayer?.play()
            playingRow = row
            updatePlayButton(sender, playing: true)

            // Auto-reset when done
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(backups[row].durationSeconds) + 0.5) { [weak self] in
                if self?.playingRow == row {
                    self?.playingRow = -1
                    self?.tableView.reloadData()
                }
            }
        } catch {
            NSLog("Vox: Playback failed: \(error)")
        }
    }

    private func updatePlayButton(_ button: NSButton, playing: Bool) {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let symbol = playing ? "stop.circle.fill" : "play.circle.fill"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        button.contentTintColor = playing ? .systemRed : .systemBlue
    }

    @objc private func reprocessAudio(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0 && row < backups.count else { return }

        let backup = backups[row]

        // Visual feedback
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let origImage = sender.image
        let origTint = sender.contentTintColor
        sender.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        sender.contentTintColor = .systemOrange
        sender.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async {
            let appContext = ContextService.shared.detect()
            let contextHint = ContextService.shared.contextHint(for: appContext)
            let isTranslate = AppDelegate.shared.translateMode

            NSLog("Vox: Black Box reprocessing \(backup.url.lastPathComponent)")
            let rawText = STTService.shared.transcribe(audioFile: backup.url)

            guard !rawText.isEmpty else {
                DispatchQueue.main.async {
                    sender.image = origImage
                    sender.contentTintColor = origTint
                    sender.isEnabled = true
                    AppDelegate.showNotification(title: "Black Box", message: "Could not recognize speech from this recording.")
                }
                return
            }

            let cleanText = LLMService.shared.process(rawText: rawText, contextHint: contextHint, translateMode: isTranslate)
            let finalText = cleanText.isEmpty ? rawText : cleanText

            DispatchQueue.main.async {
                PasteService.shared.paste(text: finalText)

                // Save to history
                if isTranslate {
                    HistoryManager.shared.addRecord(text: finalText, originalText: rawText, isTranslation: true)
                } else {
                    HistoryManager.shared.addRecord(text: finalText)
                }

                // Success feedback
                sender.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config)
                sender.contentTintColor = .systemGreen
                NSSound(named: "Glass")?.play()

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    sender.image = origImage
                    sender.contentTintColor = origTint
                    sender.isEnabled = true
                }
            }
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        backups.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        56
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        makeBackupRow(backup: backups[row], row: row)
    }

    // MARK: - Row View

    private func makeBackupRow(backup: AudioService.Backup, row: Int) -> NSView {
        let cell = HoverableRowView()
        cell.wantsLayer = true

        // Time ago label
        let timeAgo = relativeTime(from: backup.timestamp)
        let timeLabel = NSTextField(labelWithString: timeAgo)
        timeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(timeLabel)

        // Duration label
        let durStr = formatDuration(backup.durationSeconds)
        let durLabel = NSTextField(labelWithString: durStr)
        durLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .light)
        durLabel.textColor = .labelColor
        durLabel.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(durLabel)

        // Play button
        let playBtn = NSButton(frame: .zero)
        playBtn.isBordered = false
        playBtn.tag = row
        playBtn.target = self
        playBtn.action = #selector(playAudio(_:))
        playBtn.translatesAutoresizingMaskIntoConstraints = false
        let isPlaying = playingRow == row
        updatePlayButton(playBtn, playing: isPlaying)
        cell.addSubview(playBtn)

        // Reprocess button
        let reBtn = NSButton(frame: .zero)
        reBtn.isBordered = false
        reBtn.tag = row
        reBtn.target = self
        reBtn.action = #selector(reprocessAudio(_:))
        reBtn.translatesAutoresizingMaskIntoConstraints = false
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        reBtn.image = NSImage(systemSymbolName: "arrow.clockwise.circle.fill", accessibilityDescription: "Reprocess")?.withSymbolConfiguration(config)
        reBtn.contentTintColor = .systemOrange
        reBtn.imagePosition = .imageOnly
        reBtn.toolTip = "Reprocess & paste"
        cell.addSubview(reBtn)

        // Separator
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(sep)

        NSLayoutConstraint.activate([
            // Duration (left, big)
            durLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
            durLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor, constant: -2),

            // Time ago (below duration or beside)
            timeLabel.leadingAnchor.constraint(equalTo: durLabel.trailingAnchor, constant: 10),
            timeLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

            // Reprocess button (right)
            reBtn.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -16),
            reBtn.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            reBtn.widthAnchor.constraint(equalToConstant: 28),
            reBtn.heightAnchor.constraint(equalToConstant: 28),

            // Play button
            playBtn.trailingAnchor.constraint(equalTo: reBtn.leadingAnchor, constant: -8),
            playBtn.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            playBtn.widthAnchor.constraint(equalToConstant: 28),
            playBtn.heightAnchor.constraint(equalToConstant: 28),

            // Separator
            sep.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
            sep.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
        ])

        return cell
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        } else {
            let m = seconds / 60
            let s = seconds % 60
            return "\(m)m \(s)s"
        }
    }

    private func relativeTime(from date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f.string(from: date)
    }

    // MARK: - Window Delegate

    func windowWillClose(_ notification: Notification) {
        audioPlayer?.stop()
        audioPlayer = nil
        playingRow = -1
    }
}
