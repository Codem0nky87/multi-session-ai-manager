import Foundation

/// Folder navigation uses bounded SSH exec only; no SFTP subsystem is needed.
/// File read/write retain SSHService's transfer implementation for the shared
/// FileBrowserModel seam, but the folder picker never invokes them.
actor SSHDirectoryBrowser: FileTransfer {
    private let service: SSHService
    private let key: SSHKeyMaterial
    private var connection: Task<Void, Error>?
    private var closed = false

    init(host: Host, key: SSHKeyMaterial, knownHosts: KnownHostsStore,
         transport: SSHTransport = NIOSSHTransport()) {
        service = SSHService(host: host, transport: transport, knownHosts: knownHosts)
        self.key = key
    }

    private func connect() async throws {
        guard !closed else { throw CancellationError() }
        try Task.checkCancellation()
        if connection == nil {
            let service = service
            let key = key
            connection = Task {
                try await service.connect(key: key) { _, verdict in verdict == .trustedNew }
                try Task.checkCancellation()
            }
        }
        do {
            try await connection?.value
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
        } catch {
            connection = nil
            throw error
        }
    }

    func listDirectory(_ path: String) async throws -> [RemoteFile] {
        try await directoryListing(path).entries
    }

    func directoryListing(_ path: String) async throws -> RemoteDirectoryListing {
        guard !path.contains("\0") else { throw FileTransferError.failed("Invalid folder path") }
        try await connect()
        let command = service.isWindows ? Self.windowsCommand(path) : Self.posixCommand(path)
        let result = try await service.runRaw(command, timeout: .seconds(15), outputLimit: 1_048_576)
        try Task.checkCancellation()
        return try Self.parse(result.stdout, isWindows: service.isWindows)
    }

    func read(_ path: String) async throws -> Data {
        try await connect()
        return try await service.readFile(at: path)
    }

    func write(_ data: Data, to path: String) async throws {
        try await connect()
        try await service.writeFile(data, to: path)
    }

    func disconnect() async {
        closed = true
        let pending = connection
        connection = nil
        pending?.cancel()
        await service.disconnect()
        _ = await pending?.result
        await service.disconnect()
    }

    nonisolated static func posixCommand(_ path: String) -> String {
        // NUL framing preserves every valid UTF-8 filename, including newlines.
        // Explicit /bin/sh avoids dependencies on the user's shell or tools
        // such as Python, GNU find, or a particular ls output format.
        let script = #"""
        path=$1
        case "$path" in
          ''|'~') path=$HOME ;;
          '~/'*) path=$HOME/${path#\~/} ;;
        esac
        fail() { printf '\000MSAM_DIRECTORY_V1\000%s\000\000end\000' "$1"; exit 1; }
        [ -d "$path" ] || fail missing
        [ -r "$path" ] && [ -x "$path" ] || fail denied
        CDPATH= cd -L -- "$path" 2>/dev/null || fail denied
        printf '\000MSAM_DIRECTORY_V1\000ok\000%s\000' "$PWD"
        for entry in ./* ./.[!.]* ./..?*; do
          [ -e "$entry" ] || [ -L "$entry" ] || continue
          kind=f
          [ ! -d "$entry" ] || kind=d
          printf '%s\000%s\000' "$kind" "${entry#./}"
        done
        printf 'end\000'
        """#
        return "/bin/sh -c \(POSIXShell.quote(script)) sh \(POSIXShell.quote(path))"
    }

    nonisolated static func windowsCommand(_ path: String) -> String {
        let literal = "'" + path.replacingOccurrences(of: "'", with: "''") + "'"
        let script = #"""
        $ErrorActionPreference = 'Stop'
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $n = [char]0
        function emit($value) { [Console]::Write([string]$value + $n) }
        $path = \#(literal)
        try {
          if ($path -eq '/') {
            $resolved = '/'
            $items = @(Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Name -match '^[A-Za-z]$' })
          } else {
            if (!$path -or $path -eq '~') { $path = $HOME }
            elseif ($path.StartsWith('~/')) { $path = Join-Path $HOME $path.Substring(2) }
            $folder = Get-Item -LiteralPath $path -Force
            if (!$folder.PSIsContainer) { throw 'Not a folder' }
            $resolved = $folder.FullName.Replace('\', '/')
            $items = @(Get-ChildItem -LiteralPath $folder.FullName -Force)
          }
          [Console]::Write([string]$n + 'MSAM_DIRECTORY_V1' + $n)
          emit 'ok'; emit $resolved
          foreach ($item in $items) {
            if ($resolved -eq '/') { emit 'd'; emit ($item.Name + ':') }
            else { if ($item.PSIsContainer) { emit 'd' } else { emit 'f' }; emit $item.Name }
          }
          emit 'end'
        } catch {
          [Console]::Write([string]$n + 'MSAM_DIRECTORY_V1' + $n)
          emit 'failed'; emit ''; emit 'end'
          exit 1
        }
        """#
        let encoded = Data(script.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }).base64EncodedString()
        return "powershell.exe -NoProfile -NonInteractive -EncodedCommand \(encoded)"
    }

    nonisolated static func parse(_ data: Data, isWindows: Bool = false) throws -> RemoteDirectoryListing {
        let invalid = FileTransferError.failed("Could not read the remote folder. Try again.")
        let marker = Data("\0MSAM_DIRECTORY_V1\0".utf8)
        guard let range = data.range(of: marker),
              let text = String(data: data[range.upperBound...], encoding: .utf8) else { throw invalid }
        let fields = text.components(separatedBy: "\0")
        guard fields.count >= 4, fields.last == "", fields[fields.count - 2] == "end" else { throw invalid }
        switch fields[0] {
        case "missing": throw FileTransferError.notFound
        case "denied": throw FileTransferError.permissionDenied
        case "ok": break
        default: throw FileTransferError.failed("Could not open the remote folder. Check its path and permissions.")
        }
        let path = fields[1]
        guard path.hasPrefix("/") || FileBrowserModel.isDrivePath(path),
              (fields.count - 4).isMultiple(of: 2) else { throw invalid }
        var entries: [RemoteFile] = []
        for index in stride(from: 2, to: fields.count - 2, by: 2) {
            let kind = fields[index], name = fields[index + 1]
            guard kind == "d" || kind == "f", !name.isEmpty,
                  name != ".", name != "..", !name.contains("/") else { throw invalid }
            let drive = isWindows && path == "/" && FileBrowserModel.isDrivePath(name + "/")
            entries.append(.init(name: name, path: drive ? name + "/" : FileBrowserModel.join(path, name),
                                 isDirectory: kind == "d", size: 0))
        }
        return .init(path: path, entries: entries)
    }
}
