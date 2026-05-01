import Flutter
import UIKit
import XCTest

@testable import integration_test

class RunnerTests: XCTestCase {

  func testBenchmarks() {
    let app = XCUIApplication()
    app.launch()
    let integrationTest = IntegrationTestPlugin.instance()
    let testResult = integrationTest.testResults ?? [:]
    for (testName, result) in testResult {
      XCTAssertEqual(
        result, "success",
        "\(testName) failed with status: \(result)"
      )
    }
  }

}
