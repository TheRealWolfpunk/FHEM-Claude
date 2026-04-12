# FHEM-Claude

FHEM-Modul zur Anbindung der Anthropic Claude AI API. Ermöglicht Textanfragen, Bildanalyse, Smart-Home-Gerätesteuerung per Sprachbefehl (Function Calling) und mehr – direkt aus FHEM heraus.
Dieses Modul ist ein Fork von https://github.com/ahlers2mi/FHEM-Gemini.

### API-Kosten & Credits

Dieses Modul nutzt das Prepaid-System von Anthropic. Standardmäßig ist das Modell **claude-haiku-4-5** hinterlegt, da es für Hausautomations-Befehle das effizienteste Preis-Leistungs-Verhältnis bietet.

Pro 1.000 durchschnittlichen Interaktionen (Statusabfragen oder Schaltbefehle) fallen Kosten von etwa **1,50 $** an. Ein Startguthaben von **5 $** reicht somit für über 3.000 Anfragen. Bei einer täglichen Nutzung von 10 Befehlen deckt dies einen Zeitraum von rund **10 Monaten** ab. Der tatsächliche Verbrauch variiert je nach Umfang deiner FHEM-Geräteliste und der Komplexität der Aufgaben.

## Features

- 💬 Textfragen an Claude stellen
- 🖼️ Bilder analysieren (Dateipfad)
- 🏠 Smart-Home-Geräte per Sprachbefehl steuern (Function Calling)
- 📋 Geräte-Status abfragen und zusammenfassen lassen
- 🔄 Multi-Turn Chat-Verlauf (optional deaktivierbar)
- 🛡️ Whitelist-basierte Gerätekontrolle (nur explizit freigegebene Geräte)

## Voraussetzungen

- FHEM-Installation (Perl-basiert)
- Anthropic Claude API Key ([hier erhalten - kostenpflichtig, siehe oben](https://platform.claude.com))

## Installation

### Erstmalig laden

```
update all https://raw.githubusercontent.com/TheRealWolfpunk/FHEM-Claude/main/controls_Claude.txt
shutdown restart
```

### Für automatische Updates (zusammen mit `update all`)

```
update add https://raw.githubusercontent.com/TheRealWolfpunk/FHEM-Claude/main/controls_Claude.txt
```

Danach wird das Modul bei jedem `update all` automatisch aktualisiert.

## Einrichtung

### 1. Gerät definieren

```
define ClaudeAI Claude
```

### 2. API Key setzen

```
attr ClaudeAI apiKey DEIN-ANTHROPIC-CLAUDE-API-KEY
```

### 3. Optional: Modell wählen

```
attr ClaudeAI model claude-haiku-4-5
```

Das ist bereits der Standard. Aus Kostengründen sollte man auch bei diesem Modell bleiben. Andere verfügbare Modelle: `claude-sonnet-4-6`, `claude-opus-4-6`

Eine aktuelle Übersicht der Modelle gibt es hier: https://platform.claude.com/docs/en/about-claude/models/overview

## Verwendung

### Textfrage stellen

```
set ClaudeAI ask Wie ist das Wetter morgen in Berlin?
```

### Bild analysieren

```
set ClaudeAI askWithImage /opt/fhem/www/snapshot.jpg Was ist auf diesem Bild zu sehen?
```

Unterstützte Bildformate: `jpg`/`jpeg`, `png`, `gif`, `webp`, `bmp`, `heic`, `heif`.

### Geräte-Status abfragen

```
attr ClaudeAI deviceList Lampe1,Heizung,Rolladen1
set ClaudeAI askAboutDevices Welche Geräte sind gerade eingeschaltet?
```

Alternativ alle Geräte eines Raums automatisch einbeziehen:

```
attr ClaudeAI deviceRoom Wohnzimmer,Küche
set ClaudeAI askAboutDevices Gib mir eine Zusammenfassung aller Geräte.
```

Mit dem Wildcard `*` werden **alle** in FHEM definierten Geräte einbezogen:

```
attr ClaudeAI deviceList *
set ClaudeAI askAboutDevices Welche Geräte sind gerade aktiv?
```

### Geräte per Sprachbefehl steuern (Function Calling)

```
attr ClaudeAI controlList Lampe1,Heizung,Rolladen1
set ClaudeAI control Mach die Wohnzimmerlampe an
set ClaudeAI control Stelle die Heizung auf 21 Grad
set ClaudeAI control Fahre alle Rolläden runter
```

Claude löst Alias-Namen automatisch auf interne FHEM-Namen auf und wählt passende `set`-Befehle selbstständig aus. Nur Geräte aus `controlList` dürfen gesteuert werden.

Claude kann im Rahmen eines `control`-Befehls auch den aktuellen Status eines Geräts selbstständig abfragen (z. B. um zu prüfen, ob eine Lampe bereits an ist), bevor es einen Steuerbefehl absetzt.

### Chat zurücksetzen

```
set ClaudeAI resetChat
```

### Chat-Verlauf anzeigen

```
get ClaudeAI chatHistory
```

## Attribute

| Attribut | Beschreibung | Standard |
|---|---|---|
| `apiKey` | Anthropic Claude API Key (Pflicht) | – |
| `model` | Claude Modell | `claude-haiku-4-5` |
| `maxHistory` | Maximale Anzahl Chat-Nachrichten | `20` |
| `systemPrompt` | Optionaler System-Prompt | – |
| `timeout` | HTTP Timeout in Sekunden | `30` |
| `disable` | Modul deaktivieren (0/1) | `0` |
| `disableHistory` | Chat-Verlauf deaktivieren (0/1); jede Anfrage wird ohne vorherigen Verlauf an die API gesendet. Der interne Verlauf bleibt erhalten (für `resetChat`), wird aber nicht übertragen. | `0` |
| `deviceList` | Komma-getrennte Geräteliste für `askAboutDevices`; `*` bezieht alle FHEM-Geräte ein | – |
| `deviceRoom` | Komma-getrennte Raumliste; alle Geräte mit passendem `room`-Attribut werden für `askAboutDevices` verwendet | – |
| `controlList` | Komma-getrennte Liste der Geräte, die Claude steuern darf (Pflicht für `control`) | – |

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
| `lastCommand` | Letzter ausgeführter set-Befehl (z.B. `Lampe1 on`) |
| `lastCommandResult` | Ergebnis des letzten set-Befehls (`ok` oder Fehlermeldung) |

## Lizenz

Dieses Modul ist ein Community-Beitrag und steht unter der [GNU General Public License v2](https://www.gnu.org/licenses/gpl-2.0.html), entsprechend der FHEM-Lizenz.
