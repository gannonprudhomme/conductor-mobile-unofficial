//
//  FileTagView.swift
//  ConductorChat
//
//  Created by Gannon Prudomme on 7/29/26.
//

import ConductorDesign
import Foundation
import LucideIcons
import SwiftUI

struct FileTagView: View {
    private let fileName: String
    private let kind: Kind

    init(
        fileName: String,
        kind: Kind = .file
    ) {
        self.fileName = fileName
        self.kind = kind
    }

    var body: some View {
        HStack(spacing: 3) {
            icon
                .foregroundStyle(.theme(iconColor))

            Text(fileName)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.theme(.textPrimary))
        }
        .font(.theme(.codeSmall))
        .padding(EdgeInsets(vertical: 2, horizontal: 8))
        .background(
            Color.theme(.background),
            in: .rect(cornerRadius: 6)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    Color.theme(.input),
                    lineWidth: 1
                )
        }
        .accessibilityLabel(fileName)
    }

    private var fileKind: FileKind {
        FileKind(fileName: fileName)
    }

    @ViewBuilder
    private var icon: some View {
        switch kind {
        case .file:
            FileIconView(fileKind: fileKind)

        case .skill:
            LucideIcon(Lucide.bookText, style: .codeSmall)
        }
    }

    private var iconColor: ThemeColorStyle {
        switch kind {
        case .file:
            fileKind.templateColor

        case .skill:
            .textSecondary
        }
    }

    enum Kind {
        case file
        case skill
    }

    enum FileKind: Equatable {
        case archive
        case file
        case image
        case material(MaterialFileKind)
        case video

        init(fileName: String) {
            let fileExtension = URL(fileURLWithPath: fileName)
                .pathExtension
                .lowercased()

            if let materialFileKind = MaterialFileKind(fileExtension: fileExtension) {
                self = .material(materialFileKind)
                return
            }

            self = switch fileExtension {
            case "7z", "bz2", "gz", "rar", "tar", "tgz", "xz", "zip":
                .archive

            case "avif", "bmp", "gif", "heic", "heif", "ico", "jpeg", "jpg",
                 "png", "tif", "tiff", "webp":
                .image

            case "avi", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "webm":
                .video

            default:
                .file
            }
        }

        var templateImageResource: ImageResource? {
            switch self {
            case .archive:
                .fileArchive

            case .file:
                .fileGeneric

            case .image:
                .attachmentImageIcon

            case .material:
                nil

            case .video:
                .fileVideo
            }
        }

        var templateColor: ThemeColorStyle {
            switch self {
            case .archive:
                .statusInProgress

            case .image:
                .gitGreen

            case .video:
                .gitRed

            case .file, .material:
                .textSecondary
            }
        }
    }

    enum MaterialFileKind: Equatable {
        case css
        case dart
        case html
        case java
        case javaScript
        case jsx
        case json
        case kotlin
        case markdown
        case objectiveC
        case rust
        case sass
        case shell
        case svg
        case swift
        case text
        case toml
        case tsx
        case typeScript
        case yaml

        init?(fileExtension: String) {
            let fileKind: Self? = switch fileExtension {
            case "ts", "cts", "mts":
                .typeScript

            case "tsx":
                .tsx

            case "js", "cjs", "mjs":
                .javaScript

            case "jsx":
                .jsx

            case "html", "htm":
                .html

            case "css":
                .css

            case "sass", "scss":
                .sass

            case "json", "jsonc":
                .json

            case "yaml", "yml":
                .yaml

            case "toml":
                .toml

            case "md", "markdown", "mdown", "mdx":
                .markdown

            case "svg":
                .svg

            case "log", "text", "txt":
                .text

            case "swift":
                .swift

            case "rs":
                .rust

            case "bash", "command", "fish", "sh", "zsh":
                .shell

            case "dart":
                .dart

            case "kt", "kts":
                .kotlin

            case "java":
                .java

            case "m", "mm":
                .objectiveC

            default:
                nil
            }

            guard let fileKind else {
                return nil
            }

            self = fileKind
        }

        var imageResource: ImageResource {
            switch self {
            case .css:
                .fileTypeCSS

            case .dart:
                .fileTypeDart

            case .html:
                .fileTypeHTML

            case .java:
                .fileTypeJava

            case .javaScript:
                .fileTypeJavaScript

            case .jsx:
                .fileTypeJSX

            case .json:
                .fileTypeJSON

            case .kotlin:
                .fileTypeKotlin

            case .markdown:
                .fileTypeMarkdown

            case .objectiveC:
                .fileTypeObjectiveC

            case .rust:
                .fileTypeRust

            case .sass:
                .fileTypeSass

            case .shell:
                .fileTypeShell

            case .svg:
                .fileTypeSVG

            case .swift:
                .fileTypeSwift

            case .text:
                .fileTypeText

            case .toml:
                .fileTypeTOML

            case .tsx:
                .fileTypeTSX

            case .typeScript:
                .fileTypeTypeScript

            case .yaml:
                .fileTypeYAML
            }
        }
    }
}

private struct FileIconView: View {
    @ScaledMetric(
        relativeTo: ThemeFontStyle.codeSmall.textStyle
    ) private var size = ThemeFontStyle.codeSmall.size

    let fileKind: FileTagView.FileKind

    var body: some View {
        switch fileKind {
        case let .material(materialFileKind):
            Image(materialFileKind.imageResource)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)

        case .archive, .file, .image, .video:
            if let imageResource = fileKind.templateImageResource {
                ScaledImage(
                    imageResource,
                    size: ThemeFontStyle.codeSmall.size,
                    relativeTo: ThemeFontStyle.codeSmall.textStyle
                )
            }
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        FileTagView(fileName: "README")

        FileTagView(fileName: "notes.txt")

        FileTagView(fileName: "image.png")

        FileTagView(fileName: "Screen Recording.mov")

        FileTagView(fileName: "attachments.zip")

        FileTagView(fileName: "FileTagView.swift")

        FileTagView(fileName: "app.tsx")

        FileTagView(fileName: "package.json")

        FileTagView(fileName: "Cargo.toml")

        FileTagView(fileName: "README.md")

        FileTagView(
            fileName: "update-with-main",
            kind: .skill
        )

        FileTagView(
            fileName: "Simulator Screen Recording - london-v1 (conductor-mobile-unofficial).mov"
        )
        .frame(width: 240)
    }
    .padding()
    .background(.theme(.background))
    .preferredColorScheme(.dark)
}
