#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WQJITViewController : UITableViewController <UIDocumentPickerDelegate, UISearchResultsUpdating>
- (void)selectBundleID:(NSString *)bundleID;
@end

// Opens the JIT tab in WQ Prism, or pushes JIT Manager in the classic design.
void wq_open_jit_for_bundle_id(UIViewController *source, NSString *bundleID);

NS_ASSUME_NONNULL_END
