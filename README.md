Note: This parser has been deprecated in favor of iLEAPP.
Donwload iLEAPP in order to support the mobile installation logs artifact.

# iOS-Mobile-Installation-Logs-Parser 

## Bash version

`mib_parser.sh` ports the command-line Python parser to Bash 3.2 or newer
and the `sqlite3` command-line tool (both included with macOS). It does not
require Python at runtime.

```bash
bash mib_parser.sh -o bash-output mobile_installation.log.0 mobile_installation.log.1
```

Without file arguments, it reads `*.log.*` from the current directory.
Without `-o`, it writes to the current directory. Quote paths containing spaces;
use `--` before input filenames beginning with a dash.

Outputs are `mib.db` (the same `dimm` table), `Apps_State/InstalledApps.txt`,
`Apps_State/UninstalledApps.txt`, per-bundle reports in `Apps_Historical/`, and
`System_State/SystemState.txt`. Existing outputs are refused; choose a fresh
output directory for another run. Parsing failures leave no published reports.

The original seven event rules and state inference are preserved: the latest
event for each bundle determines its state, with destroying-container and
uninstalling-identifier events classified as uninstalled. Timestamp ties use
input order. Bundle identifiers include extensions and containers, so these
counts do not necessarily represent standalone apps or a full device inventory.
Newer log messages outside those original rules are not extracted.

Validation compared database rows and report bytes against the original Python
script, using the two supplied logs separately and together, bundled legacy
logs, and synthetic events. All six test methods passed, including checks for
empty input, overwrite protection, and invalid events.

![alt text](/images/mib_done.PNG "Usage example")

Script parses all the logs in the /private/var/installd/Library/Logs/MobileInstalation/*.log*

Script will produce a currently installed apps report, a uninstalled apps report and historical  
reports for both types per app. 

The types of rows extracted from the logs are for installed apps,  
moved containers, made live containers and destroyed containers.

Usage:  
  
1) Python 3.6.4 or newer.
2) Put the script in the same directory as the extracted mobile_installation.log.* files.
3) Run the script.  
4) Script will produce a SQLite database named mib.db.
5) Script will produce two directories named Apps_Historical and Apps_State. Apps_Historical contains text files per app with coresponding app entries. App_State contains two text files, one for installed apps and another for uninstalled apps.

In order to run the script again the script generated directories and SQLite db files need to be deleted or moved out of the running directory.  

Update on 1/17/2019  
Added:  
- Uninstall identifier events  
- Attempting delta patch events with version numbers  
- System reboot events  

Update 11/30/2019  
Added:  
- GUI version. Requires pip install easygui
