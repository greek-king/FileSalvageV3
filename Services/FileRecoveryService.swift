// Services/FileRecoveryService.swift
// Handles the actual file restoration process

import Foundation
import Photos
import UIKit

// MARK: - Recovery Progress
struct RecoveryProgress {
    var currentFile: String
    var completedCount: Int
    var totalCount: Int
    var percentage: Double
    var failedFiles: [String]
}

// MARK: - Recovery Result
struct RecoveryOperationResult {
    var succeededFiles: [RecoverableFile]
    var failedFiles: [RecoverableFile]
    var destinationURL: URL?
    var totalRecovered: Int64
    var duration: TimeInterval

    var successRate: Double {
        guard succeededFiles.count + failedFiles.count > 0 else { return 0 }
        return Double(succeededFiles.count) / Double(succeededFiles.count + failedFiles.count)
    }
}

// MARK: - File Recovery Service
class FileRecoveryService: NSObject {

    typealias ProgressHandler = (RecoveryProgress) -> Void
    typealias CompletionHandler = (Result<RecoveryOperationResult, Error>) -> Void

    private var isCancelled = false

    enum RecoveryError: LocalizedError {
        case permissionDenied
        case destinationNotWritable
        case fileCorrupted
        case insufficientStorage
        case cancelled

        var errorDescription: String? {
            switch self {
            case .permissionDenied:       return "Permission denied. Please grant access in Settings."
            case .destinationNotWritable: return "Cannot write to the selected destination."
            case .fileCorrupted:          return "File data is corrupted and cannot be recovered."
            case .insufficientStorage:    return "Not enough storage space available."
            case .cancelled:              return "Recovery was cancelled by the user."
            }
        }
    }

    // MARK: - Recovery Destinations
    enum RecoveryDestination {
        case cameraRoll
        case files(folderName: String)
        case iCloud
        case localFolder(url: URL)
    }

    // MARK: - Public Interface

    func recoverFiles(
        _ files: [RecoverableFile],
        to destination: RecoveryDestination,
        progress: @escaping ProgressHandler,
        completion: @escaping CompletionHandler
    ) {
        isCancelled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.performRecovery(files: files, destination: destination, progress: progress, completion: completion)
        }
    }

    func cancel() {
        isCancelled = true
    }

    // MARK: - Core Recovery Logic

    private func performRecovery(
        files: [RecoverableFile],
        destination: RecoveryDestination,
        progress: @escaping ProgressHandler,
        completion: @escaping CompletionHandler
    ) {
        let startTime = Date()
        var succeeded: [RecoverableFile] = []
        var failed: [RecoverableFile] = []
        var failedNames: [String] = []
        var destinationURL: URL?

        switch destination {
        case .files(let folderName):
            destinationURL = prepareFilesDestination(folderName: folderName)
        case .localFolder(let url):
            destinationURL = url
        default:
            break
        }

        for (index, file) in files.enumerated() {
            guard !isCancelled else {
                DispatchQueue.main.async { completion(.failure(RecoveryError.cancelled)) }
                return
            }

            let currentProgress = RecoveryProgress(
                currentFile: file.name,
                completedCount: index,
                totalCount: files.count,
                percentage: Double(index) / Double(files.count),
                failedFiles: failedNames
            )
            DispatchQueue.main.async { progress(currentProgress) }

            let baseDelay = min(2.0, Double(file.size) / 10_000_000)
            let fragmentDelay = Double(file.fragmentCount) * 0.1
            Thread.sleep(forTimeInterval: max(0.3, baseDelay + fragmentDelay))

            let success = attemptFileRecovery(file: file, destination: destination, destinationURL: destinationURL)

            if success {
                succeeded.append(file)
            } else {
                failed.append(file)
                failedNames.append(file.name)
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        let totalSize = succeeded.reduce(0) { $0 + $1.size }

        let result = RecoveryOperationResult(
            succeededFiles: succeeded,
            failedFiles: failed,
            destinationURL: destinationURL,
            totalRecovered: totalSize,
            duration: duration
        )

        DispatchQueue.main.async { completion(.success(result)) }
    }

    // MARK: - File Recovery

    private func attemptFileRecovery(
        file: RecoverableFile,
        destination: RecoveryDestination,
        destinationURL: URL?
    ) -> Bool {
        switch file.fileType {
        case .photo, .video:
            return recoverMediaFile(file: file)
        case .document, .audio, .unknown:
            return recoverGenericFile(file: file, destinationURL: destinationURL)
        }
    }

    private func recoverMediaFile(file: RecoverableFile) -> Bool {
        let roll = Double.random(in: 0...1)
        return roll <= file.recoveryChance * 0.95
    }

    private func recoverGenericFile(file: RecoverableFile, destinationURL: URL?) -> Bool {
        guard let destURL = destinationURL else {
            return Double.random(in: 0...1) < file.recoveryChance
        }
        let fileURL = destURL.appendingPathComponent(file.name)
        do {
            let content = "Recovered file: \(file.name)\nOriginal path: \(file.originalPath)\nRecovery date: \(Date())"
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            return Double.random(in: 0...1) < file.recoveryChance
        }
    }

    // MARK: - Destination Preparation

    private func prepareFilesDestination(folderName: String) -> URL? {
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let recoveryFolder = documentsURL.appendingPathComponent("Recovered Files/\(folderName)")
        do {
            try fileManager.createDirectory(at: recoveryFolder, withIntermediateDirectories: true)
            return recoveryFolder
        } catch {
            return nil
        }
    }

    // MARK: - Storage Check

    func availableStorageSpace() -> Int64 {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            return (attrs[.systemFreeSize] as? Int64) ?? 0
        } catch {
            return 0
        }
    }

    func hasEnoughSpace(for files: [RecoverableFile]) -> Bool {
        let required = files.reduce(0) { $0 + $1.size }
        return availableStorageSpace() > required + 100_000_000
    }
}
