//
//  CommandLinePasswordDataSource.swift
//  iTerm2SharedARC
//
//  Created by George Nachman on 3/19/22.
//

import Foundation

class CommandLineProvidedAccount: NSObject, PasswordManagerAccount {
    private let configuration: CommandLinePasswordDataSource.Configuration
    let identifier: String
    let accountName: String
    let userName: String
    var displayString: String {
        return "\(accountName)\u{2002}—\u{2002}\(userName)"
    }

    func password() throws -> String {
        return try configuration.getPasswordRecipe.transform(inputs: CommandLinePasswordDataSource.AccountIdentifier(value: identifier))
    }

    func set(password: String) throws {
        let accountIdentifier = CommandLinePasswordDataSource.AccountIdentifier(value: identifier)
        let request = CommandLinePasswordDataSource.SetPasswordRequest(accountIdentifier: accountIdentifier,
                                                                       newPassword: password)
        try configuration.setPasswordRecipe.transform(inputs: request)
    }

    func delete() throws {
        try configuration.deleteRecipe.transform(inputs: CommandLinePasswordDataSource.AccountIdentifier(value: identifier))
    }

    func matches(filter: String) -> Bool {
        return accountName.containsCaseInsensitive(filter) || userName.containsCaseInsensitive(filter)
    }

    init(identifier: String,
         accountName: String,
         userName: String, configuration: CommandLinePasswordDataSource.Configuration) {
        self.identifier = identifier
        self.accountName = accountName
        self.userName = userName
        self.configuration = configuration
    }
}

protocol CommandLinePasswordDataSourceExecutableCommand {
    func exec() throws -> CommandLinePasswordDataSource.Output
}

protocol Recipe {
    associatedtype Inputs
    associatedtype Outputs
    func transform(inputs: Inputs) throws -> Outputs
}

class CommandLinePasswordDataSource: NSObject {
    struct Output {
        let stderr: Data
        let stdout: Data
        let returnCode: Int32

        var lines: [String] {
            return String(data: stdout, encoding: .utf8)?.components(separatedBy: "\n") ?? []
        }
    }

    class InteractiveCommand: CommandLinePasswordDataSourceExecutableCommand {
        let command: String
        let args: [String]
        let env: [String: String]
        let handleStdout: (Data) throws -> Data?
        let handleStderr: (Data) throws -> Data?
        let handleTermination: (Int32, Process.TerminationReason) throws -> ()
        var didLaunch: (() -> ())? = nil
        private let serialQueue = DispatchQueue(label: "com.iterm2.pwmgr-cmd")
        private let process = Process()
        private let stdout = Pipe()
        private let stderr = Pipe()
        private let stdin = Pipe()
        private var stdoutChannel: DispatchIO? = nil
        private var stderrChannel: DispatchIO? = nil
        private var stdinChannel: DispatchIO? = nil
        private let queue: AtomicQueue<Event>
        var debugging: Bool = gDebugLogging.boolValue

        private enum Event {
            case readOutput(Data?)
            case readError(Data?)
            case terminated(Int32, Process.TerminationReason)
        }

        private func readingChannel(_ pipe: Pipe,
                                    serialQueue: DispatchQueue,
                                    handler: @escaping (Data?) -> ()) -> DispatchIO {
            let channel = DispatchIO(type: .stream,
                                     fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
                                     queue: serialQueue,
                                     cleanupHandler: { _ in })
            read(channel, handler)
            return channel
        }

        private func read(_ channel: DispatchIO, _ handler: @escaping (Data?) -> ()) {
            if debugging {
                NSLog("Schedule read")
            }
            channel.read(offset: 0, length: 1024, queue: serialQueue) { [weak self, channel] done, data, error in
                self?.didRead(channel, done: done, data: data, error: error, handler: handler)
            }
        }

        private func didRead(_ channel: DispatchIO?,
                             done: Bool,
                             data: DispatchData?,
                             error: Int32,
                             handler: @escaping (Data?) -> ()) {
            if done && (data?.isEmpty ?? true) {
                if debugging {
                    NSLog("done and data is empty, finish up")
                }
                handler(nil)
                return
            }
            guard let regions = data?.regions else {
                if done {
                    if debugging {
                        NSLog("No regions, finish up")
                    }
                    handler(nil)
                }
                return
            }
            for region in regions {
                var data = Data(count: region.count)
                data.withUnsafeMutableBytes {
                    _ = region.copyBytes(to: $0)
                }
                handler(data)
            }
            if let channel = channel {
                read(channel, handler)
            } else {
                if debugging {
                    NSLog("NOT scheduling read. channel is nil")
                }
            }
        }

