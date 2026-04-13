# FHEM-Claude

Version: 1.2.0

FHEM-Modul zur Anbindung der Anthropic Claude AI API. Ermöglicht Textanfragen, Bildanalyse, Smart-Home-Gerätesteuerung per Sprachbefehl und mehr – direkt aus FHEM heraus.
Dieses Modul ist ein Fork von https://github.com/ahlers2mi/FHEM-Gemini.

### API-Kosten & Credits

Dieses Modul nutzt das Prepaid-System von Anthropic. Standardmäßig ist das Modell **claude-haiku-4-5** hinterlegt, weil es aktuell das kostengünstigste Claude-Modell ist und für typische Hausautomations-Anfragen in der Regel ein sehr passendes Verhältnis aus Leistung und laufenden Kosten bietet.

Pro 1.000 durchschnittlichen Interaktionen (Statusabfragen oder Schaltbefehle) fallen grob etwa **1,50 $** an. Ein Startguthaben von **5 $** reicht damit oft bereits für über 3.000 Anfragen. Bei einer täglichen Nutzung von 10 Befehlen kann das für rund **10 Monate** ausreichen. Der tatsächliche Verbrauch hängt vom Umfang deiner FHEM-Geräteliste, vom gesendeten Kontext und von der Komplexität der Aufgaben ab.

Wichtig für die Praxis: Wenn der `localControlResolver` aktiv ist, werden viele einfache und eindeutige Steuerbefehle direkt lokal in FHEM ausgeführt. Für diese Fälle ist kein zusätzlicher Claude-API-Aufruf nötig. Das spart im Alltag Tokens und damit laufende Kosten spürbar, sodass die Nutzung von Claude in FHEM für typische Steueraufgaben meist gut bezahlbar bleibt.

## Features

- 💬 Textfragen an Claude stellen
- 🖼️ Bilder analysieren (Dateipfad)
- 🏠 Smart-Home-Geräte per Sprachbefehl steuern
- ⚡ Claude-Hybridbetrieb (Lokalmodus) mit lokalem Resolver und Claude-Fallback
- 🚀 Viele einfache Befehle direkt lokal ausführen, ohne zusätzlichen API-Call
- 📋 Geräte-Status abfragen und zusammenfassen lassen
- 🧹 Konfigurierbare `readingBlacklist` mit Wildcard-Support für kompaktere Kontexte
- 📝 Optionales `comment`-Attribut der Geräte zusätzlich als semantische Beschreibung
- 🔄 Multi-Turn Chat-Verlauf (optional deaktivierbar)
- 🛡️ Whitelist-basierte Gerätekontrolle (nur explizit freigegebene Geräte)

## Voraussetzungen

