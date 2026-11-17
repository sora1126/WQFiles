#import "WQJIT.h"
#import "WQAccess.h"
#import "WQUI.h"
#import "WQLocalization.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <Security/Security.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <stdlib.h>

static NSString *const kJITRequestKey = @"wq-jit-request";
static NSString *const kJITResponseKey = @"wq-jit-response";
static NSString *const kJITService = @"cz.kolbi.wqfiles.jit.pairing";

static NSDictionary *wq_jit_keychain_query(void)
{
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService: kJITService,
             (__bridge id)kSecAttrAccount: @"device"};
}

static NSData *wq_jit_pairing_data(void)
{
    NSMutableDictionary *query = wq_jit_keychain_query().mutableCopy;
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef value = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &value);
    if (status != errSecSuccess || !value) return nil;
    return CFBridgingRelease(value);
}

static BOOL wq_jit_save_pairing(NSData *data, NSString **errorText)
{
    NSDictionary *query = wq_jit_keychain_query();
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query,
        (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData: data});
    if (status == errSecItemNotFound) {
        NSMutableDictionary *newItem = query.mutableCopy;
        newItem[(__bridge id)kSecValueData] = data;
        newItem[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        status = SecItemAdd((__bridge CFDictionaryRef)newItem, NULL);
    }
    if (status == errSecSuccess) return YES;
    if (errorText) *errorText = [NSString stringWithFormat:@"Keychain could not save the pairing file (%d).", (int)status];
    return NO;
}

@interface WQJITViewController ()
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> *applications;
@property (nonatomic, copy) NSArray<NSDictionary *> *visibleApplications;
@property (nonatomic, copy, nullable) NSString *selectedBundleID;
@property (nonatomic, copy) NSString *status;
@property (nonatomic, strong) NSMutableArray<NSString *> *logs;
@property (nonatomic, strong, nullable) id activeExtension;
@property (nonatomic, strong, nullable) NSTimer *logTimer;
@property (nonatomic, strong, nullable) NSURL *logURL;
@property (nonatomic) NSUInteger streamedLineCount;
@property (nonatomic) double fraction;
@property (nonatomic) BOOL busy;
@property (nonatomic) BOOL promptedForPairing;
- (void)performOperation:(NSString *)operation;
- (void)showError:(NSString *)message;
@end

@implementation WQJITViewController

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _status = @"Pairing file required";
        _logs = [NSMutableArray new];
        _visibleApplications = @[];
        _fraction = -1;
        self.title = @"JIT Manager";
    }
    return self;
}

- (void)dealloc { [_logTimer invalidate]; }

- (void)viewDidLoad
{
    [super viewDidLoad];
    if (wq_prism_enabled()) {
        wq_prism_install_background(self);
        self.tableView.backgroundColor = UIColor.clearColor;
    }
    self.tableView.tableHeaderView = wq_device_header(self.view.bounds.size.width);
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refreshApps)];
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"Search JIT targets";
    self.navigationItem.searchController = search;
    self.definesPresentationContext = YES;
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (!wq_jit_pairing_data().length) {
        if (_promptedForPairing || self.presentedViewController) return;
        _promptedForPairing = YES;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Import pairing file"
            message:@"JIT Manager needs this device's .mobiledevicepairing file, Developer Mode, and a connected LocalDevVPN."
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Choose File" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) { [self importPairing]; }]];
        [self presentViewController:alert animated:YES completion:nil];
    } else if (!self.applications && !self.busy) {
        [self refreshApps];
    }
}

