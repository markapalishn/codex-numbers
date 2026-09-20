.DEFAULT_GOAL := help
APP_NAME := Codex Numbers
BUILD_DIR := build
APP := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR := $(HOME)/Applications
SWIFTC := swiftc
VERSION ?= 1.0.4
ARCHS ?= arm64 x86_64
MACOS_VERSION ?= 26.0
RELEASE_DIR := $(BUILD_DIR)/release
RELEASE_NAME := Codex-Numbers-$(VERSION)
RELEASE_DMG := $(RELEASE_DIR)/$(RELEASE_NAME).dmg
DMG_STAGING := $(RELEASE_DIR)/dmg
SOURCES := $(wildcard Sources/*.swift)
UI_SOURCES := $(filter-out Sources/main.swift,$(SOURCES))
UI_TEST_DIR := $(BUILD_DIR)/ui-tests
ICON_SOURCE := Assets/AppIcon.svg
ICONSET := $(BUILD_DIR)/AppIcon.iconset
ICON_FILE := $(BUILD_DIR)/AppIcon.icns

.PHONY: help build icon run test clean install uninstall snapshot preview update audit test-ui package
help: ## Показать команды
	@awk 'BEGIN {FS = ":.*## "} /^[a-z-]+:.*## / {printf "  make %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
$(ICON_FILE): $(ICON_SOURCE)
	@mkdir -p "$(ICONSET)"
	@sips -s format png "$(ICON_SOURCE)" --out "$(BUILD_DIR)/AppIcon-1024.png" >/dev/null
	@for size in 16 32 64 128 256 512; do \
		sips -z $$size $$size "$(BUILD_DIR)/AppIcon-1024.png" --out "$(BUILD_DIR)/AppIcon-$$size.png" >/dev/null || exit $$?; \
	done
	@cp "$(BUILD_DIR)/AppIcon-16.png" "$(ICONSET)/icon_16x16.png"
	@cp "$(BUILD_DIR)/AppIcon-32.png" "$(ICONSET)/icon_16x16@2x.png"
	@cp "$(BUILD_DIR)/AppIcon-32.png" "$(ICONSET)/icon_32x32.png"
	@cp "$(BUILD_DIR)/AppIcon-64.png" "$(ICONSET)/icon_32x32@2x.png"
	@cp "$(BUILD_DIR)/AppIcon-128.png" "$(ICONSET)/icon_128x128.png"
	@cp "$(BUILD_DIR)/AppIcon-256.png" "$(ICONSET)/icon_128x128@2x.png"
	@cp "$(BUILD_DIR)/AppIcon-256.png" "$(ICONSET)/icon_256x256.png"
	@cp "$(BUILD_DIR)/AppIcon-512.png" "$(ICONSET)/icon_256x256@2x.png"
	@cp "$(BUILD_DIR)/AppIcon-512.png" "$(ICONSET)/icon_512x512.png"
	@cp "$(BUILD_DIR)/AppIcon-1024.png" "$(ICONSET)/icon_512x512@2x.png"
	@iconutil -c icns "$(ICONSET)" -o "$(ICON_FILE)"
icon: $(ICON_FILE) ## Собрать иконку приложения
build: $(ICON_FILE) ## Собрать приложение macOS
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources" "$(BUILD_DIR)/architectures"
	@for arch in $(ARCHS); do \
		$(SWIFTC) -O -target $$arch-apple-macosx$(MACOS_VERSION) $(SOURCES) -o "$(BUILD_DIR)/architectures/CodexNumbers-$$arch" -framework AppKit || exit $$?; \
	done
	@lipo -create $(foreach arch,$(ARCHS),"$(BUILD_DIR)/architectures/CodexNumbers-$(arch)") -output "$(APP)/Contents/MacOS/CodexNumbers"
	@cp Info.plist "$(APP)/Contents/Info.plist"
	@cp "$(ICON_FILE)" "$(APP)/Contents/Resources/AppIcon.icns"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)" "$(APP)/Contents/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" "$(APP)/Contents/Info.plist"
	@codesign --force --sign - "$(APP)"
run: build ## Запустить индикатор
	@open "$(APP)"
test: ## Проверить подсчёт токенов и чтение журналов
	@mkdir -p "$(BUILD_DIR)/tests"
	@cp Tests/UsageTests.swift "$(BUILD_DIR)/tests/main.swift"
	$(SWIFTC) Sources/Usage.swift Sources/Analytics.swift "$(BUILD_DIR)/tests/main.swift" -o "$(BUILD_DIR)/tests/usage-tests"
	@"$(BUILD_DIR)/tests/usage-tests"
test-ui: ## Проверить анимации, переключения и сохранить снимки интерфейса
	@mkdir -p "$(UI_TEST_DIR)"
	@cp Tests/AnimationTests.swift "$(UI_TEST_DIR)/main.swift"
	$(SWIFTC) -O $(UI_SOURCES) "$(UI_TEST_DIR)/main.swift" -o "$(UI_TEST_DIR)/animation-tests" -framework AppKit
	@"$(UI_TEST_DIR)/animation-tests" "$(UI_TEST_DIR)"
audit: ## Сверить подсчёт с реальными записями Codex (локально)
	@mkdir -p "$(BUILD_DIR)/audit"
	@cp Tests/JournalAudit.swift "$(BUILD_DIR)/audit/main.swift"
	$(SWIFTC) -O Sources/Usage.swift Sources/Analytics.swift "$(BUILD_DIR)/audit/main.swift" -o "$(BUILD_DIR)/audit/journal-audit"
	@"$(BUILD_DIR)/audit/journal-audit"
snapshot: build ## Показать текущие данные для диагностики
	@"$(APP)/Contents/MacOS/CodexNumbers" --snapshot
preview: build ## Сохранить изображение панели аналитики
	@"$(APP)/Contents/MacOS/CodexNumbers" --preview "$(BUILD_DIR)/analytics-preview.png"
install: build ## Установить и включить автозапуск при входе
	@python3 scripts/install.py install "$(APP)" "$(INSTALL_DIR)"
update: ## Загрузить обновления и переустановить приложение
	@git diff --quiet && git diff --cached --quiet || { echo "Сначала сохраните локальные изменения в Git."; exit 1; }
	git pull --ff-only
	$(MAKE) install
package: build ## Создать DMG для GitHub Releases
	@rm -rf "$(RELEASE_DIR)"
	@mkdir -p "$(DMG_STAGING)"
	@cp -R "$(APP)" "$(DMG_STAGING)/$(APP_NAME).app"
	@ln -sfn /Applications "$(DMG_STAGING)/Программы"
	@hdiutil create -quiet -volname "$(APP_NAME)" -srcfolder "$(DMG_STAGING)" -ov -format UDZO "$(RELEASE_DMG)"
	@rm -rf "$(DMG_STAGING)"
	@echo "Готово: $(RELEASE_DMG)"
uninstall: ## Отключить автозапуск и удалить установленную копию
	@python3 scripts/install.py uninstall "$(APP)" "$(INSTALL_DIR)"
clean: ## Удалить только артефакты сборки
	@rm -rf "$(BUILD_DIR)"
