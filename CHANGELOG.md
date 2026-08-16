# Changelog

## 1.0.3 - 2026-08-08

- Fixed invalid XLSX archive paths created by Windows path separators.
- Added a persistent diagnostic log and an **Open Log File** button.
- Added detailed exception and stack information to export failures.
- Preserved temporary workbook files when export validation fails.
- Validated the completed XLSX package before reporting success.

## 1.0.2 - 2026-08-08

- Fixed Windows PowerShell 5.1 object-list conversion failures on large libraries.
- Added stage-specific error reporting.

## 1.0.1 - 2026-08-08

- Corrected PowerShell formula quoting.
- Removed Windows PowerShell 5.1 encoding hazards.
- Added a PowerShell parser check to the launcher.

## 1.0.0 - 2026-08-08

- Initial release.
