//
//  MediaPlaybackController.swift
//  Hex
//

import AppKit // For NSEvent media key simulation
import Foundation
import HexCore

private let mediaLogger = HexLog.media

/// Pauses whatever is playing when a recording starts and resumes it when the recording ends.
///
/// Pauses and resumes run one at a time, in the order they were requested. A quick
/// stop-then-start therefore can't resume media after the next recording paused it, and a stop
/// that arrives while a pause is still in flight waits for it and undoes exactly what it did.
///
/// Queuing is synchronous so the caller can record the pending pause without suspending; the
/// owner (`RecordingClientLive`, an actor) provides the isolation.
final class MediaPlaybackController {
  /// What a pause actually did, so the matching resume can undo exactly that.
  enum PauseOutcome: Sendable, Equatable {
    case nothingPaused
    case mediaRemote
    case mediaKey
    case players([String])
  }

  private var tail: Task<Void, Never>?

  /// Queues a pause. Hand the returned task to `resume(after:)` once the recording ends.
  func pause() -> Task<PauseOutcome, Never> {
    let previous = tail
    let pause = Task { () -> PauseOutcome in
      await previous?.value
      return await Self.performPause()
    }
    tail = Task { _ = await pause.value }
    return pause
  }

  /// Queues the resume for an earlier pause. Returns without waiting for it to run.
  func resume(after pause: Task<PauseOutcome, Never>) {
    let previous = tail
    tail = Task {
      await previous?.value
      await Self.performResume(pause.value)
    }
  }

  private static func performPause() async -> PauseOutcome {
    switch await NowPlaying.isPlaying() {
    case false?:
      return .nothingPaused
    case true?:
      if MediaRemote.send(.pause) {
        mediaLogger.notice("Paused media via MediaRemote")
        return .mediaRemote
      }
      await MainActor.run { sendMediaKey() }
      mediaLogger.notice("Paused media via media key")
      return .mediaKey
    case nil:
      // Playback state is unknown, so only touch players that can report their own state.
      let players = await pauseScriptablePlayers()
      return players.isEmpty ? .nothingPaused : .players(players)
    }
  }

  private static func performResume(_ outcome: PauseOutcome) async {
    switch outcome {
    case .nothingPaused:
      return
    case let .players(players):
      mediaLogger.notice("Resuming players: \(players.joined(separator: ", "))")
      await resumeScriptablePlayers(players)
    case .mediaRemote, .mediaKey:
      // Play is a no-op when media is already playing, so it goes out without first checking
      // state; that check would add a perl launch to the delay before music returns.
      if outcome == .mediaRemote, MediaRemote.send(.play) {
        mediaLogger.notice("Resumed media via MediaRemote")
        return
      }
      // The media key toggles instead, which would pause media the user restarted mid-recording.
      if await NowPlaying.isPlaying() == true {
        mediaLogger.notice("Media is already playing; skipping resume")
        return
      }
      await MainActor.run { sendMediaKey() }
      mediaLogger.notice("Resumed media via media key")
    }
  }
}

// MARK: - Now playing state

/// Reads whether the system's now-playing app is playing.
///
/// Since macOS 15.4, MediaRemote only reports playback state to Apple-signed clients; for
/// other apps `MRMediaRemoteGetNowPlayingApplicationIsPlaying` always answers false. The
/// system perl is Apple-signed, so the query runs there through its Objective-C bridge.
/// Sending commands is not restricted, so `MediaRemote.send` still works in-process.
private enum NowPlaying {
  private static let perlScript = """
  use Foundation;
  my $bundle = NSBundle->bundleWithPath_("/System/Library/PrivateFrameworks/MediaRemote.framework");
  exit 2 unless $bundle && $bundle->load;
  my $class = $bundle->classNamed_("MRNowPlayingRequest");
  exit 2 unless $class && $$class;
  @MRNowPlayingRequest::ISA = ("PerlObjCBridge");
  print(MRNowPlayingRequest->localIsPlaying ? "1" : "0");
  """

  /// `nil` when the playback state could not be determined.
  static func isPlaying() async -> Bool? {
    if let isPlaying = await queryViaPerl() {
      return isPlaying
    }
    if #unavailable(macOS 15.4) {
      return await MediaRemote.isPlaying()
    }
    return nil
  }

  private static func queryViaPerl() async -> Bool? {
    await Task.detached(priority: .userInitiated) { () -> Bool? in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
      process.arguments = ["-e", perlScript]
      let output = Pipe()
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice

      do {
        try process.run()
      } catch {
        mediaLogger.error("Failed to launch now-playing query: \(error.localizedDescription)")
        return nil
      }

      let timeout = DispatchWorkItem {
        if process.isRunning { process.terminate() }
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + 1.5, execute: timeout)
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      timeout.cancel()

      guard process.terminationStatus == 0 else {
        mediaLogger.error("Now-playing query exited with status \(process.terminationStatus)")
        return nil
      }
      switch String(decoding: data, as: UTF8.self) {
      case "1": return true
      case "0": return false
      default: return nil
      }
    }.value
  }
}

// MARK: - MediaRemote

private enum MediaRemoteCommand: Int32 {
  case play = 0
  case pause = 1
}

private enum MediaRemote {
  private typealias IsPlayingFunc = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
  private typealias SendCommandFunc = @convention(c) (Int32, CFDictionary?) -> Bool

  private static let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)

  private static let isPlayingFunc: IsPlayingFunc? = handle
    .flatMap { dlsym($0, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") }
    .map { unsafeBitCast($0, to: IsPlayingFunc.self) }

  private static let sendCommandFunc: SendCommandFunc? = handle
    .flatMap { dlsym($0, "MRMediaRemoteSendCommand") }
    .map { unsafeBitCast($0, to: SendCommandFunc.self) }

  /// Only trustworthy before macOS 15.4; see `NowPlaying`.
  static func isPlaying() async -> Bool? {
    guard let isPlayingFunc else { return nil }
    return await withCheckedContinuation { continuation in
      isPlayingFunc(DispatchQueue.main) { continuation.resume(returning: $0) }
    }
  }

  static func send(_ command: MediaRemoteCommand) -> Bool {
    guard let sendCommandFunc else {
      mediaLogger.error("MediaRemote is unavailable")
      return false
    }
    return sendCommandFunc(command.rawValue, nil)
  }
}

// MARK: - Media key

/// Simulates a media key press (the Play/Pause key) by posting a system-defined NSEvent.
/// This toggles the state of the active media app.
@MainActor
private func sendMediaKey() {
  let NX_KEYTYPE_PLAY: UInt32 = 16
  func postKeyEvent(down: Bool) {
    let flags: NSEvent.ModifierFlags = down ? .init(rawValue: 0xA00) : .init(rawValue: 0xB00)
    let data1 = Int((NX_KEYTYPE_PLAY << 16) | (down ? 0xA << 8 : 0xB << 8))
    if let event = NSEvent.otherEvent(with: .systemDefined,
                                      location: .zero,
                                      modifierFlags: flags,
                                      timestamp: 0,
                                      windowNumber: 0,
                                      context: nil,
                                      subtype: 8,
                                      data1: data1,
                                      data2: -1)
    {
      event.cgEvent?.post(tap: .cghidEventTap)
    }
  }
  postKeyEvent(down: true)
  postKeyEvent(down: false)
}

// MARK: - Scriptable players

/// Check if an application is installed by looking for its bundle
private func isAppInstalled(bundleID: String) -> Bool {
  NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
}

/// Installed players that report their own state over AppleScript (computed once at first access)
private let installedScriptablePlayers: [String] = [
  ("Music", "com.apple.Music"),
  ("iTunes", "com.apple.iTunes"),
  ("Spotify", "com.spotify.client"),
  ("VLC", "org.videolan.vlc"),
].filter { isAppInstalled(bundleID: $0.1) }.map(\.0)

// Backoff to avoid spamming AppleScript errors on systems without controllable players
@MainActor private var scriptErrorCount = 0

/// NSAppleScript is not thread-safe, so every script runs on the main actor.
@MainActor
private func pauseScriptablePlayers() -> [String] {
  guard scriptErrorCount < 3, !installedScriptablePlayers.isEmpty else { return [] }

  var scriptParts: [String] = ["set pausedPlayers to {}"]
  for appName in installedScriptablePlayers {
    // VLC exposes `playing`; Music, iTunes and Spotify expose `player state`.
    let isPlayingCondition = appName == "VLC" ? "playing" : "player state is playing"
    scriptParts.append("""
    try
      if application \"\(appName)\" is running then
        tell application \"\(appName)\"
          if \(isPlayingCondition) then
            pause
            set end of pausedPlayers to \"\(appName)\"
          end if
        end tell
      end if
    end try
    """)
  }
  scriptParts.append("return pausedPlayers")

  var error: NSDictionary?
  guard let result = NSAppleScript(source: scriptParts.joined(separator: "\n\n"))?.executeAndReturnError(&error) else {
    if let error {
      mediaLogger.error("Failed to pause media apps: \(error)")
      scriptErrorCount += 1
    }
    return []
  }

  let pausedPlayers = (0..<result.numberOfItems).compactMap { result.atIndex($0 + 1)?.stringValue }
  if !pausedPlayers.isEmpty {
    mediaLogger.notice("Paused media players: \(pausedPlayers.joined(separator: ", "))")
  }
  return pausedPlayers
}

@MainActor
private func resumeScriptablePlayers(_ players: [String]) {
  let script = players
    .filter(installedScriptablePlayers.contains)
    .map { player in
      """
      try
        if application \"\(player)\" is running then
          tell application \"\(player)\" to play
        end if
      end try
      """
    }
    .joined(separator: "\n\n")
  guard !script.isEmpty else { return }

  var error: NSDictionary?
  NSAppleScript(source: script)?.executeAndReturnError(&error)
  if let error {
    mediaLogger.error("Failed to resume media apps: \(error)")
  }
}