- (void)selectBundleID:(NSString *)bundleID
{
    self.selectedBundleID = [bundleID copy];
    if (self.isViewLoaded) [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    NSString *query = searchController.searchBar.text ?: @"";
    if (!query.length) self.visibleApplications = self.applications ?: @[];
    else {
        NSPredicate *matches = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *app, __unused NSDictionary *bindings) {
            return [app[@"name"] localizedCaseInsensitiveContainsString:query]
                || [app[@"bundleIdentifier"] localizedCaseInsensitiveContainsString:query];
        }];
        self.visibleApplications = [self.applications filteredArrayUsingPredicate:matches];
    }
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView { return 4; }

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 3;
    if (section == 1) return (NSInteger)self.visibleApplications.count;
    if (section == 2) return 2;
    return (NSInteger)self.logs.count;
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForHeaderInSection:(NSInteger)section
{
    return @[@"Connection", @"Installed apps", @"Actions", @"Detailed log"][(NSUInteger)section];
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0) return @"The pairing file is stored in this device's protected Keychain. It is sent only to the bundled JIT helper for each request.";
    if (section == 1) return @"Open the target app first, then return here and refresh. Only running apps have a PID. The target must be signed with get-task-allow; on TXM/SPTM devices it must support StikJIT's universal breakpoint protocol.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"jit"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"jit"];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = self.busy ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    cell.imageView.image = nil;
    cell.detailTextLabel.text = nil;
    cell.textLabel.numberOfLines = indexPath.section == 3 ? 0 : 1;
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Pairing file";
            cell.detailTextLabel.text = wq_jit_pairing_data().length ? @"Imported · tap to replace" : @"Required · tap to import";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Status";
            cell.detailTextLabel.text = self.status;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            cell.textLabel.text = @"Prepare device";
            cell.detailTextLabel.text = self.busy && self.fraction >= 0
                ? [NSString stringWithFormat:@"%.0f%%", self.fraction * 100] : @"Check tunnel and Developer Disk Image";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if (indexPath.section == 1) {
        NSDictionary *app = self.visibleApplications[(NSUInteger)indexPath.row];
        NSString *bundleID = app[@"bundleIdentifier"];
        cell.textLabel.text = app[@"name"];
        NSNumber *pid = [app[@"pid"] isKindOfClass:NSNumber.class] ? app[@"pid"] : nil;
        cell.detailTextLabel.text = pid ? [NSString stringWithFormat:@"%@ · PID %@", bundleID, pid] : [NSString stringWithFormat:@"%@ · not running", bundleID];
        cell.imageView.image = wq_app_icon(bundleID) ?: [UIImage systemImageNamed:@"app.dashed"];
        cell.accessoryType = [bundleID isEqualToString:self.selectedBundleID]
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    } else if (indexPath.section == 2) {
        cell.textLabel.text = indexPath.row == 0 ? @"Enable JIT" : @"Reset Developer Disk Image";
        cell.detailTextLabel.text = indexPath.row == 0 ? self.selectedBundleID : @"Recovery after a failed download or iOS update";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        cell.textLabel.text = self.logs[(NSUInteger)indexPath.row];
        cell.textLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.textLabel.enabled = !self.busy || indexPath.section == 3;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.busy) return;
    if (indexPath.section == 0 && indexPath.row == 0) [self importPairing];
    else if (indexPath.section == 0 && indexPath.row == 2) [self performOperation:@"prepare"];
    else if (indexPath.section == 1) {
        self.selectedBundleID = self.visibleApplications[(NSUInteger)indexPath.row][@"bundleIdentifier"];
        [tableView reloadData];
    } else if (indexPath.section == 2 && indexPath.row == 0) {
        if (!self.selectedBundleID.length) { [self showError:@"Select a running app first."]; return; }
        [self performOperation:@"enable"];
    } else if (indexPath.section == 2) [self performOperation:@"reset"];
}

- (void)importPairing
{
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *__unused)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *url = urls.firstObject;
    if (!url) return;
    NSString *extension = url.pathExtension.lowercaseString;
    if (![@[@"mobiledevicepairing", @"plist"] containsObject:extension]) {
        [self showError:@"Choose a .mobiledevicepairing file (or a legacy pairing .plist)."];
        return;
    }
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSError *error = nil;
    NSNumber *size = nil;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    NSData *data = size.unsignedLongLongValue <= 1024 * 1024
        ? [NSData dataWithContentsOfURL:url options:0 error:&error] : nil;
    if (scoped) [url stopAccessingSecurityScopedResource];
    id plist = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:&error] : nil;
    if (data.length > 1024 * 1024 ||
        ![plist isKindOfClass:NSDictionary.class] || ![(NSDictionary *)plist count]) {
        [self showError:error.localizedDescription ?: @"Pairing file is invalid or exceeds 1 MB."];
        return;
    }
    NSString *saveError = nil;
    if (!wq_jit_save_pairing(data, &saveError)) { [self showError:saveError]; return; }
    self.applications = nil;
    self.visibleApplications = @[];
    self.status = @"Pairing imported · connecting…";
    [self.logs removeAllObjects];
    [self.tableView reloadData];
    [self refreshApps];
}

