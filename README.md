# Appcircle Xcode Build For Testing

This step builds your application for testing.

Required Input Variables
- `$AC_SCHEME`: Specifies the project scheme for build.
- `$AC_PROJECT_PATH`: Specifies the project path. For example : ./appcircle.xcodeproj.
- `$AC_COMPILER_INDEX_STORE_ENABLE`: You can disable the indexing during the build for faster build.
- `$AC_DESTINATION`: Xcodebuild destination flag. Default : "generic/platform=iOS"

Optional Input Variables
- `$AC_REPOSITORY_DIR`: Specifies the cloned repository directory.
- `$AC_ARCHIVE_FLAGS`: Specifies the extra xcodebuild flag. For example : -configuration DEBUG
- `$AC_CONFIGURATION_NAME`: The configuration to use. You can overwrite it with this option.


Output Variables
- `$AC_TEST_APP_PATH`: Test app path.
- `$AC_UITESTS_RUNNER_PATH`: UI Tests Runner path.
- `$AC_XCTEST_PATH`: XCTest path.
- `$AC_UITESTS_RUNNER_ZIP_PATH`: UI Tests Runner Zip path.
- `$AC_XCTEST_ZIP_PATH`: XCTest Zip path.
- `$AC_TEST_IPA_PATH`: Test ipa path.
