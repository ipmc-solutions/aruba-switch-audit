## Panoramica

**Aruba & HPE Switch Audit Tool** è uno script PowerShell progettato per automatizzare l'inventario, la verifica dello stato operativo e l'estrazione delle configurazioni da apparati di rete multi-vendor. 

### Caratteristiche principali:
- **Supporto multi-protocollo**: Tenta la connessione via SSH (porta 22) con fallback automatico su Telnet (porta 23).
- **Riconoscimento OS automatico**: Rileva dinamicamente i sistemi operativi HPE Comware, ArubaOS-CX e ArubaOS-S / ProCurve, adattando la sequenza dei comandi diagnostici.
- **Gestione credenziali sicura**: Supporta set multipli di credenziali con fallback automatico tramite file esterno JSON o richiesta interattiva.
- **Report consolidato**: Salva l'output formattato e ripulito dai caratteri di controllo del terminale (ANSI/VT100) in un unico file cumulativo UTF-8.
