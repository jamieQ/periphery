import Foundation
import Shared
import XCTest

@testable import PeripheryKit
@testable import XcodeSupport

final class XcodeProjectDriverTest: XCTestCase {
    var config: Configuration!

    private let idxstorePath = "~/custom/idxstore/path"

    override func setUp() {
        super.setUp()

        config = {
            let cfg = Configuration.make()
            cfg.project = UIKitProjectPath.string
            cfg.targets = ["UIKitProject", "Target With Spaces"]
            return cfg
        }()
    }

    func test_make_emptySchemeAcceptance() {
        config.schemes = []
        
        do {
            config.skipBuild = true
            config.indexStorePath = idxstorePath
            
            XCTAssertNoThrow(
                try XcodeProjectDriver.make(configuration: config)
            )
        }
        
        do {
            config.skipBuild = true
            config.indexStorePath = nil
            
            XCTAssertThrowsError(
                try XcodeProjectDriver.make(configuration: config)
            ) { error in
                XCTAssertTrue(error.isRequiredSchemeError)
            }
        }
        
        do {
            config.skipBuild = false
            config.indexStorePath = idxstorePath
            
            XCTAssertThrowsError(
                try XcodeProjectDriver.make(configuration: config)
            ) { error in
                XCTAssertTrue(error.isRequiredSchemeError)
            }
        }
    }
    
    func test_build_emptySchemeAcceptance() {
        config.schemes = []
        config.skipBuild = true
        config.indexStorePath = idxstorePath

        XCTAssertNoThrow(
            try XcodeProjectDriver
                .make(configuration: config)
                .build()
        )
    }
}

private extension Error {
    var isRequiredSchemeError: Bool {
        let expectedErrorMessage = "The '--schemes' option is required."
        let error: Error = self // type hinting needed for some reason
        
        switch error {
        case PeripheryError.usageError(let message):
            return message == expectedErrorMessage
        default:
            return false
        }
    }
}
