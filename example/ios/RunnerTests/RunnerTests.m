@import XCTest;

// Minimal native-only test bundle. No Flutter integration_test plugin.
// If FTL can't run THIS, the issue is entirely outside our Flutter setup —
// it's bundle handling, code signing, or DDI on FTL's side.

@interface RunnerTests : XCTestCase
@end

@implementation RunnerTests

- (void)testNativeSanityCheck {
  XCTAssertTrue(YES, @"native test bundle is reachable");
}

- (void)testNativeArithmetic {
  XCTAssertEqual(2 + 2, 4);
}

@end
