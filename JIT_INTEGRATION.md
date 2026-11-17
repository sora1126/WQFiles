# Built-in StikJIT integration

## Source investigation and plan

This branch starts from `sora1126/WQFiles` `main` at `9628a5a` (WQFiles 0.9.13). It descends from the requested v0.9.5 base and contains the four-tab WQ Prism interface shown in the request. Keeping that baseline preserves its later file-manager fixes. `WQPrismTabController` in `main.m` owns the bottom navigation. `WQAppsViewController` in `WQApps.m` owns the app list and its action menu. `build.sh` makes the ad-hoc IPA and `tests/run_all_tests.sh` is its preflight gate.

The implementation follows this sequence:

1. Add a fifth JIT tab between Clean and Backups, using the same navigation and theme hooks.
2. Import `.mobiledevicepairing` (legacy `.plist` also accepted) through the iOS document picker and retain the bytes in this device's Keychain with `AfterFirstUnlockThisDeviceOnly` protection. The pairing bytes are never put into Git or the shared log.
3. Run StikJIT in a bundled Helper Extension. A process cannot synchronously debug itself. The host sends pairing bytes through one extension request; the helper writes a temporary file for StikJIT and deletes it on completion.
4. Extend the pinned StikJIT source with a small AppService listing API (`jit/stikjit-apps.patch`). The helper obtains installed apps and their running PIDs over the RSD tunnel. Enabling JIT resolves the selected bundle ID again immediately before calling `StikJIT.enableJIT`, so a stale PID is never reused.
5. Stream preparation and debugger progress to a temporary log in WQFiles' existing App Group, show it in JIT Manager, and include final logs in the response if sharing is unavailable. Add **Enable JIT** to Apps' tap and long-press menus.
6. Build the framework, helper, and IPA on the `xcode-27` GitHub Actions runner; validate the nested signatures and publish the IPA as a workflow artifact.

## Build and signing

On macOS with Xcode 27.1 or later, XcodeGen, and network access, run `bash build.sh`. The script fetches StikJIT at pinned commit `a9ccad90c7a8cb547f77ff338890e6633a65ac43`, applies the checked-in API patch, builds the framework and helper, signs each nested component and the app, then validates the IPA. GitHub Actions runs this path and uploads `WQFiles.ipa`. The artifact is **ad-hoc signed** and must be re-signed by SideStore or another installer.

The IPA contains one app, `PlugIns/WQJITHelper.appex`, and `Frameworks/StikJIT.framework`; it does not install StikDebug. The helper has its own bundle identifier (`cz.kolbi.wqfiles.JITHelper`) and uses the same existing App Group as WQFiles for progress. A sideloader must retain and sign both nested components, preserve the App Group, and grant the helper its own App ID or use a compatible profile-reuse option. WQFiles reads the helper's installed identifier at run time to tolerate sideloader renaming. The helper uses the classic `com.apple.ar.viewer` extension point and private `NSExtension` launch methods, as other sideloaded built-in StikJIT integrations do; this is not a stable public iOS API.

## Runtime requirements and limits

- The user must enable Developer Mode, connect LocalDevVPN, and import this device's pairing file. LocalDevVPN is available from the App Store.
- The selected target must be running and signed with `get-task-allow`. A target without that entitlement cannot receive JIT from StikJIT.
- On TXM/SPTM devices, a debugger attach alone is insufficient. The target's JIT allocator must implement the universal breakpoint protocol and prepare executable regions before detaching. WQFiles cannot retrofit that behavior into arbitrary apps. The target app must verify that JIT is actually usable after the debugger operation.
- Multiple targets can be selected and enabled sequentially; each operation resolves the target's current PID. WQFiles does not claim success from merely launching the helper.
- SideStore's free Apple ID permits three active sideloaded apps including SideStore and ten App IDs per week. SideStore + WQFiles leaves one sideloaded app slot for a target at a time. An embedded extension is not a separate home-screen app but can require another App ID. Multiple target registrations still work; concurrent sideloaded targets need another signing method or paid account.
- Upstream WQFiles reports worse_query file access patched from iOS 27.3 beta 2. The JIT tunnel is separate, but this combined build has **not** been tested on iOS 27. The startup health screen's **Continue Anyway** permits entering JIT Manager if file access fails.

## Device validation pending

After installing the Actions IPA, confirm that SideStore retains the helper and framework, signs the helper App ID and App Group, and that Keychain pairing survives relaunch. On iOS 26 and 27, test LocalDevVPN reachability, app/PID listing, DDI download and mount, real-time progress, cache reset, and repeated JIT operations with two known-compatible external targets. Test missing `get-task-allow`, an app that exits before attach, and TXM/SPTM targets that do and do not implement the universal protocol. No physical-device success is claimed by the CI build.

References: [WQFiles v0.9.5](https://github.com/kolbicz/WQFiles/releases/tag/v0.9.5), [StikJIT official integration guide](https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md), [SideStore FAQ](https://docs.sidestore.io/docs/faq.html), [SideStore release notes](https://docs.sidestore.io/docs/release-notes), [LocalDevVPN App Store listing](https://apps.apple.com/jp/app/localdevvpn/id6755608044).
