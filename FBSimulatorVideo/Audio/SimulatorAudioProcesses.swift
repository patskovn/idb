/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreAudio
import Darwin
import FBControlCore
import Foundation

/// Which of the Mac's audio clients belong to one simulator.
///
/// A simulator's processes play through the Mac's audio system themselves, each as a client of its
/// own: SpringBoard, the system sound server, every app. They are the processes descended from the
/// simulator's `launchd_sim`.
enum SimulatorAudioProcesses {

  /// How far up a process's ancestry to look for the simulator's launchd: its services and apps are
  /// its children, and a process one of those spawned is a grandchild.
  static let maximumDepth = 6

  /// The `launchd_sim` serving the simulator `udid`, which it names in the path of its bootstrap
  /// plist: `<device set>/<udid>/data/var/run/launchd_bootstrap.plist`.
  static func launchdPID(udid: String, fetcher: ProcessFetcher = ProcessFetcher()) -> pid_t? {
    fetcher.processes(withProcessName: "launchd_sim").first { process in
      process.arguments.contains { $0.localizedCaseInsensitiveContains("/\(udid)/") }
    }?.processIdentifier
  }

  /// The audio clients among `processes` that descend from the process `launchd`.
  static func objects(
    under launchd: pid_t, among processes: [HostAudioObjects.Process], parent: (pid_t) -> pid_t? = parentPID
  ) -> [AudioObjectID] {
    processes.filter { process in
      var pid = process.pid
      for _ in 0..<maximumDepth {
        guard let next = parent(pid), next > 1 else {
          return false
        }
        if next == launchd {
          return true
        }
        pid = next
      }
      return false
    }.map(\.object)
  }

  static func parentPID(of pid: pid_t) -> pid_t? {
    var info = proc_bsdshortinfo()
    let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
    let returned = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
      unsafe proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, pointer, size)
    }
    guard returned == size else {
      return nil
    }
    return pid_t(info.pbsi_ppid)
  }
}
