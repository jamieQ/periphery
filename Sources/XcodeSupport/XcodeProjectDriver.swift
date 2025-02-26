import Foundation
import SystemPackage
import PeripheryKit
import Shared

public final class XcodeProjectDriver {
    public static func make() throws -> Self {
        let configuration: Configuration = inject()
        try validateConfiguration(configuration: configuration)

        let project: XcodeProjectlike

        if let workspacePath = configuration.workspace {
            project = try XcodeWorkspace.make(path: .makeAbsolute(workspacePath))
        } else if let projectPath = configuration.project {
            project = try XcodeProject.make(path: .makeAbsolute(projectPath))
        } else {
            throw PeripheryError.usageError("Expected --workspace or --project option.")
        }

        // Ensure targets are part of the project
        let targets = project.targets.filter { configuration.targets.contains($0.name) }
        let invalidTargetNames = Set(configuration.targets).subtracting(targets.map { $0.name })

        if !invalidTargetNames.isEmpty {
            throw PeripheryError.invalidTargets(names: invalidTargetNames.sorted(), project: project.path.lastComponent?.string ?? "")
        }

        // Ensure schemes exist within the project
        let schemes = try project.schemes().filter { configuration.schemes.contains($0.name) }
        let validSchemeNames = Set(schemes.map { $0.name })

        if let scheme = Set(configuration.schemes).subtracting(validSchemeNames).first {
            throw PeripheryError.invalidScheme(name: scheme, project: project.path.lastComponent?.string ?? "")
        }

        return self.init(
            logger: inject(),
            configuration: configuration,
            xcodebuild: inject(),
            project: project,
            schemes: schemes,
            targets: targets
        )
    }

    private let logger: Logger
    private let configuration: Configuration
    private let xcodebuild: Xcodebuild
    private let project: XcodeProjectlike
    private let schemes: Set<XcodeScheme>
    private let targets: Set<XcodeTarget>

    init(
        logger: Logger,
        configuration: Configuration,
        xcodebuild: Xcodebuild,
        project: XcodeProjectlike,
        schemes: Set<XcodeScheme>,
        targets: Set<XcodeTarget>
    ) {
        self.logger = logger
        self.configuration = configuration
        self.xcodebuild = xcodebuild
        self.project = project
        self.schemes = schemes
        self.targets = targets
    }

    // MARK: - Private

    private static func validateConfiguration(configuration: Configuration) throws {
        guard configuration.workspace != nil || configuration.project != nil else {
            let message = "You must supply either the --workspace or --project option. If your project uses an .xcworkspace to integrate multiple projects, then supply the --workspace option. Otherwise, supply the --project option."
            throw PeripheryError.usageError(message)
        }

        if configuration.workspace != nil && configuration.project != nil {
            let message = "You must supply either the --workspace or --project option, not both. If your project uses an .xcworkspace to integrate multiple projects, then supply the --workspace option. Otherwise, supply the --project option."
            throw PeripheryError.usageError(message)
        }

        guard !configuration.schemes.isEmpty else {
            throw PeripheryError.usageError("The '--schemes' option is required.")
        }

        guard !configuration.targets.isEmpty else {
            throw PeripheryError.usageError("The '--targets' option is required.")
        }
    }
}

extension XcodeProjectDriver: ProjectDriver {
    public func build() throws {
        // Ensure test targets are built by chosen schemes
        let testTargetNames = targets.filter { $0.isTestTarget }.map { $0.name }

        if !testTargetNames.isEmpty {
            let allTestTargets = try schemes.flatMap { try $0.testTargets() }
            let missingTestTargets = Set(testTargetNames).subtracting(allTestTargets).sorted()

            if !missingTestTargets.isEmpty {
                throw PeripheryError.testTargetsNotBuildable(names: missingTestTargets)
            }
        }

        guard  !configuration.skipBuild else { return }

        if configuration.cleanBuild {
            try xcodebuild.removeDerivedData(for: project, allSchemes: Array(schemes))
        }

        for scheme in schemes {
            if configuration.outputFormat.supportsAuxiliaryOutput {
                let asterisk = colorize("*", .boldGreen)
                logger.info("\(asterisk) Building \(scheme.name)...")
            }

            let buildForTesting = !Set(try scheme.testTargets()).isDisjoint(with: testTargetNames)
            try xcodebuild.build(project: project,
                                 scheme: scheme,
                                 allSchemes: Array(schemes),
                                 additionalArguments: configuration.buildArguments,
                                 buildForTesting: buildForTesting)
        }
    }

    public func index(graph: SourceGraph) throws {
        let storePath: String

        if let path = configuration.indexStorePath {
            storePath = path
        } else {
            storePath = try xcodebuild.indexStorePath(project: project, schemes: Array(schemes))
        }

        try targets.forEach { try $0.identifyFiles() }

        let sourceFiles = targets.reduce(into: [FilePath: [String]]()) { result, target in
            target.files(kind: .swift).forEach { result[$0, default: []].append(target.name) }
        }

        try SwiftIndexer.make(storePath: storePath, sourceFiles: sourceFiles, graph: graph).perform()

        let xibFiles = Set(targets.map { $0.files(kind: .interfaceBuilder) }.joined())
        try XibIndexer.make(xibFiles: xibFiles, graph: graph).perform()

        let xcDataModelFiles = Set(targets.map { $0.files(kind: .xcDataModel) }.joined())
        try XCDataModelIndexer.make(files: xcDataModelFiles, graph: graph).perform()

        let xcMappingModelFiles = Set(targets.map { $0.files(kind: .xcMappingModel) }.joined())
        try XCMappingModelIndexer.make(files: xcMappingModelFiles, graph: graph).perform()

        let infoPlistFiles = Set(targets.map { $0.files(kind: .infoPlist) }.joined())
        try InfoPlistIndexer.make(infoPlistFiles: infoPlistFiles, graph: graph).perform()

        graph.indexingComplete()
    }
}