- (void)refreshApps
{
    if (!self.busy) [self performOperation:@"list"];
}

- (NSURL *)newLogURLForToken:(NSString *)token group:(NSString *)group
{
    NSURL *root = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group];
    if (!root) return nil;
    NSURL *folder = [root URLByAppendingPathComponent:@"Library/Caches/WQJIT" isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES
                                                  attributes:nil error:nil]) return nil;
    return [folder URLByAppendingPathComponent:[token stringByAppendingString:@".jsonl"]];
}

- (void)pollLog
{
    NSData *data = self.logURL ? [NSData dataWithContentsOfURL:self.logURL] : nil;
    NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSUInteger complete = [text hasSuffix:@"\n"] ? lines.count - 1 : lines.count > 0 ? lines.count - 1 : 0;
    if (complete <= self.streamedLineCount) return;
    for (NSUInteger index = self.streamedLineCount; index < complete; index++) {
        NSData *line = [lines[index] dataUsingEncoding:NSUTF8StringEncoding];
        id parsed = line ? [NSJSONSerialization JSONObjectWithData:line options:0 error:nil] : nil;
        NSDictionary *event = [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
        NSString *message = [event[@"text"] isKindOfClass:NSString.class] ? event[@"text"] : nil;
        if (message.length) {
            [self.logs addObject:message];
            self.status = message;
        }
        if ([event[@"fraction"] isKindOfClass:NSNumber.class]) self.fraction = [event[@"fraction"] doubleValue];
    }
    self.streamedLineCount = complete;
    [self.tableView reloadData];
}

- (void)finishWithResponse:(NSDictionary *)response error:(NSString *)errorText
{
    if (!self.busy) return;
    [self pollLog];
    [self.logTimer invalidate];
    self.logTimer = nil;
    if (self.logURL) [NSFileManager.defaultManager removeItemAtURL:self.logURL error:nil];
    self.logURL = nil;
    self.activeExtension = nil;
    self.busy = NO;
    self.navigationItem.rightBarButtonItem.enabled = YES;
    NSArray *finalLogs = [response[@"logs"] isKindOfClass:NSArray.class] ? response[@"logs"] : nil;
    if (finalLogs) self.logs = [finalLogs mutableCopy];
    NSArray *apps = [response[@"applications"] isKindOfClass:NSArray.class] ? response[@"applications"] : nil;
    if (apps) {
        self.applications = apps;
        [self updateSearchResultsForSearchController:self.navigationItem.searchController];
    }
    NSString *message = errorText ?: ([response[@"message"] isKindOfClass:NSString.class]
        ? response[@"message"] : @"The helper returned no result.");
    self.status = message;
    self.fraction = [response[@"success"] boolValue] ? 1 : -1;
    [self.tableView reloadData];
    if (errorText || ![response[@"success"] boolValue]) [self showError:message];
}

- (void)performOperation:(NSString *)operation
{
    if (self.busy) return;
    if (getenv("LC_HOME_PATH")) { [self showError:@"The bundled helper cannot run inside LiveContainer."]; return; }
    NSData *pairing = [operation isEqualToString:@"reset"] ? nil : wq_jit_pairing_data();
    if (![operation isEqualToString:@"reset"] && !pairing.length) {
        [self showError:@"Import this device's pairing file first."]; return;
    }
    NSURL *helperURL = [NSBundle.mainBundle.builtInPlugInsURL URLByAppendingPathComponent:@"WQJITHelper.appex"];
    NSString *identifier = [NSBundle bundleWithURL:helperURL].bundleIdentifier;
    if (!identifier.length) { [self showError:@"The JIT helper extension is missing from this installation."]; return; }
    if (!NSClassFromString(@"NSExtension"))
        (void)dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW);
    Class extensionClass = NSClassFromString(@"NSExtension");
    SEL factory = NSSelectorFromString(@"extensionWithIdentifier:error:");
    if (!extensionClass || ![extensionClass respondsToSelector:factory]) {
        [self showError:@"The system JIT helper API is unavailable."]; return;
    }
    NSError *error = nil;
    id extension = ((id (*)(id, SEL, NSString *, NSError **))objc_msgSend)(extensionClass, factory, identifier, &error);
    if (!extension) { [self showError:error.localizedDescription ?: @"JIT helper could not start."]; return; }
    SEL completionSelector = NSSelectorFromString(@"setRequestCompletionBlock:");
    SEL cancellationSelector = NSSelectorFromString(@"setRequestCancellationBlock:");
    SEL interruptionSelector = NSSelectorFromString(@"setRequestInterruptionBlock:");
    SEL beginSelector = NSSelectorFromString(@"beginExtensionRequestWithInputItems:completion:");
    if (![extension respondsToSelector:completionSelector] ||
        ![extension respondsToSelector:cancellationSelector] ||
        ![extension respondsToSelector:interruptionSelector] ||
        ![extension respondsToSelector:beginSelector]) {
        [self showError:@"This iOS version does not provide the required JIT helper request methods."];
        return;
    }
    NSString *group = wq_app_group();
    NSString *token = NSUUID.UUID.UUIDString;
    self.logURL = group ? [self newLogURLForToken:token group:group] : nil;
    self.streamedLineCount = 0;
    NSMutableDictionary *request = [@{@"operation": operation, @"logToken": token} mutableCopy];
    if (pairing) request[@"pairingData"] = [pairing base64EncodedStringWithOptions:0];
    if (self.selectedBundleID) request[@"bundleIdentifier"] = self.selectedBundleID;
    if (group) request[@"groupIdentifier"] = group;
    NSData *payload = [NSJSONSerialization dataWithJSONObject:request options:0 error:&error];
    if (!payload) { [self showError:error.localizedDescription ?: @"Could not encode JIT request."]; return; }
    NSExtensionItem *item = [NSExtensionItem new];
    item.userInfo = @{kJITRequestKey: payload};
    self.activeExtension = extension;
    self.busy = YES;
    self.status = @"Starting helper…";
    self.fraction = 0;
    self.navigationItem.rightBarButtonItem.enabled = NO;
    [self.logs removeAllObjects];
    [self.tableView reloadData];
    self.logTimer = [NSTimer scheduledTimerWithTimeInterval:0.3 target:self
        selector:@selector(pollLog) userInfo:nil repeats:YES];
    __weak typeof(self) weakSelf = self;
    void (^complete)(NSUUID *, NSArray *) = ^(__unused NSUUID *requestID, NSArray *items) {
        NSData *data = [(NSExtensionItem *)items.firstObject userInfo][kJITResponseKey];
        id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *response = [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf finishWithResponse:response error:nil]; });
    };
    ((void (*)(id, SEL, id))objc_msgSend)(extension, completionSelector, complete);
    void (^cancel)(NSUUID *, NSError *) = ^(__unused NSUUID *requestID, NSError *reason) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishWithResponse:nil error:reason.localizedDescription ?: @"JIT helper stopped unexpectedly."];
        });
    };
    ((void (*)(id, SEL, id))objc_msgSend)(extension, cancellationSelector, cancel);
    ((void (*)(id, SEL, id))objc_msgSend)(extension, interruptionSelector, ^(__unused NSUUID *requestID) { cancel(nil, nil); });
    ((void (*)(id, SEL, NSArray *, id))objc_msgSend)(extension,
        beginSelector, @[item], ^(NSUUID *requestID) {
            if (!requestID) cancel(nil, nil);
        });
}

- (void)showError:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"JIT Manager" message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

void wq_open_jit_for_bundle_id(UIViewController *source, NSString *bundleID)
{
    UITabBarController *tabs = source.tabBarController;
    if (tabs.viewControllers.count > 3) {
        UINavigationController *nav = (UINavigationController *)tabs.viewControllers[3];
        if ([nav.viewControllers.firstObject isKindOfClass:WQJITViewController.class]) {
            [(WQJITViewController *)nav.viewControllers.firstObject selectBundleID:bundleID];
            tabs.selectedIndex = 3;
            return;
        }
    }
    WQJITViewController *manager = [WQJITViewController new];
    [manager selectBundleID:bundleID];
    [source.navigationController pushViewController:manager animated:YES];
}
