@import XCTest;
@import integration_test;

@interface RunnerTests : XCTestCase
@end

@implementation RunnerTests

- (void)testNativeSanityCheck {
  XCTAssertTrue(YES, @"native test bundle is reachable");
}

- (void)testFlutterIntegrationTests {
  NSMutableArray<NSString *> *failures = [NSMutableArray array];
  FLTIntegrationTestRunner *runner = [[FLTIntegrationTestRunner alloc] init];
  [runner testIntegrationTestWithResults:^(SEL testSelector, BOOL success, NSString *failureMessage) {
    if (!success) {
      [failures addObject:[NSString stringWithFormat:@"%@: %@",
                           NSStringFromSelector(testSelector),
                           failureMessage ?: @"(no message)"]];
    }
  }];
  XCTAssertEqual(failures.count, (NSUInteger)0,
                 @"Flutter test failures:\n%@",
                 [failures componentsJoinedByString:@"\n"]);
}

@end
