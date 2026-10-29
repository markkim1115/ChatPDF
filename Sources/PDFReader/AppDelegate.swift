import AppKit
import PDFKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var welcome: WelcomeWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenus()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        if NSDocumentController.shared.documents.isEmpty { showWelcome(nil) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        for document in NSDocumentController.shared.documents {
            for controller in document.windowControllers {
                (controller as? ReaderWindowController)?.shutdownChat()
            }
        }
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcome(nil) }
        return true
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        filenames.forEach { Self.open(URL(fileURLWithPath: $0)) }
        sender.reply(toOpenOrPrint: .success)
    }
    static func open(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
            if let error { NSApp.presentError(error) }
            if document != nil { (NSApp.delegate as? AppDelegate)?.welcome?.close() }
        }
    }
    @objc func showWelcome(_ sender: Any?) {
        if welcome == nil { welcome = WelcomeWindowController() }
        welcome?.refreshRecents()
        welcome?.showWindow(sender)
        welcome?.window?.makeKeyAndOrderFront(sender)
    }
    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "열기"
        if panel.runModal() == .OK { panel.urls.forEach(Self.open) }
    }

    private var reader: ReaderWindowController? { NSApp.keyWindow?.windowController as? ReaderWindowController }

    // A menu action with an explicit target prevents PDFKit's internal first
    // responder from sending uncorrected rich text to the clipboard.
    @objc func copyText(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { editor.copy(sender) }
        else { reader?.copy(sender) }
    }
    @objc func copyOriginal(_ sender: Any?) { reader?.copyOriginal(sender) }
    @objc func copyCleaned(_ sender: Any?) { reader?.copyCleaned(sender) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copyText(_:)) {
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { return editor.selectedRange().length > 0 }
            return reader?.pdfView.document?.allowsCopying == true && reader?.pdfView.currentSelection?.string?.isEmpty == false
        }
        if menuItem.action == #selector(copyOriginal(_:)) || menuItem.action == #selector(copyCleaned(_:)) {
            return reader?.pdfView.document?.allowsCopying == true && reader?.pdfView.currentSelection?.string?.isEmpty == false
        }
        return true
    }

    private func buildMenus() {
        let main = NSMenu()
        NSApp.mainMenu = main
        let app = submenu("PDF Reader", in: main)
        add("PDF Reader에 관하여", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), to: app)
        app.addItem(.separator())
        let services = submenu("서비스", in: app)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        add("PDF Reader 가리기", #selector(NSApplication.hide(_:)), key: "h", to: app)
        add("기타 가리기", #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option], to: app)
        add("모두 보기", #selector(NSApplication.unhideAllApplications(_:)), to: app)
        app.addItem(.separator())
        add("PDF Reader 종료", #selector(NSApplication.terminate(_:)), key: "q", to: app)

        let file = submenu("파일", in: main)
        add("PDF 열기…", #selector(openDocument(_:)), key: "o", target: self, to: file)
        add("시작 화면", #selector(showWelcome(_:)), key: "n", target: self, to: file)
        file.addItem(.separator())
        add("닫기", #selector(NSWindow.performClose(_:)), key: "w", to: file)
        add("저장", #selector(NSDocument.save(_:)), key: "s", to: file)
        add("다른 이름으로 저장…", #selector(NSDocument.saveAs(_:)), key: "s", modifiers: [.command, .shift], to: file)
        add("저장된 상태로 되돌리기…", #selector(NSDocument.revertToSaved(_:)), to: file)
        file.addItem(.separator())
        add("ChatGPT 대화창", #selector(ReaderWindowController.toggleChat(_:)), key: "g", modifiers: [.command, .option], to: file)
        add("ChatGPT 앱으로 보내기", #selector(ReaderWindowController.sendToChatGPT(_:)), to: file)

        let edit = submenu("편집", in: main)
        add("실행 취소", Selector(("undo:")), key: "z", to: edit)
        add("다시 실행", Selector(("redo:")), key: "z", modifiers: [.command, .shift], to: edit)
        edit.addItem(.separator())
        add("오려두기", #selector(NSText.cut(_:)), key: "x", to: edit)
        add("복사", #selector(copyText(_:)), key: "c", target: self, to: edit)
        add("원문 그대로 복사", #selector(copyOriginal(_:)), key: "c", modifiers: [.command, .shift], target: self, to: edit)
        add("줄바꿈 보정하여 복사", #selector(copyCleaned(_:)), key: "c", modifiers: [.command, .option], target: self, to: edit)
        add("영역 텍스트 인식…", #selector(ReaderWindowController.recognizeRegion(_:)), key: "o", modifiers: [.command, .shift], to: edit)
        add("붙여넣기", #selector(NSText.paste(_:)), key: "v", to: edit)
        add("전체 선택", #selector(NSResponder.selectAll(_:)), key: "a", to: edit)
        edit.addItem(.separator())
        add("문서 검색…", #selector(ReaderWindowController.showSearch(_:)), key: "f", to: edit)
        add("다음 검색 결과", #selector(ReaderWindowController.nextMatch(_:)), key: "g", to: edit)
        add("이전 검색 결과", #selector(ReaderWindowController.previousMatch(_:)), key: "g", modifiers: [.command, .shift], to: edit)
        edit.addItem(.separator())
        add("복사 시 줄바꿈 보정", #selector(ReaderWindowController.toggleCleanCopy(_:)), to: edit)

        let view = submenu("보기", in: main)
        add("사이드바 보기", #selector(ReaderWindowController.toggleSidebar(_:)), key: "s", modifiers: [.command, .option], to: view)
        view.addItem(.separator())
        add("확대", #selector(ReaderWindowController.zoomIn(_:)), key: "+", to: view)
        add("축소", #selector(ReaderWindowController.zoomOut(_:)), key: "-", to: view)
        add("페이지 맞춤", #selector(ReaderWindowController.fitPage(_:)), key: "0", to: view)
        add("실제 크기", #selector(ReaderWindowController.actualSize(_:)), key: "1", to: view)
        view.addItem(.separator())
        add("이전 페이지", #selector(ReaderWindowController.previousPage(_:)), key: String(UnicodeScalar(NSUpArrowFunctionKey)!), modifiers: [.command], to: view)
        add("다음 페이지", #selector(ReaderWindowController.nextPage(_:)), key: String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: [.command], to: view)
        view.addItem(.separator())
        add("전체 화면", #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.command, .control], to: view)

        let annotations = submenu("주석", in: main)
        add("형광펜 표시", #selector(ReaderWindowController.highlight(_:)), key: "h", modifiers: [.command, .shift], to: annotations)
        add("형광펜 지우기", #selector(ReaderWindowController.eraseHighlights(_:)), to: annotations)

        let window = submenu("윈도우", in: main)
        NSApp.windowsMenu = window
        add("최소화", #selector(NSWindow.performMiniaturize(_:)), key: "m", to: window)
        add("확대 / 축소", #selector(NSWindow.performZoom(_:)), to: window)
        window.addItem(.separator())
        add("모두 앞으로 가져오기", #selector(NSApplication.arrangeInFront(_:)), to: window)
    }
    private func submenu(_ title: String, in parent: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        parent.addItem(item)
        return menu
    }
    private func add(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        menu.addItem(item)
    }
}
