.PHONY: build test app install run clean

build:
	swift build

test:
	./Scripts/run_tests.sh

app:
	./Scripts/build_app.sh

install: app
	rm -rf /Applications/MacGadgets.app
	cp -R dist/MacGadgets.app /Applications/MacGadgets.app
	@echo "Installed to /Applications/MacGadgets.app"

run: app
	open dist/MacGadgets.app

clean:
	rm -rf .build dist
