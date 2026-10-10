import Foundation
import Combine

enum AppLanguageChoice: String, CaseIterable, Identifiable {
    case automatic, en, zhHans, zhHant, es

    var id: String { rawValue }
    var nativeName: String {
        switch self {
        case .automatic: return C("Follow System", "跟随系统", "跟隨系統")
        case .en: return "English"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .es: return "Español"
        }
    }

    /// An explicit script takes precedence over regional Chinese defaults.
    func resolved(preferredLanguages: [String]) -> AppLanguageChoice {
        guard self == .automatic else { return self }
        for preference in preferredLanguages {
            let parts = preference.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-")
            guard let base = parts.first else { continue }
            if base == "en" { return .en }
            if base == "es" { return .es }
            if base == "zh" || base == "yue" {
                if parts.contains("hant") { return .zhHant }
                if parts.contains("hans") { return .zhHans }
                return base == "yue" || parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) ? .zhHant : .zhHans
            }
        }
        return .en
    }
}

/// App-specific preferences never change AppleLanguages or other system settings.
/// Existing non-actor L/C callers read a locked translation snapshot.
@MainActor
final class AppLanguage: ObservableObject {
    static let preferenceKey = "interfaceLanguage.v1"
    static let didChangeNotification = Notification.Name("CliplineInterfaceLanguageDidChange")
    static let shared = AppLanguage(defaults: .standard, appliesGlobally: true)

    @Published var selected: AppLanguageChoice {
        didSet {
            guard oldValue != selected else { return }
            defaults.set(selected.rawValue, forKey: Self.preferenceKey)
            refresh()
        }
    }
    @Published private(set) var resolved: AppLanguageChoice
    private let defaults: UserDefaults
    private let preferredLanguages: () -> [String]
    private let appliesGlobally: Bool
    private var localeObserver: NSObjectProtocol?

