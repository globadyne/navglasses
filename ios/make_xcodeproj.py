#!/usr/bin/env python3
"""
Generates TZGlasses.xcodeproj/project.pbxproj, following the structure of
Meta's DisplayAccess sample (SDK 1.1.0). Re-run after adding or removing
Swift files:  python3 make_xcodeproj.py
"""
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP = "TZGlasses"
SRC = HERE / APP
BUNDLE_ID = "com.keltonnickerson.tzglasses"   # must be unique to your Apple team
DEVELOPMENT_TEAM = "YP59H7P335"   # Kelton Nickerson (Personal Team); set to your own team ID
SDK_VERSION = "1.1.0"
PRODUCTS = ["MWDATCore", "MWDATDisplay", "MWDATMotion", "MWDATInputs", "MWDATMockDevice"]

swift = sorted(p.name for p in SRC.glob("*.swift"))
n = iter(range(1, 10_000))


def oid(prefix):
    return f"{prefix}{next(n):014X}"


file_ref = {f: oid("AA") for f in swift}
build_file = {f: oid("AB") for f in swift}
assets_ref, assets_build = oid("AA"), oid("AB")
plist_ref, ent_ref, app_ref = oid("AA"), oid("AA"), oid("AA")
prod_dep = {p: oid("AD") for p in PRODUCTS}
prod_build = {p: oid("AB") for p in PRODUCTS}
pkg = oid("AE")
main_group, products_group, app_group = oid("AC"), oid("AC"), oid("AC")
target, project = oid("AF"), oid("A0")
ph_sources, ph_frameworks, ph_resources = oid("A1"), oid("A1"), oid("A1")
cfg_t_dbg, cfg_t_rel, cfg_p_dbg, cfg_p_rel = oid("A2"), oid("A2"), oid("A2"), oid("A2")
list_t, list_p = oid("A3"), oid("A3")
# Fixed IDs (outside the counter) so adding these didn't renumber everything else.
xcconfig_ref, config_group = "AA0000000000F001", "AC0000000000F001"

target_settings = """
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_ENTITLEMENTS = {app}/{app}.entitlements;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = {team};
				ENABLE_PREVIEWS = YES;
				INFOPLIST_FILE = {app}/Info.plist;
				IPHONEOS_DEPLOYMENT_TARGET = 17.2;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = {bid};
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_STRICT_CONCURRENCY = minimal;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = 1;""".format(app=APP, bid=BUNDLE_ID, team=DEVELOPMENT_TEAM)

project_common = """
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_C_LANGUAGE_STANDARD = gnu11;
				GCC_NO_COMMON_BLOCKS = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 17.2;
				SDKROOT = iphoneos;"""

L = []
w = L.append
w("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 70;\n\tobjects = {\n")

w("/* Begin PBXBuildFile section */\n")
for f in swift:
    w(f"\t\t{build_file[f]} /* {f} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref[f]} /* {f} */; }};\n")
w(f"\t\t{assets_build} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {assets_ref} /* Assets.xcassets */; }};\n")
for p in PRODUCTS:
    w(f"\t\t{prod_build[p]} /* {p} in Frameworks */ = {{isa = PBXBuildFile; productRef = {prod_dep[p]} /* {p} */; }};\n")
w("/* End PBXBuildFile section */\n\n")

w("/* Begin PBXFileReference section */\n")
w(f"\t\t{app_ref} /* {APP}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {APP}.app; sourceTree = BUILT_PRODUCTS_DIR; }};\n")
for f in swift:
    w(f"\t\t{file_ref[f]} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {f}; sourceTree = \"<group>\"; }};\n")
w(f"\t\t{assets_ref} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\"; }};\n")
w(f"\t\t{ent_ref} /* {APP}.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = {APP}.entitlements; sourceTree = \"<group>\"; }};\n")
w(f"\t\t{plist_ref} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};\n")
w(f"\t\t{xcconfig_ref} /* Meta.xcconfig */ = {{isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Meta.xcconfig; sourceTree = \"<group>\"; }};\n")
w("/* End PBXFileReference section */\n\n")

w("/* Begin PBXFrameworksBuildPhase section */\n")
w(f"\t\t{ph_frameworks} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n")
for p in PRODUCTS:
    w(f"\t\t\t\t{prod_build[p]} /* {p} in Frameworks */,\n")
w("\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n/* End PBXFrameworksBuildPhase section */\n\n")

