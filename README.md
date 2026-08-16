# Jellyfin Movie Inventory

A small Windows desktop app that connects to a Jellyfin server and exports a user's movie library to a formatted Excel workbook. It preserves user-specific watched status, handles libraries with thousands of movies, and does not require Microsoft Excel.

## Exported workbook

The generated `.xlsx` contains seven worksheets:

1. Summary
2. All Movies
3. Unwatched Movies
4. Watched Movies
5. Potential Duplicates
6. Metadata Issues
7. Recommendation Queue

Movie rows include available Jellyfin metadata such as title, year, runtime, genres, director, ratings, content rating, library, file path, resolution, HDR status, watched state, play count, last played date, favorite status, and Jellyfin item ID.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1, included with Windows
- Network access to a Jellyfin server

Excel is not required to create the workbook.

## Run the app

1. Download or clone this repository.
2. Double-click `START Jellyfin Movie Inventory.bat`.
3. Enter the Jellyfin server URL, username, and password.
4. Choose an output location.
5. Click **Export Movie Inventory**.

The default server address is `http://localhost:8096`. Replace it with the address of your Jellyfin server if Jellyfin runs elsewhere.

If Windows blocks a downloaded script, right-click the downloaded ZIP before extracting it, choose **Properties**, select **Unblock**, and extract it again.

## Privacy and security

- Inventory processing happens locally on the Windows PC.
- The password is never written to disk, the registry, the log, or the workbook.
- The password field is cleared after successful authentication.
- The Jellyfin access token exists only in memory while the app is running.
- The app sends requests only to the Jellyfin server URL entered in the window.
- Plain HTTP does not encrypt credentials in transit. Use HTTP only on a trusted local network, or configure HTTPS for the Jellyfin server.

The app creates `JellyfinMovieInventory.log` beside the PowerShell script. If that folder is not writable, it falls back to the Windows temporary folder. The log excludes passwords and access tokens.

## What v1.0.3 fixed

Version 1.0.3 uses an explicit XLSX packager so Windows ZIP entries use the forward slashes required by the Excel file format. It also validates the completed workbook, writes a persistent diagnostic log, and preserves temporary workbook files after a failed export.

## Troubleshooting

- **Could not connect:** Confirm the server URL and that the PC can reach Jellyfin.
- **Rejected username or password:** Re-enter the Jellyfin credentials.
- **Zero movies:** Confirm the user has access to the movie libraries.
- **Blank library names:** The export still works; Jellyfin may not expose a parent library for every item.
- **Cannot overwrite the workbook:** Close the existing output file in Excel and retry.

## License

MIT. See [LICENSE](LICENSE).

This project is not affiliated with, endorsed by, or sponsored by Jellyfin. Jellyfin is a trademark of its respective owner.