    /// Isolated instances do not affect process-wide translations.
    init(defaults: UserDefaults = .standard,
         preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages },
         appliesGlobally: Bool = false) {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
        self.appliesGlobally = appliesGlobally
        let selection = defaults.string(forKey: Self.preferenceKey).flatMap(AppLanguageChoice.init(rawValue:)) ?? .automatic
        self.selected = selection
        self.resolved = selection.resolved(preferredLanguages: preferredLanguages())
        if appliesGlobally { LanguageSnapshot.shared.set(resolved) }
        localeObserver = NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func refresh() {
        resolved = selected.resolved(preferredLanguages: preferredLanguages())
        if appliesGlobally {
            LanguageSnapshot.shared.set(resolved)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    deinit {
        if let localeObserver { NotificationCenter.default.removeObserver(localeObserver) }
    }
}

private final class LanguageSnapshot: @unchecked Sendable {
    static let shared = LanguageSnapshot()
    private let lock = NSLock()
    private var language: AppLanguageChoice

    private init() {
        let selected = UserDefaults.standard.string(forKey: "interfaceLanguage.v1").flatMap(AppLanguageChoice.init(rawValue:)) ?? .automatic
        language = selected.resolved(preferredLanguages: Locale.preferredLanguages)
    }

    func get() -> AppLanguageChoice { lock.lock(); defer { lock.unlock() }; return language }
    func set(_ language: AppLanguageChoice) { lock.lock(); defer { lock.unlock() }; self.language = language }
}

func L(_ english: String, _ spanish: String) -> String {
    AppLocalization.text(english, spanish: spanish, language: LanguageSnapshot.shared.get())
}

func C(_ english: String, _ simplified: String, _ traditional: String? = nil) -> String {
    AppLocalization.text(english, simplified: simplified, traditional: traditional, language: LanguageSnapshot.shared.get())
}

enum AppLocalization {
    static func text(_ english: String, spanish: String? = nil, simplified: String? = nil,
                     traditional: String? = nil, language: AppLanguageChoice) -> String {
        switch language {
        case .zhHans: return simplified ?? chinese[english]?.0 ?? english
        case .zhHant:
            if let traditional { return traditional }
            if let value = chinese[english]?.1 { return value }
            // Established UI terminology uses the explicit dictionary below.
            return simplified?.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? simplified ?? english
        case .es: return spanish ?? spanishStrings[english] ?? english
        case .automatic, .en: return english
        }
    }

    static let chinese: [String: (String, String)] = [
        "Hide line": ("收起晾绳", "收起曬衣繩"),
        "Show line": ("展开晾绳", "展開曬衣繩"),
        "Take everything down": ("移除全部截图", "移除所有截圖"),
        "Handle screenshots": ("接管系统截图", "接管系統截圖"),
        "Open screenshots folder": ("打开截图文件夹", "開啟截圖資料夾"),
        "Sounds": ("音效", "音效"),
        "Open at login": ("登录时启动", "登入時啟動"),
        "Quit Clipline": ("退出 Clipline", "結束 Clipline"),
        "Copy": ("复制", "複製"),
        "Open": ("打开", "開啟"),
        "Show in Finder": ("在 Finder 中显示", "在 Finder 中顯示"),
        "Save to Desktop": ("保存到桌面", "儲存到桌面"),
        "Could not move this file to Trash": ("无法将文件移到废纸篓", "無法將檔案移到廢紙簍"),
        "Discard": ("丢弃", "丟棄"),
        "Take down": ("取下", "取下"),
        "Move to Trash": ("移到废纸篓", "移到廢紙簍"),
        "Copied": ("已复制", "已複製"),
        "Turn on": ("开启", "開啟"),
        "Not now": ("暂不开启", "暫時不要"),
        "Take a screenshot and it will hang here": ("截一张图，就会挂在这里", "截一張圖，就會掛在這裡"),
        "Let Clipline handle your screenshots?": ("让 Clipline 接管系统截图？", "讓 Clipline 接管系統截圖？"),
        "Screenshots will hang on the line the instant you take them, without the floating thumbnail, and will not pile up on your Desktop. Drag one to a folder to keep it, or discard it with the cross. You can turn this off from the menu bar, and your settings come back when Clipline quits.": (
            "截图会直接挂到晾绳上，关闭系统浮动缩略图，并保存到 Clipline 专用文件夹。拖到文件夹即可保存，点叉即可丢弃。可从菜单栏关闭此功能，退出时恢复原有截图设置。",
            "截圖會直接掛到曬衣繩上，關閉系統浮動縮圖，並儲存到 Clipline 專用資料夾。拖到資料夾即可儲存，點叉即可丟棄。可從選單列關閉此功能，結束時恢復原有截圖設定。"),
        "Screenshots hang instantly and skip the Desktop": ("截图直接挂到晾绳，不堆积在桌面", "截圖直接掛到曬衣繩，不堆積在桌面"),
        "Could not change the login setting": ("无法更改登录启动设置", "無法更改登入啟動設定"),
        "Move Clipline to the Applications folder and try again.": ("将 Clipline 移到应用程序文件夹，然后重试。", "將 Clipline 移到應用程式資料夾，然後再試一次。"),
        "Screenshots": ("截图", "截圖"),
        "Captures": ("截图与录屏", "截圖與錄影"),
        "Clipboard": ("剪贴板", "剪貼簿"),
        "Clipboard history": ("剪贴板历史", "剪貼簿記錄"),
        "Pause clipboard recording": ("暂停剪贴板记录", "暫停剪貼簿記錄"),
        "Resume clipboard recording": ("继续剪贴板记录", "繼續剪貼簿記錄"),
        "Clear clipboard history": ("清空剪贴板历史", "清空剪貼簿記錄"),
        "Show section controls": ("显示切换栏", "顯示切換列"),
        "Recording": ("正在记录", "正在記錄"),
        "Paused": ("已暂停", "已暫停"),
        "Clipboard history is cleared on quit": ("剪贴板历史退出后清空", "結束後清空剪貼簿記錄"),
        "Pause recording": ("暂停记录", "暫停記錄"),
        "Resume recording": ("继续记录", "繼續記錄"),
        "Copy text or an image to hang it here": ("复制文字或图片，就会挂在这里", "複製文字或圖片，就會掛在這裡"),
        "Clipboard recording is paused": ("剪贴板记录已暂停", "剪貼簿記錄已暫停"),
        "Up to 100 items · cleared when you quit": ("最近 100 条 · 退出后清空", "最近 100 筆 · 結束後清空"),
        "Copy this item to the clipboard": ("将此条目复制到剪贴板", "將此項目複製到剪貼簿"),
        "Remove from history": ("从历史中移除", "從記錄中移除"),
        "Image from ": ("图片，来源：", "圖片，來源："),
        "Pin an image here": ("在此位置固定图片", "在此位置固定圖片"),
        "Choose image…": ("选择图片…", "選擇圖片…"),
        "This screen's pin limit is reached": ("已达到当前屏幕的固定数量上限", "已達到目前螢幕的固定數量上限"),
        "Choose a pinned photo": ("选择要固定的图片", "選擇要固定的圖片"),
        "Pin image": ("固定图片", "固定圖片"),
        "Could not pin this image": ("无法固定这张图片", "無法固定這張圖片"),
        "Choose a readable image file, such as PNG, JPEG or HEIC. The screen's pin limit may also have been reached.": (
            "请选择可读取的 PNG、JPEG 或 HEIC 图片，也可能已达到当前屏幕的固定数量上限。",
            "請選擇可讀取的 PNG、JPEG 或 HEIC 圖片，也可能已達到目前螢幕的固定數量上限。"),
        "Pinned photo": ("固定图片", "固定圖片"),
        "Drag along the rope to move; double-click or right-click for options": (
            "沿晾绳拖动调整位置；双击或右键打开选项", "沿曬衣繩拖曳調整位置；按兩下或按右鍵開啟選項"),
        "Replace image…": ("更换图片…", "更換圖片…"),
        "Move to": ("移到", "移到"),
        "Left": ("左端", "左端"),
        "Center": ("中间", "中間"),
        "Right": ("右端", "右端"),
        "Unpin": ("取消固定", "取消固定"),
        "Settings…": ("设置…", "設定…"),
        "Settings": ("设置", "設定"),
        "Language": ("语言", "語言"),
        "Follow System": ("跟随系统", "跟隨系統"),
        "Interface language": ("界面语言", "介面語言"),
        "Changes take effect immediately": ("更改立即生效", "變更立即生效"),
        "No restart required": ("无需重启", "不需重新啟動"),
        "Clipline Settings": ("Clipline 设置", "Clipline 設定"),
        "Make the clothesline feel at home.": ("按你的习惯使用晾绳。", "依你的習慣使用曬衣繩。"),
        "Language changes take effect immediately.": ("切换语言立即生效。", "切換語言立即生效。"),
        "Clothesline": ("晾绳", "曬衣繩"),
        "Brush": ("画笔", "畫筆"),
        "Arrow": ("箭头", "箭頭"),
        "Rectangle": ("框线", "框線"),
        "Text": ("文字", "文字"),
        "Crop": ("裁切", "裁切"),
        "Undo": ("撤销", "復原"),
        "Redo": ("重做", "重做"),
        "Reset": ("重置", "重設"),
        "Text size": ("字号", "字級"),
        "Width": ("粗细", "粗細"),
        "Apply crop": ("应用裁切", "套用裁切"),
        "Save": ("保存", "儲存"),
        "Save as…": ("另存为…", "另存新檔…"),
        "Edit image": ("编辑图片", "編輯圖片"),
        "Image editor": ("图片编辑器", "圖片編輯器"),
        "Saved a copy: ": ("副本已保存：", "副本已儲存："),
        "Could not read this image.": ("无法读取这张图片。", "無法讀取這張圖片。"),
        "Could not export this image.": ("无法导出这张图片。", "無法匯出這張圖片。"),
        "Enter text, then click the image": ("输入文字后，点击图片放置", "輸入文字後，點選圖片放置"),
        "Drag to select an area": ("拖动选择裁切区域", "拖曳選取裁切區域"),
        "Save creates a PNG copy and keeps the original.": ("保存为 PNG 副本，保留原图。", "儲存為 PNG 副本，保留原圖。"),
        "Choose a different filename to keep the original.": ("请选择其他文件名，保留原图。", "請選擇其他檔名，保留原圖。"),
        "Long-press an image to edit it in Clipline, including over full-screen apps.": ("长按图片，在 Clipline 内编辑；支持在全屏应用上方使用。", "長按圖片，在 Clipline 內編輯；支援在全螢幕應用程式上方使用。"),
        "Highlighter": ("荧光笔", "螢光筆"),
        "Mosaic": ("马赛克", "馬賽克"),
        "Eraser": ("橡皮擦", "橡皮擦"),
        "Free crop": ("自由裁切", "自由裁切"),
        "Cancel crop": ("取消裁切", "取消裁切"),
        "Drag the frame to choose the area": ("拖动裁切框选择保留区域", "拖曳裁切框選取保留區域"),
        "Move the frame; drag corners to resize": ("拖动裁切框，拖动四角调整大小", "拖曳裁切框，拖曳四角調整大小"),
        "Quick crop": ("常用裁切", "常用裁切"),
        "Aspect ratio": ("常用比例", "常用比例"),
        "Pixel size": ("固定尺寸", "固定尺寸"),
        "Block size": ("颗粒大小", "顆粒大小"),
        "Rotate clockwise": ("顺时针旋转", "順時針旋轉"),
        "Rotate counterclockwise": ("逆时针旋转", "逆時針旋轉"),
        "Flip horizontally": ("水平翻转", "水平翻轉"),
        "Flip vertically": ("垂直翻转", "垂直翻轉"),
        "Ellipse": ("椭圆", "橢圓"),
        "Cover": ("遮盖", "遮蓋"),
        "Center Preview windows": ("缩小并居中预览窗口", "縮小並置中預覽視窗"),
        "Double-click tolerance is at least 0.7 seconds; a slower system setting is respected.": ("两次点击间隔可达 0.7 秒；系统设得更慢时也会跟随。", "兩次點擊間隔可達 0.7 秒；系統設得更慢時也會跟隨。"),
        "Accessibility permission granted.": ("辅助功能权限已生效。", "輔助使用權限已生效。"),
        "This copy of Clipline needs Accessibility permission.": ("当前运行的 Clipline 尚未获得辅助功能权限。", "目前執行的 Clipline 尚未取得輔助使用權限。"),
        "Open settings…": ("打开设置…", "開啟設定…"),
        "This is the app location on this Mac; other Macs may use a different location.": ("以下是本机当前应用的位置，每个人的安装位置可能不同。", "以下是此 Mac 目前應用程式的位置，每個人的安裝位置可能不同。"),
        "Show current app in Finder": ("在访达中显示当前应用", "在 Finder 中顯示目前應用程式"),
        "Authorize the running app": ("确认授权的是当前应用", "確認授權的是目前應用程式"),
        "Add this app with + in Accessibility settings. An older copy's permission may not apply.": ("在辅助功能设置中用 + 添加下面这个应用。旧版应用的授权可能不适用于当前版本。", "在輔助使用設定中用 + 加入下面這個應用程式。舊版的授權可能不適用於目前版本。"),
        "Mouse monitoring is unavailable; quit and reopen Clipline after authorizing it.": ("暂时无法监听鼠标；完成授权后请退出并重新打开 Clipline。", "暫時無法監聽滑鼠；完成授權後請結束並重新開啟 Clipline。"),
        "Close this window before trying a double-click in the menu bar.": ("关闭此设置窗口后，再双击菜单栏空白处测试。", "關閉此設定視窗後，再按兩下選單列空白處測試。"),
        "Requires Accessibility permission.": ("需要辅助功能权限。", "需要輔助使用權限。"),
        "Allow…": ("授权…", "授權…"),
        "Clipboard history keeps up to 100 items and is cleared when you quit.": (
            "剪贴板历史最多保留最近 100 条，退出后清空。", "剪貼簿記錄最多保留最近 100 筆，結束程式後清空。"),
        "Taking screenshots down keeps their files and your pinned photos.": (
            "移除截图只取下晾绳上的截图，保留源文件和固定图片。", "移除截圖只取下曬衣繩上的截圖，保留原始檔案與固定圖片。"),
        "History": ("历史管理", "歷史管理"),
        "Screenshot and recording folder": ("截图与录屏保存位置", "截圖與錄影儲存位置"),
        "Change Save to in macOS Screenshot Options. The line follows that folder; pinned photos stay in place.": ("在 macOS 截屏选项中修改保存位置，晾绳会跟随目录；固定图片保持不变。", "在 macOS 截圖選項中修改儲存位置，曬衣繩會跟隨目錄；固定圖片保持不變。"),
        "Restore default folder and instant screenshots": ("恢复默认位置并开启即时截图", "恢復預設位置並開啟即時截圖"),
        "Double-click empty menu-bar space to show or hide the line.": ("双击菜单栏空白处，展开或收起晾绳。", "按兩下選單列空白處，展開或收起曬衣繩。"),
        "Instant screenshots are off; macOS may show its floating thumbnail.": ("即时截图未开启，macOS 仍可能显示浮动缩略图。", "即時截圖未開啟，macOS 仍可能顯示浮動縮圖。"),
        "Instant screenshots are on; the system floating thumbnail is off.": ("即时截图已开启，系统浮动缩略图已关闭。", "即時截圖已開啟，系統浮動縮圖已關閉。"),
        "The selected folder is unavailable. Check its location and access permissions.": ("当前保存目录无法读取，请检查目录位置和访问权限。", "目前儲存目錄無法讀取，請檢查目錄位置與存取權限。"),
        "The system floating thumbnail is on. Restore instant screenshots to remove the delay.": ("系统浮动缩略图已开启，恢复即时截图可消除等待。", "系統浮動縮圖已開啟，恢復即時截圖可消除等待。"),
        "Could not enable instant screenshots.": ("无法开启即时截图。", "無法開啟即時截圖。"),
        "Check access to the selected folders and try again.": ("请检查当前保存目录的访问权限后重试。", "請檢查目前儲存目錄的存取權限後重試。"),
        "The system floating thumbnail will be turned off so captures reach the line without waiting. Save locations remain yours to choose; the line follows changes in Screenshot Options. Turning this off or quitting restores your previous thumbnail setting.": ("关闭系统浮动缩略图，让截图及时挂到晾绳。保存位置仍由你决定，晾绳会跟随系统截屏选项的目录变化。关闭此功能或退出后会恢复之前的缩略图设置。", "關閉系統浮動縮圖，讓截圖及時掛到曬衣繩。儲存位置仍由你決定，曬衣繩會跟隨系統截圖選項的目錄變化。關閉此功能或結束程式後會恢復先前的縮圖設定。")
    ]

    static let spanishStrings: [String: String] = [
        "Captures": "Capturas",
        "Screenshots": "Capturas", "Clipboard": "Portapapeles",
        "Clipboard history": "Historial del portapapeles", "Pause clipboard recording": "Pausar registro del portapapeles",
        "Resume clipboard recording": "Reanudar registro del portapapeles", "Clear clipboard history": "Borrar historial del portapapeles",
        "Show section controls": "Mostrar controles de sección", "Recording": "Registrando", "Paused": "En pausa",
        "Clipboard history is cleared on quit": "El historial se borra al salir", "Pause recording": "Pausar registro", "Resume recording": "Reanudar registro",
        "Copy text or an image to hang it here": "Copia texto o una imagen para colgarla aquí", "Clipboard recording is paused": "El registro del portapapeles está en pausa",
        "Up to 100 items · cleared when you quit": "Hasta 100 elementos · se borran al salir", "Copy this item to the clipboard": "Copiar al portapapeles",
        "Remove from history": "Quitar del historial", "Image from ": "Imagen de ", "Copied": "Copiado", "Copy": "Copiar", "Open": "Abrir",
        "Pin an image here": "Fijar una imagen aquí", "Choose image…": "Elegir imagen…", "This screen's pin limit is reached": "Se alcanzó el límite de imágenes fijas de esta pantalla",
        "Choose a pinned photo": "Elegir una imagen para fijar", "Pin image": "Fijar imagen", "Could not pin this image": "No se pudo fijar esta imagen",
        "Choose a readable image file, such as PNG, JPEG or HEIC. The screen's pin limit may also have been reached.": "Elige una imagen legible, como PNG, JPEG o HEIC. También puede haberse alcanzado el límite de imágenes fijas de la pantalla.",
        "Pinned photo": "Imagen fija", "Drag along the rope to move; double-click or right-click for options": "Arrastra por la cuerda para mover; haz doble clic o clic derecho para ver opciones",
        "Replace image…": "Cambiar imagen…", "Move to": "Mover a", "Left": "Izquierda", "Center": "Centro", "Right": "Derecha", "Unpin": "Desfijar",
        "Could not move this file to Trash": "No se pudo mover el archivo a la Papelera",
        "Settings…": "Ajustes…", "Settings": "Ajustes", "Language": "Idioma", "Follow System": "Seguir al sistema", "Interface language": "Idioma de la interfaz",
        "Changes take effect immediately": "Los cambios se aplican al instante", "No restart required": "No hace falta reiniciar",
        "Clipline Settings": "Ajustes de Clipline", "Make the clothesline feel at home.": "Adapta el tendedero a tu manera de trabajar.",
        "Language changes take effect immediately.": "Los cambios de idioma se aplican al instante.", "Clothesline": "Tendedero",
        "Brush": "Pincel",
        "Arrow": "Flecha",
        "Rectangle": "Rectángulo",
        "Text": "Texto",
        "Crop": "Recortar",
        "Undo": "Deshacer",
        "Redo": "Rehacer",
        "Reset": "Restablecer",
        "Text size": "Tamaño de texto",
        "Width": "Grosor",
        "Apply crop": "Aplicar recorte",
        "Save": "Guardar",
        "Save as…": "Guardar como…",
        "Edit image": "Editar imagen",
        "Image editor": "Editor de imágenes",
        "Saved a copy: ": "Copia guardada: ",
        "Could not read this image.": "No se pudo leer esta imagen.",
        "Could not export this image.": "No se pudo exportar esta imagen.",
        "Enter text, then click the image": "Escribe y haz clic en la imagen",
        "Drag to select an area": "Arrastra para seleccionar un área",
        "Save creates a PNG copy and keeps the original.": "Guardar crea una copia PNG y conserva el original.",
        "Choose a different filename to keep the original.": "Elige otro nombre para conservar el original.",
        "Long-press an image to edit it in Clipline, including over full-screen apps.": "Mantén pulsada una imagen para editarla en Clipline, también sobre apps a pantalla completa.",
        "Highlighter": "Resaltador",
        "Mosaic": "Mosaico",
        "Eraser": "Borrador",
        "Free crop": "Recorte libre",
        "Cancel crop": "Cancelar recorte",
        "Drag the frame to choose the area": "Arrastra el marco para elegir el área",
        "Move the frame; drag corners to resize": "Mueve el marco; arrastra las esquinas para ajustar su tamaño",
        "Quick crop": "Recorte rápido",
        "Aspect ratio": "Proporción",
        "Pixel size": "Tamaño en píxeles",
        "Block size": "Tamaño de bloque",
        "Rotate clockwise": "Girar a la derecha",
        "Rotate counterclockwise": "Girar a la izquierda",
        "Flip horizontally": "Voltear horizontalmente",
        "Flip vertically": "Voltear verticalmente",
        "Ellipse": "Elipse",
        "Cover": "Ocultar",
        "Center Preview windows": "Reducir y centrar ventanas de Vista Previa",
        "Double-click tolerance is at least 0.7 seconds; a slower system setting is respected.": "El intervalo entre clics admite al menos 0,7 segundos; se respeta un ajuste del sistema más lento.",
        "Accessibility permission granted.": "Permiso de Accesibilidad concedido.",
        "This copy of Clipline needs Accessibility permission.": "Esta copia de Clipline necesita permiso de Accesibilidad.",
        "Open settings…": "Abrir ajustes…",
        "This is the app location on this Mac; other Macs may use a different location.": "Esta es la ubicación de la app en este Mac; puede ser distinta en otros Macs.",
        "Show current app in Finder": "Mostrar la app actual en Finder",
        "Authorize the running app": "Autorizar la aplicación en ejecución",
        "Add this app with + in Accessibility settings. An older copy's permission may not apply.": "Añade esta aplicación con + en Accesibilidad. El permiso de una copia anterior puede no aplicarse.",
        "Mouse monitoring is unavailable; quit and reopen Clipline after authorizing it.": "No se pueden detectar clics; cierra y abre Clipline después de autorizarlo.",
        "Close this window before trying a double-click in the menu bar.": "Cierra esta ventana antes de probar el doble clic en la barra de menús.",
        "Requires Accessibility permission.": "Requiere permiso de Accesibilidad.", "Allow…": "Permitir…",
        "Clipboard history keeps up to 100 items and is cleared when you quit.": "El historial del portapapeles guarda hasta 100 elementos y se borra al salir.",
        "Taking screenshots down keeps their files and your pinned photos.": "Descolgar las capturas conserva sus archivos y tus imágenes fijas.", "History": "Historial",
        "Handle screenshots": "Encargarse de las capturas", "Sounds": "Sonidos", "Open at login": "Abrir al iniciar sesión",
        "Take everything down": "Descolgar todo",
        "Screenshot and recording folder": "Carpeta de capturas y grabaciones",
        "Change Save to in macOS Screenshot Options. The line follows that folder; pinned photos stay in place.": "Cambia Guardar en en Opciones de Captura. El tendedero sigue esa carpeta y las imágenes fijas permanecen en su sitio.",
        "Restore default folder and instant screenshots": "Restaurar la carpeta y las capturas instantáneas",
        "Double-click empty menu-bar space to show or hide the line.": "Haz doble clic en un espacio vacío de la barra de menús para mostrar u ocultar el tendedero.",
        "Instant screenshots are off; macOS may show its floating thumbnail.": "Las capturas instantáneas están desactivadas; macOS puede mostrar su miniatura flotante.",
        "Instant screenshots are on; the system floating thumbnail is off.": "Las capturas instantáneas están activadas y la miniatura flotante está desactivada.",
        "The selected folder is unavailable. Check its location and access permissions.": "La carpeta seleccionada no está disponible. Comprueba su ubicación y los permisos de acceso.",
        "The system floating thumbnail is on. Restore instant screenshots to remove the delay.": "La miniatura flotante está activada. Restaura las capturas instantáneas para eliminar la espera.",
        "Could not enable instant screenshots.": "No se pudieron activar las capturas instantáneas.",
        "Check access to the selected folders and try again.": "Comprueba el acceso a las carpetas seleccionadas e inténtalo de nuevo."
    ]
}
