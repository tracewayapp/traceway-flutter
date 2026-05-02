@import XCTest;
@import ObjectiveC.runtime;
@import integration_test;

@interface RunnerTests : XCTestCase
@end

@implementation RunnerTests

- (void)testNativeSanityCheck {
  XCTAssertTrue(YES, @"native test bundle is reachable");
}

+ (NSArray<NSInvocation *> *)testInvocations {
  NSMutableArray<NSInvocation *> *invocations = [NSMutableArray array];

  [invocations addObjectsFromArray:[super testInvocations]];

  FLTIntegrationTestRunner *runner = [[FLTIntegrationTestRunner alloc] init];
  NSMutableSet<NSString *> *seen = [NSMutableSet set];
  [runner testIntegrationTestWithResults:^(SEL testSelector, BOOL success, NSString *failureMessage) {
    NSString *name = NSStringFromSelector(testSelector);
    if ([seen containsObject:name]) return;
    [seen addObject:name];

    IMP imp = imp_implementationWithBlock(^(id _self) {
      XCTAssertTrue(success, @"%@", failureMessage ?: @"(no message)");
    });
    class_addMethod(self, testSelector, imp, "v@:");
    NSMethodSignature *sig = [self instanceMethodSignatureForSelector:testSelector];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = testSelector;
    [invocations addObject:inv];
  }];

  return invocations;
}

@end
