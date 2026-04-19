#!/bin/bash
TARGET_XCFRAMEWORK="/Users/xshen/workspace/clashx2/Frameworks/Libbox.xcframework"

fix_slice() {
    SLICE_PATH="$1"
    echo "Fixing slice: $SLICE_PATH"
    FRAMEWORK_PATH="$SLICE_PATH/Libbox.framework"
    
    if [ -d "$FRAMEWORK_PATH/Versions" ]; then
        cd "$FRAMEWORK_PATH"
        # 1. Remove symlinks at root
        rm -f Headers Libbox Modules Resources
        
        # 2. Copy contents from Versions/A to root
        cp -R Versions/A/* ./
        
        # 3. Flatten Resources if needed (Info.plist should be at root)
        if [ -d "Resources" ]; then
            cp -R Resources/* ./
            rm -rf Resources
        fi
        
        # 4. Remove Versions folder
        rm -rf Versions
        echo "Successfully flattened $FRAMEWORK_PATH"
    else
        echo "No Versions found in $FRAMEWORK_PATH, already flattened or different format."
    fi
}

fix_slice "$TARGET_XCFRAMEWORK/ios-arm64"
fix_slice "$TARGET_XCFRAMEWORK/ios-arm64_x86_64-simulator"
