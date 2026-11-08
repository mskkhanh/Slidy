import AppKit

/// Single source for the shortcut list shown by ⌘/. Update it when a shortcut is added or changed.
enum Shortcuts {
    static let sections: [(title: String, items: [(keys: String, action: String)])] = [
        ("Tệp", [
            ("⌘O", "Mở bài trình chiếu"),
            ("⌘E", "Hiện danh sách bài đã mở ở cột trái (Esc hoặc ⌘E để quay lại các slide)"),
            ("⌘S", "Lưu bản sao (thay đổi luôn tự lưu vào file gốc)"),
            ("⌘Q", "Thoát")
        ]),
        ("Sửa", [
            ("⌘Z / ⇧⌘Z", "Hoàn tác / Làm lại"),
            ("⌘X  ⌘C  ⌘V", "Cắt / Sao chép / Dán (cả ảnh)"),
            ("⌘A", "Chọn tất cả")
        ]),
        ("Chèn và hiệu ứng", [
            ("T", "Thêm khối văn bản"),
            ("H", "Thêm tiêu đề"),
            ("F", "Bật / tắt hiệu ứng Fade cho đối tượng đã chọn"),
            ("⌘↑ / ⌘↓", "Dời hiệu ứng Fade lên / xuống thứ tự: chọn hàng ở danh sách Fade bên phải, hoặc chọn đối tượng trên slide"),
            ("⌫ hoặc F", "Gỡ nhóm Fade đang chọn ở thanh bên phải")
        ]),
        ("Đối tượng trên slide", [
            ("Enter", "Sửa chữ trong đối tượng đã chọn"),
            ("⇧Enter", "Xuống dòng trong khối chữ"),
            ("Esc", "Thoát chế độ sửa chữ"),
            ("← ↑ ↓ →", "Dịch đối tượng 1 px (giữ ⇧ để dịch 10 px)"),
            ("⌫", "Xóa đối tượng")
        ]),
        ("Trình chiếu", [
            ("⌘F hoặc ⌘Enter", "Trình chiếu từ slide hiện tại"),
            ("→ ↓ Space Enter", "Bước tiếp theo"),
            ("← ↑", "Bước trước"),
            ("Esc", "Thoát trình chiếu")
        ]),
        ("Hiển thị", [
            ("⌘L", "Chuyển chế độ tối / sáng (chỉ đổi cách hiển thị, không đổi file)")
        ]),
        ("Trợ giúp", [
            ("⌘/", "Hiện / ẩn bảng phím tắt này")
        ])
    ]
}

final class ShortcutsPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        title = "Phím tắt"
        let heading = NSTextField(labelWithString: "Phím tắt")
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        for section in Shortcuts.sections {
            let header = NSTextField(labelWithString: section.title.uppercased())
            header.font = .systemFont(ofSize: 11, weight: .semibold); header.textColor = .secondaryLabelColor
            stack.addArrangedSubview(header)
            stack.setCustomSpacing(10, after: stack.views.last ?? header)
            for item in section.items {
                let keys = NSTextField(labelWithString: item.keys)
                keys.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
                keys.widthAnchor.constraint(equalToConstant: 140).isActive = true
                let action = NSTextField(wrappingLabelWithString: item.action)
                action.font = .systemFont(ofSize: 12)
                let row = NSStackView(views: [keys, action]); row.alignment = .firstBaseline; row.spacing = 12
                stack.addArrangedSubview(row)
            }
            stack.setCustomSpacing(16, after: stack.views.last ?? header)
        }
        let flipped = FlippedView(); flipped.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: flipped.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor, constant: -12),
            flipped.widthAnchor.constraint(equalToConstant: 500)
        ])
        let scroll = NSScrollView(); scroll.documentView = flipped; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let close = NSButton(title: "Đóng", target: self, action: #selector(closeSheet))
        close.keyEquivalent = "\u{1b}"
        let root = NSView()
        for view in [heading, scroll, close] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8), scroll.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -10),
            close.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), close.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        contentView = root
    }
    @objc private func closeSheet() { sheetParent?.endSheet(self) }
    override func cancelOperation(_ sender: Any?) { closeSheet() }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }
