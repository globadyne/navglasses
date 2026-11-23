//
// BridgeClient.swift
//
// Live connection to tz_bridge.py on the nav PC: ws://<pc-address>:8080/ws.
// Reconnects on its own if the PC, WiFi or bridge drops out.
//

import Foundation
import Observation

@Observable
@MainActor
final class BridgeClient {
  enum Status: Equatable {
    case off, connecting, live, noData, failed(String)

    var text: String {
      switch self {
      case .off: "Off"
      case .connecting: "Connecting…"
      case .live: "Live"
      case .noData: "Connected, TimeZero not sending"
      case .failed(let reason): reason
      }
    }
  }

  private(set) var snapshot: BoatSnapshot?
  private(set) var status: Status = .off
  private(set) var lastMessageAt: Date?
  private(set) var address = ""

  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var socket: URLSessionWebSocketTask?
  @ObservationIgnored private let session: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 10
    config.waitsForConnectivity = false
    return URLSession(configuration: config)
  }()

  /// Accepts "192.168.1.20", "192.168.1.20:8080" or "ws://…/ws".
  static func url(for address: String) -> URL? {
    var a = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !a.isEmpty else { return nil }
    if !a.hasPrefix("ws://") && !a.hasPrefix("wss://") {
      if a.hasPrefix("http://") { a.removeFirst("http://".count) }
      let hostPart = a.split(separator: "/").first.map(String.init) ?? a
      let hasPort = hostPart.contains(":")
      a = "ws://" + hostPart + (hasPort ? "" : ":8080") + "/ws"
    }
    return URL(string: a)
  }

  func connect(to address: String) {
    disconnect()
    self.address = address
    guard let url = Self.url(for: address) else {
      status = .failed("Enter the nav PC's address in Settings")
      return
    }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        await self?.runOnce(url)
        if Task.isCancelled { break }
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  func disconnect() {
    loop?.cancel()
    loop = nil
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    status = .off
  }

  /// Used by the demo feed so the rest of the app works without a bridge.
  func inject(_ snap: BoatSnapshot) {
    snapshot = snap
    lastMessageAt = Date()
  }

  private func runOnce(_ url: URL) async {
    status = .connecting
    let ws = session.webSocketTask(with: url)
    socket = ws
    ws.resume()
    do {
      while !Task.isCancelled {
        let message = try await ws.receive()
        let data: Data
        switch message {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default: continue
        }
        do {
          let snap = try BoatSnapshot.decoder.decode(BoatSnapshot.self, from: data)
          snapshot = snap
          lastMessageAt = Date()
          if let age = snap.rxAgeS, age < 5 {
            status = .live
          } else {
            status = .noData
          }
        } catch {
          status = .failed("Unexpected data from the bridge")
        }
      }
    } catch {
      if !Task.isCancelled {
        status = .failed("Can't reach the bridge at \(address). Retrying…")
      }
    }
    ws.cancel(with: .goingAway, reason: nil)
  }
}