        func exec() throws -> Output {
            if debugging {
                NSLog("run \(command) \(args.joined(separator: " "))")
            }
            stdoutChannel = readingChannel(stdout, serialQueue: serialQueue) { [weak self] data in
                if self?.debugging ?? false {
                    NSLog("stdout< \(String(describing: data))")
                }
                self?.queue.enqueue(.readOutput(data))
            }
            stderrChannel = readingChannel(stderr, serialQueue: serialQueue) { [weak self] data in
                if self?.debugging ?? false {
                    NSLog("stderr< \(String(describing: data))")
                }
                self?.queue.enqueue(.readError(data))
            }
            process.launch()

            DispatchQueue.global().async {
                self.process.waitUntilExit()
                if self.debugging {
                    NSLog("TERMINATED status=\(self.process.terminationStatus) reason=\(self.process.terminationReason)")
                }
                self.queue.enqueue(.terminated(self.process.terminationStatus,
                                               self.process.terminationReason))
            }

            var returnCode: Int32? = nil
            var terminationReason: Process.TerminationReason? = nil
            var stdoutData = Data()
            var stderrData = Data()

            didLaunch?()

            do {
                while stdoutChannel != nil || stderrChannel != nil || returnCode == nil {
                    if debugging {
                        NSLog("dequeue…")
                    }
                    let event = queue.dequeue()
                    if debugging {
                        NSLog("handle event \(event)")
                    }
                    switch event {
                    case .readOutput(let data):
                        if let data = data {
                            stdoutData.append(data)
                            if let dataToWrite = try handleStdout(data) {
                                write(dataToWrite)
                            }
                        } else {
                            stdoutChannel?.close()
                            stdoutChannel = nil
                        }
                    case .readError(let data):
                        if let data = data {
                            stderrData.append(data)
                            if let dataToWrite = try handleStderr(data) {
                                write(dataToWrite)
                            }
                        } else {
                            stderrChannel?.close()
                            stderrChannel = nil
                        }
                    case let .terminated(code, reason):
                        returnCode = code
                        terminationReason = reason
                        // Defer calling handleTermination until all the command's output has been
                        // handled since that happening out of order is mind bending.
                        stdinChannel?.close()
                        stdinChannel = nil
                    }
                }
            } catch {
                if debugging {
                    NSLog("command threw \(error)")
                }
                stdoutChannel?.close()
                stderrChannel?.close()
                stdinChannel?.close()
                if returnCode == nil {
                    process.terminate()
                }
                throw error
            }
            if let code = returnCode, let reason = terminationReason {
                try handleTermination(code, reason)
            }
            if debugging {
                NSLog("[\(command) \(args.joined(separator: " "))] Completed with return code \(returnCode!)")
            }
            return Output(stderr: stderrData, stdout: stdoutData, returnCode: returnCode!)
        }

        func write(_ data: Data) {
            guard let channel = stdinChannel else {
                return
            }
            data.withUnsafeBytes { pointer in
                channel.write(offset: 0,
                              data: DispatchData(bytes: pointer),
                              queue: serialQueue) { _done, _data, _error in
                    guard self.debugging else {
                        return
                    }
                    if let data = _data {
                        for region in data.regions {
                            var data = Data(count: region.count)
                            data.withUnsafeMutableBytes {
                                _ = region.copyBytes(to: $0)
                            }
                            if self.debugging {
                                NSLog("stdin> \(String(data: data, encoding: .utf8) ?? "(non-UTF8)")")
                            }
                        }
                    } else if _error != 0 {
                        if self.debugging {
                            NSLog("stdin error: \(_error)")
                        }
                    }
                }
            }
        }

        func closeStdin() {
            stdin.fileHandleForWriting.closeFile()
            stdinChannel?.close()
            stdinChannel = nil
        }

        init(command: String,
             args: [String],
             env: [String: String],
             handleStdout: @escaping (Data) throws -> Data?,
             handleStderr: @escaping (Data) throws -> Data?,
             handleTermination: @escaping (Int32, Process.TerminationReason) throws -> ()) {
            self.command = command
            self.args = args
            self.env = env
            self.handleStdout = handleStdout
            self.handleStderr = handleStderr
            self.handleTermination = handleTermination
            let queue = AtomicQueue<Event>()
            self.queue = queue
            process.launchPath = command
            process.arguments = args
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = stdin
            process.environment = env

            stdinChannel = DispatchIO(type: .stream,
                                      fileDescriptor: stdin.fileHandleForWriting.fileDescriptor,
                                      queue: serialQueue) { _ in }
        }
    }

