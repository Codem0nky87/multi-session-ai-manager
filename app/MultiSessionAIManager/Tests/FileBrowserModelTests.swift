import Testing
import Foundation
@testable import MultiSessionAIManager

private func dir(_ name: String, _ path: String) -> RemoteFile {
    RemoteFile(name: name, path: path, isDirectory: true, size: 0)
}
private func file(_ name: String, _ path: String, size: Int = 1) -> RemoteFile {
    RemoteFile(name: name, path: path, isDirectory: false, size: size)
}

// MARK: - Pure helper: join

@Test func joinJoinsWithSingleSlash() {
    #expect(FileBrowserModel.join("/a", "b") == "/a/b")
    #expect(FileBrowserModel.join("/a/", "b") == "/a/b")
    #expect(FileBrowserModel.join("/", "b") == "/b")
    #expect(FileBrowserModel.join("/a/b", "c") == "/a/b/c")
}

// MARK: - Pure helper: parent

@Test func parentReturnsContainingDirectory() {
    #expect(FileBrowserModel.parent(of: "/a/b/c") == "/a/b")
    #expect(FileBrowserModel.parent(of: "/a") == "/")
    #expect(FileBrowserModel.parent(of: "/") == "/")
    #expect(FileBrowserModel.parent(of: "/a/b/") == "/a")
}

// MARK: - Pure helper: sort

@Test func sortPutsDirsFirstThenCaseInsensitiveName() {
    let input = [file("Zeta", "/Zeta"), dir("alpha", "/alpha"),
                 dir("Beta", "/Beta"), file("apple", "/apple")]
    let sorted = FileBrowserModel.sort(input)
    #expect(sorted.map(\.name) == ["alpha", "Beta", "apple", "Zeta"])
    #expect(sorted.map(\.isDirectory) == [true, true, false, false])
}

// MARK: - Pure helper: breadcrumbs

@Test func breadcrumbsForNestedPath() {
    let bc = FileBrowserModel.breadcrumbs(for: "/Users/u/dev")
    #expect(bc.map(\.name) == ["/", "Users", "u", "dev"])
    #expect(bc.map(\.path) == ["/", "/Users", "/Users/u", "/Users/u/dev"])
}

@Test func breadcrumbsForRoot() {
    let bc = FileBrowserModel.breadcrumbs(for: "/")
    #expect(bc.map(\.name) == ["/"])
    #expect(bc.map(\.path) == ["/"])
}

// MARK: - Pure helper: visible (hidden-file filtering)

@Test func visibleHidesDotfilesByDefault() {
    let input = [file(".bashrc", "/.bashrc"), dir(".git", "/.git"),
                 file("README.md", "/README.md"), dir("src", "/src")]
    let shown = FileBrowserModel.visible(input, showHidden: false)
    #expect(shown.map(\.name) == ["README.md", "src"])
}

@Test func visibleShowsDotfilesWhenEnabled() {
    let input = [file(".bashrc", "/.bashrc"), dir(".git", "/.git"),
                 file("README.md", "/README.md"), dir("src", "/src")]
    let shown = FileBrowserModel.visible(input, showHidden: true)
    #expect(shown.map(\.name) == [".bashrc", ".git", "README.md", "src"])
}

@Test func visiblePreservesOrderOfRemainingEntries() {
    let input = [dir("a", "/a"), file(".hidden", "/.hidden"), dir("b", "/b")]
    #expect(FileBrowserModel.visible(input, showHidden: false).map(\.name) == ["a", "b"])
}

@MainActor
@Test func visibleEntriesReflectsShowHiddenToggleInstantly() async {
    let t = FakeFileTransfer()
    t.entries["/"] = [dir(".git", "/.git"), file(".env", "/.env"),
                      file("main.swift", "/main.swift")]
    let m = FileBrowserModel(transfer: t, root: "/")
    await m.load()
    #expect(m.entries.count == 3)                       // full listing retained
    #expect(m.visibleEntries.map(\.name) == ["main.swift"])
    m.showHidden = true
    #expect(m.visibleEntries.count == 3)                // instant, no reload
}

// MARK: - Model async behaviour against the fake

@MainActor
private func makeFake() -> FakeFileTransfer {
    let t = FakeFileTransfer()
    t.entries["/"] = [dir("home", "/home"), file("readme.txt", "/readme.txt", size: 10)]
    t.entries["/home"] = [file("b.txt", "/home/b.txt"), dir("Apps", "/home/Apps")]
    return t
}

@MainActor
@Test func loadPopulatesSortedEntries() async {
    let t = makeFake()
    let m = FileBrowserModel(transfer: t, root: "/")
    await m.load()
    #expect(m.currentPath == "/")
    #expect(m.entries.map(\.name) == ["home", "readme.txt"])
    #expect(m.errorMessage == nil)
}

@MainActor
@Test func openDirectoryNavigatesAndLoads() async {
    let t = makeFake()
    let m = FileBrowserModel(transfer: t, root: "/")
    await m.load()
    let home = m.entries.first { $0.name == "home" }!
    await m.open(home)
    #expect(m.currentPath == "/home")
    #expect(m.entries.map(\.name) == ["Apps", "b.txt"])
}

@MainActor
@Test func openFileIsNoOpForNavigation() async {
    let t = makeFake()
    let m = FileBrowserModel(transfer: t, root: "/")
    await m.load()
    let readme = m.entries.first { $0.name == "readme.txt" }!
    await m.open(readme)
    #expect(m.currentPath == "/")
    #expect(m.entries.map(\.name) == ["home", "readme.txt"])
}

@MainActor
@Test func goUpReturnsToParent() async {
    let t = makeFake()
    let m = FileBrowserModel(transfer: t, root: "/")
    await m.load()
    await m.open(m.entries.first { $0.name == "home" }!)
    #expect(m.currentPath == "/home")
    await m.goUp()
    #expect(m.currentPath == "/")
    #expect(m.entries.map(\.name) == ["home", "readme.txt"])
}

@MainActor
@Test func goUpAtRootStaysAtRoot() async {
    let t = makeFake()
    let m = FileBrowserModel(transfer: t, root: "/")
    await m.load()
    await m.goUp()
    #expect(m.currentPath == "/")
    #expect(m.entries.map(\.name) == ["home", "readme.txt"])
}

@MainActor
@Test func loadSetsErrorMessageOnNotFound() async {
    let t = FakeFileTransfer() // empty -> listDirectory throws .notFound
    let m = FileBrowserModel(transfer: t, root: "/missing")
    await m.load()
    #expect(m.errorMessage != nil)
    #expect(m.entries.isEmpty)
}

// MARK: - Fake transfer write/read

@MainActor
@Test func fakeRecordsWritesAndReads() async throws {
    let t = FakeFileTransfer()
    let data = Data("hi".utf8)
    try await t.write(data, to: "/x.txt")
    #expect(t.writes.count == 1)
    #expect(t.writes.first?.path == "/x.txt")
    #expect(t.writes.first?.size == 2)
    let back = try await t.read("/x.txt")
    #expect(back == data)
}

@MainActor
@Test func fakeThrowsInjectedError() async {
    let t = FakeFileTransfer()
    t.listError = .permissionDenied
    t.entries["/"] = []
    await #expect(throws: FileTransferError.self) {
        _ = try await t.listDirectory("/")
    }
}
