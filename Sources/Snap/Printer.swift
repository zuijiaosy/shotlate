import AppKit

/// Prints an image on one page, scaled down to fit and centered.
enum Printer {
    /// `pdf` writes to a file instead of showing the print panel (used by the self-checks).
    static func operation(for rep: NSBitmapImageRep, pdf: URL? = nil) -> NSPrintOperation {
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        let view = NSImageView(frame: CGRect(origin: .zero, size: rep.size))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        info.orientation = rep.size.width > rep.size.height ? .landscape : .portrait
        if let pdf {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = pdf
        }
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = pdf == nil
        operation.showsProgressPanel = pdf == nil
        operation.jobTitle = Exporter.defaultFileName(format: .png)
        return operation
    }

    static func print(_ rep: NSBitmapImageRep) {
        NSApp.activate()
        operation(for: rep).run()
    }
}