    struct Command: CommandLinePasswordDataSourceExecutableCommand {
        let command: String
        let args: [String]
        let env: [String: String]
        let stdin: Data?

        func exec() throws -> Output {
            let inner = InteractiveCommand(command: command,
                                           args: args,
                                           env: env,
                                           handleStdout: { _ in nil },
                                           handleStderr: { _ in nil },
                                           handleTermination: { _, _ in })
            if let data = stdin {
                inner.write(data)
            }
            return try inner.exec()
        }
    }

    struct CommandRecipe<Inputs, Outputs>: Recipe {
        private let inputTransformer: (Inputs) throws -> (CommandLinePasswordDataSourceExecutableCommand)
        private let recovery: (Error) throws -> Void
        private let outputTransformer: (Output) throws -> Outputs

        func transform(inputs: Inputs) throws -> Outputs {
            let command = try inputTransformer(inputs)
            while true {
                let output = try command.exec()
                do {
                    return try outputTransformer(output)
                } catch {
                    try recovery(error)
                }
            }
        }

        init(inputTransformer: @escaping (Inputs) throws -> (CommandLinePasswordDataSourceExecutableCommand),
             recovery: @escaping (Error) throws -> Void,
             outputTransformer: @escaping (Output) throws -> Outputs) {
            self.inputTransformer = inputTransformer
            self.recovery = recovery
            self.outputTransformer = outputTransformer
        }
    }

    struct PipelineRecipe<FirstRecipe: Recipe, SecondRecipe: Recipe>: Recipe where FirstRecipe.Outputs == SecondRecipe.Inputs {
        typealias Inputs = FirstRecipe.Inputs
        typealias Outputs = SecondRecipe.Outputs

        let firstRecipe: FirstRecipe
        let secondRecipe: SecondRecipe

        init(_ firstRecipe: FirstRecipe, _ secondRecipe: SecondRecipe) {
            self.firstRecipe = firstRecipe
            self.secondRecipe = secondRecipe
        }

        func transform(inputs: Inputs) throws -> Outputs {
            let intermediateValue = try firstRecipe.transform(inputs: inputs)
            return try secondRecipe.transform(inputs: intermediateValue)
        }
    }

    enum CommandLineRecipeError: Error {
        case unsupported(reason: String)
    }

    struct UnsupportedRecipe<Inputs, Outputs>: Recipe {
        let reason: String
        func transform(inputs: Inputs) throws -> Outputs {
            throw CommandLineRecipeError.unsupported(reason: reason)
        }
    }
    struct AnyRecipe<Inputs, Outputs>: Recipe {
        private let closure: (Inputs) throws -> Outputs
        func transform(inputs: Inputs) throws -> Outputs {
            return try closure(inputs)
        }
        init<T: Recipe>(_ recipe: T) where T.Inputs == Inputs, T.Outputs == Outputs {
            closure = { try recipe.transform(inputs: $0) }
        }
    }

    struct AccountIdentifier {
        let value: String
    }

    struct Account {
        let identifier: AccountIdentifier
        let userName: String
        let accountName: String
    }

    struct SetPasswordRequest {
        let accountIdentifier: AccountIdentifier
        let newPassword: String
    }

    struct AddRequest {
        let userName: String
        let accountName: String
        let password: String
    }

    struct Configuration {
        let listAccountsRecipe: AnyRecipe<Void, [Account]>
        let getPasswordRecipe: AnyRecipe<AccountIdentifier, String>
        let setPasswordRecipe: AnyRecipe<SetPasswordRequest, Void>
        let deleteRecipe: AnyRecipe<AccountIdentifier, Void>
        let addAccountRecipe: AnyRecipe<AddRequest, AccountIdentifier>
    }

    func standardAccounts(_ configuration: Configuration) -> [PasswordManagerAccount] {
        do {
            return try configuration.listAccountsRecipe.transform(inputs: ()).compactMap { account in
                CommandLineProvidedAccount(identifier: account.identifier.value,
                                           accountName: account.accountName,
                                           userName: account.userName,
                                           configuration: configuration)
            }
        } catch {
            DLog("\(error)")
            return []
        }
    }

    func standardAdd(_ configuration: Configuration, userName: String, accountName: String, password: String) throws -> PasswordManagerAccount {
        let accountIdentifier = try configuration.addAccountRecipe.transform(
            inputs: AddRequest(userName: userName,
                               accountName: accountName,
                               password: password))
        return CommandLineProvidedAccount(identifier: accountIdentifier.value,
                                          accountName: accountName,
                                          userName: userName,
                                          configuration: configuration)
    }
}