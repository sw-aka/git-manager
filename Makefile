.PHONY: gen build test run clean

gen:
	/opt/homebrew/bin/xcodegen generate

build:
	xcodebuild -project GitManager.xcodeproj -scheme GitManager -configuration Release -derivedDataPath build/DerivedData build
	mkdir -p build
	ditto build/DerivedData/Build/Products/Release/GitManager.app build/GitManager.app

test:
	xcodebuild -project GitManager.xcodeproj -scheme GitManager -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS' test

run:
	open build/GitManager.app

clean:
	rm -rf build GitManager.xcodeproj
