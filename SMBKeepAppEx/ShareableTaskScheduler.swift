//
//  ShareableTaskScheduler.swift
//  SMBKeep
//
//  Created by xiaogd on 2026/6/19.
//  Copyright © 2026 Apple. All rights reserved.
//

import Foundation

actor ShareableTaskScheduler<Key: Hashable & Sendable, Result: Sendable>: Sendable {

    private enum TaskState {
        case inProgress(task: Task<Result, Error>)
    }

    private var runningTasks: [Key: TaskState] = [:]

    func request(key: Key, makeNewTask: @Sendable @escaping () async throws -> Result) async throws -> Result {
        do {
            while true {
                try Task.checkCancellation()
                if case let .inProgress(task) = runningTasks[key] {
                    if !task.isCancelled {
                        return try await task.value
                    }
                    _ = try? await task.value
                    await Task.yield()
                } else {
                    break
                }
            }

            let newTask = Task.detached {
                return try await makeNewTask()
            }

            do {
                let newTaskItem: TaskState = .inProgress(task: newTask)
                runningTasks[key] = newTaskItem
                let result = try await withTaskCancellationHandler {
                    try await newTask.value
                } onCancel: {
                    newTask.cancel()
                }
                runningTasks[key] = nil
                return result
            } catch {
                runningTasks[key] = nil
                if newTask.isCancelled {
                    throw CancellationError()
                }

                throw error
            }
        } catch {
            throw error
        }
    }

    func cancelRequest(key: Key) {
        guard case let .inProgress(task) = runningTasks[key] else {
            return
        }

        task.cancel()
    }
}