- FHEM-Installation (Perl-basiert)
- Anthropic Claude API Key ([hier erhalten - kostenpflichtig, siehe oben](https://platform.claude.com))

## Installation

### Erstmalig laden

```text
update all https://raw.githubusercontent.com/TheRealWolfpunk/FHEM-Claude/main/controls_Claude.txt
shutdown restart
```

### Für automatische Updates (zusammen mit `update all`)

```text
update add https://raw.githubusercontent.com/TheRealWolfpunk/FHEM-Claude/main/controls_Claude.txt
```

Danach wird das Modul bei jedem `update all` automatisch aktualisiert.

## Einrichtung

### 1. Gerät definieren

```text
define ClaudeAI Claude
```

### 2. API Key setzen

```text
attr ClaudeAI apiKey DEIN-ANTHROPIC-CLAUDE-API-KEY
```

### 3. Optional: Modell wählen

```text
attr ClaudeAI model claude-haiku-4-5
```

Das ist bereits der Standard und für typische FHEM-Anwendungen meist eine sehr gute Wahl. Gleichzeitig ist **claude-haiku-4-5** aktuell das kostengünstigste verfügbare Claude-Modell. Andere verfügbare Modelle: `claude-sonnet-4-6`, `claude-opus-4-6`

Eine aktuelle Übersicht der Modelle gibt es hier: https://platform.claude.com/docs/en/about-claude/models/overview

## Verwendung

### Textfrage stellen

```text
set ClaudeAI ask Wie ist das Wetter morgen in Berlin?
```

### Bild analysieren

```text
set ClaudeAI askWithImage /opt/fhem/www/snapshot.jpg Was ist auf diesem Bild zu sehen?
```

Unterstützte Bildformate: `jpg`/`jpeg`, `png`, `gif`, `webp`.

### Geräte-Status abfragen

```text
attr ClaudeAI deviceList Lampe1,Heizung,Rolladen1
set ClaudeAI askAboutDevices Welche Geräte sind gerade eingeschaltet?
```

Alternativ alle Geräte eines Raums automatisch einbeziehen:

```text
attr ClaudeAI deviceRoom Wohnzimmer,Küche
set ClaudeAI askAboutDevices Gib mir eine Zusammenfassung aller Geräte.
```

Mit dem Wildcard `*` werden **alle** in FHEM definierten Geräte einbezogen:

```text
attr ClaudeAI deviceList *
set ClaudeAI askAboutDevices Welche Geräte sind gerade aktiv?
```

### Geräte per Sprachbefehl steuern

```text
attr ClaudeAI controlList Lampe1,Heizung,Rolladen1
set ClaudeAI control Mach die Wohnzimmerlampe an
set ClaudeAI control Stelle die Heizung auf 21 Grad
set ClaudeAI control Fahre alle Rolläden runter
```

Nur Geräte aus `controlList` dürfen gesteuert werden.

### Readings und Befehle gezielt aus dem Kontext ausschließen

Mit `readingBlacklist` lassen sich technisch wenig hilfreiche oder sehr
umfangreiche Readings bzw. Befehlsnamen gezielt aus dem an Claude gesendeten
Kontext herausfiltern. Das hilft, den übertragenen Kontext kompakter zu halten.

```text
attr ClaudeAI readingBlacklist R-* Wifi_* battery
```

- die Liste ist leerzeichen-getrennt
- Wildcards mit `*` werden unterstützt
- die Blacklist wird auf `askAboutDevices`, den `control`-Kontext und
  `get_device_state` angewendet
- zusätzlich gibt es eine interne Standard-Blacklist für typische technische
  Einträge, die für Claude meist wenig hilfreich sind

Wenn bei FHEM-Geräten das Attribut `comment` gepflegt ist, wird dieses außerdem
zusätzlich als Beschreibung in den Device- und Control-Kontext übernommen.

## Claude-Hybridbetrieb (Lokalmodus) mit lokalem Resolver

Wenn `localControlResolver` aktiviert ist, arbeitet das Modul im Hybridbetrieb:

1. **Lokaler Resolver zuerst**
   - viele einfache und eindeutige Steuerbefehle werden direkt in FHEM ausgeführt
   - dafür wird in diesen Fällen kein zusätzlicher Claude-API-Call ausgelöst
   - das spart im Alltag Tokens und damit laufende Kosten
   - typische Standardschaltungen reagieren dadurch in der Praxis meist sehr direkt

2. **Claude als Fallback für komplexere Sprache**
   - komplexe, mehrdeutige oder freier formulierte Anweisungen werden weiterhin von Claude verarbeitet
   - dadurch bleibt die Sprachsteuerung flexibel, ohne dass einfache Befehle immer über die API laufen müssen

Der lokale Resolver übernimmt viele typische Standardschaltungen direkt in FHEM. Das spart im Alltag unnötige API-Aufrufe und hilft dabei, die laufenden Kosten für Claude in FHEM überschaubar zu halten. Für komplexere Sprache bleibt Claude im Hintergrund weiterhin verfügbar.

Aktivieren oder deaktivieren:

```text
attr ClaudeAI localControlResolver 1
```

bzw.

```text
attr ClaudeAI localControlResolver 0
```

Bei `1` ist der lokale Resolver aktiv.  
Bei `0` läuft jeder `control`-Befehl vollständig über Claude.

### Typische Vorteile

- viele einfache Standardbefehle werden direkt in FHEM ausgeführt
- für lokal aufgelöste Befehle ist kein zusätzlicher API-Aufruf nötig
- das spart im Alltag Tokens und damit laufende Kosten
- Claude bleibt trotzdem für schwierigere Fälle verfügbar

### Typische Grenzen

- der lokale Resolver arbeitet bewusst konservativ
- er übernimmt nur Befehle, die sicher und eindeutig auflösbar sind
- freie oder sehr indirekte Sprache landet weiterhin beim Claude-Fallback
- komplexe Semantik, Szenenlogik oder unklare Zielmengen werden lokal bewusst nicht „erraten“

### Typische Fälle, die oft lokal funktionieren

- Alias-Treffer auf genau ein Gerät  
  z. B. `mach Stehlampe an`
- eindeutige Kombinationen aus Raum + Gerätetyp + einfachem Schaltkommando  
  z. B. `mach die Lampen im Wohnzimmer an`
- referenzielle Folgeanweisungen auf die letzte Zielmenge  
  z. B. `mach sie wieder aus`

### Typische Fälle, die weiterhin über Claude laufen

- komplexe oder freie Semantik  
  z. B. `mach es gemütlicher`
- nicht eindeutig auflösbare Sprache
- komplexere Wert- oder Parameteranweisungen
- Fälle, in denen zuerst Zustände geprüft oder interpretiert werden sollen

Claude löst im Fallback Alias-Namen automatisch auf interne FHEM-Namen auf, kann passende `set`-Befehle wählen und bei Bedarf auch den Status eines Geräts selbstständig abfragen, bevor ein Steuerbefehl abgesetzt wird.

### Chat zurücksetzen

```text
set ClaudeAI resetChat
```

### Chat-Verlauf anzeigen

```text
get ClaudeAI chatHistory
```

## Attribute

| Attribut | Beschreibung | Standard |
|---|---|---|
| `apiKey` | Anthropic Claude API Key (Pflicht) | – |
| `model` | Claude Modell | `claude-haiku-4-5` |
| `maxHistory` | Maximale Anzahl Chat-Nachrichten; weniger Verlauf hält den mitgesendeten Kontext kleiner | `10` |
| `maxTokens` | Maximale Antwortlänge; ohne gesetztes Attribut werden je nach Anfrageart Fallback-Werte verwendet: `600` für `ask`/`askAboutDevices`, `300` für `control`/Tool Use | – |
| `timeout` | HTTP Timeout in Sekunden | `30` |
| `disable` | Modul deaktivieren (`0/1`) | `0` |
| `disableHistory` | Chat-Verlauf deaktivieren (`0/1`); jede Anfrage wird als eigenständiges Gespräch behandelt | `0` |
| `promptCaching` | Prompt-Caching via Claude API aktivieren (`0/1`); wiederkehrende Prompts und Kontexte können dadurch effizienter verarbeitet werden | `0` |
| `deviceContextMode` | Kontext für `askAboutDevices`: `compact` oder `detailed`; `compact` hält den Kontext kleiner, `detailed` liefert mehr Informationen | `detailed` |
| `controlContextMode` | Kontext für `control`: `compact` oder `detailed`; `compact` hält den Kontext kleiner, `detailed` liefert mehr Informationen | `detailed` |
| `localControlResolver` | Aktiviert den lokalen Resolver für den Claude-Hybridbetrieb (`0/1`); einfache und eindeutige `control`-Befehle werden direkt in FHEM ausgeführt, komplexere Fälle laufen weiter über Claude | `1` |
| `readingBlacklist` | Leerzeichen-getrennte Liste von Reading- oder Befehlsnamen, die nicht an Claude übermittelt werden; Wildcards wie `R-*` oder `Wifi_*` werden unterstützt; gilt für Device-/Control-Kontext und `get_device_state` | – |
| `deviceList` | Komma-getrennte Geräteliste für `askAboutDevices`; `*` bezieht alle FHEM-Geräte ein | – |
| `controlList` | Komma-getrennte Liste der Geräte, die Claude steuern darf (Pflicht für `control`) | – |
| `deviceRoom` | Komma-getrennte Raumliste; Geräte mit passendem `room`-Attribut werden automatisch für `askAboutDevices` verwendet | – |
| `systemPrompt` | Optionaler System-Prompt; längere Prompts erhöhen den mitgesendeten Kontext pro Anfrage | – |

## Readings

| Reading | Beschreibung |
|---|---|
| `response` | Letzte Textantwort von Claude (Roh-Markdown) |
| `responsePlain` | Letzte Textantwort, Markdown-Syntax entfernt (reiner Text, ideal für Telegram, Notify) |
| `responseHTML` | Letzte Textantwort, Markdown in HTML konvertiert (ideal für Tablet-UI, Web-Frontends) |
| `responseSSML` | Letzte Textantwort, für Sprachausgabe bereinigt und als SSML aufbereitet |
| `state` | Aktueller Status (`initialized`, `requesting...`, `ok`, `error`, `disabled`) |
| `lastError` | Letzter Fehler |
| `chatHistory` | Anzahl der Nachrichten im Chat-Verlauf |
| `lastCommand` | Letzter ausgeführter `set`-Befehl (z. B. `Lampe1 on`) |
| `lastCommandResult` | Ergebnis des letzten `set`-Befehls (`ok` oder Fehlermeldung) |

## Lizenz

Dieses Modul ist ein Community-Beitrag und steht unter der [GNU General Public License v2](https://www.gnu.org/licenses/gpl-2.0.html), entsprechend der FHEM-Lizenz.
