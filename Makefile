.DEFAULT_GOAL := help
APP_NAME := Codex Numbers
BUILD_DIR := build
APP := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR := $(HOME)/Applications
SWIFTC := swiftc
VERSION ?= 1.0.0
ARCHS ?= arm64 x86_64
MACOS_VERSION ?= 26.0
RELEASE_DIR := $(BUILD_DIR)/release
RELEASE_NAME := Codex-Numbers-$(VERSION)
RELEASE_DMG := $(RELEASE_DIR)/$(RELEASE_NAME).dmg
DMG_STAGING := $(RELEASE_DIR)/dmg
SOURCES := $(wildcard Sources/*.swift)
UI_SOURCES := $(filter-out Sources/main.swift,$(SOURCES))
UI_TEST_DIR := $(BUILD_DIR)/ui-tests

.PHONY: help build run test clean install uninstall snapshot preview update audit test-ui package
help: ## Показать команды
	@awk 'BEGIN {FS = ":.*## "} /^[a-z-]+:.*## / {printf "  make %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
build: ## Собрать приложение macOS
	@mkdir -p "$(APP)/Contents/MacOS" "$(BUILD_DIR)/architectures"
	@for arch in $(ARCHS); do \
		$(SWIFTC) -O -target $$arch-apple-macosx$(MACOS_VERSION) $(SOURCES) -o "$(BUILD_DIR)/architectures/CodexNumbers-$$arch" -framework AppKit || exit $$?; \
	done
	@lipo -create $(foreach arch,$(ARCHS),"$(BUILD_DIR)/architectures/CodexNumbers-$(arch)") -output "$(APP)/Contents/MacOS/CodexNumbers"
	@cp Info.plist "$(APP)/Contents/Info.plist"
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
