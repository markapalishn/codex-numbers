.DEFAULT_GOAL := help
APP_NAME := Codex Numbers
BUILD_DIR := build
APP := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR := $(HOME)/Applications
SWIFTC := swiftc
SOURCES := $(wildcard Sources/*.swift)

.PHONY: help build run test clean install uninstall snapshot preview update audit
help: ## Показать команды
	@awk 'BEGIN {FS = ":.*## "} /^[a-z-]+:.*## / {printf "  make %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
build: ## Собрать приложение macOS
	@mkdir -p "$(APP)/Contents/MacOS"
	$(SWIFTC) -O $(SOURCES) -o "$(APP)/Contents/MacOS/CodexNumbers" -framework AppKit
	@cp Info.plist "$(APP)/Contents/Info.plist"
	@codesign --force --sign - "$(APP)"
run: build ## Запустить индикатор
	@open "$(APP)"
test: ## Проверить подсчёт токенов и чтение журналов
	@mkdir -p "$(BUILD_DIR)/tests"
	@cp Tests/UsageTests.swift "$(BUILD_DIR)/tests/main.swift"
	$(SWIFTC) Sources/Usage.swift Sources/Analytics.swift "$(BUILD_DIR)/tests/main.swift" -o "$(BUILD_DIR)/tests/usage-tests"
	@"$(BUILD_DIR)/tests/usage-tests"
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
uninstall: ## Отключить автозапуск и удалить установленную копию
	@python3 scripts/install.py uninstall "$(APP)" "$(INSTALL_DIR)"
clean: ## Удалить только артефакты сборки
	@rm -rf "$(BUILD_DIR)"
