#!/bin/bash

# Set variables
APP_NAME="Click2Hide"
APP_PATH="build/Build/Products/Release/$APP_NAME.app"
DMG_NAME="$APP_NAME.dmg"
DMG_PATH="dist/$DMG_NAME"
TEMP_DIR="temp_dmg_contents" # Temporary directory for DMG contents

# Create the build directory if it doesn't exist
mkdir -p build

# Build the app using xcodebuild
xcodebuild -scheme "$APP_NAME" -configuration Release -derivedDataPath build ARCHS="arm64 x86_64"

# Check if the build was successful
if [ ! -d "$APP_PATH" ]; then
  echo "Build failed. Exiting."
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
