import Foundation

extension BinaryInteger {
    /// How every count reads in the UI ("Record 1 of 1000", "300 records", "Rows 1200"): a plain integer without
    /// grouping separators, as Navicat shows it, so the footer, status bar and info pane always agree.
    var countText: String { String(self) }
}

/// "1 table", "2 tables": the noun pluralised for the count (English UI).
func countLabel(_ count: some BinaryInteger, _ singular: String, _ plural: String? = nil) -> String {
    "\(count.countText) \(count == 1 ? singular : plural ?? singular + "s")"
}
