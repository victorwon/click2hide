#!/bin/bash

# Set variables
APP_NAME="Click2Hide"
APP_PATH="build/Build/Products/Release/$APP_NAME.app"
DMG_NAME="$APP_NAME.dmg"
DMG_PATH="dist/$DMG_NAME"
TEMP_DIR="temp_dmg_contents"                                     # Temporary directory for DMG contents
CODE_SIGN_IDENTITY="Apple Development: Victor Weng (SBQKADNQZW)" # Replace with your code signing identity

# Create the build directory if it doesn't exist
mkdir -p build

# Clean previous builds
xcodebuild clean -scheme "$APP_NAME" -derivedDataPath build

# Build the app using xcodebuild for both arm64 and x86_64 architectures
xcodebuild -scheme "$APP_NAME" -configuration Release -derivedDataPath build \
  -destination 'platform=macOS,arch=arm64' \
  -destination 'platform=macOS,arch=x86_64'

# Check if the build was successful
if [ ! -d "$APP_PATH" ]; then
  echo "Build failed. Exiting."
  exit 1
fi

# Code sign the app
codesign --deep --force --verify --verbose --sign "$CODE_SIGN_IDENTITY" "$APP_PATH"

# Check if the code signing was successful
if [ $? -ne 0 ]; then
  echo "Code signing failed. Exiting."
  exit 1
fi

# Create the dist directory if it doesn't exist
mkdir -p dist

# Create a temporary folder for DMG contents
mkdir -p "$TEMP_DIR"

# Copy the app to the temporary folder
cp -R "$APP_PATH" "$TEMP_DIR/"

# Create an alias to the Applications folder
ln -s /Applications "$TEMP_DIR/Applications"

# Create a DMG file
hdiutil create "$DMG_PATH" -srcfolder "$TEMP_DIR" -format UDZO -volname "$APP_NAME"

# Clean up temporary files
rm -rf "$TEMP_DIR"

# Check if the DMG was created successfully
if [ -f "$DMG_PATH" ]; then
  echo "DMG created successfully at $DMG_PATH"
else
  echo "Failed to create DMG."
  exit 1
fi
