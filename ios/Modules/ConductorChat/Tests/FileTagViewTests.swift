//
//  FileTagViewTests.swift
//  ConductorChatTests
//
//  Created by Gannon Prudomme on 7/30/26.
//

@testable import ConductorChat
import Testing

@Suite("File tag view")
struct FileTagViewTests {
    @Test("File extensions select supported attachment icons")
    @MainActor
    func supportedFileKinds() {
        #expect(FileTagView.FileKind(fileName: "image.png") == .image)
        #expect(FileTagView.FileKind(fileName: "PHOTO.JPEG") == .image)
        #expect(FileTagView.FileKind(fileName: "recording.mov") == .video)
        #expect(FileTagView.FileKind(fileName: "export.WEBM") == .video)
        #expect(FileTagView.FileKind(fileName: "attachments.zip") == .archive)
        #expect(FileTagView.FileKind(fileName: "source.tar.gz") == .archive)
    }

    @Test(
        "Development file extensions select material icons",
        arguments: [
            ("script.ts", FileTagView.MaterialFileKind.typeScript),
            ("component.tsx", .tsx),
            ("script.mjs", .javaScript),
            ("component.jsx", .jsx),
            ("index.html", .html),
            ("style.css", .css),
            ("style.scss", .sass),
            ("package.json", .json),
            ("workflow.yml", .yaml),
            ("Cargo.toml", .toml),
            ("README.md", .markdown),
            ("logo.svg", .svg),
            ("notes.txt", .text),
            ("Feature.swift", .swift),
            ("main.rs", .rust),
            ("setup.sh", .shell),
            ("main.dart", .dart),
            ("Main.kt", .kotlin),
            ("Main.java", .java),
            ("AppDelegate.m", .objectiveC),
        ]
    )
    @MainActor
    func materialFileKind(
        fileName: String,
        expectedKind: FileTagView.MaterialFileKind
    ) {
        #expect(
            FileTagView.FileKind(fileName: fileName) == .material(expectedKind)
        )
    }

    @Test("Material icon aliases are case insensitive")
    @MainActor
    func materialFileKindAliases() {
        #expect(
            FileTagView.FileKind(fileName: "config.JSONC") == .material(.json)
        )
        #expect(
            FileTagView.FileKind(fileName: "script.zsh") == .material(.shell)
        )
        #expect(
            FileTagView.FileKind(fileName: "Screen.MD") == .material(.markdown)
        )
    }

    @Test("Extensionless and unknown files use the generic icon")
    @MainActor
    func genericFileKind() {
        #expect(FileTagView.FileKind(fileName: "README") == .file)
        #expect(FileTagView.FileKind(fileName: ".gitignore") == .file)
        #expect(FileTagView.FileKind(fileName: "data.custom") == .file)
    }
}