w("/* Begin PBXGroup section */\n")
w(f"\t\t{main_group} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{app_group} /* {APP} */,\n\t\t\t\t{config_group} /* Config */,\n\t\t\t\t{products_group} /* Products */,\n\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
w(f"\t\t{config_group} /* Config */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{xcconfig_ref} /* Meta.xcconfig */,\n\t\t\t);\n\t\t\tpath = Config;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
w(f"\t\t{products_group} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{app_ref} /* {APP}.app */,\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
w(f"\t\t{app_group} /* {APP} */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n")
for f in swift:
    w(f"\t\t\t\t{file_ref[f]} /* {f} */,\n")
w(f"\t\t\t\t{assets_ref} /* Assets.xcassets */,\n\t\t\t\t{ent_ref} /* {APP}.entitlements */,\n\t\t\t\t{plist_ref} /* Info.plist */,\n")
w(f"\t\t\t);\n\t\t\tpath = {APP};\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n/* End PBXGroup section */\n\n")

w("/* Begin PBXNativeTarget section */\n")
w(f"\t\t{target} /* {APP} */ = {{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {list_t} /* Build configuration list for PBXNativeTarget \"{APP}\" */;\n")
w(f"\t\t\tbuildPhases = (\n\t\t\t\t{ph_sources} /* Sources */,\n\t\t\t\t{ph_frameworks} /* Frameworks */,\n\t\t\t\t{ph_resources} /* Resources */,\n\t\t\t);\n")
w(f"\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = {APP};\n\t\t\tpackageProductDependencies = (\n")
for p in PRODUCTS:
    w(f"\t\t\t\t{prod_dep[p]} /* {p} */,\n")
w(f"\t\t\t);\n\t\t\tproductName = {APP};\n\t\t\tproductReference = {app_ref} /* {APP}.app */;\n\t\t\tproductType = \"com.apple.product-type.application\";\n\t\t}};\n/* End PBXNativeTarget section */\n\n")

w("/* Begin PBXProject section */\n")
w(f"\t\t{project} /* Project object */ = {{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastSwiftUpdateCheck = 2620;\n\t\t\t\tLastUpgradeCheck = 2620;\n\t\t\t}};\n")
w(f"\t\t\tbuildConfigurationList = {list_p} /* Build configuration list for PBXProject \"{APP}\" */;\n\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n")
w(f"\t\t\tmainGroup = {main_group};\n\t\t\tpackageReferences = (\n\t\t\t\t{pkg} /* XCRemoteSwiftPackageReference \"meta-wearables-dat-ios\" */,\n\t\t\t);\n")
w(f"\t\t\tproductRefGroup = {products_group} /* Products */;\n\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n\t\t\ttargets = (\n\t\t\t\t{target} /* {APP} */,\n\t\t\t);\n\t\t}};\n/* End PBXProject section */\n\n")

w("/* Begin PBXResourcesBuildPhase section */\n")
w(f"\t\t{ph_resources} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t\t{assets_build} /* Assets.xcassets in Resources */,\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n/* End PBXResourcesBuildPhase section */\n\n")

w("/* Begin PBXSourcesBuildPhase section */\n")
w(f"\t\t{ph_sources} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n")
for f in swift:
    w(f"\t\t\t\t{build_file[f]} /* {f} in Sources */,\n")
w("\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n/* End PBXSourcesBuildPhase section */\n\n")

w("/* Begin XCBuildConfiguration section */\n")
for cid, name, extra in ((cfg_t_dbg, "Debug", ""), (cfg_t_rel, "Release", "")):
    # Meta's App ID and Client Token come from Config/Meta.xcconfig (and its uncommitted MetaSecrets.xcconfig).
    w(f"\t\t{cid} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbaseConfigurationReference = {xcconfig_ref} /* Meta.xcconfig */;\n\t\t\tbuildSettings = {{{target_settings}{extra}\n\t\t\t}};\n\t\t\tname = {name};\n\t\t}};\n")
dbg = project_common + """
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_TESTABILITY = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				ONLY_ACTIVE_ARCH = YES;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";"""
rel = project_common + """
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_OPTIMIZATION_LEVEL = "-O";
				VALIDATE_PRODUCT = YES;"""
w(f"\t\t{cfg_p_dbg} /* Debug */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{{dbg}\n\t\t\t}};\n\t\t\tname = Debug;\n\t\t}};\n")
w(f"\t\t{cfg_p_rel} /* Release */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{{rel}\n\t\t\t}};\n\t\t\tname = Release;\n\t\t}};\n")
w("/* End XCBuildConfiguration section */\n\n")

w("/* Begin XCConfigurationList section */\n")
w(f"\t\t{list_t} /* Build configuration list for PBXNativeTarget \"{APP}\" */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{cfg_t_dbg} /* Debug */,\n\t\t\t\t{cfg_t_rel} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n")
w(f"\t\t{list_p} /* Build configuration list for PBXProject \"{APP}\" */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{cfg_p_dbg} /* Debug */,\n\t\t\t\t{cfg_p_rel} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n")
w("/* End XCConfigurationList section */\n\n")

w("/* Begin XCRemoteSwiftPackageReference section */\n")
w(f"\t\t{pkg} /* XCRemoteSwiftPackageReference \"meta-wearables-dat-ios\" */ = {{\n\t\t\tisa = XCRemoteSwiftPackageReference;\n\t\t\trepositoryURL = \"https://github.com/meta/meta-wearables-dat-ios\";\n\t\t\trequirement = {{\n\t\t\t\tkind = exactVersion;\n\t\t\t\tversion = {SDK_VERSION};\n\t\t\t}};\n\t\t}};\n")
w("/* End XCRemoteSwiftPackageReference section */\n\n")

w("/* Begin XCSwiftPackageProductDependency section */\n")
for p in PRODUCTS:
    w(f"\t\t{prod_dep[p]} /* {p} */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tpackage = {pkg} /* XCRemoteSwiftPackageReference \"meta-wearables-dat-ios\" */;\n\t\t\tproductName = {p};\n\t\t}};\n")
w("/* End XCSwiftPackageProductDependency section */\n")
w(f"\t}};\n\trootObject = {project} /* Project object */;\n}}\n")

out = HERE / f"{APP}.xcodeproj" / "project.pbxproj"
out.parent.mkdir(exist_ok=True)
out.write_text("".join(L))

# Shared scheme so `xcodebuild -scheme TZGlasses` works straight away.
scheme_dir = HERE / f"{APP}.xcodeproj" / "xcshareddata" / "xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
ref = f'''<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{target}" BuildableName = "{APP}.app" BlueprintName = "{APP}" ReferencedContainer = "container:{APP}.xcodeproj"></BuildableReference>'''
(scheme_dir / f"{APP}.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2620" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            {ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES"></TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
''')
print(f"Wrote {out.relative_to(HERE)} with {len(swift)} Swift files")
